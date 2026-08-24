import SwiftUI

/// A worktree's live run status, aggregated from its chats' controllers.
enum WorktreeStatus: Sendable {
    case idle
    case running
    case error

    var color: Color {
        switch self {
        case .idle: .secondary
        case .running: .green
        case .error: .red
        }
    }

    var isActive: Bool { self == .running }
}
