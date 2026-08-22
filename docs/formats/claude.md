# Claude Code — Formats

Verified against Claude Code v2.1.239 (installed locally, `claude --version`) on 2026-08-22, cross-checked against official docs and real captured output (`claude -p ... --output-format stream-json --verbose`). Live probe transcripts: `/tmp/claude_probe1.jsonl`, `/tmp/claude_probe2.jsonl`. On-disk transcript inspected directly from `~/.claude/projects/`.

Note: the local install used for probing carries a customized settings/plugin/tool config (extra MCP servers, custom permission mode `"auto"`, extra tool names in `tools`/`agents`/`skills`). Those config-dependent *values* are not portable, but the *event schema* (types, field names, nesting) is unaffected by that and is what's documented below.

## Binary & install

- Native binary, installed via `curl -fsSL https://claude.ai/install.sh | bash` (macOS/Linux/WSL), Homebrew (`brew install --cask claude-code`), winget, apt/dnf/apk, or npm (`npm install -g @anthropic-ai/claude-code`, requires Node 22+ to *install* but the shipped binary doesn't use Node at runtime — it's a native postinstall download per-platform, e.g. `@anthropic-ai/claude-code-darwin-arm64`). [Install docs](https://code.claude.com/docs/en/install)
- `claude --version` → `2.1.239 (Claude Code)` (confirmed locally).
- For embedding: the Agent SDK (`@anthropic-ai/claude-agent-sdk` npm, or `claude-agent-sdk` PyPI) bundles the native binary as an optional dependency and is a thin process-management wrapper around the same CLI/stream-json protocol described here. Flotilla can spawn the raw `claude` binary directly — no SDK dependency required.

## Invocation modes

| Mode | Flags |
|---|---|
| Interactive | `claude` or `claude "initial prompt"` |
| Non-interactive ("print") | `-p` / `--print` — required for everything below |
| Structured output | `--output-format text\|json\|stream-json` (default `text`; only valid with `-p`) |
| Streaming input | `--input-format text\|stream-json` (only valid with `-p`) |
| Verbose stream | `--verbose` (see quirk below — effectively **required** with `--output-format stream-json`) |
| Partial/delta streaming | `--include-partial-messages` (requires `-p` + `--output-format stream-json`) |
| Continue most recent session in cwd | `-c` / `--continue` |
| Resume a specific session | `-r` / `--resume [session-id]` |

Full flag reference: [code.claude.com/docs/en/cli-reference](https://code.claude.com/docs/en/cli-reference). `claude --help` **does not list every flag** — the docs page explicitly warns of this, and confirmed locally (e.g. `--advisor`, `--append-subagent-system-prompt` appear in docs but not in `--help` output on this install).

**Full-auto / "yolo" mode — exact flags:**
```
claude -p --dangerously-skip-permissions "prompt"
```
`--dangerously-skip-permissions` bypasses all permission checks outright. The equivalent explicit form is `--permission-mode bypassPermissions`. A third flag, `--allow-dangerously-skip-permissions`, only *adds* bypass as an available mode (e.g. to the Shift+Tab cycle) without starting in it — **not** the same thing, don't use it expecting yolo behavior. Anthropic recommends bypass mode only in network-isolated sandboxes.

`--permission-mode` choices on this build: `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan` (the `auto` classifier-based mode is newer than most published docs — see Quirks).

For CI-reproducible runs, `--bare` skips hook/plugin/MCP/CLAUDE.md auto-discovery (becoming default for `-p` in a future release, per docs); combine with `--allowedTools` to pre-approve tools since bare mode has no settings-based permission source.

## Session & resume

- Session ID: a UUID. First appears as `session_id` on the very first stream line (`system`/`init`), and on every subsequent stream line. Also embedded as the transcript filename on disk.
- `--resume [session-id]` (or interactive picker if omitted, or fuzzy name match) — reopens that exact session, same ID, full history reloaded (verified: asked the resumed session "what was the last tool result" and it correctly recalled it from before the process restarted). Emits a `SessionStart:resume` hook event instead of `SessionStart:startup`.
- `-c` / `--continue` — resumes the most recent session for the current cwd, no ID needed.
- New session: just omit `--resume`/`--continue`; a fresh UUID is generated (`system`/`init`).
- Fork: `--fork-session` (combine with `--resume`/`--continue`) — reuses that session's history but writes to a **new** session ID instead of continuing the original file.
- `--session-id <uuid>` — force a specific UUID for a new session (must be a valid UUID you generate).
- `--no-session-persistence` — run without ever writing a transcript to disk (confirmed: no file appears in `~/.claude/projects/...` afterward). Useful for throwaway/test invocations.

## On-disk transcript

- Path: `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`
- cwd encoding: every `/` in the absolute cwd is replaced with `-`. Verified: cwd `/Users/yodusk/Developer/oss/flotilla` → directory `-Users-yodusk-Developer-oss-flotilla`.
- Subagent transcripts (per multiple independent third-party analyses, not yet in official docs — see Quirks) live in a sibling directory named after the parent session UUID: `<project>/<parent-session-uuid>/subagents/agent-<id>.jsonl`. Every line in a subagent file carries `isSidechain: true`; every line in the top-level file carries `isSidechain: false`. The link from parent→child is the spawning tool call's `tool_use_result.agentId` (on the `Agent`/legacy `Task` tool's result line in the parent file); there is no reverse pointer from the child file back to the parent's tool-call line.
- One line = one JSON object (NDJSON), append-only. Distinct line/entry `type`s seen: `user`, `assistant`, `system`, `attachment`, `queue-operation`, `atis-latch`, `last-prompt`, plus community-documented `file-history-snapshot`, `compact_boundary` (as a `system` subtype). See "On-disk JSONL schema" below.
- How it differs from the live stream (`--output-format stream-json`):
  - **No `system`/`init` or `result` line** on disk — those are stream-only framing events. Session metadata for a resumed session is reconstructed by replaying the `user`/`assistant` lines, not from a stored init record.
  - **No `stream_event`** lines on disk regardless of whether `--include-partial-messages` was used live — only settled, complete assistant/user messages are persisted.
  - Field naming: the on-disk tool-result payload is `toolUseResult` (camelCase); the equivalent live-stream field is `tool_use_result` (snake_case). Confirmed directly: both were captured from the same tool call in probe 2.
  - On disk, every line carries graph-linkage fields not present on the live stream: `uuid` (this line's ID) and `parentUuid` (the line immediately before it in the conversation, forming a linked list/tree, not a flat array).
  - On disk, subagent (sidechain) traffic is fully separated into its own file; on the live stream, subagent messages are normally invisible (only their `tool_use`/`tool_result` blocks show up on the parent channel) unless `--forward-subagent-text` is passed, in which case they're interleaved into the *same* stdout stream and distinguished only by `parent_tool_use_id`.

## Live stream event schema (stream-json)

Enable with `-p --output-format stream-json --verbose` (add `--include-partial-messages` for token-level deltas). **`--verbose` is not optional in practice**: per a third-party writeup and consistent with Anthropic's own examples always including it, running without `--verbose` in this mode is documented elsewhere as a hard error in some builds — always pass it.

Every line is one JSON object, newline-delimited (NDJSON) — do not try to parse the whole stdout as one JSON document.

### `system` / `subtype: "hook_started"` / `"hook_response"`
Only appear if a `SessionStart` (or other) hook is configured; `SessionStart`/`Setup` hook events are always emitted regardless of `--include-hook-events`. Real example (both lines, from probe 1):
```json
{"type":"system","subtype":"hook_started","hook_id":"d82edf5b-2818-4a63-8d1c-e833aebac423","hook_name":"SessionStart:startup","hook_event":"SessionStart","uuid":"f78252ef-c8dc-49a6-9f40-7f9e6b5ebbe4","session_id":"6c39b822-07f3-44ee-873a-79bb211ca784"}
{"type":"system","subtype":"hook_response","hook_id":"d82edf5b-2818-4a63-8d1c-e833aebac423","hook_name":"SessionStart:startup","hook_event":"SessionStart","output":"","stdout":"","stderr":"","exit_code":0,"outcome":"success","uuid":"9992858b-24ab-4589-bde0-6c42bed25411","session_id":"6c39b822-07f3-44ee-873a-79bb211ca784"}
```

### `system` / `subtype: "init"` — always the first "real" line
Session metadata. Real (trimmed) example:
```json
{"type":"system","subtype":"init","cwd":"/Users/yodusk/Developer/oss/flotilla","session_id":"6c39b822-07f3-44ee-873a-79bb211ca784","tools":["Task","Bash","Read","Write","Edit", "..."],"mcp_servers":[{"name":"exa","status":"connected"}],"model":"claude-opus-4-8[1m]","permissionMode":"auto","slash_commands":["...","doctor","..."],"apiKeySource":"none","claude_code_version":"2.1.239","output_style":"default","agents":["claude","Explore","general-purpose"],"skills":["...","code-review","..."],"plugins":[{"name":"pyright-lsp","version":"1.0.0"}],"capabilities":["interrupt_receipt_v1"],"uuid":"7bb06976-522a-402d-86be-082eab2c27c8","memory_paths":{"auto":"/Users/yodusk/.claude/projects/.../memory/"}}
```
Key fields for a parser: `session_id` (the ID to use for `--resume`), `cwd`, `model`, `tools` (available tool names), `mcp_servers` (name + `status`: `connected`/`pending`/`needs-auth`), `permissionMode`, `claude_code_version`. On resume this repeats with the same `session_id` and a preceding `hook_name: "SessionStart:resume"` instead of `"SessionStart:startup"`.

Also seen: `system` / `subtype: "status"`, e.g. `{"type":"system","subtype":"status","status":"requesting", ...}` fired right before each API call starts (not officially documented; observed on every turn in both probes).

Per official Agent SDK docs, other `system` subtypes exist: `"compact_boundary"` (after context compaction), `"informational"` (plain-text banners), `"worker_shutting_down"`.

### `stream_event` — only with `--include-partial-messages`
Wraps a raw Anthropic Messages-API SSE event verbatim in `.event`. This is the same event set as the [Messages API streaming protocol](https://platform.claude.com/docs/en/build-with-claude/streaming). Real examples captured:

`message_start`:
```json
{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-opus-4-8","id":"msg_011CeHbucbG55dxkXFJ58NTz","type":"message","role":"assistant","content":[],"stop_reason":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":7554,"cache_read_input_tokens":16152,"output_tokens":1}}},"session_id":"...","parent_tool_use_id":null,"uuid":"2c1b4946-...","ttft_ms":2584}
```
`content_block_start` (text block):
```json
{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"session_id":"...","parent_tool_use_id":null,"uuid":"..."}
```
`content_block_start` (tool_use block):
```json
{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01VZZJVua3WwYdHxznpdFp9u","name":"Bash","input":{},"caller":{"type":"direct"}}},"session_id":"...","parent_tool_use_id":null,"uuid":"..."}
```
`content_block_delta` (`text_delta`):
```json
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"P"}},"session_id":"...","parent_tool_use_id":null,"uuid":"..."}
```
`content_block_delta` (`input_json_delta` — tool input streams as fragmented JSON text, must be concatenated then parsed once complete):
```json
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\": \"ech"}},"session_id":"...","parent_tool_use_id":null,"uuid":"..."}
```
`content_block_stop`:
```json
{"type":"stream_event","event":{"type":"content_block_stop","index":0},"session_id":"...","parent_tool_use_id":null,"uuid":"..."}
```
`message_delta` (carries final `stop_reason` + cumulative usage for the turn):
```json
{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"input_tokens":2,"cache_creation_input_tokens":5550,"cache_read_input_tokens":18157,"output_tokens":84},"context_management":{"applied_edits":[]}},"session_id":"...","parent_tool_use_id":null,"uuid":"..."}
```
`message_stop`:
```json
{"type":"stream_event","event":{"type":"message_stop"},"session_id":"...","parent_tool_use_id":null,"uuid":"..."}
```
Per [Anthropic streaming docs](https://platform.claude.com/docs/en/build-with-claude/streaming) and [Agent SDK streaming docs](https://code.claude.com/docs/en/agent-sdk/streaming-output): also expect `thinking_delta` and `signature_delta` (extended-thinking models) and `citations_delta`, plus `content_block` types `thinking` / `redacted_thinking` — not captured live in these probes (the probe model didn't emit thinking blocks) but part of the same underlying API event set Claude Code passes through unmodified.

`parent_tool_use_id` is `null` for the main conversation; set to the `Agent` tool_use `id` for subagent messages **only if `--forward-subagent-text` is passed** (v2.1.211+; nested subagents v2.1.219+). Without that flag subagents only surface as `tool_use`/`tool_result` blocks on the parent channel.

### `assistant` — one settled message per turn (always present, regardless of partial-message flag)
Full Anthropic `Message` object nested under `.message`. Real example (tool call):
```json
{"type":"assistant","message":{"model":"claude-opus-4-8","id":"msg_011CeHbvhPGeSAEMmKRgtdsr","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01VZZJVua3WwYdHxznpdFp9u","name":"Bash","input":{"command":"echo hello-flotilla-probe","description":"Echo probe string"},"caller":{"type":"direct"}}],"stop_reason":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":5550,"cache_read_input_tokens":18157,"output_tokens":20}},"parent_tool_use_id":null,"session_id":"...","uuid":"b82c740a-...","timestamp":"2026-08-22T10:08:30.072Z","request_id":"req_011CeHbvggbjRJNceqNdpKKt"}
```
Note `stop_reason` is `null` here on the live stream's `assistant` line even though the turn's real stop reason (`tool_use`) is known — it only lands correctly in the preceding `message_delta` stream_event and in the on-disk copy of this same message (see below). Text-only example already shown in probe 1 output.

### `user` — tool result being fed back to Claude (also used for real human input in `--input-format stream-json`)
```json
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01VZZJVua3WwYdHxznpdFp9u","type":"tool_result","content":"hello-flotilla-probe","is_error":false}]},"parent_tool_use_id":null,"session_id":"...","uuid":"e3fb3a4d-...","timestamp":"2026-08-22T10:08:30.401Z","tool_use_result":{"stdout":"hello-flotilla-probe","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false}}
```
`tool_use_result` (snake_case, live stream only) carries the tool-specific structured result — shape varies per tool (Bash: `stdout`/`stderr`/`interrupted`; other tools have their own shapes, e.g. Read returns file content metadata).

### `rate_limit_event`
Not officially documented; observed after every turn in both probes:
```json
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1787405400,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false},"uuid":"...","session_id":"..."}
```

### `result` — always the last line of a completed turn
```json
{"is_error":false,"duration_api_ms":2756,"num_turns":1,"stop_reason":"end_turn","session_id":"6c39b822-...","total_cost_usd":0.08375099999999999,"usage":{"input_tokens":2,"cache_creation_input_tokens":7554,"cache_read_input_tokens":16152,"output_tokens":5,"output_tokens_details":{"thinking_tokens":0},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"cache_creation":{"ephemeral_1h_input_tokens":7554,"ephemeral_5m_input_tokens":0}},"modelUsage":{"claude-opus-4-8[1m]":{"inputTokens":2,"outputTokens":5,"costUSD":0.08375099999999999,"contextWindow":1000000,"maxOutputTokens":64000}},"permission_denials":[],"terminal_reason":"completed","subtype":"success","api_error_status":null,"result":"PONG","type":"result","duration_ms":2801,"uuid":"..."}
```
Note `type`/`subtype` appear at the very end of the object in real output (field order is not an API contract — don't rely on it). `result` (the final text) is present only when `subtype: "success"`.

## On-disk JSONL schema

Line types actually observed for the same conversation shown above (`~/.claude/projects/-Users-yodusk-Developer-oss-flotilla/f09a80c4-....jsonl`):

1. `queue-operation` (enqueue/dequeue of the initial prompt):
```json
{"type":"queue-operation","operation":"enqueue","timestamp":"...","sessionId":"...","content":"Run: echo hello-flotilla-probe . Then reply with exactly: DONE"}
```
2. `user` (the human prompt) — `message.content` is a **plain string** for a real prompt vs. an **array of blocks** for a tool result:
```json
{"parentUuid":null,"isSidechain":false,"promptId":"f2bcfc19-...","type":"user","message":{"role":"user","content":"Run: echo hello-flotilla-probe . Then reply with exactly: DONE"},"uuid":"0a71037c-...","timestamp":"...","permissionMode":"auto","cwd":"/Users/yodusk/Developer/oss/flotilla","sessionId":"...","version":"2.1.239","gitBranch":"main"}
```
3. `attachment` (this build only — injected context blocks like tool-list deltas, skill listings, token-budget reminders; not part of the documented public schema, treat as opaque/skippable):
```json
{"parentUuid":"...","isSidechain":false,"attachment":{"type":"total_tokens_reminder","text":"<total_tokens>15000000 tokens left</total_tokens>"},"type":"attachment","uuid":"...","cwd":"...","sessionId":"...","version":"2.1.239"}
```
4. `assistant` (settled message — same nested Anthropic `Message` shape as the live stream's `assistant.message`, but with correct `stop_reason` and extra fields `requestId`, `effort`, `cwd`, `gitBranch`, `version`):
```json
{"parentUuid":"...","isSidechain":false,"message":{"model":"claude-opus-4-8","id":"msg_011CeHbvhPGeSAEMmKRgtdsr","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01VZZJVua3WwYdHxznpdFp9u","name":"Bash","input":{"command":"echo hello-flotilla-probe","description":"Echo probe string"}}],"stop_reason":"tool_use","usage":{"input_tokens":2,"output_tokens":84}},"requestId":"req_011CeHbvggbjRJNceqNdpKKt","type":"assistant","uuid":"b82c740a-...","timestamp":"...","effort":"high","cwd":"...","sessionId":"...","version":"2.1.239","gitBranch":"main"}
```
5. `user` carrying a tool result — same block shape as live stream, but `toolUseResult` is **camelCase** (vs. `tool_use_result` snake_case on the live stream) and adds `sourceToolAssistantUUID` (the `uuid` of the assistant line that issued the call):
```json
{"parentUuid":"...","isSidechain":false,"promptId":"f2bcfc19-...","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01VZZJVua3WwYdHxznpdFp9u","type":"tool_result","content":"hello-flotilla-probe","is_error":false}]},"uuid":"e3fb3a4d-...","timestamp":"...","toolUseResult":{"stdout":"hello-flotilla-probe","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false},"sourceToolAssistantUUID":"b82c740a-...","cwd":"...","sessionId":"...","version":"2.1.239"}
```
6. `last-prompt` (bookkeeping line, one per session, overwritten/appended as conversation grows — points at the latest leaf):
```json
{"type":"last-prompt","lastPrompt":"Run: echo hello-flotilla-probe . Then reply with exactly: DONE","leafUuid":"20dbae56-...","sessionId":"..."}
```
Also seen once, before the first real line: `{"type":"atis-latch","atis":"","sessionId":"..."}` — undocumented, appears to be an internal marker, safe to ignore.

Not present in these probe transcripts but documented by multiple independent third-party analyses of Claude Code's format (not yet in official docs — treat as **medium confidence**, verify against your own files before relying on it):
- `system` lines with `subtype: "compact_boundary"` after auto-compaction.
- `file-history-snapshot` lines (pre/post-turn file-state checkpoints, used for `/rewind`-style undo).
- `isCompactSummary` flag on a `user` line when it's a synthetic compaction summary rather than real input.

Common fields on every line: `uuid`, `parentUuid` (linked-list/tree pointer — walk it to reconstruct causal order; **do not** assume file order alone is sufficient once subagents/sidechains are involved), `timestamp` (ISO 8601), `sessionId`, `cwd`, `gitBranch`, `version`.

### Divergence from the live stream, summarized
| | Live stream (`stream-json`) | On-disk JSONL |
|---|---|---|
| Has `system`/`init`, `result` | Yes | No |
| Has `stream_event` (deltas) | Yes, with `--include-partial-messages` | Never |
| Tool-result field name | `tool_use_result` (snake_case) | `toolUseResult` (camelCase) |
| Subagent messages | Merged into main stream only with `--forward-subagent-text`, keyed by `parent_tool_use_id` | Fully separate file per subagent, keyed by `isSidechain` + directory structure |
| Linkage | `session_id`, `parent_tool_use_id` only | Full `uuid`/`parentUuid` graph |
| `assistant.stop_reason` | `null` on the `assistant` line itself (real value only in the `message_delta` stream_event) | Correct value present directly |

## Token usage

- Per-turn (one API call): `usage` object on the `assistant.message.usage` (live stream and on-disk both) and on the `stream_event` `message_start`/`message_delta` events. Fields: `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `cache_creation.ephemeral_5m_input_tokens`, `cache_creation.ephemeral_1h_input_tokens`, `output_tokens_details.thinking_tokens`.
- Cumulative for the whole `-p` invocation (all turns, all tool round-trips): top-level `usage` on the final `result` line, plus `total_cost_usd` (USD) and `modelUsage` (per-model breakdown: `inputTokens`, `outputTokens`, `cacheReadInputTokens`, `cacheCreationInputTokens`, `costUSD`, `contextWindow`, `maxOutputTokens`, `canonicalModel`).
- `result.usage` covers only the **main loop** — subagent token/cost accounting is separate and must be summed from `modelUsage` or from subagent transcript files; do not assume `result.usage` includes subagent spend (documented Agent SDK caveat, applies identically to the CLI's `json`/`stream-json` result).
- `--output-format json` (non-streaming) returns exactly this same `result`-line object shape as the single JSON output.

## Tool calls & results

- Call: an `assistant` message content block, `{"type":"tool_use","id":"toolu_...","name":"<ToolName>","input":{...}}`. `input` streams incrementally as fragmented JSON text via `input_json_delta.partial_json` when partial messages are enabled — concatenate all fragments for a given block `index` before `JSON.parse`-ing; do not try to parse partial fragments individually.
- Result: a `user` message, `{"type":"tool_result","tool_use_id":"toolu_...","content":<string or content-block array>,"is_error":<bool>}`. `content` is a plain string for simple text tools (confirmed: Bash echo output) but per Anthropic's tool_result spec can also be an array of content blocks (e.g. for image results) — a parser must handle both shapes.
- Tool-specific structured metadata (exit code equivalent, stdout/stderr, etc.) lives in the sibling `tool_use_result` (stream) / `toolUseResult` (disk) field, **not** inside the `tool_result` content block itself. Shape is per-tool and undocumented as a formal schema; Bash's shape (`stdout`, `stderr`, `interrupted`, `isImage`, `noOutputExpected`) was confirmed directly.
- Match calls to results by `tool_use_id` (on the result) == `id` (on the call).
- Subagent dispatch: the `Agent` tool (older builds/docs: `Task`) is itself just a `tool_use` block; its `input` carries the subagent prompt/type, and its `tool_use_result`/`toolUseResult` carries (per third-party analysis) an `agentId` used to locate `subagents/agent-<id>.jsonl` on disk.

## Turn completion & errors

- A **turn** (one assistant response cycle) ends when `assistant.message.stop_reason` is non-null and not `tool_use`; if it's `tool_use`, the loop continues (tool executes, `user` tool_result is fed back, another `assistant` message follows).
- A **whole `-p` invocation** ends with exactly one `result` line (stdout), process exits with code 0 on success, non-zero on failure — check exit code as a first-pass signal, then parse `result` for detail.
- `result.subtype` values (from Agent SDK docs, same field on the CLI's `result`/`--output-format json`): `success` (`result` field has the final text), `error_max_turns`, `error_max_budget_usd`, `error_during_execution` (API failure / cancelled request — cost fields may be zeroed, `stop_reason` may be `null`), `error_max_structured_output_retries`. Only `success` guarantees `result` is populated — always check `subtype` before reading `result`.
- `result.is_error` (bool) and `result.errors` (string array, on error subtypes) carry the error signal/detail; `result.stop_reason` mirrors the last assistant turn's stop reason (`end_turn`, `max_tokens`, `refusal`, or `tool_use` on an abnormal stop) — confirmed `"end_turn"` and `"tool_use"` in captured probes.
- `permission_denials` (array, empty in both probes) on `result` — populated when a tool call was blocked by permission rules; check this even on `is_error:false` runs since a denial doesn't necessarily fail the whole turn.
- A subprocess that exits with **no `result` line at all** (crash, killed, SIGTERM) should be treated as a hard failure by any parser — per the Agent SDK docs, a genuine process crash still tries to emit a synthetic final `error_during_execution` result before exiting, but connection/process failures can also occur with no result at all.

## Quirks & drift risks

- **This install is ahead of / diverges from published docs.** `--permission-mode` accepts `auto`/`dontAsk` values and `claude auto-mode ...` subcommands not mentioned in most current doc pages found; multiple flags (`--advisor`, `--append-subagent-system-prompt`, `--json-schema`, `--max-budget-usd`) exist that aren't in `claude --help`'s own listing. **Treat `claude --help` and any single docs page as incomplete; verify against the actual installed version's real output before shipping a parser.**
- **`--max-turns` is not present in this build's `--help` or observed flags** — the Agent SDK-level `maxTurns`/turn-limiting concept exists, but confirm the CLI flag name against your installed version rather than assuming SDK option names map 1:1 to CLI flags.
- **Unparseable lines will happen.** Anything a hook, MCP server, or background subprocess writes to stdout can land inline in the stream; wrap every line's `JSON.parse` in try/catch and skip failures rather than aborting the whole run (recommended pattern from a third-party parser writeup, and consistent with Anthropic's own jq examples piping through `select()`).
- **Ordering is a merge, not a sequence**, once subagents are involved (`--forward-subagent-text`): concurrent subagents interleave at line granularity; never infer causality from line adjacency — use `parent_tool_use_id` (stream) / `uuid`+`parentUuid` (disk) instead.
- **Field order in JSON objects is not stable/meaningful** — e.g. `type`/`subtype` appear at the end of the real `result` object, not the start.
- **`assistant.stop_reason` is `null` on the live-stream `assistant` line itself** even for a completed turn; the authoritative value is only in the `message_delta` stream_event (partial-messages mode) or the on-disk copy of the same message. If you don't use `--include-partial-messages`, you cannot get the real stop_reason until the *next* `result` or `user` line disambiguates it (tool_use vs. end_turn is inferable from whether a `tool_use` content block is present, but `max_tokens`/`refusal` are not otherwise recoverable from that line alone).
- **Buffering/backpressure**: per official docs, if your stdout consumer reads slowly, Claude Code will wait before exiting on a large final response; this behavior changed in v2.1.x (older versions could wait very long) — don't assume the process exits immediately after the last byte is available if you're slow to drain the pipe.
- **`--verbose` + `--output-format stream-json`**: multiple independent write-ups note omitting `--verbose` is treated as a hard error in `-p` + `stream-json` mode on recent builds — always pass it, don't treat it as merely cosmetic.
- **Subagent transcript layout is undocumented by Anthropic** (community-reverse-engineered only, consistent across 3 independent sources checked here). Confidence: medium. Verify against a real multi-agent session on your target version before depending on the `subagents/agent-<id>.jsonl` path or the `agentId` field name.
- **`--dangerously-skip-permissions` vs `--allow-dangerously-skip-permissions`** are easy to confuse — the former is the actual bypass; the latter only makes bypass *available* as a mode without engaging it. A supervisor building "yolo mode" must use the former (or `--permission-mode bypassPermissions`).
- **This session's own tool/skill/plugin config leaked into every captured `init`/`assistant` line** (custom tools like `ScheduleWakeup`, `CronCreate`, a nonstandard `"auto"` permission mode) — a vanilla end-user install will show a much shorter, standard tool list (`Task`, `Bash`, `Read`, `Edit`, `Write`, `Glob`, `Grep`, `WebFetch`, `WebSearch`, `NotebookEdit`, `TodoWrite`/task tools, `ToolSearch`). Don't hardcode this probe's exact `tools` array as the universal set — treat `init.tools` as authoritative *per session*, not a fixed constant.

## Sources

- https://code.claude.com/docs/en/cli-reference
- https://code.claude.com/docs/en/headless
- https://code.claude.com/docs/en/agent-sdk/agent-loop
- https://code.claude.com/docs/en/agent-sdk/streaming-output
- https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode
- https://code.claude.com/docs/en/agent-sdk/typescript
- https://code.claude.com/docs/en/agent-sdk/cost-tracking
- https://code.claude.com/docs/en/install / https://code.claude.com/docs/en/setup
- https://platform.claude.com/docs/en/build-with-claude/streaming
- Local ground truth: `claude --help`, `claude --version` (2.1.239), and three live probes with `-p --output-format stream-json --verbose [--include-partial-messages]` against this machine's install, plus direct inspection of `~/.claude/projects/-Users-yodusk-Developer-oss-flotilla/*.jsonl`
- Community (used only where consistent across multiple independent sources, and flagged as medium-confidence above): https://www.adityabawankule.io/blog/claude-code-session-jsonl-format, https://startdebugging.net/2026/07/stream-nested-subagent-output-from-a-headless-claude-code-run/, https://huytieu.com/blog/anatomy-of-a-claude-code-conversation-transcript/, https://github.com/udhaykumarbala/claude-code-parser, https://docs.rs/skiagram-core (claude_code.rs adapter), https://github.com/d1ll0n/parse-cc
- Open documentation gaps acknowledged by Anthropic (useful to track for drift): https://github.com/anthropics/claude-code/issues/24596, /issues/24612, /issues/24594, /issues/44911, /issues/41265
