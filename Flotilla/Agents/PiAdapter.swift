import Foundation

/// pi (earendil-works). Stream: `pi --mode json`. No permission system exists —
/// nothing to bypass. Resume: `--session <id>`. `--mode json` and `--mode rpc`
/// share the exact same event serialization. See docs/formats/pi.md.
struct PiAdapter: AgentProvider {
    let kind: AgentKind = .pi

    let capabilities = AgentCapabilities(
        streamsAssistantDeltas: true,
        streamsCommandOutput: true,
        supportsResume: true,
        supportsImages: true,
        supportsMCP: false   // pi ships without built-in MCP
    )

    func launch(prompt: String, worktree: URL, session: String?, config: AgentConfig) -> LaunchSpec {
        var args = ["--mode", "json"]
        if let model = config.model { args += ["--model", model] }
        if let session { args += ["--session", session] }
        args.append(prompt)
        return LaunchSpec(
            executable: config.binaryPath ?? kind.defaultBinary,
            arguments: args,
            environment: config.extraEnvironment,
            workingDirectory: worktree
        )
    }

    func parseStream(line: String) -> [TranscriptEvent] {
        guard let obj = jsonObject(line), let type = obj["type"] as? String else {
            return [.raw(line)]
        }
        switch type {
        case "session":
            return [.sessionStarted(SessionInfo(
                id: obj["id"] as? String ?? "", agent: .pi, model: nil,
                cwd: obj["cwd"] as? String))]
        case "turn_start":
            return [.turnStarted]
        case "turn_end":
            let reason = ((obj["message"] as? [String: Any])?["stopReason"] as? String).map(Self.stopReason)
            return [.turnCompleted(stopReason: reason)]
        case "message_update":
            return parseMessageUpdate(obj)
        case "message_end":
            return parseMessageEnd(obj)
        case "tool_execution_start":
            guard let id = obj["toolCallId"] as? String, let name = obj["toolName"] as? String else { return [] }
            return [.toolCall(ToolCall(id: id, name: name, kind: Self.toolKind(name),
                input: jsonValue(obj["args"])))]
        case "tool_execution_update":
            if let id = obj["toolCallId"] as? String,
               let partial = (obj["partialResult"] as? [String: Any])?["output"] as? String {
                return [.commandOutputDelta(id: id, chunk: partial)]
            }
            return []
        case "tool_execution_end":
            guard let id = obj["toolCallId"] as? String else { return [] }
            return [.toolResult(ToolResult(callID: id, name: obj["toolName"] as? String,
                content: flattenContent((obj["result"] as? [String: Any])?["content"]),
                isError: obj["isError"] as? Bool ?? false,
                structured: jsonValue(obj["result"])))]
        case "bash_execution_update":
            return [.commandOutputDelta(id: obj["id"] as? String ?? "bash", chunk: obj["delta"] as? String ?? "")]
        case "agent_settled":
            return [.runFinished(RunOutcome(isError: false, stopReason: nil,
                finalText: nil, usage: nil, errorMessage: nil))]
        case "agent_end":
            // Not terminal on its own: willRetry may be true. Wait for agent_settled.
            return []
        case "auto_retry_start", "auto_retry_end", "extension_error", "queue_update",
             "compaction_start", "compaction_end":
            return [.notice(Notice(level: .info, message: type))]
        default:
            return [.raw(line)]
        }
    }

    func parseRollout(line: String) -> [TranscriptEvent] {
        // On-disk entries wrap AgentMessage under {type:"message", message:{...}}.
        guard let obj = jsonObject(line) else { return [.raw(line)] }
        switch obj["type"] as? String {
        case "session":
            return [.sessionStarted(SessionInfo(id: obj["id"] as? String ?? "",
                agent: .pi, model: nil, cwd: obj["cwd"] as? String))]
        case "message":
            return parseAgentMessage(obj["message"] as? [String: Any])
        default:
            return []   // model_change, compaction, label, etc. — skip
        }
    }

    func sessionFileURL(session: String, worktree: URL) -> URL? {
        // ~/.pi/agent/sessions/--<cwd>--/<timestamp>_<uuid>.jsonl — timestamp
        // prefix isn't derivable from the id; resolve by scanning the dir.
        return nil
    }

    // MARK: - Parsing

    private func parseMessageUpdate(_ obj: [String: Any]) -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []
        if let usage = obj["usage"] as? [String: Any] {
            let u = Self.usage(usage, scope: .turn)
            if u.total > 0 { events.append(.usage(u)) }
        }
        guard let sub = obj["assistantMessageEvent"] as? [String: Any] else { return events }
        switch sub["type"] as? String {
        case "text_delta":
            events.append(.assistantDelta(blockID: (sub["contentIndex"] as? Int).map(String.init),
                text: sub["delta"] as? String ?? ""))
        case "thinking_delta":
            events.append(.thinkingDelta(blockID: (sub["contentIndex"] as? Int).map(String.init),
                text: sub["delta"] as? String ?? ""))
        case "toolcall_delta":
            let idx = String(sub["contentIndex"] as? Int ?? 0)
            events.append(.toolCallArgsDelta(id: idx, fragment: sub["delta"] as? String ?? ""))
        default:
            break
        }
        return events
    }

    private func parseMessageEnd(_ obj: [String: Any]) -> [TranscriptEvent] {
        parseAgentMessage(obj["message"] as? [String: Any])
    }

    /// Shared shape between `message_end` events and on-disk `message` entries.
    private func parseAgentMessage(_ message: [String: Any]?) -> [TranscriptEvent] {
        guard let message else { return [] }
        switch message["role"] as? String {
        case "user":
            if let text = message["content"] as? String {
                return [.userMessage(text: text)]
            }
            return [.userMessage(text: flattenContent(message["content"]))]
        case "assistant":
            var events: [TranscriptEvent] = []
            if let content = message["content"] as? [[String: Any]] {
                for block in content {
                    switch block["type"] as? String {
                    case "text": events.append(.assistantMessage(blockID: nil, text: block["text"] as? String ?? ""))
                    case "thinking": events.append(.thinkingMessage(blockID: nil, text: block["thinking"] as? String ?? ""))
                    default: break   // toolCall handled via tool_execution_* events
                    }
                }
            }
            if let usage = message["usage"] as? [String: Any] {
                events.append(.usage(Self.usage(usage, scope: .turn)))
            }
            return events
        case "toolResult":
            return [.toolResult(ToolResult(callID: message["toolCallId"] as? String ?? "",
                name: message["toolName"] as? String,
                content: flattenContent(message["content"]),
                isError: message["isError"] as? Bool ?? false, structured: nil))]
        default:
            return []
        }
    }

    static func usage(_ obj: [String: Any], scope: TokenUsage.Scope) -> TokenUsage {
        TokenUsage(
            input: obj["input"] as? Int ?? 0,
            output: obj["output"] as? Int ?? 0,
            cacheRead: obj["cacheRead"] as? Int ?? 0,
            cacheWrite: obj["cacheWrite"] as? Int ?? 0,
            reasoning: obj["reasoning"] as? Int ?? 0,
            total: obj["totalTokens"] as? Int ?? 0,
            costUSD: (obj["cost"] as? [String: Any])?["total"] as? Double,
            scope: scope
        )
    }

    static func stopReason(_ raw: String) -> StopReason {
        switch raw {
        case "stop": .endTurn
        case "toolUse": .toolUse
        case "length": .maxTokens
        case "aborted": .aborted
        case "error": .error
        default: .other(raw)
        }
    }

    static func toolKind(_ name: String) -> ToolKind {
        switch name {
        case "bash": return .shell
        case "edit", "write": return .fileEdit
        case "read", "grep", "find", "ls": return .generic
        default: return .generic
        }
    }
}
