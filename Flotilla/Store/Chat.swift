import Foundation
import SwiftData

/// One conversation with one agent — a tab within a worktree. Owns the agent
/// choice and the agent's session id; the transcript itself lives in the agent's
/// own on-disk file, not here (see DESIGN.md / docs/formats/normalized.md).
@Model
final class Chat {
    var title: String
    var agentRaw: String
    var sessionID: String?
    var order: Int
    var createdAt: Date
    var worktree: Worktree?

    init(title: String, agent: AgentKind, order: Int = 0, createdAt: Date = .now) {
        self.title = title
        self.agentRaw = agent.rawValue
        self.order = order
        self.createdAt = createdAt
    }

    var agent: AgentKind {
        get { AgentKind(rawValue: agentRaw) ?? .claude }
        set { agentRaw = newValue.rawValue }
    }
}
