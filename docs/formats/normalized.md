# Normalized model — `TranscriptEvent`

The one vocabulary every adapter emits. UI, sidebar status, and token counters
bind only to these; nothing above the adapter boundary knows which CLI produced
them. Built from the live-verified specs in `claude.md`, `codex.md`, `pi.md`.

## Cases

```
sessionStarted(SessionInfo)          id + agent + model? + cwd?
userMessage(text)
assistantDelta(blockID?, text)       streaming assistant text
assistantMessage(blockID?, text)     settled assistant text
thinkingDelta(blockID?, text)
thinkingMessage(blockID?, text)
toolCall(ToolCall)                   settled: id, name, kind, input
toolCallArgsDelta(id, fragment)      streaming raw JSON-args fragment
toolResult(ToolResult)               callID, name?, content, isError, structured?
commandOutputDelta(id, chunk)        live stdout/stderr from a running command
usage(TokenUsage)                    scope = .turn | .cumulative
turnStarted
turnCompleted(stopReason?)
runFinished(RunOutcome)              terminal: isError, stopReason, finalText?, usage?
notice(Notice)                       non-fatal: hooks, rate limits, warnings, status
raw(line)                            unknown / passthrough — never crash on drift
```

`StopReason` normalizes to: `endTurn | toolUse | maxTokens | refusal | aborted |
error | other(String)`.

## Mapping — live stream

| Normalized | Claude `stream-json` | Codex `exec --json` | Codex `app-server` | pi `--mode json`/`rpc` |
|---|---|---|---|---|
| sessionStarted | `system`/`init` (`session_id`, `model`, `cwd`) | `thread.started` (`thread_id`) | `thread/started` (`thread.id`) | line 1 `session` (`id`, `cwd`) |
| userMessage | `user` w/ string content (input mode) | — (echoed) | `item/*` `userMessage` | `message_*` role `user` |
| assistantDelta | `stream_event` `content_block_delta`/`text_delta` | — (no deltas) | `item/agentMessage/delta` | `message_update` → `text_delta` |
| assistantMessage | `assistant` w/ `text` block | `item.completed` `agent_message` | `item/completed` `agentMessage` | `message_end` role `assistant` |
| thinkingDelta | `stream_event` `thinking_delta` | — | `item/reasoning/textDelta` | `message_update` → `thinking_delta` |
| thinkingMessage | `assistant` `thinking` block | `item.completed` `reasoning` | `item/completed` reasoning | `message_end` w/ `thinking` block |
| toolCall | `assistant` `tool_use` block | `item.*` `command_execution`/`file_change`/`mcp_tool_call`/`web_search`/`todo_list` | `item/*` `commandExecution`/`fileChange`/`mcpToolCall`… | `tool_execution_start` / `toolcall_end` |
| toolCallArgsDelta | `input_json_delta.partial_json` | — | (streamed per item) | `toolcall_delta.delta` |
| toolResult | `user` `tool_result` block (+ `tool_use_result`) | `item.completed` w/ `status`/`aggregated_output` | `item/completed` | `tool_execution_end` / `message` role `toolResult` |
| commandOutputDelta | — | — | `item/commandExecution/outputDelta` (base64) | `bash_execution_update.delta` / `tool_execution_update` |
| usage | `assistant.message.usage` (turn); `result.usage` (cumul) | `turn.completed.usage` (turn) | `thread/tokenUsage/updated` (`.last`/`.total`) | `message_update.usage`; `get_session_stats` |
| turnStarted | (implicit: `message_start`) | `turn.started` | `turn/started` | `turn_start` |
| turnCompleted | `message_delta.stop_reason` | `turn.completed` | `turn/completed` | `turn_end` |
| runFinished | `result` (`subtype`, `result`, `usage`) | process exit after `turn.completed`/`turn.failed` | (client decides) | `agent_settled` |
| notice | `system` `status`/hooks, `rate_limit_event` | standalone `error` (non-fatal) | `hook/*`, `account/rateLimits/updated`, `error` | `auto_retry_*`, `extension_error`, `queue_update` |

## Mapping — on-disk rollout (`parseRollout`)

| Normalized | Claude `.jsonl` | Codex `rollout-*.jsonl` | pi `.jsonl` |
|---|---|---|---|
| sessionStarted | (reconstruct; no init line) | `session_meta` | line 1 `session` |
| userMessage | `user` string content | `response_item` `message` role user / `event_msg` `user_message` | `message` role user |
| assistantMessage | `assistant` block | `response_item` `message` role assistant / `event_msg` `agent_message` | `message` role assistant |
| toolCall / toolResult | `assistant` `tool_use` / `user` `toolUseResult` (camelCase) | `response_item` `function_call`/`function_call_output`; legacy `event_msg` `*_end` | `message` role assistant `toolCall` / role `toolResult` |
| usage | `assistant.message.usage` | `event_msg` `token_count` | `AssistantMessage.usage` |

## Hard-won reconciliation rules (from the live captures)

1. **Stream ≠ disk, per agent.** Field casing flips (`tool_use_result` →
   `toolUseResult`; Codex exec `agent_message` snake vs app-server `agentMessage`
   camel). Two parsers per adapter, never shared.
2. **No shared item vocabulary between Codex exec and app-server.** Different
   casing *and* different shapes (app-server adds deltas/hooks/approvals).
3. **Terminal signal differs.** Claude → `result` line. Codex exec → process
   exit after `turn.completed`/`turn.failed`. pi → `agent_settled` (NOT
   `agent_end`; `agent_end.willRetry` may be true). Treat "process exited with no
   terminal event" as an abnormal failure for all three.
4. **Usage scope differs.** Claude/Codex-exec/pi-`message_update` report
   *per-turn*; sum for a session total. Codex app-server and pi
   `get_session_stats` give cumulative. Tag every `usage` with `.scope`.
5. **Claude `assistant.stop_reason` is null on the live line.** Real value is in
   the `message_delta` stream_event (partial mode) or on disk. Without
   `--include-partial-messages`, infer `toolUse` from presence of a `tool_use`
   block; otherwise wait for `result`.
6. **Tool args stream as fragmented JSON** (Claude `input_json_delta`, pi
   `toolcall_delta`) — concatenate per block, parse once at `toolcall_end`.
7. **pi has no permission model.** No approval events exist; don't wait for any.
8. **Unknown lines happen** (hooks, MCP, config warnings, schema drift, Codex
   `.zst`). Every parse is try/parse → `.raw` on failure. Never abort the stream.
9. **Codex exec needs a git repo** (`--skip-git-repo-check` off = refuses) — a
   worktree is a git dir, so fine, but scratch dirs need the flag.

## Yolo launch flags (no permissions — see DESIGN.md)

- Claude: `claude -p --output-format stream-json --verbose --dangerously-skip-permissions [--resume <id>]`
- Codex: `codex exec --json --dangerously-bypass-approvals-and-sandbox [resume <id>]`
  (or `--sandbox danger-full-access` to keep the OS sandbox)
- pi: `pi --mode json [--session <id>]` (no approval flag exists; nothing to bypass)
