import Foundation
import Observation

/// Drives one chat's agent session and turns the normalized event stream into
/// renderable lines. Lives in memory only — the durable transcript is the
/// agent's own file (see DESIGN.md).
@MainActor
@Observable
final class ChatController {
    struct Line: Identifiable, Sendable {
        let id = UUID()
        var role: Role
        var text: String
        enum Role: Sendable { case user, assistant, thinking, tool, notice, done }
    }

    private(set) var lines: [Line] = []
    private(set) var isRunning = false
    private(set) var usage: TokenUsage?

    private var session: OneShotSession?
    private let worktree: URL
    private let agent: AgentKind

    init(worktree: URL, agent: AgentKind, sessionID: String? = nil) {
        self.worktree = worktree
        self.agent = agent
        if let sessionID {
            self.session = makeSession(sessionID)
        }
    }

    func send(_ prompt: String) {
        guard !prompt.isEmpty, !isRunning else { return }
        lines.append(Line(role: .user, text: prompt))
        isRunning = true

        let session = session ?? makeSession(nil)
        self.session = session

        Task { [weak self] in
            // Begin consuming events for this turn.
            let consume = Task { await self?.consume(session.events) }
            do { try await session.send(prompt) }
            catch { self?.append(.notice, "launch failed: \(error)") }
            _ = await consume.value
            self?.isRunning = false
        }
    }

    func stop() {
        Task { await session?.stop() }
    }

    // MARK: - Private

    private func makeSession(_ id: String?) -> OneShotSession {
        let provider = AgentRegistry.provider(for: agent)
        let config = AgentConfig(binaryPath: AgentRegistry.resolveBinary(agent.defaultBinary))
        return OneShotSession(provider: provider, worktree: worktree, config: config, sessionID: id)
    }

    private func consume(_ events: AsyncStream<TranscriptEvent>) async {
        for await event in events {
            apply(event)
            if case .runFinished = event { break }
        }
    }

    private func apply(_ event: TranscriptEvent) {
        switch event {
        case .userMessage(let text):
            append(.user, text)
        case .assistantDelta(_, let text):
            appendDelta(.assistant, text)
        case .assistantMessage(_, let text):
            append(.assistant, text)
        case .thinkingDelta(_, let text):
            appendDelta(.thinking, text)
        case .thinkingMessage(_, let text):
            append(.thinking, text)
        case .toolCall(let call):
            append(.tool, "→ \(call.name)")
        case .toolResult(let result):
            append(.tool, "\(result.isError ? "✗" : "✓") \(result.name ?? "result")")
        case .usage(let u):
            usage = u
        case .runFinished(let outcome):
            append(.done, outcome.isError ? "error: \(outcome.errorMessage ?? "unknown")" : "done")
        case .notice(let n):
            append(.notice, n.message)
        case .sessionStarted, .turnStarted, .turnCompleted, .toolCallArgsDelta, .commandOutputDelta, .raw:
            break
        }
    }

    private func append(_ role: Line.Role, _ text: String) {
        lines.append(Line(role: role, text: text))
    }

    private func appendDelta(_ role: Line.Role, _ text: String) {
        if let last = lines.last, last.role == role {
            lines[lines.count - 1].text += text
        } else {
            lines.append(Line(role: role, text: text))
        }
    }
}
