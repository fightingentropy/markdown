import Foundation

/// Talks to the local `assistant` CLI (assistant Code) instead of calling an HTTP
/// API. This lets the note assistant reuse the user's assistant subscription —
/// no separate provider API key required.
///
/// The CLI is invoked with `--output-format stream-json --verbose
/// --include-partial-messages`, which emits NDJSON that mirrors the
/// provider Messages streaming format (`content_block_delta`, `message_stop`,
/// etc.). We translate those events into the same "accumulated-text" delta
/// contract the OpenAI client uses, so `NoteAssistant` barely notices the
/// difference.
struct assistantSubscriptionClient {
    enum ClientError: LocalizedError {
        case cliNotFound
        case processFailed(code: Int32, stderr: String)
        case emptyReply
        case timedOut

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return """
                    Couldn't find the `assistant` CLI on this Mac. Install assistant Code \
                    (https://assistant.com/assistant-code) or make sure it is available on your PATH.
                    """
            case .processFailed(let code, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return "The assistant CLI exited with code \(code)."
                }
                return "The assistant CLI failed: \(trimmed)"
            case .emptyReply:
                return "The assistant CLI finished without returning a reply."
            case .timedOut:
                return "The assistant CLI timed out before returning a reply."
            }
        }
    }

    /// Runs the CLI with `prompt` as the user message (with optional extra
    /// system-prompt text) and streams back the accumulated reply text as it
    /// arrives. Sensitive prompt content is supplied through standard input,
    /// never through process arguments. Returns the full reply on success.
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
        //
        // `Task.detached` does NOT inherit the caller's cancellation, so we
        // hold the worker task in a box and cancel it explicitly both from the
        // stream's `onTermination` (consumer torn down) and from a task
        // cancellation handler (parent request cancelled on file switch /
        // panel close / stop). Cancelling makes `runProcess` see
        // `Task.isCancelled` and terminate the subprocess instead of letting
        // it run to completion in the background.
        let workerBox = WorkerTaskBox()
        let stream = AsyncThrowingStream<ProgressEvent, Error> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try Self.runProcess(
                        executable: executable,
                        prompt: prompt,
                        systemPrompt: systemPrompt,
                        terminationBox: workerBox
                    ) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            workerBox.task = task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                workerBox.terminate()
            }
        }

        return try await withTaskCancellationHandler {
            var accumulated = ""
            // Tracks whether the trailing `result` payload was authoritative
            // and non-empty. When it is, an empty final reply is a *valid*
            // empty model answer, not a failure, so we don't raise
            // `.emptyReply`.
            var sawNonEmptyResult = false
            var sawAuthoritativeResult = false
            for try await event in stream {
                switch event {
                case .deltaText(let text):
                    accumulated += text
                    await onDelta(accumulated)
                case .finalResult(let final):
                    // The CLI emits a trailing `{"type":"result",...}` line
                    // with the full reply. Treat it as authoritative: prefer
                    // it over the incrementally accumulated text whenever it is
                    // non-empty (this also covers older CLI builds where
                    // partial-messages were dropped). An explicitly empty
                    // result is a legitimate empty answer and is left as-is.
                    sawAuthoritativeResult = true
                    if !final.isEmpty {
                        accumulated = final
                        sawNonEmptyResult = true
                        await onDelta(accumulated)
                    }
                case .reportedError(let message):
                    throw ClientError.processFailed(code: -1, stderr: message)
                }
            }

            let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only treat an empty reply as a failure when the CLI never gave us
            // an authoritative (non-error) result to confirm it was intentional.
            guard !trimmed.isEmpty || (sawAuthoritativeResult && !sawNonEmptyResult) else {
                throw ClientError.emptyReply
            }
            return accumulated
        } onCancel: {
            workerBox.task?.cancel()
            workerBox.terminate()
        }
    }

    // MARK: - Subprocess

    enum ProgressEvent: Sendable, Equatable {
        case deltaText(String)
        case finalResult(String)
        case reportedError(String)
    }

    /// Wall-clock ceiling for a single CLI invocation. The `assistant` CLI is
    /// interactive and can block on auth or a wedged network connection, so
    /// we terminate it (then escalate to SIGKILL) if it overruns. Surfaced as
    /// a timeout error rather than hanging the assistant indefinitely.
    private static let processTimeout: TimeInterval = 120

    private static func runProcess(
        executable: URL,
        prompt: String,
        systemPrompt: String?,
        terminationBox: WorkerTaskBox,
        emit: (ProgressEvent) -> Void
    ) throws {
        let process = Process()
        process.executableURL = executable

        // `ps` and Activity Monitor expose process arguments to other local
        // processes. Both the request and note context therefore arrive on
        // stdin. assistant Code has no documented file-based system-prompt flag,
        // so the context is clearly delimited in the input instead of relying
        // on a non-portable CLI option.
        let promptInput = try SecureTemporaryFile(
            contents: Self.standardInputData(for: prompt, systemPrompt: systemPrompt)
        )
        try promptInput.unlinkFromFilesystem()
        process.standardInput = promptInput.fileHandle
        defer { withExtendedLifetime(promptInput) {} }
        process.arguments = Self.processArguments()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Let a cancellation (file switch / panel close / stop) terminate the
        // process directly, which unblocks the synchronous stdout read below
        // immediately instead of waiting for the next byte or the watchdog.
        // Signal by PID so the `@Sendable` hook never captures the non-Sendable
        // `Process`.
        let cancelPID = process.processIdentifier
        terminationBox.terminateAction = {
            kill(cancelPID, SIGTERM)
        }
        defer { terminationBox.terminateAction = nil }

        // Drain stderr concurrently on a background readability handler.
        // Reading it only after the process exits (as the old code did) could
        // deadlock: a verbose/erroring CLI that fills the 64KB stderr pipe
        // buffer blocks on write while we are still blocked reading stdout.
        let stderrCollector = StderrCollector()
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrCollector.append(data)
            }
        }

        // Wall-clock watchdog: terminate (then SIGKILL) the process if it
        // overruns, so a wedged/auth-blocked CLI can't hang the request. We
        // signal by PID (a Sendable `Int32`) rather than capturing the
        // non-Sendable `Process` inside the `@Sendable` timer handler.
        let pid = process.processIdentifier
        let timedOut = TimeoutFlag()
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        watchdog.schedule(deadline: .now() + Self.processTimeout)
        watchdog.setEventHandler {
            timedOut.set()
            kill(pid, SIGTERM)
            // Give it a moment to honor SIGTERM, then force-kill.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                kill(pid, SIGKILL)
            }
        }
        watchdog.resume()
        defer {
            watchdog.cancel()
            stderrHandle.readabilityHandler = nil
        }

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

                switch Self.parseLine(line) {
                case .deltaText(let delta):
                    emit(.deltaText(delta))
                case .finalResult(let final):
                    emit(.finalResult(final))
                case .reportedError(let message):
                    process.terminate()
                    throw ClientError.processFailed(code: -1, stderr: message)
                case nil:
                    continue
                }
            }
        }

        process.waitUntilExit()

        if timedOut.isSet {
            throw ClientError.timedOut
        }

        guard process.terminationStatus == 0 else {
            let stderr = stderrCollector.string
            throw ClientError.processFailed(code: process.terminationStatus, stderr: stderr)
        }
    }

    /// Arguments contain only fixed flags. Keeping prompt values out of this API makes it
    /// difficult to accidentally regress to exposing note contents in `ps`.
    static func processArguments() -> [String] {
        [
            "-p",
            "--input-format", "text",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages"
        ]
    }

    static func standardInputData(for prompt: String, systemPrompt: String?) -> Data {
        guard let systemPrompt, !systemPrompt.isEmpty else {
            return Data(prompt.utf8)
        }

        let combined = """
        <markdown-note-context>
        \(systemPrompt)
        </markdown-note-context>

        <user-request>
        \(prompt)
        </user-request>
        """
        return Data(combined.utf8)
    }

    // MARK: - JSON line parsing

    struct StreamEnvelope: Decodable {
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

    /// Decodes a single NDJSON line into a typed `ProgressEvent`, deciding
    /// once per line whether it is a text delta, an authoritative `result`, or
    /// an error result. Returns nil for unrecognized / non-content lines.
    /// `internal` and deterministic so it can be unit-tested without a process.
    static func parseLine(_ line: String) -> ProgressEvent? {
        guard let data = line.data(using: .utf8),
              let env = try? JSONDecoder().decode(StreamEnvelope.self, from: data) else {
            return nil
        }

        switch env.type {
        case "stream_event":
            guard let event = env.event,
                  event.type == "content_block_delta",
                  let delta = event.delta,
                  delta.type == "text_delta",
                  let text = delta.text else {
                return nil
            }
            return .deltaText(text)
        case "result":
            // A `result` with `is_error == true` is an error regardless of
            // whether it carries result text; otherwise it is the final reply.
            if env.isError == true {
                return .reportedError(env.result ?? "assistant Code CLI reported an error.")
            }
            return .finalResult(env.result ?? "")
        default:
            return nil
        }
    }

    // MARK: - Locating `assistant`

    /// Caches the resolved CLI URL across calls so the (potentially slow,
    /// rc-file-sourcing) login-shell probe runs at most once per launch
    /// rather than on every cold request.
    private static let locatedExecutable = ResolvedExecutableCache()

    /// Finds the `assistant` CLI by probing the common install locations first
    /// and, only if nothing is found there, asking the user's login shell as
    /// a best-effort fallback. GUI apps launched from Finder inherit a minimal
    /// `PATH`, so we can't rely on `/usr/bin/env` to locate it. The result is
    /// cached so the login shell is sourced at most once per launch.
    private static func locateExecutable() -> URL? {
        if let cached = locatedExecutable.value {
            return cached
        }

        let resolved = Self.resolveExecutable()
        if let resolved {
            locatedExecutable.value = resolved
        }
        return resolved
    }

    private static func resolveExecutable() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates: [String] = [
            "\(home)/.local/bin/assistant",
            "\(home)/.assistant/local/assistant",
            "\(home)/bin/assistant",
            "/opt/homebrew/bin/assistant",
            "/usr/local/bin/assistant",
            "/usr/bin/assistant"
        ]
        for path in candidates where Self.isUsableExecutable(path) {
            return URL(fileURLWithPath: path)
        }

        // Best-effort fallback: ask the login shell where `assistant` lives, then
        // re-validate the result on our side. We only trust the path if it is
        // a regular, executable file named `assistant` — never executing whatever
        // arbitrary string the shell prints, which could be a side effect or a
        // PATH-injected binary.
        if let resolved = Self.resolveViaLoginShell(),
           Self.isUsableExecutable(resolved) {
            return URL(fileURLWithPath: resolved)
        }

        return nil
    }

    /// Validates that `path` points at a regular, executable file actually
    /// named `assistant`, guarding against the login shell returning a directory,
    /// a non-executable, or some other unexpected string.
    private static func isUsableExecutable(_ path: String) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: path) else {
            return false
        }
        return URL(fileURLWithPath: path).lastPathComponent == "assistant"
    }

    private static func resolveViaLoginShell() -> String? {
        let process = Process()
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-c", "command -v assistant"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        // Bound the probe with a wall-clock timeout: a login shell that blocks
        // (e.g. a wedged rc file) must not hang the request indefinitely.
        let timedOut = TimeoutFlag()
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        watchdog.schedule(deadline: .now() + 10)
        watchdog.setEventHandler {
            timedOut.set()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        watchdog.resume()
        defer { watchdog.cancel() }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard !timedOut.isSet, process.terminationStatus == 0 else { return nil }

        // `command -v` can emit multiple lines; trust only the first path-like
        // token so an rc file's stray stdout can't smuggle in an alternate
        // path on a later line.
        let output = String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.hasPrefix("/") })
        return (output?.isEmpty == false) ? output : nil
    }
}

// MARK: - Sendable helpers

/// A per-invocation, owner-readable file used to bridge sensitive input into
/// a subprocess without placing it in argv. Standard-input files are unlinked
/// before launch and remain readable only through their already-open handle;
/// system-prompt files are removed automatically when the invocation ends.
private final class SecureTemporaryFile {
    enum FileError: LocalizedError {
        case couldNotCreate

        var errorDescription: String? {
            "Couldn't create protected temporary input for the assistant CLI."
        }
    }

    let url: URL
    let fileHandle: FileHandle
    private var pathExists = true

    init(contents: Data) throws {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("Markdown-assistant-\(UUID().uuidString)", isDirectory: false)

        guard fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw FileError.couldNotCreate
        }

        do {
            let fileHandle = try FileHandle(forUpdating: url)
            try fileHandle.write(contentsOf: contents)
            try fileHandle.seek(toOffset: 0)
            self.url = url
            self.fileHandle = fileHandle
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    func unlinkFromFilesystem() throws {
        guard pathExists else { return }
        try FileManager.default.removeItem(at: url)
        pathExists = false
    }

    deinit {
        try? fileHandle.close()
        if pathExists {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Holds the detached worker `Task` and a terminate hook so cancellation can
/// both cancel the task and SIGTERM the subprocess (the latter unblocks the
/// synchronous stdout read immediately).
private final class WorkerTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: Task<Void, Never>?
    private var _terminateAction: (@Sendable () -> Void)?

    var task: Task<Void, Never>? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _task
        }
        set {
            lock.lock()
            _task = newValue
            lock.unlock()
        }
    }

    var terminateAction: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _terminateAction
        }
        set {
            lock.lock()
            _terminateAction = newValue
            lock.unlock()
        }
    }

    func terminate() {
        terminateAction?()
    }
}

/// Thread-safe accumulator for the subprocess's stderr, written from the
/// pipe's background `readabilityHandler` and read after `waitUntilExit()`.
private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// A one-way flag set from a background watchdog and read on the worker.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

/// Caches the resolved `assistant` executable URL across calls.
private final class ResolvedExecutableCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: URL?

    var value: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return cached
        }
        set {
            lock.lock()
            cached = newValue
            lock.unlock()
        }
    }
}
