# Port Changes And Status Views To GUI

## Problem

The TUI has `changes` and `status` views for JJHub/JJ working-copy workflows.
The GUI has no equivalent, even though users need change lists, status, diffs,
and bookmark actions from the native app.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- TUI source of truth: `../tui/internal/ui/views/changes.go`.
- TUI registration: `changes` and `status` in
  `../tui/internal/ui/views/registry.go`.
- TUI JJHub client support: `ListChanges`, `ViewChange`, `ChangeDiff`,
  `WorkingCopyDiff`, `Status`, `CreateBookmark`, and `DeleteBookmark` in
  `../tui/internal/jjhub/client.go`.
- GUI has no `NavDestination` or view for changes/status.

## Goal

Add GUI parity for the TUI changes/status surface.

## Proposed Changes

- Add `ChangesView.swift` and a status mode or dedicated `StatusView.swift`.
- Add JJHub client methods to `SmithersClient.swift` or a dedicated GUI JJHub
  client.
- Support change list, selected change details, change diff, working-copy
  status/diff, create bookmark, and delete bookmark.
- Match TUI refresh, empty, and error behavior.

## Acceptance Criteria

- Users can open a Changes view from GUI navigation.
- Users can inspect a selected JJHub change and its diff.
- Users can inspect working-copy status/diff.
- Users can create and delete bookmarks where the TUI supports it.
- Behavior and command shapes match the TUI/JJHub client.

