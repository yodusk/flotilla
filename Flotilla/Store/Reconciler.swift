import Foundation
import SwiftData

/// Reconciles persisted worktree records against reality on launch. A worktree
/// can vanish (deleted on disk, removed by a crash); its `Chat` rows cascade
/// away with it. See DESIGN.md ("reconcile-on-launch").
@MainActor
enum Reconciler {
    static func run(_ context: ModelContext) async {
        let git = GitService()
        let fm = FileManager.default
        guard let repos = try? context.fetch(FetchDescriptor<Repo>()) else { return }

        for repo in repos {
            // The set of worktree paths git actually knows about for this repo.
            let live = Set((try? await git.listWorktrees(repo: repo.url))?.map(\.path) ?? [])
            for worktree in repo.worktrees {
                let onDisk = fm.fileExists(atPath: worktree.path)
                let knownToGit = live.isEmpty || live.contains(worktree.path)
                if !onDisk || !knownToGit {
                    context.delete(worktree)
                }
            }
        }
    }
}
