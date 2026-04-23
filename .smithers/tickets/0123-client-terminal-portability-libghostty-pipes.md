# Client: terminal portability via libghostty pipes backend

## Context

The current terminal stack is macOS AppKit code. `TerminalView.swift` imports `AppKit` at the top, owns a singleton `GhosttyApp` around `ghostty_app_t` (`430-543`), defines `TerminalSurfaceView: NSView` with AppKit key/mouse/clipboard handling (`572-1660`), exposes `TerminalSurfaceRepresentable: NSViewRepresentable` (`1687-1756`), and renders `TerminalView` on top of that (`1760-1815`). The surrounding macOS session layer still assumes native daemon-backed PTY attachment: `project.yml:121-123` bundles `smithers-session-daemon` and `smithers-session-connect`, `Smithers.SessionStore.swift:138-220` creates native terminal sessions, and `Smithers.SessionController.swift:93-183` launches and talks to the local session daemon.

The spec requires a SwiftUI terminal that works on both macOS and iOS and is fed by the `libghostty` pipes backend through `libsmithers-core`, not by AppKit NSView plumbing in the UI layer.

## Problem

As long as terminal rendering is an `NSViewRepresentable` backed by daemon-local PTY assumptions, iOS cannot share the terminal surface and desktop-remote cannot share the runtime contract with iOS.

## Goal

Replace the AppKit terminal view path with a cross-platform SwiftUI terminal surface that works on macOS and iOS, uses libghostty’s pipes backend, and gets PTY bytes from `libsmithers-core` rather than direct daemon/file-descriptor assumptions in the Swift layer.

## Scope

- **In scope**
  - Replace the shared terminal entry point so the UI-visible terminal surface compiles for both macOS and iOS.
  - Move AppKit-only code out of the shared terminal path:
    - `NSViewRepresentable`,
    - `TerminalSurfaceView: NSView`,
    - AppKit event monitors,
    - macOS pasteboard/context-menu details.
  - Use the Stage 0 libghostty renderer work from `0092` and the runtime PTY transport from `0120`/`0094` so the shared terminal view is driven by byte streams, resize events, focus changes, title changes, and bell/notification callbacks instead of local daemon attach semantics.
  - Update the terminal-related store layer so remote terminals are keyed off runtime PTY handles, not the current `smithers-session-daemon` / `smithers-session-connect` flow. The remote path must not depend on `SessionController` or the bundled helper binaries.
  - Keep macOS-only affordances, but make them adapters around the shared terminal surface:
    - desktop context menus and split commands,
    - shortcut interception,
    - desktop clipboard integration.
  - Preserve the existing UITest placeholder behavior or an equivalent cross-platform test surface so UI tests can run without full terminal rendering.
- **Out of scope**
  - The connection/session runtime itself; `0120` owns that.
  - Shared navigation shell refactors in `0122`.
  - Desktop-local engine policy beyond whatever compatibility shim is temporarily needed during migration.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md`
- `.smithers/tickets/0092-poc-libghostty-ios.md`
- `.smithers/tickets/0094-poc-zig-websocket-pty.md`
- `.smithers/tickets/0106-plue-oauth2-pkce-for-mobile.md`
- `.smithers/tickets/0109-client-oauth2-signin-ui.md`
- `TerminalView.swift:430-1815`
- `project.yml:121-147`
- `macos/Sources/Smithers/Smithers.SessionStore.swift:138-220`
- `macos/Sources/Smithers/Smithers.SessionController.swift:93-183`

## Acceptance criteria

- The shared terminal view compiles and runs on both macOS and iOS.
- Remote terminal rendering is driven by libghostty pipes-backend input from `libsmithers-core`, not direct daemon/file-descriptor assumptions in shared Swift code.
- The remote path no longer requires `NSViewRepresentable` or `smithers-session-daemon` resources.
- MacOS keeps its desktop-only affordances behind macOS-specific adapters.
- Terminal behaviors required by the current UI still work:
  - resize,
  - focus,
  - title updates,
  - bell/notifications,
  - clipboard copy/paste,
  - UITest placeholder mode.
- iOS simulator/device validation proves the shared terminal view actually renders remote PTY output.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the shared terminal path is not just `#if os(iOS)` hiding a stub, the remote path does not touch `SessionController`, and the iOS test build exercises a real renderer path rather than only the placeholder branch.

## Risks / unknowns

- Input handling parity between macOS hardware keyboards and iOS touch keyboards will expose edge cases in modifier/key translation.
- There may be a short compatibility window where local macOS mode still needs the old daemon path while remote mode moves first. That split must stay explicit.
- libghostty API packaging across macOS, simulator, and device may force some follow-up build-graph adjustments with `0121`.
