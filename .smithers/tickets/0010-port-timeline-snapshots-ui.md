# Port Timeline And Snapshots UI To GUI

## Problem

The GUI has snapshot client methods but no timeline/snapshots view. The TUI
supports snapshot listing, refresh, diff, fork, and replay.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- TUI source of truth: `../tui/internal/ui/views/timeline.go`.
- TUI client support: `ListSnapshots`, `DiffSnapshots`, `ForkRun`, and
  `ReplayRun` in `../tui/internal/smithers/timetravel.go`.
- GUI methods exist in `SmithersClient.swift`, but `rg` shows no GUI call sites.

## Goal

Add GUI timeline/snapshot inspection and actions for Smithers runs.

## Proposed Changes

- Add `TimelineView.swift`.
- Open it from runs and run inspector.
- List snapshots for a run with current selected snapshot details.
- Show adjacent snapshot diffs.
- Support fork from snapshot and replay from snapshot.
- Refresh periodically or provide equivalent live refresh behavior.

## Acceptance Criteria

- Users can inspect snapshots for a run.
- Users can view diffs between snapshots.
- Users can fork and replay from a snapshot.
- The GUI uses the same Smithers semantics as the TUI.

