import Foundation

/// OpenAI Codex CLI. Stream: `codex exec --json`. Yolo:
/// `--dangerously-bypass-approvals-and-sandbox`. Resume: `codex exec resume <id>`.
/// See docs/formats/codex.md. NOTE: exec item types are snake_case and distinct
/// from app-server's camelCase — this parser is for the exec stream only.
struct CodexAdapter: AgentProvider {
    let kind: AgentKind = .codex

    let capabilities = AgentCapabilities(
        streamsAssistantDeltas: false,  // exec emits only settled item.completed
        streamsCommandOutput: false,
        supportsResume: true,
        supportsImages: true,
        supportsMCP: true
    )

    func launch(prompt: String, worktree: URL, session: String?, config: AgentConfig) -> LaunchSpec {
        var args = ["exec", "--json", "--dangerously-bypass-approvals-and-sandbox"]
        if let model = config.model { args += ["--model", model] }
        if let session {
            // `codex exec resume <id> <prompt>`
            args += ["resume", session, prompt]
        } else {
            args.append(prompt)
        }
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
        case "thread.started":
            return [.sessionStarted(SessionInfo(
                id: obj["thread_id"] as? String ?? "", agent: .codex, model: nil, cwd: nil))]
        case "turn.started":
            return [.turnStarted]
        case "turn.completed":
            var events: [TranscriptEvent] = []
            if let usage = obj["usage"] as? [String: Any] {
                events.append(.usage(Self.usage(usage)))
            }
            events.append(.turnCompleted(stopReason: .endTurn))
            return events
        case "turn.failed":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String
            return [.runFinished(RunOutcome(isError: true, stopReason: .error,
                finalText: nil, usage: nil, errorMessage: msg))]
        case "item.started", "item.updated", "item.completed":
            return parseItem(obj, phase: type)
        case "error":
            return [.notice(Notice(level: .warning, message: obj["message"] as? String ?? "error"))]
        default:
            return [.raw(line)]
        }
    }

    func parseRollout(line: String) -> [TranscriptEvent] {
        // Rollout wraps RolloutItem in {timestamp,type,payload}. Legacy vs
        // paginated encodings both exist — see docs/formats/codex.md.
        // TODO: full rollout mapping (response_item / event_msg / .zst).
        return []
    }

    func sessionFileURL(session: String, worktree: URL) -> URL? {
        // ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl — date-sharded,
        // so it can't be derived from the id alone; scan instead.
        return nil
    }

    func sessionSearchRoot(worktree: URL) -> URL? {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    // MARK: - Items

    private func parseItem(_ obj: [String: Any], phase: String) -> [TranscriptEvent] {
        guard let item = obj["item"] as? [String: Any],
              let id = item["id"] as? String,
              let itemType = item["type"] as? String else { return [] }
        let completed = phase == "item.completed"

        switch itemType {
        case "agent_message":
            return completed ? [.assistantMessage(blockID: id, text: item["text"] as? String ?? "")] : []
        case "reasoning":
            return completed ? [.thinkingMessage(blockID: id, text: item["text"] as? String ?? "")] : []
        case "command_execution":
            if completed {
                let exit = item["exit_code"] as? Int
                let failed = (item["status"] as? String == "failed") || (exit != nil && exit != 0)
                return [.toolResult(ToolResult(callID: id, name: "shell",
                    content: item["aggregated_output"] as? String ?? "", isError: failed,
                    structured: jsonValue(item)))]
            }
            return [.toolCall(ToolCall(id: id, name: "shell", kind: .shell,
                input: .object(["command": jsonValue(item["command"])])))]
        case "file_change":
            return [.toolCall(ToolCall(id: id, name: "file_change", kind: .fileEdit,
                input: jsonValue(item["changes"])))]
        case "mcp_tool_call":
            let name = "\(item["server"] as? String ?? "mcp")/\(item["tool"] as? String ?? "")"
            if completed {
                let err = (item["error"] as? [String: Any])?["message"] as? String
                return [.toolResult(ToolResult(callID: id, name: name,
                    content: err ?? flattenContent((item["result"] as? [String: Any])?["content"]),
                    isError: err != nil, structured: jsonValue(item["result"])))]
            }
            return [.toolCall(ToolCall(id: id, name: name, kind: .mcp,
                input: jsonValue(item["arguments"])))]
        case "web_search":
            return [.toolCall(ToolCall(id: id, name: "web_search", kind: .webSearch,
                input: jsonValue(item)))]
        case "todo_list":
            return [.toolCall(ToolCall(id: id, name: "todo_list", kind: .plan,
                input: jsonValue(item["items"])))]
        case "error":
            return [.notice(Notice(level: .warning, message: item["message"] as? String ?? "error"))]
        default:
            return [.raw("\(item)")]
        }
    }

    static func usage(_ obj: [String: Any]) -> TokenUsage {
        let input = obj["input_tokens"] as? Int ?? 0
        let output = obj["output_tokens"] as? Int ?? 0
        return TokenUsage(
            input: input, output: output,
            cacheRead: obj["cached_input_tokens"] as? Int ?? 0,
            cacheWrite: obj["cache_write_input_tokens"] as? Int ?? 0,
            reasoning: obj["reasoning_output_tokens"] as? Int ?? 0,
            total: input + output, costUSD: nil, scope: .turn
        )
    }
}
