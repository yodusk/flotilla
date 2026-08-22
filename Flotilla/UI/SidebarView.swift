import SwiftUI
import SwiftData
import AppKit

/// The fleet at a glance: worktrees grouped by repo. Add repos and worktrees.
struct SidebarView: View {
    @Binding var selection: Worktree?
    @Environment(\.modelContext) private var context
    @Query(sort: \Repo.addedAt) private var repos: [Repo]

    private let git = GitService()

    var body: some View {
        List(selection: $selection) {
            ForEach(repos) { repo in
                Section(repo.name) {
                    ForEach(repo.worktrees.sorted(by: { $0.createdAt < $1.createdAt })) { worktree in
                        Label(worktree.name, systemImage: "arrow.triangle.branch")
                            .tag(worktree)
                            .contextMenu {
                                Button("Remove Worktree", role: .destructive) {
                                    remove(worktree, in: repo)
                                }
                            }
                    }
                    Button {
                        Task { await addWorktree(to: repo) }
                    } label: {
                        Label("New Worktree", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                addRepo()
            } label: {
                Label("Add Repository", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .padding(8)
        }
    }

    // MARK: - Actions

    private func addRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let repo = Repo(name: url.lastPathComponent, path: url.path)
        context.insert(repo)
    }

    private func addWorktree(to repo: Repo) async {
        let slug = "run-\(Int(Date().timeIntervalSince1970) % 100000)"
        let path = repo.url.appendingPathComponent(".flotilla/worktrees/\(slug)")
        let branch = "flotilla/\(slug)"
        do {
            let base = try await git.currentBranch(worktree: repo.url)
            try await git.addWorktree(repo: repo.url, path: path, branch: branch, base: base)
            let worktree = Worktree(name: slug, path: path.path, branch: branch, base: base)
            worktree.repo = repo
            context.insert(worktree)
            worktree.chats.append(Chat(title: "Chat 1", agent: .claude))
            selection = worktree
        } catch {
            NSLog("Flotilla: worktree add failed: \(error)")
        }
    }

    private func remove(_ worktree: Worktree, in repo: Repo) {
        Task {
            try? await git.removeWorktree(repo: repo.url, path: worktree.url, force: true)
            if selection == worktree { selection = nil }
            context.delete(worktree)
        }
    }
}
