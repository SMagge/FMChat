# FMChat

A tiny SwiftUI chat app for Apple's **on-device Foundation Model** (Apple Intelligence) — no cloud, no API keys. Includes tool calling so the model can read your local files.

## Features

- Streaming chat with the on-device model (`FoundationModels` framework)
- Tool calling (read-only):
  - `listDirectory` — list files/folders
  - `readFile` — read a text file
  - `searchText` — grep-style recursive text search
- Multi-turn context, "New Chat" reset, Markdown rendering

Ask things like: *"List what's in ~/Projects"*, *"Summarize ~/FMChat/FMChat.swift"*, *"Search for TODO in ~/myrepo"*.

## Requirements

- Apple Silicon Mac
- macOS 26 (Tahoe) or later
- **Apple Intelligence enabled** (System Settings → Apple Intelligence & Siri)
- Xcode Command Line Tools (`xcode-select --install`)

## Build & run

```bash
./build.sh
open FMChat.app
```

## Notes & limits

- The on-device model is small (~3B parameters) with a limited (~4K token) context window — great for focused questions and single files, not whole-codebase analysis. Tool output is truncated to ~4000 characters.
- Tools are strictly read-only; the app never writes, deletes, or sends anything off-device.
