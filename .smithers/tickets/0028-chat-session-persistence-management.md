# Add Chat Session Persistence Management

## Problem

The GUI `SessionStore` keeps sessions only in memory. The TUI has persistent
session history and dialogs/CLI-backed session load/delete/rename flows.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI source: `SessionStore.swift`.
- TUI source of truth: session model/dialog code under
  `../tui/internal/ui/model/session.go` and
  `../tui/internal/ui/dialog/sessions.go`.
- GUI sessions vanish when the app exits.

## Goal

Add persistent session management to the GUI.

## Proposed Changes

- Load session history from the same storage/source the TUI uses.
- Persist new GUI chat sessions.
- Add rename/delete/load controls.
- Preserve grouping/search in the sidebar.
- Ensure active session title/preview are updated from persisted messages.

## Acceptance Criteria

- GUI sessions survive app restart.
- Users can load prior sessions.
- Users can rename and delete sessions.
- Sidebar search/grouping works with persisted sessions.
- Behavior matches TUI session semantics.

