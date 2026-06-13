import Foundation
import Observation

struct NoteAssistantContext: Equatable {
    let fileURL: URL
    let title: String
    let markdown: String
}

struct NoteAssistantMessage: Identifiable, Hashable {
    enum Role: String, Hashable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
    let createdAt: Date
    let renderedMarkdown: AttributedString?

    /// `isFinal` gates the (relatively expensive) markdown parse. While a
    /// reply is still streaming we leave `renderedMarkdown` nil so the bubble
    /// renders the raw accumulated text via its plain-`Text` fallback; the
    /// AttributedString is built exactly once when the stream completes.
    /// Parsing on every delta is O(n^2) on the main actor for long replies.
    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        isFinal: Bool = true
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        if isFinal, role == .assistant, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.renderedMarkdown = try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
        } else {
            self.renderedMarkdown = nil
        }
    }
}

@Observable
@MainActor
final class NoteAssistant {
    var messages: [NoteAssistantMessage] = []
    var draft: String = ""
    var isPresented = false
    var isSending = false
    var errorMessage: String?
    @ObservationIgnored private(set) var currentContext: NoteAssistantContext?
    /// The in-flight request. Held so we can cancel it when the user switches
    /// files, closes the panel, resets the chat, or hits the stop control.
    /// Cancelling propagates through the streaming clients' `onTermination`
    /// hooks, which lets the `assistant` subprocess / URLSession task tear down
    /// instead of running to completion in the background.
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    /// Monotonic token identifying the active request. A cancelled/stale task
    /// only clears shared state (`sendTask`, `isSending`) if its generation is
    /// still current, so a late-finishing old request can't clobber a newer
    /// one that started right after a file switch or reset.
    @ObservationIgnored private var sendGeneration = 0

    func updateContext(fileURL: URL?, title: String, markdown: String) {
        guard let fileURL else {
            if currentContext != nil {
                reset()
            }
            currentContext = nil
            return
        }

        let nextContext = NoteAssistantContext(fileURL: fileURL, title: title, markdown: markdown)
        let didSwitchFiles = currentContext?.fileURL != nextContext.fileURL
        currentContext = nextContext
        errorMessage = nil

        if didSwitchFiles {
            reset()
        }
    }

    func reset() {
        cancelSending()
        messages.removeAll()
        draft = ""
        errorMessage = nil
        isSending = false
    }

    /// Cancels the in-flight request (if any) without otherwise clearing the
    /// transcript. Used by the composer's stop control and whenever the panel
    /// is dismissed while a reply is streaming.
    func stopStreaming() {
        guard isSending else { return }
        cancelSending()
        isSending = false
    }

    private func cancelSending() {
        sendTask?.cancel()
        sendTask = nil
        sendGeneration &+= 1
    }

    /// Synchronous entry point used by the UI. Owns the streaming `Task` so it
    /// can be cancelled from `reset()` / `stopStreaming()`.
    func send(using settings: AssistantSettings) {
        sendTask?.cancel()
        sendGeneration &+= 1
        let generation = sendGeneration
        sendTask = Task { [weak self] in
            await self?.sendCurrentDraft(using: settings, generation: generation)
        }
    }

    /// Clears `sendTask`/`isSending` only if `generation` is still the active
    /// request — guards against a stale task tearing down a newer one.
    private func finishRequest(generation: Int) {
        guard generation == sendGeneration else { return }
        sendTask = nil
        isSending = false
    }

    func togglePresentation() {
        isPresented.toggle()
    }

    func sendCurrentDraft(using settings: AssistantSettings, generation: Int = -1) async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            errorMessage = "Enter a question first."
            finishRequest(generation: generation)
            return
        }

        guard let model = AssistantSettings.model(for: settings.selectedModel) else {
            errorMessage = "Selected assistant model is not available."
            finishRequest(generation: generation)
            return
        }

        guard settings.isConfigured else {
            errorMessage = model.requiresAPIKey
                ? "Add your OpenAI API key in Settings first."
                : "Assistant isn't available right now."
            finishRequest(generation: generation)
            return
        }

        guard let context = currentContext else {
            errorMessage = "Open a note first so the assistant has file context."
            finishRequest(generation: generation)
            return
        }

        let userMessage = NoteAssistantMessage(role: .user, text: prompt)
        messages.append(userMessage)
        let requestMessages = messages
        let assistantMessage = NoteAssistantMessage(role: .assistant, text: "")
        messages.append(assistantMessage)
        draft = ""
        errorMessage = nil
        isSending = true
        let configuration = AssistantRequestConfiguration(
            apiKey: settings.apiKey,
            model: model,
            reasoningEffort: settings.selectedReasoningEffort.reasoningEffort.flatMap { effort in
                model.supportedReasoningEfforts.contains(effort) ? effort : nil
            }
        )

        do {
            switch model.apiStyle {
            case .chatCompletions:
                try await runChatCompletions(
                    requestMessages: requestMessages,
                    context: context,
                    configuration: configuration,
                    assistantMessageID: assistantMessage.id
                )
            case .assistantCodeCLI:
                try await runassistantSubscription(
                    requestMessages: requestMessages,
                    context: context,
                    assistantMessageID: assistantMessage.id
                )
            }
            // Build the markdown AttributedString exactly once, now that the
            // reply is complete (it was rendered as raw text while streaming).
            finalizeAssistantMessage(id: assistantMessage.id)
        } catch let error where Self.isCancellation(error) {
            // The request was cancelled (file switch / panel close / stop).
            // `URLSession` surfaces this as `URLError(.cancelled)` rather than
            // `CancellationError`, so both are treated the same here. Leave
            // whatever partial text arrived in place and finalize it so it
            // still renders as markdown; don't surface an error.
            finalizeAssistantMessage(id: assistantMessage.id)
            removeEmptyAssistantMessage(
                assistantMessageID: assistantMessage.id,
                userMessageID: userMessage.id,
                prompt: prompt
            )
            finishRequest(generation: generation)
            return
        } catch {
            guard currentContext?.fileURL == context.fileURL else {
                finishRequest(generation: generation)
                return
            }
            errorMessage = error.localizedDescription
            removeEmptyAssistantMessage(
                assistantMessageID: assistantMessage.id,
                userMessageID: userMessage.id,
                prompt: prompt
            )
        }

        finishRequest(generation: generation)
    }

    private func removeEmptyAssistantMessage(
        assistantMessageID: UUID,
        userMessageID: UUID,
        prompt: String
    ) {
        let partialReply = assistantMessageText(for: assistantMessageID)
        guard partialReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messages.removeAll { $0.id == assistantMessageID }
        if messages.last?.id == userMessageID {
            messages.removeLast()
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = prompt
            }
        }
    }

    private func runChatCompletions(
        requestMessages: [NoteAssistantMessage],
        context: NoteAssistantContext,
        configuration: AssistantRequestConfiguration,
        assistantMessageID: UUID
    ) async throws {
        let streamedReply = try await NoteAssistantClient().streamReply(
            to: requestMessages,
            context: context,
            configuration: configuration
        ) { [weak self] partialReply in
            guard let self else { return }
            self.updateAssistantMessage(id: assistantMessageID, text: partialReply)
        }
        guard currentContext?.fileURL == context.fileURL else { return }

        if streamedReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallbackReply = try await NoteAssistantClient().reply(
                to: requestMessages,
                context: context,
                configuration: configuration
            )
            guard currentContext?.fileURL == context.fileURL else { return }
            updateAssistantMessage(id: assistantMessageID, text: fallbackReply)
        }
    }

    private func runassistantSubscription(
        requestMessages: [NoteAssistantMessage],
        context: NoteAssistantContext,
        assistantMessageID: UUID
    ) async throws {
        let prompts = assistantSubscriptionPromptBuilder.build(
            messages: requestMessages,
            context: context
        )
        _ = try await assistantSubscriptionClient().streamReply(
            prompt: prompts.userPrompt,
            systemPrompt: prompts.systemPrompt
        ) { [weak self] partialReply in
            guard let self else { return }
            self.updateAssistantMessage(id: assistantMessageID, text: partialReply)
        }
    }

    private func updateAssistantMessage(id: UUID, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let existing = messages[index]
        messages[index] = NoteAssistantMessage(
            id: existing.id,
            role: existing.role,
            text: text,
            createdAt: existing.createdAt,
            isFinal: false
        )
    }

    /// Re-creates the message with `isFinal: true` so its markdown is parsed
    /// once after streaming completes (or is cancelled).
    private func finalizeAssistantMessage(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let existing = messages[index]
        guard existing.renderedMarkdown == nil else { return }
        messages[index] = NoteAssistantMessage(
            id: existing.id,
            role: existing.role,
            text: existing.text,
            createdAt: existing.createdAt,
            isFinal: true
        )
    }

    private func assistantMessageText(for id: UUID) -> String {
        messages.first(where: { $0.id == id })?.text ?? ""
    }

    /// True for both Swift structured-concurrency cancellation and the
    /// `URLError(.cancelled)` that `URLSession` raises when its task is
    /// cancelled, so cancelling a request never looks like a real failure.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }
}

private struct NoteAssistantClient {
    /// Dedicated session with explicit timeouts so a stalled OpenAI
    /// connection fails instead of leaving the assistant spinning forever.
    /// `timeoutIntervalForRequest` bounds the gap between bytes (important for
    /// the SSE stream, where the body stays open), while
    /// `timeoutIntervalForResource` caps the whole exchange.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    func streamReply(
        to messages: [NoteAssistantMessage],
        context: NoteAssistantContext,
        configuration: AssistantRequestConfiguration,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        guard configuration.model.apiStyle == .chatCompletions else {
            throw NoteAssistantError.invalidResponse(
                "This model cannot be used over the chat-completions API."
            )
        }

        var request = URLRequest(url: configuration.model.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        let requestBody = ChatCompletionsRequest(
            model: configuration.model.id,
            messages: makeChatMessages(messages: messages, context: context),
            reasoningEffort: configuration.requestReasoningEffort,
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NoteAssistantError.invalidResponse("No HTTP response received.")
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let data = try await collectData(from: bytes)
            let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
            throw NoteAssistantError.invalidResponse(
                apiError?.error.message ?? "OpenAI request failed with status \(httpResponse.statusCode)."
            )
        }

        return try await consumeChatCompletionsStream(bytes: bytes, onDelta: onDelta)
    }

    func reply(
        to messages: [NoteAssistantMessage],
        context: NoteAssistantContext,
        configuration: AssistantRequestConfiguration
    ) async throws -> String {
        guard configuration.model.apiStyle == .chatCompletions else {
            throw NoteAssistantError.invalidResponse(
                "This model cannot be used over the chat-completions API."
            )
        }

        var request = URLRequest(url: configuration.model.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")

        let requestBody = ChatCompletionsRequest(
            model: configuration.model.id,
            messages: makeChatMessages(messages: messages, context: context),
            reasoningEffort: configuration.requestReasoningEffort,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await Self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NoteAssistantError.invalidResponse("No HTTP response received.")
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
            throw NoteAssistantError.invalidResponse(
                apiError?.error.message ?? "OpenAI request failed with status \(httpResponse.statusCode)."
            )
        }

        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        let text = decoded.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw NoteAssistantError.invalidResponse("OpenAI returned an empty reply.")
        }
        return text
    }

    private func makeChatMessages(
        messages: [NoteAssistantMessage],
        context: NoteAssistantContext
    ) -> [ChatCompletionsRequest.Message] {
        let systemMessage = ChatCompletionsRequest.Message(
            role: "system",
            content: """
            You are a concise note assistant. Answer questions using the current markdown file as the primary source of truth. If the answer is not in the file, say so clearly. Prefer short direct answers, but use bullets when it improves clarity.
            """
        )

        // Send only the file name, never the absolute path. The full path
        // leaks the macOS username and directory structure to a third party
        // (OpenAI) and isn't needed to answer questions about the note.
        let contextMessage = ChatCompletionsRequest.Message(
            role: "system",
            content: """
            Current file name: \(context.fileURL.lastPathComponent)
            Current file title: \(context.title)

            Current markdown file contents:
            \(context.markdown)
            """
        )

        let historyMessages = messages.map { message in
            ChatCompletionsRequest.Message(
                role: message.role.rawValue,
                content: message.text
            )
        }

        return [systemMessage, contextMessage] + historyMessages
    }

    private func consumeChatCompletionsStream(
        bytes: URLSession.AsyncBytes,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        var accumulatedText = ""

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            try await processSSEData(
                data,
                accumulatedText: &accumulatedText,
                onDelta: onDelta
            )
        }

        return accumulatedText
    }

    private func processSSEData(
        _ payload: String,
        accumulatedText: inout String,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws {
        guard payload != "[DONE]" else { return }

        let data = Data(payload.utf8)
        if let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
            throw NoteAssistantError.invalidResponse(apiError.error.message)
        }

        guard let chunk = try? JSONDecoder().decode(ChatCompletionsChunk.self, from: data) else {
            return
        }

        for choice in chunk.choices {
            if let content = choice.delta.content, !content.isEmpty {
                accumulatedText += content
                await onDelta(accumulatedText)
            }
        }
    }

    private func collectData(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }
}

private struct AssistantRequestConfiguration {
    let apiKey: String
    let model: AssistantModel
    let reasoningEffort: AssistantReasoningEffort?

    /// The `reasoning_effort` value to put in the chat-completions request
    /// body, or nil to omit the field entirely. We only ever send it for
    /// models that actually advertise reasoning support (non-empty
    /// `supportedReasoningEfforts`) and only for an effort that model lists,
    /// so non-reasoning models never receive an invalid `reasoning_effort`.
    var requestReasoningEffort: String? {
        guard !model.supportedReasoningEfforts.isEmpty,
              let effort = reasoningEffort,
              model.supportedReasoningEfforts.contains(effort) else {
            return nil
        }
        return effort.rawValue
    }
}

private struct ChatCompletionsRequest: Encodable {
    let model: String
    let messages: [Message]
    let reasoningEffort: String?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case reasoningEffort = "reasoning_effort"
        case stream
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ChatCompletionsChunk: Decodable {
    struct Choice: Decodable {
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let content: String?
    }

    let choices: [Choice]
}

private struct ChatCompletionsResponse: Decodable {
    let choices: [Choice]

    var outputText: String {
        choices
            .compactMap(\.message.content)
            .joined(separator: "\n")
    }

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}

private struct APIErrorEnvelope: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let message: String
    }
}

private enum NoteAssistantError: LocalizedError {
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message):
            return message
        }
    }
}

/// Serialises the in-memory chat history + note context into the two-part
/// prompt shape the `assistant` CLI wants: a system-prompt addendum carrying
/// the note body, and a user-facing prompt that includes prior turns as
/// plain text (since a one-shot `assistant -p` invocation doesn't carry a
/// multi-turn session across calls).
enum assistantSubscriptionPromptBuilder {
    struct Prompts {
        let systemPrompt: String
        let userPrompt: String
    }

    static func build(
        messages: [NoteAssistantMessage],
        context: NoteAssistantContext
    ) -> Prompts {
        let systemPrompt = """
        You are a concise note assistant embedded in a macOS Markdown editor. \
        Answer questions using the current markdown file as the primary source of \
        truth. If the answer is not in the file, say so clearly. Prefer short \
        direct answers, but use bullets when it improves clarity. Do not call \
        any tools — respond with plain markdown text only.

        Current file name: \(context.fileURL.lastPathComponent)
        Current file title: \(context.title)

        Current markdown file contents:
        \(context.markdown)
        """

        // Every message up to (but not including) the last user message is
        // prior context; the final user message is the prompt to answer. The
        // caller always appends the latest user message before invoking us.
        guard let latestUser = messages.last(where: { $0.role == .user }) else {
            return Prompts(systemPrompt: systemPrompt, userPrompt: "")
        }

        let priorMessages = messages
            .prefix(while: { $0.id != latestUser.id })
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if priorMessages.isEmpty {
            return Prompts(systemPrompt: systemPrompt, userPrompt: latestUser.text)
        }

        var transcript = "Previous conversation (for context):\n\n"
        for message in priorMessages {
            let speaker = message.role == .user ? "User" : "Assistant"
            transcript += "\(speaker): \(message.text)\n\n"
        }
        transcript += "Current user message:\n\(latestUser.text)"
        return Prompts(systemPrompt: systemPrompt, userPrompt: transcript)
    }
}
