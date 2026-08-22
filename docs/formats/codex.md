# Codex CLI — Formats

Verified against `codex-cli 0.148.0` (`/opt/homebrew/bin/codex`, installed locally), live `codex exec --json` / `codex app-server` runs, local `~/.codex/sessions/**/*.jsonl` rollouts, and the `openai/codex` GitHub source (`codex-rs/exec/src/exec_events.rs`, `codex-rs/app-server-protocol/src/protocol/{common,v2}.rs`, `codex-rs/rollout/src/*`).

## Binary & install

- Binary name: `codex`. Installed here via Homebrew at `/opt/homebrew/bin/codex`; also distributable via `npm i -g @openai/codex`.
- `codex --version` → `codex-cli 0.148.0`.
- `$CODEX_HOME` defaults to `~/.codex` (config, auth, sessions, hooks all live there).

## Invocation modes

- `codex [PROMPT]` — interactive TUI. With no subcommand, all flags are forwarded to the interactive CLI.
- `codex exec [PROMPT]` (alias `codex e`) — non-interactive, single-shot. This is what a supervisor should spawn.
- `codex app-server` — JSON-RPC 2.0 server over stdio/websocket/unix-socket, built for rich clients (VS Code extension, etc.). Preferred for a real supervisor app driving multiple concurrent threads/turns.
- `codex mcp-server` — Codex as an MCP server (stdio); not relevant to a process-supervisor use case.
- `codex exec resume [SESSION_ID] [PROMPT]` / `codex exec fork <SESSION_ID> [PROMPT]` — continue/branch a prior exec session.

### Key `codex exec` flags

| Flag | Effect |
|---|---|
| `--json` | Emit JSONL events on stdout (see schema below). Without it, only the final message prints to stdout; progress goes to stderr either way. |
| `-o, --output-last-message <FILE>` | Write the final agent message to a file (still also printed to stdout). |
| `--output-schema <FILE>` | Require the final response to conform to a JSON Schema file; final text on stdout becomes that JSON. |
| `-s, --sandbox <read-only\|workspace-write\|danger-full-access>` | Sandbox policy for model-run shell commands. Default for `exec` is **read-only**. |
| `-a, --ask-for-approval <untrusted\|on-request\|never>` | (Interactive `codex` / app-server; `exec` has no `-a` flag — approval is implied by sandbox mode and `--dangerously-bypass-approvals-and-sandbox`.) |
| `--ephemeral` | Don't persist a rollout file to disk. |
| `--skip-git-repo-check` | Codex normally refuses to run outside a git repo; this overrides that. |
| `-C, --cd <DIR>` | Working root for the agent. |
| `-m, --model <MODEL>` | Model override. |
| `--full-auto` | **Deprecated on `exec`** (prints a warning); on interactive/`codex`/`app-server` clients it's shorthand for `--ask-for-approval on-request --sandbox workspace-write` — *not* fully unattended. |
| `--dangerously-bypass-approvals-and-sandbox` (clap alias **`--yolo`**) | Skip **all** confirmation prompts and run with **no OS sandbox at all** (not merely full filesystem access under a sandbox — the sandbox itself is bypassed). Source: `codex-rs/exec/src/cli.rs`, `#[arg(long = "dangerously-bypass-approvals-and-sandbox", alias = "yolo", ...)]`. `--yolo` is a real alias but does not appear in `--help` output. |
| `--ignore-user-config` | Skip loading `$CODEX_HOME/config.toml` (auth still uses `CODEX_HOME`). |

**FULL-AUTO / unattended-supervisor recipe.** For a subprocess-driven macOS supervisor there are two distinct tiers, confirmed from `docs/sandbox.md` and `codex-rs/exec/src/cli.rs`:

1. **Full access, still OS-sandboxed, never prompts** (recommended default for "yolo" mode in an app that still wants Seatbelt/Landlock containment):
   ```
   codex exec --json --sandbox danger-full-access -a never "<prompt>"
   ```
   Note: `-a/--ask-for-approval` is **not** a flag on `codex exec` (see table above) — `exec` derives "never ask" from the sandbox choice; there is no separate approval flag to pass on `exec`. `-a never` only applies to interactive `codex` / `app-server` turns.
2. **True YOLO — no sandbox, no prompts at all:**
   ```
   codex exec --json --dangerously-bypass-approvals-and-sandbox "<prompt>"
   # equivalently: codex exec --json --yolo "<prompt>"
   ```
   This is the closest non-interactive equivalent to "full-auto danger-full-access + never", and is what most CI/automation setups actually mean by "yolo mode". It conflicts with `--full-auto` (clap `conflicts_with = "full_auto"`) and is documented as "EXTREMELY DANGEROUS... intended solely for running in environments that are externally sandboxed."

For `codex` (interactive) and `codex app-server`, the same `--dangerously-bypass-approvals-and-sandbox` / `--yolo` flag exists and additionally conflicts with `--approval-policy`/`--full-auto`.

## Session & resume

- Every thread has a **thread/session id** (UUIDv7-shaped string, e.g. `01a028f1-8136-7a00-bb65-3974b07b327b`).
  - In `exec --json`: emitted as `thread_id` on the very first `thread.started` event.
  - In `app-server`: emitted as `thread.id` inside the `thread/start` response's `result.thread.id`, and again in the `thread/started` notification (`params.thread.id`). Internally this is still called `sessionId` in the same payload (`"sessionId":"01a028f3-...` — identical value to `thread.id`).
  - In rollout files: the `session_meta` line's `payload.session_id` / `payload.id`, and it's embedded in the rollout filename itself.
- **Resume:**
  - `codex exec resume --last "<prompt>"` — resume the most recently recorded session in the current cwd.
  - `codex exec resume <SESSION_ID> "<prompt>"` — resume by UUID (or thread name). `--all` disables cwd filtering when searching.
  - `codex exec fork <SESSION_ID> ["<prompt>"]` — branch history into a new thread id.
  - app-server: `thread/resume` (reopen by id so later `turn/start` calls append), `thread/fork` (copy history into a new thread id, optional `lastTurnId` boundary).
  - Interactive TUI: `codex resume` (picker, or `--last`), `codex fork` (picker, or `--last`).
- `experimental_resume`: not exposed as a documented `config.toml` key in the fetched sources/docs for this version — resume is driven entirely by the `resume`/`fork` subcommands and app-server `thread/resume`/`thread/fork` methods, not a config toggle. Treat any reference to `experimental_resume` as unverified/legacy; do not build a parser around it.

## On-disk rollout

- **Path pattern:** `~/.codex/sessions/YYYY/MM/DD/rollout-<TIMESTAMP>-<UUID>.jsonl`, e.g.:
  `~/.codex/sessions/2026/07/24/rollout-2026-07-24T17-08-39-019f943e-00d2-7c62-9359-6573b5502a96.jsonl`
  Older files (pre ~2025-09) may lack the date-sharded `YYYY/MM/DD` layout and use `.json` (single JSON, not JSONL) — treat those as legacy/unsupported for a live parser.
  `--ephemeral` skips writing this file entirely.
- **Line shape (`RolloutLine`)**, one JSON object per line:
  ```json
  {"timestamp":"2026-07-24T13:09:07.366Z","type":"<item-type>","payload":{...}}
  ```
  `type`/`payload` is a tagged union (`RolloutItem` from `codex-history`, re-exported by `codex-rs/rollout`). An optional `ordinal` field (u64) may appear for sequence tracking on newer paginated threads.
- **`RolloutItem` variants seen live** (types confirmed by `is_persisted_rollout_item`/`decode_rollout_item` in `codex-rs/rollout/src/policy.rs` and `codex-rs/state`):
  - `session_meta` — `SessionMetaItem`: `session_id`/`id`, `timestamp`, `cwd`, `originator` (e.g. `"codex-tui"`, `"codex-exec"`), `cli_version`, `source`, `thread_source`, `model_provider`, `base_instructions`. First line of every rollout.
  - `turn_context` — `TurnContextItem`: per-turn snapshot — `turn_id`, `cwd`, `workspace_roots`, `approval_policy`, `approvals_reviewer`, `sandbox_policy` (`{"type":"danger-full-access"}` etc.), `model`, `personality`, `collaboration_mode`.
  - `response_item` — raw model I/O (`ResponseItem`): `message` (role `developer`/`user`/`assistant`), `reasoning` (with `encrypted_content`, only readable by OpenAI), `function_call` / `function_call_output` (MCP/tool calls), `tool_search_call` / `tool_search_output`.
  - `event_msg` — protocol-level events, tagged by `payload.type`: `task_started`, `user_message`, `agent_message`, `token_count` (usage — see below), `mcp_tool_call_end`, `task_complete` (carries `last_agent_message`), and others (`ThreadRolledBack`, `TurnAborted`, etc. per `codex-rs/protocol/src/protocol.rs::EventMsg`).
  - `world_state` — full/partial snapshot of loaded context (AGENTS.md text, etc.), `payload.full: bool`.
  - `Compacted` — history-compaction summary items.
  - `InterAgentCommunication` / `InterAgentCommunicationMetadata` — multi-agent message passing.
  - `SecurityRiskScore` — present in newer builds; not seen in local captures.
- **Compression:** `codex-rs/rollout/src/compression.rs` exposes `RolloutLineReader`, `existing_rollout_path`, `plain_rollout_path`, and `spawn_rollout_compression_worker` — rollouts can be transparently `.zst`-compressed on disk (older/inactive sessions) and decompressed on read. A parser reading raw files must check for a `.jsonl.zst` sibling/rename, not assume plain `.jsonl` always exists uncompressed.
- **SQLite index:** `codex-rs/state/` extracts searchable metadata (title from first `UserMessage`, token usage from `TokenCount` events, git info from `SessionMetaLine`, goals from `ThreadGoalUpdated`) into a SQLite-backed index used by `thread/list`, `thread/read`, etc. in app-server, and by `codex resume`'s picker. Do not treat the SQLite DB as authoritative for content — it's a derived index; the JSONL is the source of truth. `codex migrate-rollouts` inspects/migrates legacy sessions into the paginated/indexed form.

## exec --json event schema

Source of truth: `codex-rs/exec/src/exec_events.rs` (`ThreadEvent` enum, `#[serde(tag = "type")]`). All examples below are real captured output from `codex exec --json` (v0.148.0).

**Top-level `type` values:** `thread.started`, `turn.started`, `turn.completed`, `turn.failed`, `item.started`, `item.updated`, `item.completed`, `error`.

```jsonl
{"type":"thread.started","thread_id":"01a028f1-8136-7a00-bb65-3974b07b327b"}
{"type":"turn.started"}
{"type":"turn.completed","usage":{"input_tokens":33592,"cached_input_tokens":27136,"cache_write_input_tokens":0,"output_tokens":97,"reasoning_output_tokens":0}}
{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'gpt-nonexistent-bogus-model' model is not supported when using Codex with a ChatGPT account.\"}}"}}
{"type":"error","message":"{\"type\":\"error\",\"status\":400,...}"}
```

`ThreadStartedEvent = {thread_id: string}`. `TurnStartedEvent = {}` (empty object — no fields). `TurnCompletedEvent = {usage: Usage}`. `TurnFailedEvent = {error: ThreadErrorEvent}` where `ThreadErrorEvent = {message: string}` (message is frequently itself a JSON-encoded string from the upstream API — parse it as JSON if it starts with `{`). Standalone `error` events (not nested in `turn.failed`) use the same `{type:"error", message}` shape and are non-fatal/warning-ish (e.g. deprecation notices, config warnings) — they don't necessarily end the turn.

### `item.*` events

`ItemStartedEvent`/`ItemUpdatedEvent`/`ItemCompletedEvent` all wrap a single `item: ThreadItem`:
```rust
struct ThreadItem { id: String, #[serde(flatten)] details: ThreadItemDetails }
```
`ThreadItemDetails` is `#[serde(tag = "type", rename_all = "snake_case")]`, so on the wire the item object is `{"id": "...", "type": "<kind>", ...kind-specific fields}`. Item ids (`item_0`, `item_1`, ...) are assigned by the exec JSONL mapper itself (`event_processor_with_jsonl_output.rs`), not the underlying app-server item id — they are stable within one `codex exec` invocation but are **not** the same ids app-server would emit for the identical turn.

Important asymmetry from `map_started_item`/`map_completed_item_mut`: **`agent_message` and `reasoning` items never get an `item.started` event** — they only ever appear as `item.completed` (reasoning items are additionally suppressed entirely if their summary text is empty, which is common when reasoning summaries aren't requested). Every other item kind (`command_execution`, `file_change`, `mcp_tool_call`, `web_search`, `todo_list`, `error`) gets `item.started` (status `in_progress`) then `item.completed` (or is left dangling `in_progress` if the process is killed mid-turn — a parser must handle a turn ending without a completion for a started item).

**Item kinds** (`type` field), each with real captured examples:

- **`agent_message`** — `{text: string}`. Final or intermediate assistant text.
  ```json
  {"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Hello!\n\nFiles in this directory:\n\n- `.git/`\n- `a.txt`"}}
  ```
- **`reasoning`** — `{text: string}` (joined reasoning-summary lines). Suppressed if empty.
- **`command_execution`** — `{command: string, aggregated_output: string, exit_code: number|null, status: "in_progress"|"completed"|"failed"|"declined"}`.
  ```json
  {"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'ls -la'","aggregated_output":"","exit_code":null,"status":"in_progress"}}
  {"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc 'ls -la'","aggregated_output":"total 8\ndrwxr-xr-x@  4 yodusk  wheel   128 Aug 22 14:08 .\n...\n","exit_code":0,"status":"completed"}}
  ```
- **`file_change`** — `{changes: [{path: string, kind: "add"|"delete"|"update"}], status: "in_progress"|"completed"|"failed"}` (source `Failed`/`Declined` both collapse to exec's `"failed"`). Emitted **only as a completed event** in practice for a straightforward patch (an `item.started` can appear for longer-running patches).
  ```json
  {"type":"item.completed","item":{"id":"item_1","type":"file_change","changes":[{"path":"/private/tmp/flotilla-codex-test/notes.txt","kind":"add"}],"status":"completed"}}
  ```
- **`mcp_tool_call`** — `{server: string, tool: string, arguments: <json>, result: {content: [...], meta?: <json>, structured_content: <json>|null}|null, error: {message: string}|null, status: "in_progress"|"completed"|"failed"}`.
  ```json
  {"type":"item.started","item":{"id":"item_0","type":"mcp_tool_call","server":"exa","tool":"web_search_exa","arguments":{"query":"openai codex cli","numResults":1},"result":null,"error":null,"status":"in_progress"}}
  {"type":"item.completed","item":{"id":"item_0","type":"mcp_tool_call","server":"exa","tool":"web_search_exa","arguments":{"query":"openai codex cli","numResults":1},"result":{"content":[{"type":"text","text":"Title: CLI – Codex | OpenAI Developers\n...","_meta":{"searchTime":1239.7}}],"structured_content":null},"error":null,"status":"completed"}}
  ```
- **`web_search`** — `{id: string, query: string, action: WebSearchAction}`. `WebSearchAction` (tagged enum, from `codex_protocol::models`): `{"type":"search","query":string|null,"queries":string[]|null}` | `{"type":"open_page","url":string|null}` | `{"type":"find_in_page","url":string|null,"pattern":string|null}` | `{"type":"other"}`. Not reproduced live in this session (the interactive `--search` flag doesn't exist on `codex exec`; live web search requires `-c 'tools.web_search=true'`/an MCP web-search tool instead) — shape is taken directly from source, not guessed.
- **`todo_list`** — `{items: [{text: string, completed: bool}]}`. Gets both `item.started` (initial plan) and repeated `item.completed`/`item.updated` as steps toggle.
  ```json
  {"type":"item.started","item":{"id":"item_2","type":"todo_list","items":[{"text":"Identify refactor boundaries and current dependencies","completed":false},{"text":"Extract the target logic into small focused modules","completed":false},{"text":"Verify behavior and update documentation","completed":false}]}}
  ```
- **`collab_tool_call`** — multi-agent/subagent spawning (`SpawnAgent`/`SendInput`/`Wait`/`CloseAgent`), with `agents_states: {[threadId]: {status, message}}`. Present in source (`ThreadItemDetails::CollabToolCall`) but not covered by `developers.openai.com/codex/noninteractive`'s public item-type list; treat as present-but-undocumented on the public site, and confirm via `codex app-server generate-json-schema` per-install before depending on it.
- **`error`** — `{message: string}`. Non-fatal error surfaced as a turn item (distinct from the top-level `error` event and from `turn.failed`).

## app-server JSON-RPC schema

Confirmed live against `codex app-server` (stdio, default transport) with a raw JSON-RPC handshake. **The `"jsonrpc":"2.0"` field is genuinely omitted on the wire** in both directions — confirmed from real captured traffic, not just the docs' claim.

### Requests (client → server)

- `initialize` — first call on any connection. `params: {clientInfo: {name, title, version}, capabilities?: {experimentalApi?, optOutNotificationMethods?, ...}}`. Real response:
  ```json
  {"id":0,"result":{"userAgent":"flotilla_probe/0.148.0 (Mac OS 26.6.0; arm64) ghostty/1.3.1 (flotilla_probe; 0.1.0)","codexHome":"/Users/yodusk/.codex","platformFamily":"unix","platformOs":"macos"}}
  ```
- `initialized` (notification, no `id`) — must follow `initialize` before any other call; server rejects earlier calls with `"Not initialized"`.
- `thread/start` — `params: {cwd?, model?, sandboxPolicy?/sandbox?, ...}` (v2 `ThreadStartParams`; passing `sandboxPolicy: null` falls back to config default — in the live run this resolved to `workspaceWrite`). Response `result.thread` is the full thread object (id, path, model, sandbox, approvalPolicy, etc. — real shape below). Also fires a `thread/started` notification with the same thread payload, and auto-subscribes the connection to that thread's turn/item events.
- `thread/resume` — same params shape, reopens by id.
- `thread/fork` — copies history into a new thread id, optional `lastTurnId` boundary; also accepts `ephemeral: true`.
- `turn/start` — `params: {threadId: string, input: [{type:"text", text: string}, ...], model?, cwd?, sandboxPolicy?, ...}`. Response is the initial `turn` object (`status: "inProgress"`, empty `items`); real turn progress streams via notifications, not the response.
- `turn/steer` — append input to the in-flight turn without starting a new one.
- `turn/interrupt` — cancel an in-flight turn; turn ends with `status: "interrupted"`.
- `thread/list`, `thread/read`, `thread/archive`, `thread/delete`, `thread/unsubscribe`, `command/exec` (one-off sandboxed shell command without a thread), `review/start`, etc. — see full list in `codex-rs/app-server/README.md` / `developers.openai.com/codex/app-server`.

### Notifications (server → client)

Real captured sequence for a single `turn/start` (`"Say hi in exactly 3 words."`), in order:

```json
{"method":"remoteControl/status/changed","params":{"status":"disabled","serverName":"yodusks-mac.local","installationId":"97b251e4-...","environmentId":null},"emittedAtMs":1787393428709}
{"method":"thread/started","params":{"thread":{"id":"01a028f3-52a6-7641-a224-d9cf86dcd320","sessionId":"01a028f3-52a6-7641-a224-d9cf86dcd320","status":{"type":"idle"},"path":"/Users/yodusk/.codex/sessions/2026/08/22/rollout-....jsonl","cwd":"/tmp/...","model":null,"turns":[],...}},"emittedAtMs":...}
{"method":"mcpServer/startupStatus/updated","params":{"threadId":"...","name":"exa","status":"starting","error":null,"failureReason":null},"emittedAtMs":...}
{"method":"thread/status/changed","params":{"threadId":"...","status":{"type":"active","activeFlags":[]}},"emittedAtMs":...}
{"method":"turn/started","params":{"threadId":"...","turn":{"id":"01a028f3-5a6d-7843-86e2-5c7105e722b8","status":"inProgress","startedAt":1787393432,...}},"emittedAtMs":...}
{"method":"hook/started","params":{"threadId":"...","turnId":"...","run":{"id":"session-start:0:...","eventName":"sessionStart","status":"running",...}},"emittedAtMs":...}
{"method":"hook/completed","params":{"threadId":"...","turnId":"...","run":{...,"status":"completed","durationMs":35}},"emittedAtMs":...}
{"method":"item/started","params":{"item":{"type":"userMessage","id":"01a028f3-5fb5-...","content":[{"type":"text","text":"Say hi in exactly 3 words.","text_elements":[]}]},"threadId":"...","turnId":"...","startedAtMs":...},"emittedAtMs":...}
{"method":"item/completed","params":{"item":{"type":"userMessage",...},"threadId":"...","turnId":"...","completedAtMs":...},"emittedAtMs":...}
{"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_060ab8fb...","text":"","phase":"final_answer","memoryCitation":null},"threadId":"...","turnId":"...","startedAtMs":...},"emittedAtMs":...}
{"method":"item/agentMessage/delta","params":{"threadId":"...","turnId":"...","itemId":"msg_060ab8fb...","delta":"Hi"},"emittedAtMs":...}
{"method":"item/agentMessage/delta","params":{"threadId":"...","turnId":"...","itemId":"msg_060ab8fb...","delta":" there"},"emittedAtMs":...}
{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_060ab8fb...","text":"Hi there, friend!","phase":"final_answer","memoryCitation":null},"threadId":"...","turnId":"...","completedAtMs":...},"emittedAtMs":...}
{"method":"thread/tokenUsage/updated","params":{"threadId":"...","turnId":"...","tokenUsage":{"total":{"totalTokens":19107,"inputTokens":19098,"cachedInputTokens":11008,"cacheWriteInputTokens":0,"outputTokens":9,"reasoningOutputTokens":0},"last":{...same shape...},"modelContextWindow":258400}},"emittedAtMs":...}
{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":...},"secondary":null,"credits":{...},"planType":"prolite",...}},"emittedAtMs":...}
{"method":"thread/status/changed","params":{"threadId":"...","status":{"type":"idle"}},"emittedAtMs":...}
{"method":"turn/completed","params":{"threadId":"...","turn":{"id":"...","items":[{"type":"agentMessage",...,"text":"Hi there, friend!"}],"itemsView":"summary","status":"completed","error":null,"startedAt":1787393432,"completedAt":1787393435,"durationMs":3197}},"emittedAtMs":...}
```

Notes confirmed from this trace:
- Every notification carries an `emittedAtMs` timestamp — a JSON-RPC extension, not part of vanilla JSON-RPC 2.0.
- app-server item `type` values are **camelCase** (`userMessage`, `agentMessage`) — different casing from exec's **snake_case** (`agent_message`). A shared parser must not assume the two formats share item-type strings.
- `item/agentMessage/delta` streams incremental text (`delta` field) between `item/started` and `item/completed` for `agentMessage` items — exec's JSONL format has no equivalent streaming; it only emits the final `item.completed`.
- `thread/tokenUsage/updated` fires once per turn (after the last content, before `turn/completed`), with **camelCase field names** distinct from exec's usage object (`totalTokens` not `total_tokens`, `inputTokens` not `input_tokens`, etc.), nested under `.total` and `.last`.
- Full `ServerNotification` method list (from `codex-rs/app-server-protocol/src/protocol/common.rs`, `server_notification_definitions!`): `error`, `thread/started`, `thread/status/changed`, `thread/archived`, `thread/deleted`, `thread/unarchived`, `thread/closed`, `thread/reverted` (experimental), `skills/changed`, `thread/name/updated`, `thread/goal/updated`, `thread/goal/cleared`, `thread/queue/changed` (experimental), `project/changed` (experimental), `thread/project/updated` (experimental), `thread/environment/connected`/`disconnected` (experimental), `thread/settings/updated` (experimental), `thread/tokenUsage/updated`, `turn/started`, `hook/started`, `turn/completed`, `hook/completed`, `turn/diff/updated`, `turn/plan/updated`, `item/started`, `item/autoApprovalReview/started`/`completed`, `item/completed`, `rawResponseItem/completed` (internal/Cloud-only), `item/agentMessage/delta`, `item/plan/delta` (experimental), `command/exec/outputDelta`, `process/outputDelta`/`process/exited` (experimental), `item/commandExecution/outputDelta`, `item/commandExecution/terminalInteraction`, `item/fileChange/outputDelta`, `serverRequest/resolved`, `item/mcpToolCall/progress`, `mcpServer/oauthLogin/completed`, `mcpServer/startupStatus/updated`, `account/updated`, `account/rateLimits/updated`, `app/list/updated`, `item/reasoning/summaryTextDelta`, `item/reasoning/summaryPartAdded`, `item/reasoning/textDelta`, `thread/compacted` (deprecated), `model/rerouted`, `thread/realtime/started` (experimental), `remoteControl/status/changed`.
- Server → client **requests** (need a response, not just a notification): `item/commandExecution/requestApproval`, and the analogous file-change/patch approval request — these are how approval prompts are delivered in app-server mode (unlike `exec`, which has no interactive approval channel and just fails/denies per its sandbox policy).

## Token usage

- **`exec --json`**: only on `turn.completed`, top-level `usage` object — flat, snake_case: `{input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens, reasoning_output_tokens}`. No running/cumulative total is given inside the exec stream itself — each `turn.completed.usage` is per-turn (confirmed: consecutive turns in the same session showed the *same* `cached_input_tokens` growing turn over turn, i.e. it does look like the API's per-request usage figure, not a session cumulative counter — treat `usage` as "this turn's request," and sum across turns yourself if you need a session total).
- **`app-server`**: `thread/tokenUsage/updated` notification, `params.tokenUsage` — camelCase, and explicitly split into `.total` (session-cumulative) and `.last` (most recent turn), plus `modelContextWindow`: `{total: {totalTokens, inputTokens, cachedInputTokens, cacheWriteInputTokens, outputTokens, reasoningOutputTokens}, last: {...same fields...}, modelContextWindow: number}`.
- **rollout JSONL**: `event_msg` line with `payload.type == "token_count"`, `payload.info.total_token_usage` / `payload.info.last_token_usage` (snake_case, same total/last split as app-server) plus `payload.rate_limits`.

## Tool calls & results

| | exec --json | app-server | rollout |
|---|---|---|---|
| Shell command | `item` type `command_execution`: `command`, `aggregated_output` (buffered, grows across `item.updated`... in practice only start/complete were observed), `exit_code`, `status` | item `type: "commandExecution"` (camelCase); streamed via `item/commandExecution/outputDelta` (base64 chunks) instead of a single aggregated string; approvals via `item/commandExecution/requestApproval` server-request | `response_item` (`function_call`/`function_call_output` for the underlying model turn) plus legacy `event_msg` `exec_command_end` for older/legacy-history threads |
| File change / patch | `item` type `file_change`: `changes: [{path, kind}]`, `status` | item `type: "fileChange"`; streamed via `item/fileChange/outputDelta` | `response_item` (the model's patch tool call) |
| MCP tool call | `item` type `mcp_tool_call`: `server`, `tool`, `arguments`, `result.content[]`/`.structured_content`, `error.message`, `status` | item `type: "mcpToolCall"`; progress via `item/mcpToolCall/progress` | `response_item` `function_call`/`function_call_output` (raw), plus legacy `event_msg` `mcp_tool_call_end` (`{call_id, invocation:{server,tool,arguments}, duration:{secs,nanos}, result:{Ok:{content:[...]}}\|{Err:...}}`) |
| Plan / todo | `item` type `todo_list`: `items: [{text, completed}]` | item `type: "plan"`(?) streamed via `item/plan/delta` (experimental) | `EventMsg::ItemCompleted` with `TurnItem::Plan` (paginated) or legacy plan events |
| Web search | `item` type `web_search`: `id`, `query`, `action` (tagged enum) | not directly observed; presumably `item/started`/`completed` with an equivalent `webSearch` item type, given the shared `WebSearchAction`/`WebSearchItem` types in `codex-protocol` | legacy `event_msg` `web_search_end`/`web_search_begin` |

## Turn completion & errors

- **Detecting turn end in `exec --json`:** the stream ends the turn on exactly one of `turn.completed` (success, has `usage`) or `turn.failed` (has `error.message`). A parser should treat "process exited without either event" as an abnormal/crashed turn.
- **Process exit codes for `codex exec`:** `0` on a normal successful run (verified: `turn.completed` → exit 0). `1` on a failed turn (verified: invalid-model run emitted `turn.failed` then exited 1). CLI-argument/usage errors (e.g. unknown flag) also exit non-zero before any JSON is printed at all — a parser must handle "zero JSONL lines, non-zero exit" as a distinct case from a `turn.failed` event.
- **`app-server`:** turn end is the `turn/completed` notification (`turn.status`: `"completed"` | `"interrupted"` | possibly `"failed"`— error surfaces via the `error` notification and/or `turn.error` field, not fully exercised live here). `turn/interrupt` explicitly produces `status: "interrupted"`.
- **Error shapes differ by layer:** upstream API errors surface as a JSON-encoded *string* inside `error.message` (see the `turn.failed` example above — that's the raw OpenAI API error body, string-escaped one level). Config/deprecation warnings surface as ordinary `item.completed` items of type `error` (exec) rather than terminal errors. Parse defensively: try `JSON.parse` on `error.message`/`ThreadErrorEvent.message`, fall back to treating it as plain text.

## Quirks & drift risks

- **`app-server` is explicitly `[experimental]`** per `codex --help` — expect breaking changes between minor versions. Regenerate schemas per-install with `codex app-server generate-ts --out DIR` / `generate-json-schema --out DIR`; don't hand-maintain TypeScript/JSON-Schema copies across Codex upgrades.
- **exec and app-server item vocabularies are not interchangeable**: `snake_case` types + flat fields in exec vs `camelCase` methods/types + richer nested objects (deltas, hooks, approvals) in app-server. Do not write one item-parsing function for both formats.
- **`.zst` rollout compression** exists (`codex-rs/rollout/src/compression.rs`) but was not observed on any local session file in this environment (all local files were plain `.jsonl`/`.json`) — implement decompression defensively (check extension / magic bytes) rather than assuming it's active, since it may only kick in for archived/inactive sessions.
- **Legacy vs paginated rollout/history modes** (`ThreadHistoryMode::Legacy` default vs `Paginated`) change *which* `event_msg` variants get persisted at all (see `should_persist_event_msg` in `codex-rs/rollout/src/policy.rs`) — e.g. `agent_message`/`web_search_end`/`mcp_tool_call_end` are only persisted as legacy `event_msg` lines under `Legacy` mode; `Paginated` mode instead persists them as `ItemCompleted` events carrying a `TurnItem`. A rollout parser must handle both encodings of the same semantic content.
- **`--full-auto` is a false friend for automation**: it still asks for approval on anything outside the sandbox (`on-request`), and it's *deprecated* specifically on `codex exec` (prints a warning, kept only for backward compat). Don't use it as the "no prompts" flag — see the FULL-AUTO recipe above.
- **`--yolo` is a real but hidden alias**: works as clap alias for `--dangerously-bypass-approvals-and-sandbox` but doesn't appear in `--help` text — verified from source, not docs.
- **`codex exec` has no `-a/--ask-for-approval` flag** — only interactive `codex` and `app-server` expose approval-policy granularity; `exec`'s only levers are `--sandbox` and the bypass flag. Don't assume flag parity across subcommands.
- **Item id namespaces don't line up.** exec's `item_N` ids are synthetic and per-invocation; app-server ids are real per-item ids (`msg_...`, thread-local UUIDs for user messages); rollout `response_item`/`call_id`s are yet another id space (OpenAI Responses-API ids like `rs_...`, `fc_...`, `call_...`). Never assume an id from one surface resolves in another.
- **`turn.completed.usage` in exec is per-turn, not cumulative** — sum it yourself for a running total, or use app-server's `tokenUsage.total` which is already cumulative.
- **Sandbox policy shape varies**: CLI flag values (`read-only`/`workspace-write`/`danger-full-access`) vs JSON representations seen live (`{"type":"danger-full-access"}` in rollout `turn_context`; `{"type":"workspaceWrite","writableRoots":[],"networkAccess":false,...}` in app-server's `thread/start` response) — note the **snake_case-with-dashes CLI value** vs **camelCase JSON tag** (`danger-full-access` → `dangerFullAccess`? not fully confirmed — the live capture only exercised `workspaceWrite`/`danger-full-access`-as-turn-context; verify the `dangerFullAccess` camelCase spelling against a live app-server response before hardcoding it).
- **MCP servers can gate exec entirely**: per the official non-interactive docs, an MCP server configured with `required = true` that fails to initialize makes `codex exec` exit with an error rather than continuing — a supervisor spawning `exec` should not assume "it started" implies "it will produce JSONL."
- **Git-repo requirement**: `codex exec` refuses to run outside a git repository unless `--skip-git-repo-check` is passed — a real gotcha for a supervisor spawning it against arbitrary/scratch directories.

## Sources

- https://developers.openai.com/codex/noninteractive
- https://developers.openai.com/codex/app-server
- https://developers.openai.com/codex/cli/reference
- https://developers.openai.com/codex/agent-approvals-security
- https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md
- https://raw.githubusercontent.com/openai/codex/main/codex-rs/exec/src/exec_events.rs
- https://github.com/openai/codex/blob/main/codex-rs/exec/src/event_processor_with_jsonl_output.rs
- https://github.com/openai/codex/blob/main/codex-rs/exec/src/cli.rs
- https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs
- https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2.rs
- https://raw.githubusercontent.com/openai/codex/main/codex-rs/rollout/src/lib.rs
- https://raw.githubusercontent.com/openai/codex/main/codex-rs/rollout/src/policy.rs
- https://github.com/openai/codex/blob/main/codex-rs/rollout/src/model_context.rs
- https://github.com/openai/codex/blob/main/codex-rs/core/src/codex/rollout_reconstruction.rs
- https://github.com/openai/codex/blob/main/codex-rs/core/src/web_search.rs
- https://github.com/openai/codex/blob/main/codex-rs/protocol/src/items.rs
- https://github.com/openai/codex/blob/main/docs/sandbox.md
- https://deepwiki.com/openai/codex/3.5.2-rollout-persistence-and-replay
- Local: `codex --help`, `codex exec --help`, `codex exec resume --help`, `codex app-server --help`, `~/.codex/sessions/**/*.jsonl` (real rollout files), and live `codex exec --json` / `codex app-server` stdio sessions run during this research (2026-08-22, codex-cli 0.148.0).
