# Port Live Run Chat To GUI

## Problem

The TUI supports live chat for a Smithers run/node, including transcript
loading, SSE updates, attempt navigation, follow mode, a context side pane, and
hijack/resume handoff. The GUI has `streamChat` in `SmithersClient.swift`, but
no GUI view uses it.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- TUI source of truth: `../tui/internal/ui/views/livechat.go`.
- TUI opens live chat from run inspect/node inspect.
- GUI `SmithersClient.streamChat` exists but is unused.
- GUI has no run live-chat view or route.

## Goal

Add native GUI live run chat with TUI-equivalent transcript, streaming, and
hijack behavior.

## Proposed Changes

- Add `LiveRunChatView.swift`.
- Add route entry points from runs, run inspector, and node inspector.
- Fetch run metadata and chat transcript.
- Connect `streamChat` and append live blocks.
- Support attempt tracking/navigation and latest-attempt indicators.
- Support follow/unfollow behavior.
- Add a context pane equivalent to the TUI side pane.
- Implement hijack/resume handoff semantics or a GUI-appropriate equivalent
  that preserves TUI behavior.

## Acceptance Criteria

- A user can open live chat for a run and optionally for a node.
- Existing transcript and new streamed blocks render in order.
- Attempt navigation works for multi-attempt runs.
- Follow mode tracks new output and can be disabled by user scrolling.
- Hijack/resume behavior matches the TUI as closely as the GUI platform allows.

