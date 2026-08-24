import SwiftUI
import SwiftData
import AppKit

/// The fleet at a glance: worktrees grouped by repo, each with a live status
/// dot and the agents running in it. Add repos and worktrees here.
struct SidebarView: View {
    @Binding var selection: Worktree?
    @Environment(\.modelContext) private var context
    @Environment(ChatStore.self) private var store
    @Query(sort: \Repo.addedAt) private var repos: [Repo]

    private let git = GitService()

    var body: some View {
        List(selection: $selection) {
            ForEach(repos) { repo in
                Section {
                    ForEach(repo.worktrees.sorted(by: { $0.createdAt < $1.createdAt })) { worktree in
                        WorktreeRow(worktree: worktree, status: store.status(for: worktree))
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
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } header: {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.tertiary)
                        Text(repo.name)
                        Spacer()
                        if !repo.worktrees.isEmpty {
                            Text("\(repo.worktrees.count)")
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button(action: addRepo) {
                Label("Add Repository", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(10)
        }
    }

    // MARK: - Actions

    private func addRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        context.insert(Repo(name: url.lastPathComponent, path: url.path))
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
            worktree.chats.forEach(store.forget)
            context.delete(worktree)
        }
    }
}

/// One worktree in the sidebar: status dot · branch name · the agents it runs.
private struct WorktreeRow: View {
    let worktree: Worktree
    let status: WorktreeStatus

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: status)
            Text(worktree.name)
                .lineLimit(1)
            Spacer(minLength: 6)
            ForEach(agents, id: \.self) { agent in
                Image(systemName: agent.symbol)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var agents: [AgentKind] {
        var seen: [AgentKind] = []
        for chat in worktree.chats where !seen.contains(chat.agent) { seen.append(chat.agent) }
        return seen
    }
}

/// Small pulsing dot conveying run status.
private struct StatusDot: View {
    let status: WorktreeStatus
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
            .opacity(status.isActive && pulse ? 0.35 : 1)
            .animation(status.isActive
                ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                : .default, value: pulse)
            .onAppear { pulse = true }
    }
}
