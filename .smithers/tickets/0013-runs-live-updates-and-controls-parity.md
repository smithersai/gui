# Bring Runs View To TUI Parity

## Problem

The GUI runs view lists and expands runs, but lacks several TUI behaviors:
global SSE live updates, polling fallback, hijack, workflow filter, run
inspector navigation, snapshots navigation, and cancel confirmation.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- TUI source of truth: `../tui/internal/ui/views/runs.go`.
- GUI source: `RunsView.swift`.
- GUI `SmithersClient.streamRunEvents` exists but has no GUI call sites.

## Goal

Port the TUI runs behavior into the GUI.

## Proposed Changes

- Connect to global run event streaming and update rows live.
- Add polling fallback when SSE is unavailable.
- Add workflow filter matching TUI behavior.
- Add dedicated run inspect navigation.
- Add snapshots/timeline navigation.
- Add hijack action.
- Add cancel confirmation before cancelling non-terminal runs.
- Preserve approve/deny/cancel action feedback.

## Acceptance Criteria

- GUI runs update live when Smithers emits run events.
- GUI gracefully falls back when streaming is unavailable.
- Users can filter by workflow.
- Users can inspect, chat, snapshot, hijack, approve, deny, and cancel runs
  with TUI-equivalent behavior.

