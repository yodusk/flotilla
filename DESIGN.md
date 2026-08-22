# Flotilla — Design

A macOS (SwiftUI, macOS 26) app to supervise a fleet of coding-agent CLIs
running in parallel across isolated git worktrees. Like conductor.build, for
myself, and multi-agent from the start.

## Principles

- Flotilla is a **supervisor**, not an agent framework. Agents are external
  CLIs spawned as subprocesses. We manage lifecycle, isolation, and review.
- **Normalize early, stay generic.** Agent-specific quirks live behind one
  adapter boundary; everything after it speaks one event vocabulary.
- Functions and services over class hierarchies. Explicit data flow.
- The value is the **fleet dashboard + diff review**, not a prettier terminal.

## Supported agents

Pluggable via an adapter per CLI. All run **yolo / full-auto** (see Permissions).

- **Claude Code** — `claude -p --output-format stream-json --verbose`,
  `--resume <id>`, `--permission-mode bypassPermissions`. One-shot + resume.
- **Codex CLI** — `codex exec` (`--json`), `codex exec resume`,
  `--sandbox danger-full-access --ask-for-approval never`. One-shot + resume.
- **pi** — [earendil-works/pi](https://github.com/earendil-works/pi) (pi.dev),
  `@earendil-works/pi-coding-agent`. `--mode json` (JSON-lines events) or
  `--mode rpc` (bidirectional JSON over stdin/stdout, built for process
  integration); session resume via `--session-dir` / `/resume`. Prefer RPC:
  a persistent process, cleanest to drive.

All three support **both** process shapes; the runner abstracts over them:
- **one-shot + resume** — spawn per turn, pass a session id to continue.
  Claude `-p … --resume`, Codex `exec --json` + resume, pi `-p` + `--session-dir`.
- **persistent bidirectional** — long-lived process, turns on stdin, events on
  stdout. Claude `--input-format stream-json`, Codex `app-server` (JSON-RPC/
  stdio), pi `--mode rpc`.

**Default to one-shot + resume.** Idle tabs then cost zero processes — right for
a fleet of many worktrees × tabs. Upgrade only the *focused* tab to a persistent
process if cold-start latency annoys. Persistent-for-all = N idle processes.

## Noun model

```
Repo
 └─ Worktree        unit of git isolation: branch + working dir + diff
     └─ Chat (tab)  one conversation, one agent, one session + process
         (many chats per worktree; agents may be mixed)
```

- **Worktree** owns the branch, directory, and therefore the **diff**.
- **Chat** owns agent choice, session id, subprocess, transcript.
- The diff inspector is **worktree-wide** — shared by all its tabs, unchanged
  by tab switches.

## Concurrency

- Multiple chats share one worktree's files.
- Policy: **free-for-all** (user accepts the risk of concurrent edits to the
  same directory). No write lock in v1.
- Escape hatch (later, not v1): snapshot/stash-backup on chat send for undo.

## Layout — three-column NavigationSplitView

```
┌────────────┬───────────────────────────┬─────────────┐
│ Sidebar    │ [Chat1][Chat2][+]  tabs    │ Diff        │
│            │                            │ (worktree-  │
│ Repo A     │ transcript of active tab   │  wide)      │
│  ▸ wt-login│                            │             │
│  ▸ wt-api  │ prompt box                 │ git actions │
│ Repo B     │ status: agent·tokens·model │             │
│  ▸ wt-…    │                            │             │
└────────────┴───────────────────────────┴─────────────┘
```

- **Sidebar**: worktrees grouped by repo, each with a status dot
  (idle / running / waiting-input / done / error). `+ New Worktree`.
- **Center**: tab strip of chats (icon = agent); active chat's transcript,
  prompt box, status bar.
- **Inspector**: worktree diff (changed-files tree + unified diff) and git
  actions (commit, push, open PR, rebase-on-base, discard, open in editor).
  Collapsible.
- Fully unified UI — agent is a per-chat setting; capabilities gate small bits.

## Module boundaries (Swift)

- **GitService** — thin async wrapper over the `git` CLI: worktree
  add/list/remove, diff, status, commit, push. Returns structs. Agent-agnostic.
- **AgentRunner** — spawns whatever the adapter specifies, streams stdout
  lines, forwards to the adapter's parser. One instance per active chat.
- **Adapters** (`AgentProvider`) — one per CLI:
  - `buildLaunch(prompt, worktree, session) -> (binary, args, env)`
  - `parseStream(line) -> [TranscriptEvent]?` — live in-flight turn (stdout)
  - `parseRollout(line) -> [TranscriptEvent]?` — on-disk history, cold open
  - both tolerant; unknown → `.raw`. Stream and on-disk formats differ per agent.
  - `resumeArgs(session) -> args`
  - `sessionFileURL(session, worktree) -> URL` — where the agent persists it
  - `capabilities` — what UI to show/hide (MCP, images…)
- **RunStore** — source of truth over SwiftData: `@Model` types `Repo`,
  `Worktree`, `Chat` (`Repo 1—* Worktree 1—* Chat`), bound into SwiftUI via
  `@Query`. Owns reconcile-on-launch against `git worktree list --porcelain`.
  These are the one place classes are warranted — they have real
  identity/lifecycle. Live per-turn status stays in-memory, not in the DB.
- **Views** — bind to RunStore + the active chat's event stream. Thin.

## Normalized transcript events

The lingua franca every adapter emits; UI binds only to these:

```
.sessionStarted(id)
.userMessage(text)
.assistantText(text)
.toolCall(name, input)
.toolResult(output, isError)
.tokenUsage(input, output)
.error(message)
.finished(reason)
.raw(line)              // unknown/passthrough — never crash on schema drift
```

## Storage

Flotilla stores **only its own nouns**, not transcripts. Each agent already
persists a durable JSONL transcript; we read theirs.

- **Ours** (SwiftData): `Repo`, `Worktree`, `Chat` `@Model` types, including the
  chat → (agent, session id, worktree) mapping; light UI state. No transcripts,
  no per-token status — durable nouns only, so write volume stays low.
- **Theirs** (read-only, by session id):
  - Claude → `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`
  - Codex → `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (+ SQLite index; `.zst`
    when cold — materialized back to `.jsonl` on resume)
  - pi → session dir (`PI_CODING_AGENT_SESSION_DIR` / `--session-dir`)
- History on cold-open = read the agent's file via `parseRollout`. Live turn =
  `parseStream` off stdout. Both feed one in-memory transcript.
- Free crash recovery: the agent's file survives even if Flotilla dies mid-turn.

## Cross-cutting concerns

- **Agent detection**: probe installed CLIs + versions on launch; grey out
  missing ones with install hints.
- **Session model**: a chat's process is transient; the session id on disk is
  durable. Resume rather than keep a long-lived process. Survives crashes.
- **Permissions**: none. Every harness runs yolo / full-auto — no approval
  prompts, no permission UI, no capability-gating for perms. Worktree isolation
  is the only safety net. This is a single-user, own-machine tool by design.
- **Reconcile-on-launch**: match persisted state to real worktrees; offer
  cleanup of orphans left by crashes.

## Open questions

- `AgentSession` abstraction over both process shapes (one-shot+resume vs
  persistent bidirectional) without leaking either into the rest of the app.
- Codex `.zst` cold rollouts: read compressed directly, or only parse plain?
```
