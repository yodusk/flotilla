import Foundation
import SwiftData
import Observation

/// Owns `ChatController`s for the app's lifetime, keyed by chat. Lifting them
/// out of the views means a running agent survives tab/worktree switches — the
/// whole point of a parallel fleet — and lets the sidebar read run status for
/// any worktree, open or not.
@MainActor
@Observable
final class ChatStore {
    private var controllers: [PersistentIdentifier: ChatController] = [:]

    func controller(for chat: Chat, in worktree: Worktree) -> ChatController {
        if let existing = controllers[chat.persistentModelID] { return existing }
        let controller = ChatController(worktree: worktree.url, agent: chat.agent, sessionID: chat.sessionID)
        controller.onSessionID = { [weak chat] id in chat?.sessionID = id }
        controllers[chat.persistentModelID] = controller
        return controller
    }

    /// Aggregate status across a worktree's chats. Reading each controller's
    /// `isRunning` here registers the sidebar as an observer.
    func status(for worktree: Worktree) -> WorktreeStatus {
        let live = worktree.chats.compactMap { controllers[$0.persistentModelID] }
        if live.contains(where: \.isRunning) { return .running }
        if live.contains(where: \.lastIsError) { return .error }
        return .idle
    }

    func forget(_ chat: Chat) {
        controllers[chat.persistentModelID] = nil
    }
}
