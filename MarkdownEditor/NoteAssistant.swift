import Foundation

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

    let id = UUID()
    let role: Role
    let text: String
    let createdAt = Date()
}

@Observable
@MainActor
final class NoteAssistant {
    var messages: [NoteAssistantMessage] = []
    var draft: String = ""
    var isPresented = false
    var isSending = false
    var errorMessage: String?
    private(set) var currentContext: NoteAssistantContext?

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
        messages.removeAll()
        draft = ""
        errorMessage = nil
        isSending = false
    }

    func sendCurrentDraft(using settings: AssistantSettings) async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            errorMessage = "Enter a question first."
            return
        }

        guard settings.isConfigured else {
            errorMessage = "Add your OpenCode API key in Settings first."
            return
        }

        guard let context = currentContext else {
            errorMessage = "Open a note first so the assistant has file context."
            return
        }

        let userMessage = NoteAssistantMessage(role: .user, text: prompt)
        messages.append(userMessage)
        draft = ""
        errorMessage = nil
        isSending = true
        let configuration = AssistantRequestConfiguration(
            apiKey: settings.apiKey,
            model: settings.selectedModel,
            endpoint: AssistantSettings.responsesEndpoint
        )

        do {
            let reply = try await NoteAssistantClient().reply(
                to: messages,
                context: context,
                configuration: configuration
            )
            guard currentContext?.fileURL == context.fileURL else {
                isSending = false
                return
            }
            messages.append(NoteAssistantMessage(role: .assistant, text: reply))
        } catch {
            guard currentContext?.fileURL == context.fileURL else {
                isSending = false
                return
            }
            errorMessage = error.localizedDescription
            if messages.last?.id == userMessage.id {
                messages.removeLast()
                draft = prompt
            }
        }

        isSending = false
    }
}

private struct NoteAssistantClient {
    func reply(
        to messages: [NoteAssistantMessage],
        context: NoteAssistantContext,
        configuration: AssistantRequestConfiguration
    ) async throws -> String {
        let requestBody = ResponsesRequest(
            model: configuration.model,
            instructions: """
            You are a concise note assistant. Answer questions using the current markdown file as the primary source of truth. If the answer is not in the file, say so clearly. Prefer short direct answers, but use bullets when it improves clarity.
            """,
            input: makeInputMessages(messages: messages, context: context)
        )

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NoteAssistantError.invalidResponse("No HTTP response received.")
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
            throw NoteAssistantError.invalidResponse(
                apiError?.error.message ?? "OpenCode request failed with status \(httpResponse.statusCode)."
            )
        }

        let decoded = try JSONDecoder().decode(ResponsesResponse.self, from: data)
        let text = decoded.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw NoteAssistantError.invalidResponse("OpenCode returned an empty reply.")
        }

        return text
    }

    private func makeInputMessages(
        messages: [NoteAssistantMessage],
        context: NoteAssistantContext
    ) -> [ResponsesRequest.InputMessage] {
        let contextMessage = ResponsesRequest.InputMessage(
            role: "developer",
            text: """
            Current file path: \(context.fileURL.path)
            Current file title: \(context.title)

            Current markdown file contents:
            \(context.markdown)
            """
        )

        let historyMessages = messages.map { message in
            ResponsesRequest.InputMessage(
                role: message.role.rawValue,
                text: message.text
            )
        }

        return [contextMessage] + historyMessages
    }
}

private struct AssistantRequestConfiguration {
    let apiKey: String
    let model: String
    let endpoint: URL
}

private struct ResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: [InputMessage]

    struct InputMessage: Encodable {
        let type = "message"
        let role: String
        let content: [InputContent]

        init(role: String, text: String) {
            self.role = role
            self.content = [InputContent(text: text)]
        }
    }

    struct InputContent: Encodable {
        let type = "input_text"
        let text: String
    }
}

private struct ResponsesResponse: Decodable {
    let output: [OutputItem]

    var outputText: String {
        output
            .compactMap(\.content)
            .flatMap { $0 }
            .compactMap(\.text)
            .joined(separator: "\n")
    }

    struct OutputItem: Decodable {
        let content: [OutputContent]?
    }

    struct OutputContent: Decodable {
        let text: String?
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
