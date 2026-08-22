# pi (earendil-works) — Formats

Scope: `@earendil-works/pi-coding-agent` CLI, from the `earendil-works/pi` monorepo (mirrored at
`badlogic/pi-mono`; `badlogic` is the primary author). NOT the Python `Ashutosh0428/pi-agent`.

Confidence: high for CLI flags, RPC commands/responses, JSON event envelope, and session file
format — these are quoted verbatim from `docs/*.md` in the repo, which are shipped, versioned
docs. Medium-high for the exact `AssistantMessageEvent` and `AgentEvent`/`AgentSessionEvent` union
shapes — pulled directly from the TypeScript source (`packages/ai/src/types.ts`,
`packages/agent/src/types.ts`, `packages/coding-agent/src/core/agent-session.ts`), not from a
hand-written spec doc, so field lists are exact as of the commit read but the union is large and
some rarely-emitted variants (retry/summarization-retry events) are cited from the `rpc.md` table
only, not cross-checked against source. Built-in tool arg schemas (read/write/edit/bash/grep) are
from source (`packages/coding-agent/src/core/tools/*.ts`); `find`/`ls` schemas were not fetched.

## Binary & install

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
# or
curl -fsSL https://pi.dev/install.sh | sh
```

Binary name: `pi`. Auth: `ANTHROPIC_API_KEY` (or other provider env vars) or `/login` for OAuth
subscriptions. Config root: `~/.pi/agent/` (override with `PI_CODING_AGENT_DIR`; session storage
override with `PI_CODING_AGENT_SESSION_DIR` / `--session-dir`).

Source: https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md

## Invocation modes

```
pi [options] [@files...] [messages...]
```

| Flag | Mode |
|------|------|
| (default) | Interactive TUI |
| `-p`, `--print` | Print final response text and exit |
| `--mode json` | Stream all session events as JSON lines to stdout, then exit |
| `--mode rpc` | JSON protocol over stdin/stdout, long-lived process |
| SDK (`createAgentSession` from `@earendil-works/pi-coding-agent`, Node/TS only) | Embed directly, no subprocess |

`-p`/`--print` also reads piped stdin and merges it into the initial prompt:
`cat README.md | pi -p "Summarize this text"`.

### Full-auto / no-confirmation mode

**There is no tool-approval or "yolo" flag, because pi has no built-in tool-confirmation system at
all — in any mode, interactive included.** From the README's design-principles section: *"It
intentionally does not include built-in MCP, sub-agents, permission popups, plan mode, to-dos, or
background bash."* By default pi gives the model 4 tools (`read`, `write`, `edit`, `bash`) and
executes every tool call the model requests, unconfirmed. If you want a confirmation gate, you
build one yourself as an extension (`pi.on("tool_call", ...)` can return `{ block: true, reason }`)
or run pi inside a container/sandbox (see `docs/containerization.md`: Gondolin micro-VM, plain
Docker, or OpenShell).

What `--approve`/`-a` and `--no-approve`/`-na` actually gate is **project trust** — whether pi is
allowed to load `.pi/settings.json`, project-local extensions, and project skills/packages for this
run — not tool execution. Interactive mode shows a one-time trust prompt per project folder
(saved via `/trust` to `~/.pi/agent/trust.json`); `-p`, `--mode json`, and `--mode rpc` never show
this prompt and instead fall back to `defaultProjectTrust` (`ask` default, `always`, or `never` in
`~/.pi/agent/settings.json`) unless `--approve`/`--no-approve` overrides it for the one run. This
is the closest thing to a "trust" flag pi has; it is orthogonal to tool execution, which is always
unconfirmed.

To restrict what the model *can* do (the actual lever for a supervisor app that wants a safety
boundary), use tool allow/deny flags instead of hunting for a permission flag:

| Option | Effect |
|--------|--------|
| `--tools <list>`, `-t <list>` | Allowlist only these tools |
| `--exclude-tools <list>`, `-xt <list>` | Denylist specific tools |
| `--no-builtin-tools`, `-nbt` | Disable built-ins, keep extension/custom tools |
| `--no-tools`, `-nt` | Disable all tools |

Built-in tool names: `read`, `bash`, `edit`, `write`, `grep`, `find`, `ls`. Example read-only run:
`pi --tools read,grep,find,ls -p "Review the code"`.

Sources:
https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md#quick-start ,
https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/usage.md (Project Trust
section, CLI Reference, Design Principles),
https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md (Extensions /
Permissions & Containerization sections)

## Session & resume

Session id: a UUID, assigned per session file, present in the first JSONL line
(`{"type":"session", ..., "id": "<uuid>"}`). Sessions auto-save under
`~/.pi/agent/sessions/--<cwd-with-/-replaced-by-->/<timestamp>_<uuid>.jsonl` unless
`--no-session` is passed.

CLI flags:

| Flag | Effect |
|------|--------|
| `-c`, `--continue` | Continue the most recent session for this cwd |
| `-r`, `--resume` | Interactive picker (interactive mode only) |
| `--session <path\|id>` | Open a specific session file or partial UUID |
| `--fork <path\|id>` | Copy a session into a new session file, then continue that |
| `--session-dir <dir>` | Custom session storage root (also `PI_CODING_AGENT_SESSION_DIR`) |
| `--no-session` | Ephemeral — do not persist to disk |
| `--name <name>`, `-n <name>` | Set session display name at startup |

**Non-interactive continuation**: `pi -c -p "next instruction"` continues the most recent session
non-interactively; `pi --session <id> -p "..."` continues a specific one. In RPC mode this is
equivalent to starting the process with `--session <id>` (there is no separate "resume" RPC
command — session choice is a startup flag, not a runtime command). The RPC `new_session` command
starts a fresh session mid-process and accepts `parentSession` for lineage tracking (see below).

**Branching**: sessions are trees, not linear logs. Every entry has `id`/`parentId`; the "leaf" is
the current position. `/tree` (interactive) moves the leaf without creating a new file. `/fork`
(interactive) or `--fork <path|id>` (CLI) copies the active path up to a chosen point into a new
session file. `/clone` duplicates the current active branch into a new file at the current
position. RPC's `new_session` with `{"parentSession": "/path/to/parent.jsonl"}` records lineage in
the new session's header (`parentSession` field) without copying entries.

Sources:
https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md ,
https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md#new_session

## On-disk session format

Path: `~/.pi/agent/sessions/--<cwd>--/<timestamp>_<uuid>.jsonl` (cwd's `/` replaced with `-`).
Format: JSONL, one JSON object per line, current version **3** (v1/v2 auto-migrated on load).

**Line 1 — `SessionHeader`** (no `id`/`parentId`, not part of the tree):
```json
{"type":"session","version":3,"id":"uuid","timestamp":"2024-12-03T14:00:00.000Z","cwd":"/path/to/project"}
```
With a parent session (from `/fork`, `/clone`, or `newSession({parentSession})`), adds
`"parentSession":"/path/to/original/session.jsonl"`.

**All other lines** extend `SessionEntryBase { type, id (8-char hex), parentId (string|null), timestamp (ISO string) }`.
Entry `type` values and payloads:

- `message` — `{ message: AgentMessage }`. The provider-neutral transcript unit; see below for the `AgentMessage` union.
- `model_change` — `{ provider, modelId }`
- `thinking_level_change` — `{ thinkingLevel }`
- `compaction` — `{ summary, tokensBefore, firstKeptEntryId? , retainedTail?: AgentMessage[], usage?, details?, fromHook? }`. Newer entries carry `retainedTail` (self-contained checkpoint) instead of/alongside `firstKeptEntryId`.
- `branch_summary` — `{ fromId, summary, usage?, details?, fromHook? }`
- `custom` — `{ customType, data }`. Extension state; does NOT participate in LLM context.
- `custom_message` — `{ customType, content, display, details? }`. Extension-injected message that DOES participate in context.
- `label` — `{ targetId, label }` (bookmark; `label: undefined` clears it)
- `session_info` — `{ name }` (display name, set via `/name` or `--name`)

**`AgentMessage` union** (the provider-neutral transcript — the "message" field of a `message` entry):

```typescript
// base (packages/ai/src/types.ts)
interface UserMessage { role: "user"; content: string | (TextContent|ImageContent)[]; timestamp: number }
interface AssistantMessage {
  role: "assistant";
  content: (TextContent | ThinkingContent | ToolCall)[];
  api: string; provider: string; model: string; responseModel?: string;
  usage: Usage;
  stopReason: "stop" | "length" | "toolUse" | "error" | "aborted" | "deferred"; // "pending" never persisted
  errorMessage?: string;
  timestamp: number;
}
interface ToolResultMessage {
  role: "toolResult"; toolCallId: string; toolName: string;
  content: (TextContent|ImageContent)[]; details?: any; usage?: Usage; isError: boolean; timestamp: number;
}
// extended (packages/coding-agent/src/core/messages.ts)
interface BashExecutionMessage {
  role: "bashExecution"; command: string; output: string; exitCode: number|undefined;
  cancelled: boolean; truncated: boolean; fullOutputPath?: string; excludeFromContext?: boolean; timestamp: number;
}
interface CustomMessage { role: "custom"; customType: string; content: string|(TextContent|ImageContent)[]; display: boolean; details?: any; timestamp: number }
interface BranchSummaryMessage { role: "branchSummary"; summary: string; fromId: string; timestamp: number }
interface CompactionSummaryMessage { role: "compactionSummary"; summary: string; tokensBefore: number; timestamp: number }
```

Content blocks: `TextContent {type:"text", text}`, `ImageContent {type:"image", data(base64), mimeType}`,
`ThinkingContent {type:"thinking", thinking, thinkingSignature?, redacted?}`,
`ToolCall {type:"toolCall", id, name, arguments, thoughtSignature?, namespace?}`.

Example lines:
```json
{"type":"message","id":"a1b2c3d4","parentId":null,"timestamp":"2024-12-03T14:00:01.000Z","message":{"role":"user","content":"Hello","timestamp":1733234401000}}
{"type":"message","id":"b2c3d4e5","parentId":"a1b2c3d4","timestamp":"2024-12-03T14:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Hi!"}],"provider":"anthropic","model":"claude-sonnet-4-5","api":"anthropic-messages","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":15,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":1733234402000}}
{"type":"message","id":"c3d4e5f6","parentId":"b2c3d4e5","timestamp":"2024-12-03T14:00:03.000Z","message":{"role":"toolResult","toolCallId":"call_123","toolName":"bash","content":[{"type":"text","text":"output"}],"isError":false,"timestamp":1733234403000}}
```

Tree walking / context building is done by `SessionManager.buildContextEntries()` /
`buildSessionContext()`: walk leaf→root, honor the most recent `compaction` entry on the path
(use `retainedTail` as a checkpoint if present, else `firstKeptEntryId`..compaction).

Source: https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md
(exhaustive — this doc IS the parser spec; also cross-referenced against
`packages/coding-agent/src/core/session-manager.ts` and `packages/coding-agent/src/core/messages.ts`
per that doc's own citations, not independently re-fetched by this research pass).

## `--mode json` event schema

```bash
pi --mode json "Your prompt"
```

Emits one JSON object per line to stdout. **Line 1 is always the `SessionHeader`** (same shape as
on-disk, above: `{"type":"session","version":3,"id":...,"timestamp":...,"cwd":...}`), then a
stream of `JsonAgentSessionEvent` objects.

`JsonAgentSessionEvent` = `AgentSessionEvent` with two changes: (1) `message_update` drops the
cumulative `message` field and keeps only `usage` + a stripped `assistantMessageEvent` (no
`partial` field on any sub-event, to keep line size linear instead of resending the whole
accumulating message every delta); (2) a `toolcall_start` sub-event additionally gets constant-size
`id` and `toolName` fields spliced in (since without `partial` you'd otherwise have no way to know
which tool call started).

### Event types (discriminated by `type`)

**Base agent lifecycle** (`packages/agent/src/types.ts` `AgentEvent`, re-exported into
`AgentSessionEvent` — `agent_end` is overridden, see below):

| type | shape |
|---|---|
| `agent_start` | `{ type }` |
| `turn_start` | `{ type }` — one turn = one assistant response + its tool calls/results |
| `turn_end` | `{ type, message: AgentMessage, toolResults: ToolResultMessage[] }` |
| `message_start` | `{ type, message: AgentMessage }` |
| `message_update` | (JSON-mode shape) `{ type, usage: Usage, assistantMessageEvent: JsonAssistantMessageEvent }` — only for streaming assistant messages |
| `message_end` | `{ type, message: AgentMessage }` — final authoritative message |
| `tool_execution_start` | `{ type, toolCallId, toolName, args: any }` |
| `tool_execution_update` | `{ type, toolCallId, toolName, args: any, partialResult: any }` — streamed tool output, e.g. live bash stdout |
| `tool_execution_end` | `{ type, toolCallId, toolName, result: any, isError: boolean }` |

**Session-level additions** (`packages/coding-agent/src/core/agent-session.ts` `AgentSessionEvent`):

| type | shape |
|---|---|
| `agent_end` | `{ type, messages: AgentMessage[], willRetry: boolean }` — overrides the base `agent_end`; `willRetry` distinguishes "one LLM call ended" from "the whole run is done" (see Turn completion below) |
| `agent_settled` | `{ type }` — run is fully done: no pending retry, compaction retry, or queued continuation remains |
| `queue_update` | `{ type, steering: string[], followUp: string[] }` — full pending-queue snapshot, emitted whenever it changes |
| `compaction_start` | `{ type, reason: "manual"\|"threshold"\|"overflow" }` |
| `compaction_end` | `{ type, reason, result: CompactionResult\|undefined, aborted: boolean, willRetry: boolean, errorMessage?: string }` |
| `entry_appended` | `{ type, entry: SessionEntry }` — mirrors what was just written to the JSONL file |
| `session_info_changed` | `{ type, name: string\|undefined }` |
| `thinking_level_changed` | `{ type, level: ThinkingLevel }` |
| `auto_retry_start` | `{ type, attempt, maxAttempts, delayMs, errorMessage }` |
| `auto_retry_end` | `{ type, success: boolean, attempt, finalError?: string }` |
| `summarization_retry_scheduled` | `{ type, attempt, maxAttempts, delayMs, errorMessage }` (compaction/branch-summary LLM call retry) |
| `summarization_retry_attempt_start` | `{ type, source: "branchSummary" }` or `{ type, source: "compaction", reason }` |
| `summarization_retry_finished` | `{ type }` |
| `bash_execution_update` | `{ type, id?: string, delta: string }` — `!command`/RPC `bash` streaming chunk; `id` present only if the originating RPC `bash` command supplied one |

### `assistantMessageEvent` sub-events (inside `message_update`; `partial` stripped in JSON/RPC mode)

Full union, from `packages/ai/src/types.ts` `AssistantMessageEvent` (interactive/SDK consumers get
the `partial: AssistantMessage` field too — the cumulative message-so-far — but JSON/RPC mode
strips it):

```typescript
type AssistantMessageEvent =
  | { type: "start" }
  | { type: "text_start"; contentIndex: number }
  | { type: "text_delta"; contentIndex: number; delta: string }
  | { type: "text_end"; contentIndex: number; content: string }
  | { type: "thinking_start"; contentIndex: number }
  | { type: "thinking_delta"; contentIndex: number; delta: string }
  | { type: "thinking_end"; contentIndex: number; content: string }
  | { type: "toolcall_start"; contentIndex: number; id: string; toolName: string }  // id/toolName added in JSON mode
  | { type: "toolcall_delta"; contentIndex: number; delta: string }   // delta = raw partial JSON-arguments text
  | { type: "toolcall_end"; contentIndex: number; toolCall: ToolCall }
  | { type: "done"; reason: "stop" | "length" | "toolUse" | "deferred"; message: AssistantMessage }
  | { type: "error"; reason: "aborted" | "error"; error: AssistantMessage }
```
(`done`/`error` here are the low-level per-LLM-call terminators; they end up embedded as the
final `message_end` event's `message.stopReason`, not emitted standalone in the session event
stream — `message_end` is the one to watch.)

`contentIndex` + `delta` let you assemble live text/thinking/tool-call-argument JSON without
tracking cumulative snapshots. The top-level `usage` field on `message_update` is the latest
cumulative provider-reported usage and "may remain zero when a provider only reports usage at
completion" — don't rely on it being populated before `message_end`.

### Worked example (annotated)

```json
{"type":"session","version":3,"id":"9f2c...","timestamp":"...","cwd":"/repo"}
{"type":"agent_start"}
{"type":"turn_start"}
{"type":"message_start","message":{"role":"assistant","content":[],"provider":"anthropic","model":"claude-sonnet-4-5","api":"anthropic-messages","usage":{...},"stopReason":"pending","timestamp":...}}
{"type":"message_update","usage":{"input":120,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":120,"cost":{...}},"assistantMessageEvent":{"type":"text_start","contentIndex":0}}
{"type":"message_update","usage":{...},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"I'll list"}}
{"type":"message_update","usage":{...},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":" the files."}}
{"type":"message_update","usage":{...},"assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"I'll list the files."}}
{"type":"message_update","usage":{...},"assistantMessageEvent":{"type":"toolcall_start","contentIndex":1,"id":"call_abc","toolName":"bash"}}
{"type":"message_update","usage":{...},"assistantMessageEvent":{"type":"toolcall_delta","contentIndex":1,"delta":"{\"command\":\"ls"}}
{"type":"message_update","usage":{...},"assistantMessageEvent":{"type":"toolcall_delta","contentIndex":1,"delta":" -la\"}"}}
{"type":"message_update","usage":{...},"assistantMessageEvent":{"type":"toolcall_end","contentIndex":1,"toolCall":{"type":"toolCall","id":"call_abc","name":"bash","arguments":{"command":"ls -la"}}}}
{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"I'll list the files."},{"type":"toolCall","id":"call_abc","name":"bash","arguments":{"command":"ls -la"}}],"provider":"anthropic","model":"claude-sonnet-4-5","api":"anthropic-messages","usage":{...},"stopReason":"toolUse","timestamp":...}}
{"type":"tool_execution_start","toolCallId":"call_abc","toolName":"bash","args":{"command":"ls -la"}}
{"type":"tool_execution_end","toolCallId":"call_abc","toolName":"bash","result":{"content":[{"type":"text","text":"total 48\ndrwxr-xr-x ..."}],"details":{}},"isError":false}
{"type":"message_start","message":{"role":"toolResult","toolCallId":"call_abc","toolName":"bash","content":[{"type":"text","text":"total 48\n..."}],"isError":false,"timestamp":...}}
{"type":"message_end","message":{"role":"toolResult","toolCallId":"call_abc","toolName":"bash","content":[{"type":"text","text":"total 48\n..."}],"isError":false,"timestamp":...}}
{"type":"turn_end","message":{"role":"assistant","content":[...],"stopReason":"toolUse",...},"toolResults":[{"role":"toolResult","toolCallId":"call_abc",...}]}
{"type":"turn_start"}
... (model reads tool result, produces final text turn) ...
{"type":"turn_end","message":{...,"stopReason":"stop"},"toolResults":[]}
{"type":"agent_end","messages":[...],"willRetry":false}
{"type":"agent_settled"}
```
(Delta content and exact byte-for-byte framing above is illustrative — every field name and event
`type` is verbatim from source/docs; the specific tool-call JSON chunking is not.)

Sources: https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md (event
list + framing prose, quoted near-verbatim above), source files
`packages/coding-agent/src/core/agent-session.ts` and `packages/agent/src/types.ts` and
`packages/ai/src/types.ts` for the exact union field lists.

## `--mode rpc` protocol

Custom JSON-over-stdin/stdout protocol (**not** JSON-RPC 2.0 — no `jsonrpc`/`method`/`params`
envelope; commands are flat `{type, ...fields}` objects and responses are flat
`{type:"response", command, success, ...}`).

```bash
pi --mode rpc [--provider p] [--model m] [--name n] [--no-session] [--session-dir d]
```

**Framing**: strict JSONL, LF (`\n`) only. Do not use Node's `readline` — it also splits on
U+2028/U+2029, which can appear inside JSON string values and would corrupt framing. Strip a
trailing `\r` if present; don't otherwise treat CR as a delimiter.

**Events on stdout are the same `JsonAgentSessionEvent` stream as `--mode json`** — RPC mode's
`rpc-mode.ts` calls the identical `toJsonEvent(event)` transform before writing
(`output(toJsonEvent(event))`), confirmed from source. So everything in the `--mode json` section
above applies verbatim to RPC mode's event stream; RPC just interleaves command/response lines on
the same stdout.

Every command may include an optional `id`; if present, the matching response echoes it back
(`bash_execution_update` events also carry the originating `bash` command's `id`, when supplied).

### Client → agent commands

| type | fields | response `data` |
|---|---|---|
| `prompt` | `message`, `images?: ImageContent[]`, `streamingBehavior?: "steer"\|"followUp"` (required if already streaming) | none (events follow async) |
| `steer` | `message`, `images?` | none |
| `follow_up` | `message`, `images?` | none |
| `abort` | — | none |
| `new_session` | `parentSession?: string` (path) | `{cancelled: boolean}` |
| `get_state` | — | `{model, thinkingLevel, isStreaming, isCompacting, steeringMode, followUpMode, sessionFile, sessionId, sessionName?, autoCompactionEnabled, messageCount, pendingMessageCount}` |
| `get_messages` | — | `{messages: AgentMessage[]}` |
| `set_model` | `provider`, `modelId` | full `Model` object |
| `cycle_model` | — | `{model, thinkingLevel, isScoped}` or `null` |
| `get_available_models` | — | `{models: Model[]}` |
| `set_thinking_level` | `level: "off"\|"minimal"\|"low"\|"medium"\|"high"\|"xhigh"\|"max"` | none |
| `cycle_thinking_level` | — | `{level}` or `null` |
| `get_available_thinking_levels` | — | `{levels: string[]}` |
| `set_steering_mode` | `mode: "all"\|"one-at-a-time"` | none |
| `set_follow_up_mode` | `mode: "all"\|"one-at-a-time"` | none |
| `compact` | `customInstructions?` | `{summary, firstKeptEntryId, tokensBefore, estimatedTokensAfter, usage?, details}` |
| `set_auto_compaction` | `enabled: boolean` | none |
| `set_auto_retry` | `enabled: boolean` | none |
| `abort_retry` | — | none |
| `bash` | `command`, `id?` (for correlating `bash_execution_update`) | `{output, exitCode, cancelled, truncated, fullOutputPath?}` |
| `abort_bash` | — | none |
| `get_session_stats` | — | see Token usage section below |
| `export_html` | `outputPath?` | `{path}` |
| `set_session_name` | (per source `rpc-types.ts`) | none |
| `get_entries` / `get_tree` / `get_last_assistant_text` / `get_commands` | (per source `rpc-types.ts`, not documented in prose in `rpc.md`'s excerpt fetched) | tree/entries/text/commands respectively |

Prompt acceptance semantics: the `prompt` response's `success:true` means "accepted, queued, or
handled" — NOT "the turn finished." A prompt sent while already streaming without
`streamingBehavior` returns `success:false`. Failures that occur *after* acceptance (e.g. the LLM
call errors) are reported via the normal event stream (`agent_end`/`message_end` with an error
`stopReason`), not as a second response for that request id.

### Agent → client (besides the shared event stream)

- **Response**: `{id?, type:"response", command, success:true, data?}` or
  `{id?, type:"response", command, success:false, error: string}` — e.g.
  `{"type":"response","command":"set_model","success":false,"error":"Model not found: invalid/model"}`.
- **Extension UI requests**: `{type:"extension_ui_request", id, ...}` when an extension calls
  `ctx.ui.confirm/prompt/etc.`; client must reply with
  `{type:"extension_ui_response", id, ...}` on stdin. This is the one place a confirmation-style
  round trip exists in RPC mode — but only if a loaded extension asks for it, not for built-in
  tools.
- **Malformed input**: unparseable stdin line → `{type:"response", command:"parse", success:false, error:"Failed to parse command: ..."}` (no `id`, since none could be read).

Sources: https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md (full
command/response catalog, quoted/paraphrased above),
`packages/coding-agent/src/modes/rpc/rpc-mode.ts` and
`packages/coding-agent/src/modes/rpc/rpc-types.ts` (confirms `toJsonEvent` reuse, exact response
union, and error-response shape),
`packages/coding-agent/src/modes/rpc/rpc-client.ts` (reference TS subprocess client — a strong
worked example of a parser: JSONL line reader, request/response correlation by `id`, event
listener registration).

## Token usage & cost

`Usage` shape (same object everywhere tokens are reported):
```typescript
interface Usage {
  input: number; output: number; cacheRead: number; cacheWrite: number;
  cacheWrite1h?: number;   // Anthropic-only subset of cacheWrite
  reasoning?: number;      // subset of output, only if provider reports it
  totalTokens: number;
  cost: { input: number; output: number; cacheRead: number; cacheWrite: number; total: number };
}
```

Where it appears:
- On every persisted `AssistantMessage.usage` (session JSONL and `message_end` events).
- On `ToolResultMessage.usage?` (rare — usage from LLM work a tool itself performed internally).
- On `message_update`'s top-level `usage` field (cumulative-so-far; may read 0 until the provider
  reports usage, which for some providers is only at stream completion).
- RPC `compact` response's `data.usage` (cost of generating the compaction summary).
- RPC `get_session_stats` response:
  ```json
  {
    "sessionFile": "...", "sessionId": "...",
    "userMessages": 5, "assistantMessages": 5, "toolCalls": 12, "toolResults": 12, "totalMessages": 22,
    "tokens": {"input":50000,"output":10000,"cacheRead":40000,"cacheWrite":5000,"total":105000},
    "cost": 0.45,
    "contextUsage": {"tokens":60000,"contextWindow":200000,"percent":30}
  }
  ```
  `tokens`/`cost` are session-wide totals (assistant messages + tool-reported usage + compaction/
  branch-summary generation). `contextUsage` is the live estimate used for auto-compaction/footer
  display; `contextUsage.tokens`/`.percent` are `null` immediately after a compaction until a fresh
  post-compaction assistant response supplies real usage.
- Interactive footer and `/session` show the same numbers; team-lead's note about `/cost` was not
  found as a documented slash command in the fetched docs — `/session` is the one that shows
  token/cost totals. Treat "`/cost`" as **not confirmed**; don't build a parser assumption around it.

Source: https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md
(`get_session_stats`, `compact`), `packages/ai/src/types.ts` (`Usage` interface).

## Tool calls & results

**Built-in tools and their exact argument schemas** (from source,
`packages/coding-agent/src/core/tools/*.ts`; TypeBox schemas translate straightforwardly to JSON
Schema types shown):

```typescript
// read
{ path: string; offset?: number /* 1-indexed line */; limit?: number /* max lines */ }
// result.details: { truncation?: TruncationResult }

// write
{ path: string; content: string }
// result.details: {} (creates parent dirs automatically)

// edit
{ path: string; edits: Array<{ oldText: string; newText: string }> }  // exact unique-match replacement
// result.details: { diff: string; patch: string /* unified patch */; firstChangedLine?: number }

// bash
{ command: string; timeout?: number /* seconds, no default timeout */ }
// result.details: { truncation?: TruncationResult; fullOutputPath?: string }

// grep
{ pattern: string; path?: string; glob?: string; ignoreCase?: boolean; literal?: boolean; context?: number; limit?: number /* default 100 */ }

// find, ls — schemas not fetched in this pass; follow the same ToolDefinition shape.
```

**Representation of a tool call in the transcript** (`ToolCall` content block, inside an
`AssistantMessage.content[]`):
```json
{"type":"toolCall","id":"call_abc","name":"bash","arguments":{"command":"ls -la"}}
```

**Representation of a tool result** (`ToolResultMessage`, its own transcript entry / `message`
role `toolResult`):
```json
{"role":"toolResult","toolCallId":"call_abc","toolName":"bash","content":[{"type":"text","text":"..."}],"details":{},"isError":false,"timestamp":...}
```
`content` is `(TextContent|ImageContent)[]` — same content-block union as everywhere else. Errors
are NOT a separate event type: a failing tool sets `isError:true` on this same message shape and
puts the error text in `content`; the tool's `execute()` throwing is caught by the runtime and
converted into this error-flagged result (see `bash.ts`: exit code ≠ 0 → `throw new Error(...)`,
caught upstream, `isError:true`).

**In `--mode json`/RPC event stream**, the same tool call/result surfaces three times across the
event sequence, each showing a different facet:
1. `message_update` `toolcall_end` sub-event → the `ToolCall` block as the model emitted it.
2. `tool_execution_start` / `tool_execution_end` events → `{toolCallId, toolName, args}` /
   `{toolCallId, toolName, result, isError}` — `result` here is the raw
   `{content, details}` tool-execute return value, not wrapped in the `ToolResultMessage` shape yet.
3. `message_start`/`message_end` for the synthesized `ToolResultMessage` → the canonical transcript
   form shown above, which is what gets persisted to the session JSONL and is what
   `get_messages`/on-disk parsers should key off of.

Extensions can intercept: `tool_call` event fires after `tool_execution_start`/before execution and
can return `{block: true, reason}` to short-circuit (this is the extension-built confirmation
mechanism mentioned above, not a pi built-in); `tool_result` event fires after execution and can
override `content`/`details`/`isError`/`usage`.

Sources:
`packages/coding-agent/src/core/tools/{read,write,edit,bash,grep}.ts` (schemas/details, verified
from source), `packages/agent/src/types.ts` (`AgentToolResult`, `BeforeToolCallResult`,
`AfterToolCallResult`), https://pi.dev/docs/latest/extensions (`tool_call`/`tool_result` event
shapes and `isToolCallEventType`/`isBashToolResult` narrowing helpers).

## Turn completion & errors

**Turn vs. run vs. settled** — three distinct completion signals, easy to conflate:
- **One LLM call** completes with `message_end` (`AssistantMessage.stopReason` ∈
  `stop|length|toolUse|error|aborted|deferred`).
- **One turn** (assistant response + its tool calls/results) completes with `turn_end`
  (`{message, toolResults}`). `toolUse` stopReason means another turn follows; `stop` usually ends
  the run, but not always (steering/follow-up queues can inject another turn).
- **The whole run** ends with `agent_end` — `{messages, willRetry}`. **Check `willRetry`**: `true`
  means this `agent_end` will be followed by an automatic retry, compaction-retry, or a queued
  continuation — the run is not actually over. A parser waiting for "done" should not stop on
  `agent_end` alone.
- **Fully settled** (nothing pending at all — no retry, no compaction retry, no queued
  continuation) is signaled by `agent_settled`. **This is the correct terminal signal to wait for**
  in a supervisor that wants to know "pi is now idle."

**Errors**:
- Per-assistant-message: `stopReason: "error"` or `"aborted"` + `errorMessage: string` on the
  `AssistantMessage` (both in `message_end` and in the on-disk transcript). Streams "must not
  throw" per the `StreamFn` contract in `packages/agent/src/types.ts` — provider/network failures
  are always encoded this way, never as a thrown exception out of the event stream.
  `stopReason:"pending"` is a placeholder used only mid-stream on `partial` messages before
  `text_end`/`done`/`error`; it is never persisted.
- Retryable transient errors (rate limit, overloaded, 5xx) trigger `auto_retry_start`/
  `auto_retry_end` (enabled by default; toggle via RPC `set_auto_retry` or abort with
  `abort_retry`). Summarization (compaction/branch-summary) calls have their own parallel retry
  events: `summarization_retry_scheduled` → `summarization_retry_attempt_start` →
  `summarization_retry_finished`.
- RPC command-level errors: `{type:"response", command, success:false, error: string}` — this is
  distinct from an agent-run error; it means the command itself was rejected (bad model id,
  malformed JSON, etc.), before/without touching the agent loop.
- Extension errors: `extension_error` event on stdout, `{extensionPath, event, error}` (per
  `rpc-mode.ts` source: `output({type:"extension_error", extensionPath, event, error})`).
- **Process exit**: `--mode json` and `-p` exit the process when the run settles (`agent_settled`
  equivalent) — normal Unix exit code semantics, not separately documented with an exit-code
  table in the fetched docs; treat process exit + stdout EOF as the ultimate fallback completion
  signal if you don't want to rely on parsing `agent_settled`. RPC mode stays alive until stdin
  closes (`process.stdin.on("end", ...)` triggers `shutdown()`) or a client-driven shutdown occurs.

Sources: `packages/agent/src/types.ts` (`StreamFn` contract, `StopReason`),
`packages/coding-agent/src/core/agent-session.ts` (`AgentSessionEvent` union incl. `agent_end.willRetry`,
`agent_settled`), `packages/coding-agent/src/modes/rpc/rpc-mode.ts` (extension_error emission,
stdin-end shutdown), https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md
(Error Handling section, response shape).

## Quirks & drift risks

- **No permission system to bypass** is itself the biggest surprise for anyone porting mental
  models from Claude Code/Codex: every tool call executes unconfirmed by default, in every mode.
  A supervisor app that wants a "confirm before bash" UX has to implement it itself — via an
  extension that intercepts `tool_call` and blocks, or via containerization — pi will not gate this
  for you. Don't design a parser around expecting a `permission_request`-style event; it doesn't
  exist upstream (only extensions can synthesize one via `extension_ui_request`, and only if the
  user has installed such an extension).
- **`--mode json` and `--mode rpc` share the exact same event serialization** (`toJsonEvent`), so a
  single event parser works for both — the only difference is RPC interleaves command/response
  lines and stays alive across multiple prompts. Don't write two parsers.
- **On-disk `AgentMessage` and streamed `message_end`/`message_start` events use the identical
  message shape** — but `message_update` deltas do NOT, and mid-stream messages carry
  `stopReason:"pending"` which never appears on disk. If you build one shared type for "a message,"
  make `stopReason` accept `"pending"` in the streaming path and reject it in the persisted-session
  path.
- **`partial` stripping is JSON/RPC-mode-only.** SDK/interactive consumers of `AgentEvent` directly
  get the full cumulative `partial: AssistantMessage` on every sub-event. If future pi versions
  change what "provider-neutral" fields exist, they change here first.
- **Extensions can register custom message roles, custom tools, and even override built-in tools
  entirely** ("Custom tools (or replace built-in tools entirely)" is explicitly listed as an
  extension capability), and pi packages "run with full system access" per the README's security
  note. A session file or event stream from a heavily-customized pi install may contain
  `custom`/`custom_message` entries and tool names your parser has never seen — treat unknown
  `type`/tool names as pass-through/unknown rather than fatal-parse-error.
- **Session version churn**: v1→v2 added the tree (`id`/`parentId`); v2→v3 renamed the
  `hookMessage` role to `custom`. Old files are auto-migrated on load by pi itself, but a
  standalone parser reading raw JSONL from disk will see whatever version was written and must
  handle the older `hookMessage` role name if reading pre-v3 files directly rather than through
  pi's own `SessionManager`.
- **Compaction is lossy but reconstructible**: `retainedTail` (newer) vs. `firstKeptEntryId`
  (legacy) are two different ways the same "what survives compaction" concept is encoded — a
  parser needs to handle both.
- **`get_session_stats`'s `contextUsage.tokens`/`.percent` go `null` right after compaction** until
  a fresh assistant turn reports usage — don't treat `null` as zero/error.
- **RPC command catalog beyond what `docs/rpc.md`'s fetched excerpt covered**: `set_session_name`,
  `get_entries`, `get_tree`, `get_last_assistant_text`, `get_commands` exist in
  `rpc-types.ts`'s `RpcResponse` union but this pass did not fetch their full request-field
  documentation from `rpc.md` prose — treat those five as real-but-under-documented-here.
- **Themes/rich formatting are TUI-only** (`dark`/`light`, `.pi/themes/`) — they affect interactive
  rendering, not `--mode json`/`--mode rpc` output, which is always plain JSON.
- **Model/provider naming is not a fixed enum in the SDK sense**: `ProviderId = KnownProvider |
  string` and `Api = KnownApi | (string & {})` — both are deliberately open unions so
  custom/community providers don't break typing. Don't validate `provider`/`api` fields against a
  closed enum.

## Sources

- https://github.com/earendil-works/pi — monorepo root, README (packages table, permissions/containerization, philosophy)
- https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md — CLI overview, quick start, customization
- https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/usage.md — full CLI Reference table, Project Trust, Design Principles
- https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md — `--mode json` event schema (primary spec for that mode)
- https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md — RPC protocol, commands, responses, error handling, framing rules
- https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sessions.md — session management, branching, compaction overview
- https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md — on-disk JSONL format, full entry-type catalog, `SessionManager` API
- https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sdk.md — SDK tool factories, built-in tool names, `defineTool`
- https://pi.dev/ — project site (four-modes overview, "no permission popups" philosophy)
- https://pi.dev/docs/latest/extensions — `tool_call`/`tool_result` extension event shapes
- `packages/coding-agent/src/core/agent-session.ts` — `AgentSessionEvent` union (source, not a docs page)
- `packages/agent/src/types.ts` — `AgentEvent`, `AgentTool`, `StreamFn` contract, `BeforeToolCallResult`/`AfterToolCallResult`
- `packages/ai/src/types.ts` — `AssistantMessageEvent`, `Usage`, message/content-block types, `StopReason`
- `packages/ai/src/utils/event-stream.ts` — confirms `done`/`error` are the only stream terminators
- `packages/coding-agent/src/core/tools/{read,write,edit,bash,grep}.ts` — built-in tool arg/detail schemas
- `packages/coding-agent/src/modes/rpc/rpc-mode.ts` — confirms RPC reuses `toJsonEvent`, extension_error/parse-error shapes
- `packages/coding-agent/src/modes/rpc/rpc-types.ts` — full `RpcResponse` union (source)
- `packages/coding-agent/src/modes/rpc/rpc-client.ts` — reference TS subprocess client implementation

All GitHub source URLs above were fetched from `earendil-works/pi`; identical content was
cross-confirmed via the `badlogic/pi-mono` mirror in search results (same author, `badlogic`,
95k★/11.7k🍴 repo — this is a large, actively maintained project, not a toy).
