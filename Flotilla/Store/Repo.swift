import Foundation
import SwiftData

/// A git repository the user has added. Top of the noun hierarchy.
@Model
final class Repo {
    var name: String
    var path: String
    var addedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Worktree.repo)
    var worktrees: [Worktree] = []

    init(name: String, path: String, addedAt: Date = .now) {
        self.name = name
        self.path = path
        self.addedAt = addedAt
    }

    var url: URL { URL(fileURLWithPath: path) }
}
