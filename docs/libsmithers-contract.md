# libsmithers integration contract

**Status:** skeleton. Locked for all three parallel streams.
**Header:** [`libsmithers/include/smithers.h`](../libsmithers/include/smithers.h)
**Pattern reference:** [`ghostty/include/ghostty.h`](../ghostty/include/ghostty.h),
[`ghostty/src/apprt/embedded.zig`](../ghostty/src/apprt/embedded.zig),
[`ghostty/src/apprt/gtk/App.zig`](../ghostty/src/apprt/gtk/App.zig),
[`ghostty/macos/Sources/Ghostty/Ghostty.App.swift`](../ghostty/macos/Sources/Ghostty/Ghostty.App.swift).

## Goal

Replicate Ghostty's architecture for SmithersGUI:

```
libsmithers (Zig, runtime-agnostic)
│
├── apprt/embedded.zig   → C ABI → consumed by Swift/AppKit (macOS)
└── apprt/gtk/           → GTK4 exe, written directly in Zig (Linux)
```

Every piece of non-UI business logic that is currently in Swift moves into
`libsmithers/`. macOS and Linux each get a *thin* UI layer on top.

## The three parallel streams

Each stream has an exclusive write boundary. Respect it.

| Stream | Owner | Writes in | Reads from |
|---|---|---|---|
| A | `/codex` #A | `libsmithers/**` | `smithers.h`, current Swift files (read-only), `ghostty/` |
| B | `/codex` #B | `linux/**` | `smithers.h`, `ghostty/src/apprt/gtk/**` |
| C | `/codex` #C | `macos/**`, root `*.swift`, `Package.swift`, `project.yml`, `CSmithersKit/**` | `smithers.h`, `ghostty/macos/Sources/Ghostty/**` |

**Nobody writes to `ghostty/`.** It is a submodule and reference only.

## Protocol for ABI changes

1. The header in `libsmithers/include/smithers.h` is the source of truth.
2. If a stream needs a new function, new enum variant, new struct field, etc.,
   it drops a file: `libsmithers/ABI_CHANGE_REQUEST_<slug>.md` describing:
   - What's needed and why
   - Proposed header diff
   - Which other streams are affected
3. The orchestrator (Claude, main conversation) reviews all requests, edits
   the header if accepted, notifies the affected streams.
4. No stream edits `smithers.h` directly.

## Core design rules (lifted from ghostty)

### Types

- **Opaque handles** only cross the ABI. `smithers_app_t`, `smithers_session_t`,
  etc. are `void *`. Peek-through is a bug.
- **Non-opaque structs/enums** in the header are duplicated in
  `libsmithers/src/apprt/structs.zig` with a `// keep in sync` comment.
- **Model types** (RunSummary, Workflow, ChatBlock, Ticket, … ~80 types in
  `SmithersModels.swift`) do NOT get dedicated C structs. They cross the ABI
  as JSON strings. The Swift and GTK layers parse/emit JSON. This keeps the
  ABI narrow and evolvable.

### Threading

- All host → core calls synchronous, main-thread.
- All core → host events via callbacks registered in
  `smithers_runtime_config_s` at `smithers_app_new`.
- Long-running work inside the core uses its own threads; results land on the
  main thread via `wakeup` + event stream draining.

### Memory / strings

- Core returns strings as `smithers_string_s { ptr, len }` and owns them.
  Host must call `smithers_string_free(s)` exactly once.
- Same rule for `smithers_bytes_s` and `smithers_error_s`.
- Any pointer passed into the core is borrowed for the call duration only
  unless the specific function documents otherwise.

### Actions (core → host)

- Single tagged union `smithers_action_s` passed to the `action` callback.
- New variants are appended only — never renumbered, never removed (bump a
  feature flag instead).
- Swift and GTK shells both switch on the tag. If a shell can't handle a
  variant yet, it returns `false` and logs; core falls back.

### Streams

- Anything that is async/multi-event (SSE, devtools frames, chat tokens,
  run state) returns a `smithers_event_stream_t`.
- Each event is `{tag, json_payload}`. Host parses the JSON.
- Stream termination is `SMITHERS_EVENT_END`.

### Wide APIs (SmithersClient)

- SmithersClient.swift has ~60+ methods. Do NOT enumerate all of them as C
  functions. Instead expose:
  - `smithers_client_call(method, args_json) → result_json` for unary calls
  - `smithers_client_stream(method, args_json) → event_stream` for streaming
- Method names mirror the existing Swift names ("listWorkflows",
  "inspectRun", "approveNode", "streamDevTools", "streamChat", etc.) so the
  mapping from Swift to ABI is mechanical.

## Build targets (after all three streams complete)

```
$ zig build                     # default: macOS static lib + Swift build
$ zig build -Dapp-runtime=gtk   # Linux GTK4 exe
$ zig build test                # libsmithers e2e test suite
$ swift test                    # Swift wrapper tests
```

## Success criteria

Stream A:
- `libsmithers/zig-out/lib/libsmithers.a` + `smithers.h` build cleanly
- `zig build test` green with coverage of every public ABI function
- No remaining references to ported Swift files inside `libsmithers/`

Stream B:
- `zig build -Dapp-runtime=gtk` produces a runnable `linux/smithers-gtk` exe
- App opens, can pick a workspace, open a session, render palette, run a
  slash command
- Looks like a GNOME/GTK4 app (not a macOS clone). Uses libadwaita where it
  improves feel.

Stream C:
- Every ported Swift file in root is deleted
- Thin wrappers exist in `macos/Sources/Smithers/{App,Session,Client,…}.swift`
- `Package.swift` and `project.yml` updated; Xcode build links
  `libsmithers.a` alongside `libghostty-fat.a`
- SwiftUI views still compile and pass their existing tests (updated to
  target the wrapper layer)
- Old Swift tests for deleted logic ported to `libsmithers/test/`

## What NOT to do

- Do not touch `ghostty/` submodule.
- Do not introduce Rust, C++, or another language. Zig only.
- Do not design for cross-platform UI frameworks (no Qt, Tauri, Flutter).
  macOS is SwiftUI + AppKit. Linux is GTK4 (ideally via libadwaita).
- Do not build backwards-compat shims. When Swift logic is ported to Zig,
  delete the Swift copy in the same commit.
- Do not create a feature flag for "use libsmithers vs use old Swift".
  Cutover is atomic per domain.
- Do not use the same commit message template the current repo uses (emoji
  prefixes) unless you verify with `git log` that's the actual style.

## Trunk-only workflow

All commits land on `main`. No feature branches. Stream boundaries are
enforced by directory, not by branch.
