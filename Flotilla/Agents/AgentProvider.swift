import Foundation

/// One implementation per CLI. The only place agent-specific knowledge lives:
/// how to launch it, how to turn its output into `TranscriptEvent`s, and where
/// it persists sessions. Everything else in the app is agent-agnostic.
protocol AgentProvider: Sendable {
    var kind: AgentKind { get }
    var capabilities: AgentCapabilities { get }

    /// Build the subprocess invocation for a one-shot turn (spawn + resume model).
    func launch(prompt: String, worktree: URL, session: String?, config: AgentConfig) -> LaunchSpec

    /// Parse one line of the live stdout stream. Tolerant: unknown → `[.raw]`.
    func parseStream(line: String) -> [TranscriptEvent]

    /// Parse one line of the on-disk session file (history, cold open).
    /// The on-disk format differs from the stream — see docs/formats/normalized.md.
    func parseRollout(line: String) -> [TranscriptEvent]

    /// Where this agent persists the given session's transcript, if directly
    /// derivable from the id (e.g. Claude names the file by session id).
    func sessionFileURL(session: String, worktree: URL) -> URL?

    /// Directory to scan for a session file when the name isn't derivable from
    /// the id (Codex date-shards, pi timestamp-prefixes). `SessionFiles.locate`
    /// scans this for a file whose name contains the session id.
    func sessionSearchRoot(worktree: URL) -> URL?
}

extension AgentProvider {
    func sessionSearchRoot(worktree: URL) -> URL? { nil }
}

/// A subprocess invocation. `AgentRunner` executes this; adapters only describe it.
struct LaunchSpec: Sendable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: URL
}

/// Per-run knobs an adapter needs when building the launch. All runs are yolo
/// (see DESIGN.md) — no permission config here by design.
struct AgentConfig: Sendable {
    var binaryPath: String?
    var model: String?
    var extraEnvironment: [String: String] = [:]
}

/// What the UI should show/hide for this agent. Permissions are absent on
/// purpose: every agent runs full-auto.
struct AgentCapabilities: Sendable {
    var streamsAssistantDeltas: Bool
    var streamsCommandOutput: Bool
    var supportsResume: Bool
    var supportsImages: Bool
    var supportsMCP: Bool
}
