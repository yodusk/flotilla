import Foundation
import Observation

/// Drives one chat's agent session and turns the normalized event stream into
/// renderable items. Correlates tool calls with their results, and drops
/// protocol noise (hooks, rate limits, status) so the transcript reads as a
/// conversation. Lives in memory only — the durable transcript is the agent's
/// own file (see DESIGN.md).
@MainActor
@Observable
final class ChatController {
    /// One tool invocation and its eventual result, rendered as a single card.
    struct ToolRun: Sendable {
        var callID: String
        var name: String
        var kind: ToolKind
        var summary: String
        var status: Status
        var output: String
        enum Status: Sendable { case running, ok, failed }
    }

    struct Item: Identifiable {
        let id = UUID()
        var kind: Kind
        enum Kind {
            case user(String)
            case assistant(String)
            case thinking(String)
            case tool(ToolRun)
            case error(String)
        }
    }

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    private(set) var usage: TokenUsage?
    private(set) var sessionID: String?

    /// Called when the agent reports its session id (new run or first resume),
    /// so the owner can persist it on the `Chat`.
    var onSessionID: ((String) -> Void)?

    private var toolIndex: [String: Int] = [:]
    private var session: OneShotSession?
    private let provider: AgentProvider
    private let worktree: URL
    private let agent: AgentKind

    init(worktree: URL, agent: AgentKind, sessionID: String? = nil) {
        self.worktree = worktree
        self.agent = agent
        self.provider = AgentRegistry.provider(for: agent)
        self.sessionID = sessionID
        if let sessionID { self.session = makeSession(sessionID) }
    }

    /// Load prior turns from the agent's on-disk transcript. No-op if there's no
    /// session yet or the transcript is already populated. See docs/formats.
    func loadHistory() async {
        guard let sessionID, items.isEmpty else { return }
        guard let url = SessionFiles.locate(provider, session: sessionID, worktree: worktree),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            for event in provider.parseRollout(line: String(line)) { apply(event) }
        }
    }

    func send(_ prompt: String) {
        guard !prompt.isEmpty, !isRunning else { return }
        items.append(Item(kind: .user(prompt)))
        isRunning = true

        let session = session ?? makeSession(nil)
        self.session = session

        Task { [weak self] in
            let consume = Task { await self?.consume(session.events) }
            do { try await session.send(prompt) }
            catch { self?.items.append(Item(kind: .error("launch failed: \(error)"))) }
            _ = await consume.value
            self?.isRunning = false
        }
    }

    func stop() { Task { await session?.stop() } }

    // MARK: - Private

    private func makeSession(_ id: String?) -> OneShotSession {
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
            appendText(text, as: .userRole)

        case .assistantDelta(_, let text):
            streamText(text, as: .assistantRole)
        case .assistantMessage(_, let text):
            appendText(text, as: .assistantRole)

        case .thinkingDelta(_, let text):
            streamText(text, as: .thinkingRole)
        case .thinkingMessage(_, let text):
            appendText(text, as: .thinkingRole)

        case .toolCall(let call):
            startTool(call)
        case .commandOutputDelta(let id, let chunk):
            appendToolOutput(id, chunk)
        case .toolResult(let result):
            finishTool(result)

        case .usage(let u):
            usage = u
        case .runFinished(let outcome):
            if outcome.isError {
                items.append(Item(kind: .error(outcome.errorMessage ?? "run failed")))
            }
        case .notice(let n):
            if n.level == .error { items.append(Item(kind: .error(n.message))) }
            // info/warning notices (hooks, rate limits, status) are dropped.

        case .sessionStarted(let info):
            if !info.id.isEmpty, info.id != sessionID {
                sessionID = info.id
                onSessionID?(info.id)
            }
        case .turnStarted, .turnCompleted, .toolCallArgsDelta, .raw:
            break
        }
    }

    // MARK: - Text items

    private enum Role { case userRole, assistantRole, thinkingRole }

    private func appendText(_ text: String, as role: Role) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Collapse a just-streamed item into its settled form (prefix match);
        // otherwise it's a distinct block — append it.
        if let last = items.last, matches(last.kind, role) {
            let existing = current(last.kind)
            if existing.isEmpty || trimmed.hasPrefix(existing) {
                items[items.count - 1].kind = make(role, trimmed)
                return
            }
        }
        items.append(Item(kind: make(role, trimmed)))
    }

    private func streamText(_ text: String, as role: Role) {
        if let last = items.last, matches(last.kind, role), case let existing = current(last.kind) {
            items[items.count - 1].kind = make(role, existing + text)
        } else {
            items.append(Item(kind: make(role, text)))
        }
    }

    private func matches(_ kind: Item.Kind, _ role: Role) -> Bool {
        switch (kind, role) {
        case (.user, .userRole), (.assistant, .assistantRole), (.thinking, .thinkingRole): true
        default: false
        }
    }

    private func current(_ kind: Item.Kind) -> String {
        switch kind {
        case .user(let t), .assistant(let t), .thinking(let t): t
        default: ""
        }
    }

    private func make(_ role: Role, _ text: String) -> Item.Kind {
        switch role {
        case .userRole: .user(text)
        case .assistantRole: .assistant(text)
        case .thinkingRole: .thinking(text)
        }
    }

    // MARK: - Tool items

    private func startTool(_ call: ToolCall) {
        let run = ToolRun(callID: call.id, name: displayName(call), kind: call.kind,
                          summary: summarize(call), status: .running, output: "")
        toolIndex[call.id] = items.count
        items.append(Item(kind: .tool(run)))
    }

    private func appendToolOutput(_ id: String, _ chunk: String) {
        guard let idx = toolIndex[id], case .tool(var run) = items[idx].kind else { return }
        run.output += chunk
        items[idx].kind = .tool(run)
    }

    private func finishTool(_ result: ToolResult) {
        guard let idx = toolIndex[result.callID], case .tool(var run) = items[idx].kind else {
            return  // orphan result — drop rather than show a stray line
        }
        run.status = result.isError ? .failed : .ok
        if !result.content.isEmpty { run.output = result.content }
        items[idx].kind = .tool(run)
    }

    // MARK: - Summaries

    private func displayName(_ call: ToolCall) -> String {
        call.name
    }

    private func summarize(_ call: ToolCall) -> String {
        switch call.kind {
        case .shell:
            return call.input["command"]?.stringValue ?? ""
        case .fileEdit:
            if let path = call.input["path"]?.stringValue { return shorten(path) }
            if let changes = call.input.arrayValue, let first = changes.first {
                return shorten(first["path"]?.stringValue ?? "")
            }
            return ""
        case .webSearch:
            return call.input["query"]?.stringValue ?? ""
        case .plan:
            let count = call.input.arrayValue?.count ?? 0
            return count > 0 ? "\(count) steps" : ""
        default:
            return ""
        }
    }

    private func shorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: home, with: "~")
    }
}
