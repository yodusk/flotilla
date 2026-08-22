import SwiftUI

/// Right inspector: the worktree-wide diff (shared by all its chats) + git
/// actions. Reflects the working directory, unchanged by tab switches.
struct DiffInspectorView: View {
    let worktree: Worktree

    @State private var changes: [GitService.FileChange] = []
    @State private var diff = ""
    @State private var loading = false

    private let git = GitService()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changes").font(.headline)
                Spacer()
                Button { Task { await reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            Divider()

            if changes.isEmpty && !loading {
                ContentUnavailableView("No changes", systemImage: "checkmark.circle")
                    .frame(maxHeight: .infinity)
            } else {
                List(changes) { change in
                    HStack {
                        Text(change.status).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                        Text(change.path).lineLimit(1).truncationMode(.middle)
                    }
                }
                .listStyle(.inset)

                Divider()
                ScrollView {
                    Text(diff)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 240)
            }
        }
        .task(id: worktree.persistentModelID) { await reload() }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        changes = (try? await git.status(worktree: worktree.url)) ?? []
        diff = (try? await git.diff(worktree: worktree.url)) ?? ""
    }
}
