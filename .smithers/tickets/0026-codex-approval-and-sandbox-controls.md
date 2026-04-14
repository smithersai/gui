# Add Codex Approval And Sandbox Controls

## Problem

The TUI exposes approval/sandbox permission controls. The GUI currently reports
that approval policy is fixed by the bridge.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI placeholder: `ChatView.swift` appends "Codex approval policy is fixed by
  the current GUI bridge: never ask, full workspace access."
- TUI permission dialogs live under `../tui/internal/ui/dialog/permissions.go`.

## Goal

Add GUI controls for Codex approval and sandbox policy.

## Proposed Changes

- Expose current approval/sandbox configuration in the GUI.
- Add a picker/dialog for supported policies.
- Thread selected policy into Codex FFI/session creation.
- Replace placeholder slash-command behavior.

## Acceptance Criteria

- GUI users can inspect current approval/sandbox settings.
- GUI users can change supported settings before a turn/session.
- The Codex bridge honors the selected settings.
- Behavior matches the TUI permission model.

