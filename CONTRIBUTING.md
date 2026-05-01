# Contributing

This repository contains the SwiftUI macOS app for Smithers GUI. The `codex/`
and `ghostty/` directories are vendored trees; avoid changing them unless the
task is explicitly about those integrations.

## Build And Test

- Build the app with `swift build`.
- Run the debug build with `.build/debug/SmithersGUI`.
- Run focused tests with `swift test --filter <TestName>`.
- If you add an app source file, make sure it is included in both SwiftPM and
  `SmithersGUI.xcodeproj` when the Xcode project is part of the workflow.

## Developer Debug Mode

Developer debug mode is a sidecar panel for inspecting the running app without
leaving the current screen. It is enabled automatically in debug builds. It can
also be controlled explicitly at launch:

```sh
SMITHERS_GUI_DEBUG=1 .build/debug/SmithersGUI
.build/debug/SmithersGUI --developer-debug
.build/debug/SmithersGUI --no-developer-debug
```

Truthy environment values are `1`, `true`, `yes`, `on`, and `enabled`.
Falsey values are `0`, `false`, `no`, `off`, and `disabled`.
`--no-developer-debug` wins over the environment variable and debug-build
default.

When enabled, the panel can be opened from the sidebar under `Developer`, with
`Cmd+Shift+D`, or from chat with `/debug`.

The panel currently has two tabs:

- `State`: current route, Smithers connection status, active session, session
  count, run tabs, active model, active messages, and recent message previews.
- `Logs`: file logger stats and recent JSONL app logs with level filtering,
  search, and auto-refresh.

The full log viewer remains available from the normal `Logs` route. The debug
panel reuses the same `AppLogger.fileWriter` data and should not introduce a
second logging pipeline.

## Extending Debug State

Add new debug fields through `DeveloperDebugSnapshot` in
`DeveloperDebugView.swift`. Prefer snapshot rows over direct view reads so the
state remains easy to test. Keep values sanitized before they are displayed:
do not expose raw tokens, API keys, cookies, authorization headers, private
keys, or long unbounded payloads.

When adding a new debug surface:

- Keep it read-only unless the task explicitly needs a mutation.
- Prefer compact summaries over dumping entire model objects.
- Add focused tests in `Tests/SmithersGUITests/DeveloperDebugTests.swift`.
- Keep the normal app usable while the panel is open.
