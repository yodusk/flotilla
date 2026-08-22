import SwiftUI

/// One chat's transcript + prompt box. Owns a `ChatController` for the live run.
struct ChatView: View {
    let chat: Chat
    let worktree: Worktree

    @State private var controller: ChatController
    @State private var draft = ""

    init(chat: Chat, worktree: Worktree) {
        self.chat = chat
        self.worktree = worktree
        _controller = State(initialValue: ChatController(
            worktree: worktree.url, agent: chat.agent, sessionID: chat.sessionID))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.lines) { line in
                        transcriptRow(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            Divider()
            statusBar
            promptBox
        }
    }

    @ViewBuilder
    private func transcriptRow(_ line: ChatController.Line) -> some View {
        switch line.role {
        case .user:
            Text(line.text).fontWeight(.medium)
        case .assistant:
            Text(line.text)
        case .thinking:
            Text(line.text).font(.callout).foregroundStyle(.secondary).italic()
        case .tool:
            Text(line.text).font(.system(.callout, design: .monospaced)).foregroundStyle(.blue)
        case .notice:
            Text(line.text).font(.caption).foregroundStyle(.secondary)
        case .done:
            Text(line.text).font(.caption).foregroundStyle(.green)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label(chat.agent.displayName, systemImage: "cpu")
            if let u = controller.usage {
                Text("\(u.input + u.output) tok")
            }
            Spacer()
            if controller.isRunning {
                ProgressView().controlSize(.small)
                Button("Stop") { controller.stop() }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private var promptBox: some View {
        HStack(spacing: 8) {
            TextField("Message \(chat.agent.displayName)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty || controller.isRunning)
        }
        .padding(12)
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        controller.send(prompt)
        draft = ""
    }
}
