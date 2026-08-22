import Foundation

/// Claude Code. Stream: `-p --output-format stream-json --verbose`. Yolo:
/// `--dangerously-skip-permissions`. Resume: `--resume <id>`. See docs/formats/claude.md.
struct ClaudeAdapter: AgentProvider {
    let kind: AgentKind = .claude

    let capabilities = AgentCapabilities(
        streamsAssistantDeltas: true,   // with --include-partial-messages
        streamsCommandOutput: false,
        supportsResume: true,
        supportsImages: true,
        supportsMCP: true
    )

    func launch(prompt: String, worktree: URL, session: String?, config: AgentConfig) -> LaunchSpec {
        var args = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions",
        ]
        if let model = config.model { args += ["--model", model] }
        if let session { args += ["--resume", session] }
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
        case "system":
            return parseSystem(obj)
        case "assistant":
            return parseAssistant(obj)
        case "user":
            return parseUser(obj)
        case "stream_event":
            return parseStreamEvent(obj)
        case "result":
            return parseResult(obj)
        case "rate_limit_event":
            return [.notice(Notice(level: .info, message: "rate limit update"))]
        default:
            return [.raw(line)]
        }
    }

    func parseRollout(line: String) -> [TranscriptEvent] {
        // On-disk .jsonl: no init/result lines; toolUseResult is camelCase.
        // Assistant/user message shapes match the stream, so reuse where they overlap.
        guard let obj = jsonObject(line), let type = obj["type"] as? String else {
            return [.raw(line)]
        }
        switch type {
        case "assistant": return parseAssistant(obj)
        case "user": return parseUser(obj, resultField: "toolUseResult")
        default: return []   // queue-operation, attachment, last-prompt, etc. — skip
        }
    }

    func sessionFileURL(session: String, worktree: URL) -> URL? {
        // ~/.claude/projects/<cwd-with-slashes-as-dashes>/<session>.jsonl
        let encoded = worktree.path.replacingOccurrences(of: "/", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encoded)/\(session).jsonl")
    }

    // MARK: - Parsing

    private func parseSystem(_ obj: [String: Any]) -> [TranscriptEvent] {
        guard obj["subtype"] as? String == "init" else {
            return [.notice(Notice(level: .info, message: obj["subtype"] as? String ?? "system"))]
        }
        let info = SessionInfo(
            id: obj["session_id"] as? String ?? "",
            agent: .claude,
            model: obj["model"] as? String,
            cwd: obj["cwd"] as? String
        )
        return [.sessionStarted(info)]
    }

    private func parseAssistant(_ obj: [String: Any]) -> [TranscriptEvent] {
        guard let message = obj["message"] as? [String: Any] else { return [.raw("\(obj)")] }
        var events: [TranscriptEvent] = []
        if let content = message["content"] as? [[String: Any]] {
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String {
                        events.append(.assistantMessage(blockID: block["id"] as? String, text: text))
                    }
                case "thinking":
                    if let text = block["thinking"] as? String {
                        events.append(.thinkingMessage(blockID: nil, text: text))
                    }
                case "tool_use":
                    if let id = block["id"] as? String, let name = block["name"] as? String {
                        events.append(.toolCall(ToolCall(
                            id: id, name: name,
                            kind: Self.toolKind(name),
                            input: jsonValue(block["input"])
                        )))
                    }
                default:
                    break
                }
            }
        }
        if let usage = message["usage"] as? [String: Any] {
            events.append(.usage(Self.usage(usage, scope: .turn)))
        }
        return events
    }

    private func parseUser(_ obj: [String: Any], resultField: String = "tool_use_result") -> [TranscriptEvent] {
        guard let message = obj["message"] as? [String: Any] else { return [] }
        // A plain-string content is real human input; an array carries tool results.
        if let text = message["content"] as? String {
            return [.userMessage(text: text)]
        }
        guard let content = message["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { block in
            guard block["type"] as? String == "tool_result",
                  let id = block["tool_use_id"] as? String else { return nil }
            return .toolResult(ToolResult(
                callID: id,
                name: nil,
                content: flattenContent(block["content"]),
                isError: block["is_error"] as? Bool ?? false,
                structured: jsonValue(obj[resultField])
            ))
        }
    }

    private func parseStreamEvent(_ obj: [String: Any]) -> [TranscriptEvent] {
        guard let event = obj["event"] as? [String: Any] else { return [] }
        switch event["type"] as? String {
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                return [.assistantDelta(blockID: nil, text: delta["text"] as? String ?? "")]
            case "thinking_delta":
                return [.thinkingDelta(blockID: nil, text: delta["thinking"] as? String ?? "")]
            case "input_json_delta":
                // Tool-args fragments; block index is the only correlator here.
                let idx = String(event["index"] as? Int ?? 0)
                return [.toolCallArgsDelta(id: idx, fragment: delta["partial_json"] as? String ?? "")]
            default:
                return []
            }
        case "message_delta":
            if let delta = event["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                return [.turnCompleted(stopReason: Self.stopReason(reason))]
            }
            return []
        default:
            return []
        }
    }

    private func parseResult(_ obj: [String: Any]) -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []
        if let usage = obj["usage"] as? [String: Any] {
            var u = Self.usage(usage, scope: .cumulative)
            u.costUSD = obj["total_cost_usd"] as? Double
            events.append(.usage(u))
        }
        let subtype = obj["subtype"] as? String
        events.append(.runFinished(RunOutcome(
            isError: obj["is_error"] as? Bool ?? (subtype != "success"),
            stopReason: (obj["stop_reason"] as? String).map(Self.stopReason),
            finalText: obj["result"] as? String,
            usage: nil,
            errorMessage: (obj["errors"] as? [String])?.joined(separator: "\n")
        )))
        return events
    }

    // MARK: - Helpers

    static func usage(_ obj: [String: Any], scope: TokenUsage.Scope) -> TokenUsage {
        let input = obj["input_tokens"] as? Int ?? 0
        let output = obj["output_tokens"] as? Int ?? 0
        let cacheRead = obj["cache_read_input_tokens"] as? Int ?? 0
        let cacheWrite = obj["cache_creation_input_tokens"] as? Int ?? 0
        return TokenUsage(
            input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
            reasoning: (obj["output_tokens_details"] as? [String: Any])?["thinking_tokens"] as? Int ?? 0,
            total: input + output, costUSD: nil, scope: scope
        )
    }

    static func stopReason(_ raw: String) -> StopReason {
        switch raw {
        case "end_turn": .endTurn
        case "tool_use": .toolUse
        case "max_tokens": .maxTokens
        case "refusal": .refusal
        default: .other(raw)
        }
    }

    static func toolKind(_ name: String) -> ToolKind {
        if name.hasPrefix("mcp__") { return .mcp }
        switch name {
        case "Bash": return .shell
        case "Edit", "Write", "NotebookEdit": return .fileEdit
        case "Task", "Agent": return .subagent
        case "WebSearch", "WebFetch": return .webSearch
        case "TodoWrite": return .plan
        default: return .generic
        }
    }
}
