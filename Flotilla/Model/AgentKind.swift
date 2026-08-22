import Foundation

/// The coding-agent CLIs Flotilla can drive. Each maps to one `AgentProvider`.
enum AgentKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case claude
    case codex
    case pi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .pi: "pi"
        }
    }

    /// Default binary name; overridable per-agent in settings.
    var defaultBinary: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .pi: "pi"
        }
    }
}
