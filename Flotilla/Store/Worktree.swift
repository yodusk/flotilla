import Foundation
import SwiftData

/// The unit of git isolation: a linked worktree on its own branch. Owns the
/// working directory and therefore the diff. Holds one or more chats (tabs).
@Model
final class Worktree {
    var name: String
    var path: String
    var branch: String
    var base: String
    var createdAt: Date
    var repo: Repo?

    @Relationship(deleteRule: .cascade, inverse: \Chat.worktree)
    var chats: [Chat] = []

    init(name: String, path: String, branch: String, base: String, createdAt: Date = .now) {
        self.name = name
        self.path = path
        self.branch = branch
        self.base = base
        self.createdAt = createdAt
    }

    var url: URL { URL(fileURLWithPath: path) }
}
