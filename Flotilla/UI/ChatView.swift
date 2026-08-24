import SwiftUI

/// One chat's transcript + prompt box. Owns a `ChatController` for the live run.
struct ChatView: View {
    let chat: Chat
    let worktree: Worktree

    @Environment(ChatStore.self) private var store
    @State private var draft = ""

    private var controller: ChatController { store.controller(for: chat, in: worktree) }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            statusBar
            promptBox
        }
        .task { await controller.loadHistory() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(controller.items) { item in
                        row(item).id(item.id)
                    }
                    if controller.isRunning {
                        TypingIndicator().id("typing")
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .onChange(of: controller.items.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(controller.items.last?.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ChatController.Item) -> some View {
        switch item.kind {
        case .user(let text):
            UserBubble(text: text)
        case .assistant(let text):
            AssistantText(text: text)
        case .thinking(let text):
            ThinkingBlock(text: text)
        case .tool(let run):
            ToolCard(run: run)
        case .error(let text):
            ErrorRow(text: text)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
            Text(chat.agent.displayName)
            if let u = controller.usage {
                Text("·")
                Text("\(u.input + u.output) tok")
                if let cost = u.costUSD {
                    Text(String(format: "· $%.3f", cost))
                }
            }
            Spacer()
            if controller.isRunning {
                ProgressView().controlSize(.small)
                Button("Stop", role: .destructive) { controller.stop() }
                    .buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private var promptBox: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message \(chat.agent.displayName)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .font(.body)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || controller.isRunning)
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .padding(16)
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        controller.send(prompt)
        draft = ""
    }
}
