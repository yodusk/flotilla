# Flotilla

A native macOS app for supervising a fleet of parallel coding agents — Claude
Code, Codex, and pi — each in its own git worktree, driven as a subprocess.
Like conductor.build, multi-agent from the start.

> Early scaffold. The architecture and normalized agent-event model are in
> place and the app builds; the run loop and diff review are still being wired.

See [`DESIGN.md`](DESIGN.md) for the architecture and
[`docs/formats/`](docs/formats/) for the reverse-engineered agent output formats
and the normalized `TranscriptEvent` model.

## Requirements

- macOS 26+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- The agent CLIs you want to drive: `claude`, `codex`, `pi`

## Build

The Xcode project is generated from `project.yml` and is not committed.

```sh
xcodegen
open Flotilla.xcodeproj
```

To build from the command line, point at a full Xcode (not just Command Line
Tools):

```sh
xcodegen
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Flotilla.xcodeproj -scheme Flotilla \
  -destination 'platform=macOS' build
```

## Layout

```
project.yml            XcodeGen spec (source of truth)
DESIGN.md              Architecture
docs/formats/          Agent output-format specs + normalized model
Flotilla/
  Model/               TranscriptEvent, JSONValue, AgentKind — the normalized vocabulary
  Agents/              AgentProvider protocol, sessions, per-CLI adapters, registry
  Git/                 GitService — worktree/diff plumbing over the git CLI
  Store/               SwiftData @Model types: Repo, Worktree, Chat
  UI/                  Three-column shell: sidebar, chat tabs, diff inspector
```
