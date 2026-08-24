import SwiftUI

/// User turn: a subtle filled bubble to set it apart from assistant prose.
struct UserBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.18)))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Assistant prose, rendered as inline markdown.
struct AssistantText: View {
    let text: String
    var body: some View {
        Text(markdown(text))
            .textSelection(.enabled)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Reasoning: de-emphasized, capped, easy to skim past.
struct ThinkingBlock: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "brain")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 10))
    }
}

/// A tool call and its result, folded into one card.
struct ToolCard: View {
    let run: ChatController.ToolRun

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                Text(run.name)
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(.medium)
                if !run.summary.isEmpty {
                    Text(run.summary)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                status
            }
            if !run.output.isEmpty {
                Text(run.output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 6))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }

    @ViewBuilder private var status: some View {
        switch run.status {
        case .running: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var icon: String {
        switch run.kind {
        case .shell: "terminal"
        case .fileEdit: "pencil"
        case .mcp: "puzzlepiece.extension"
        case .plan: "checklist"
        case .webSearch: "magnifyingglass"
        case .subagent: "person.2"
        case .generic: "wrench.and.screwdriver"
        }
    }
}

struct ErrorRow: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: .rect(cornerRadius: 10))
    }
}

struct TypingIndicator: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().frame(width: 6, height: 6)
                    .opacity(on ? 0.9 : 0.3)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: on)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .onAppear { on = true }
    }
}
