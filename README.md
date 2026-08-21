# Flotilla

A native macOS app for running a fleet of parallel Claude Code agents, each in its own git worktree.

> Early scaffold. No features yet — just an empty app that launches.

## Requirements

- macOS 26+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

The Xcode project is generated from `project.yml` and is not committed. Generate it, then open:

```sh
xcodegen
open Flotilla.xcodeproj
```

## Layout

```
project.yml            XcodeGen spec (source of truth)
Flotilla/
  FlotillaApp.swift    App entry point
  ContentView.swift    Root view
  Assets.xcassets      App icon + accent color
```
