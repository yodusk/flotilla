import Foundation

/// A live conversation with one agent. Hides the process shape (one-shot+resume
/// vs persistent) from the rest of the app — callers only see turns in and a
/// stream of normalized events out. See DESIGN.md.
protocol AgentSession: Actor {
    var events: AsyncStream<TranscriptEvent> { get }
    func send(_ turn: String) async throws
    func stop() async
}

enum AgentSessionError: Error, Sendable {
    case processFailed(exitCode: Int32)
    case launchFailed(String)
    case alreadyRunning
}

/// Default session: spawns the agent per turn and resumes by session id between
/// turns. Idle sessions hold no process — the right default for a large fleet.
/// (A persistent-bidirectional variant can be added later behind the same
/// protocol; all three agents also support that mode.)
actor OneShotSession: AgentSession {
    private let provider: AgentProvider
    private let worktree: URL
    private let config: AgentConfig
    private var sessionID: String?
    private var current: Process?

    private let stream: AsyncStream<TranscriptEvent>
    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    nonisolated let events: AsyncStream<TranscriptEvent>

    init(provider: AgentProvider, worktree: URL, config: AgentConfig, sessionID: String? = nil) {
        self.provider = provider
        self.worktree = worktree
        self.config = config
        self.sessionID = sessionID
        (self.stream, self.continuation) = AsyncStream.makeStream()
        self.events = stream
    }

    func send(_ turn: String) async throws {
        guard current == nil else { throw AgentSessionError.alreadyRunning }
        let spec = provider.launch(prompt: turn, worktree: worktree, session: sessionID, config: config)
        try await run(spec)
    }

    func stop() async {
        current?.terminate()
        current = nil
    }

    private func run(_ spec: LaunchSpec) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.currentDirectoryURL = spec.workingDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(spec.environment) { _, new in new }

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        current = process

        let provider = self.provider
        let continuation = self.continuation

        // Forward parsed stdout lines as they arrive.
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
                for event in provider.parseStream(line: String(line)) {
                    continuation.yield(event)
                    if case .sessionStarted(let info) = event {
                        Task { await self.captureSession(info.id) }
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            current = nil
            throw AgentSessionError.launchFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        current = nil

        if process.terminationStatus != 0 {
            continuation.yield(.notice(Notice(level: .error,
                message: "\(provider.kind.displayName) exited with code \(process.terminationStatus)")))
        }
    }

    private func captureSession(_ id: String) {
        sessionID = id
    }
}
