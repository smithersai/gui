# Port Full Run Inspector To GUI

## Problem

The GUI runs view has expandable details, but it does not provide the TUI's full
run inspector with list/DAG modes, node detail navigation, live chat entry
points, hijack, snapshots, rerun, and watch hooks.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- TUI source of truth: `../tui/internal/ui/views/runinspect.go` and
  `../tui/internal/ui/views/nodeinspect.go`.
- GUI `RunsView.swift` loads `inspectRun`, but only renders inline details.

## Goal

Add a dedicated GUI run inspector matching the TUI's run/node inspection
behavior.

## Proposed Changes

- Add `RunInspectView.swift` and `NodeInspectView.swift`.
- Open inspector from selected run.
- Support flat node list and DAG/tree mode.
- Show run metadata, task state, iteration, attempt, and timestamps.
- Open node inspector from a selected node.
- Link to live run/node chat.
- Link to snapshots/timeline.
- Implement hijack, rerun, and watch behavior where applicable.

## Acceptance Criteria

- Users can open a full run inspector from the GUI runs list.
- Users can switch between list and DAG modes.
- Users can inspect a node in detail.
- Users can open live chat and snapshots from inspector.
- TUI key-driven actions have GUI equivalents.

