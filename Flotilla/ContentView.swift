import SwiftUI
import SwiftData

/// Three-column shell: worktrees (sidebar) → chats+transcript (center) →
/// worktree-wide diff (inspector). See DESIGN.md.
struct ContentView: View {
    @Environment(\.modelContext) private var context
    @State private var store = ChatStore()
    @State private var selectedWorktree: Worktree?
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedWorktree)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let worktree = selectedWorktree {
                WorktreeDetailView(worktree: worktree)
                    .inspector(isPresented: $showInspector) {
                        DiffInspectorView(worktree: worktree)
                            .inspectorColumnWidth(min: 280, ideal: 360)
                    }
            } else {
                ContentUnavailableView("No worktree selected",
                    systemImage: "sailboat",
                    description: Text("Pick a worktree, or create one to start a run."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Diff", systemImage: "sidebar.trailing")
                }
                .disabled(selectedWorktree == nil)
            }
        }
        .environment(store)
        .task { await Reconciler.run(context) }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Repo.self, Worktree.self, Chat.self], inMemory: true)
}
