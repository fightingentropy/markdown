import Foundation

/// Talks to the local `claude` CLI (Claude Code) instead of calling an HTTP
/// API. This lets the note assistant reuse the user's Claude subscription —
/// no separate Anthropic API key required.
///
/// The CLI is invoked with `--output-format stream-json --verbose
/// --include-partial-messages`, which emits NDJSON that mirrors the
/// Anthropic Messages streaming format (`content_block_delta`, `message_stop`,
/// etc.). We translate those events into the same "accumulated-text" delta
/// contract the OpenAI client uses, so `NoteAssistant` barely notices the
/// difference.
struct ClaudeSubscriptionClient {
    enum ClientError: LocalizedError {
        case cliNotFound
        case processFailed(code: Int32, stderr: String)
        case emptyReply

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return """
                    Couldn't find the `claude` CLI on this Mac. Install Claude Code \
                    (https://claude.com/claude-code) or make sure it is available on your PATH.
                    """
            case .processFailed(let code, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return "The claude CLI exited with code \(code)."
                }
                return "The claude CLI failed: \(trimmed)"
            case .emptyReply:
                return "The claude CLI finished without returning a reply."
            }
        }
    }

    /// Runs the CLI with `prompt` as the user message (with optional extra
    /// system-prompt text) and streams back the accumulated reply text as it
    /// arrives. Returns the full reply on success.
    func streamReply(
        prompt: String,
        systemPrompt: String?,
        onDelta: @escaping @Sendable @MainActor (String) -> Void
    ) async throws -> String {
        guard let executable = Self.locateExecutable() else {
            throw ClientError.cliNotFound
        }

        // The subprocess reading loop is synchronous (it calls `Process`,
        // `Pipe`, and `FileHandle` APIs that aren't `Sendable`), so we keep
        // it entirely inside a detached task and bridge progress back via a
        // Sendable `AsyncThrowingStream<String, Error>`.
        let stream = AsyncThrowingStream<ProgressEvent, Error> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try Self.runProcess(
                        executable: executable,
                        prompt: prompt,
                        systemPrompt: systemPrompt
                    ) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }

        var accumulated = ""
        for try await event in stream {
            switch event {
            case .deltaText(let text):
                accumulated += text
                await onDelta(accumulated)
            case .finalResult(let final):
                // The CLI always emits a trailing `{"type":"result",...}` line
                // with the full reply. If we somehow missed the incremental
                // events (e.g. partial-messages disabled on an older CLI
                // build), this keeps the final reply consistent.
                if accumulated.isEmpty, !final.isEmpty {
                    accumulated = final
                    await onDelta(accumulated)
                }
            }
        }

        let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClientError.emptyReply
        }
        return accumulated
    }

    // MARK: - Subprocess

    private enum ProgressEvent: Sendable {
        case deltaText(String)
        case finalResult(String)
    }

    private static func runProcess(
        executable: URL,
        prompt: String,
        systemPrompt: String?,
        emit: (ProgressEvent) -> Void
    ) throws {
        let process = Process()
        process.executableURL = executable

        var arguments: [String] = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages"
        ]
        if let systemPrompt, !systemPrompt.isEmpty {
            arguments.append(contentsOf: ["--append-system-prompt", systemPrompt])
        }
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        var buffer = Data()

        while true {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }

            let chunk: Data
            do {
                chunk = try stdoutHandle.read(upToCount: 4096) ?? Data()
            } catch {
                process.terminate()
                throw error
            }
            if chunk.isEmpty {
                break
            }

            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)
                guard !lineData.isEmpty else { continue }
                guard let line = String(data: lineData, encoding: .utf8),
                      !line.isEmpty else { continue }

                if let delta = Self.extractDelta(from: line) {
                    emit(.deltaText(delta))
                } else if let final = Self.extractFinalResult(from: line) {
                    emit(.finalResult(final))
                } else if let apiError = Self.extractReportedError(from: line) {
                    process.terminate()
                    throw ClientError.processFailed(code: -1, stderr: apiError)
                }
            }
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.processFailed(code: process.terminationStatus, stderr: stderr)
        }
    }

    // MARK: - JSON line parsing

    private struct StreamEnvelope: Decodable {
        let type: String
        let event: Event?
        let result: String?
        let isError: Bool?

        enum CodingKeys: String, CodingKey {
            case type
            case event
            case result
            case isError = "is_error"
        }

        struct Event: Decodable {
            let type: String
            let delta: Delta?

            struct Delta: Decodable {
                let type: String?
                let text: String?
            }
        }
    }

    private static func extractDelta(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let env = try? JSONDecoder().decode(StreamEnvelope.self, from: data),
              env.type == "stream_event",
              let event = env.event,
              event.type == "content_block_delta",
              let delta = event.delta,
              delta.type == "text_delta",
              let text = delta.text else {
            return nil
        }
        return text
    }

    private static func extractFinalResult(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let env = try? JSONDecoder().decode(StreamEnvelope.self, from: data),
              env.type == "result",
              env.isError != true,
              let result = env.result else {
            return nil
        }
        return result
    }

    private static func extractReportedError(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let env = try? JSONDecoder().decode(StreamEnvelope.self, from: data),
              env.type == "result",
              env.isError == true else {
            return nil
        }
        return env.result ?? "Claude Code CLI reported an error."
    }

    // MARK: - Locating `claude`

    /// Finds the `claude` CLI by probing the common install locations and,
    /// if nothing is found there, asking the user's login shell. GUI apps
    /// launched from Finder inherit a minimal `PATH`, so we can't rely on
    /// `/usr/bin/env` to locate it.
    private static func locateExecutable() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates: [String] = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let resolved = Self.resolveViaLoginShell(),
           fileManager.isExecutableFile(atPath: resolved) {
            return URL(fileURLWithPath: resolved)
        }

        return nil
    }

    private static func resolveViaLoginShell() -> String? {
        let process = Process()
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-c", "command -v claude"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty == false) ? output : nil
    }
}
