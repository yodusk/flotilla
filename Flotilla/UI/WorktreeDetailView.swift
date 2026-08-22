import SwiftUI
import SwiftData

/// Center pane: a tab strip of chats over one worktree, plus the active chat's
/// transcript and prompt box. Chats share the worktree's files (free-for-all
/// writes — see DESIGN.md).
struct WorktreeDetailView: View {
    @Bindable var worktree: Worktree
    @Environment(\.modelContext) private var context
    @State private var selectedChat: Chat?

    private var chats: [Chat] {
        worktree.chats.sorted { $0.order < $1.order }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            if let chat = selectedChat ?? chats.first {
                ChatView(chat: chat, worktree: worktree)
                    .id(chat.persistentModelID)
            } else {
                ContentUnavailableView("No chats", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .navigationTitle(worktree.name)
        .navigationSubtitle(worktree.branch)
        .onAppear { if selectedChat == nil { selectedChat = chats.first } }
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(chats) { chat in
                Button {
                    selectedChat = chat
                } label: {
                    Label(chat.title, systemImage: icon(for: chat.agent))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background((selectedChat ?? chats.first) == chat
                            ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: .rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Menu {
                ForEach(AgentKind.allCases) { kind in
                    Button(kind.displayName) { addChat(kind) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
        .padding(6)
    }

    private func icon(for agent: AgentKind) -> String {
        switch agent {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .pi: "function"
        }
    }

    private func addChat(_ agent: AgentKind) {
        let chat = Chat(title: "Chat \(chats.count + 1)", agent: agent, order: chats.count)
        chat.worktree = worktree
        context.insert(chat)
        selectedChat = chat
    }
}
