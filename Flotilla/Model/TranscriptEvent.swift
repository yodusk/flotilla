import Foundation

/// The normalized event vocabulary every adapter emits. Nothing above the
/// adapter boundary knows which CLI produced these. See docs/formats/normalized.md.
enum TranscriptEvent: Sendable {
    case sessionStarted(SessionInfo)
    case userMessage(text: String)
    case assistantDelta(blockID: String?, text: String)
    case assistantMessage(blockID: String?, text: String)
    case thinkingDelta(blockID: String?, text: String)
    case thinkingMessage(blockID: String?, text: String)
    case toolCall(ToolCall)
    case toolCallArgsDelta(id: String, fragment: String)
    case toolResult(ToolResult)
    case commandOutputDelta(id: String, chunk: String)
    case usage(TokenUsage)
    case turnStarted
    case turnCompleted(stopReason: StopReason?)
    case runFinished(RunOutcome)
    case notice(Notice)
    case raw(String)
}

struct SessionInfo: Sendable, Equatable {
    var id: String
    var agent: AgentKind
    var model: String?
    var cwd: String?
}

struct ToolCall: Sendable, Equatable {
    var id: String
    var name: String
    var kind: ToolKind
    var input: JSONValue
}

/// A hint about what a tool call does, so the UI can render it appropriately.
/// Derived per-adapter; `.generic` when unknown.
enum ToolKind: String, Sendable, Equatable {
    case generic
    case shell
    case fileEdit
    case mcp
    case plan
    case webSearch
    case subagent
}

struct ToolResult: Sendable, Equatable {
    var callID: String
    var name: String?
    var content: String
    var isError: Bool
    var structured: JSONValue?
}

struct TokenUsage: Sendable, Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var reasoning: Int = 0
    var total: Int = 0
    var costUSD: Double?
    var scope: Scope

    /// Whether this figure is for one turn or cumulative over the session.
    /// The two must not be summed together — see docs/formats/normalized.md rule 4.
    enum Scope: Sendable, Equatable { case turn, cumulative }
}

enum StopReason: Sendable, Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case refusal
    case aborted
    case error
    case other(String)
}

struct RunOutcome: Sendable, Equatable {
    var isError: Bool
    var stopReason: StopReason?
    var finalText: String?
    var usage: TokenUsage?
    var errorMessage: String?
}

struct Notice: Sendable, Equatable {
    var level: Level
    var message: String

    enum Level: Sendable, Equatable { case info, warning, error }
}
