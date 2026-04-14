# Add Feedback Command Parity

## Problem

The GUI `/feedback` slash command is a placeholder. The TUI has richer command
and feedback-related flows that should be treated as the correct behavior.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI placeholder: `ChatView.swift` appends "Feedback capture is not wired into
  this GUI yet."
- TUI command palette/dialog behavior lives under `../tui/internal/ui/dialog`.

## Goal

Replace the GUI feedback placeholder with a real feedback capture flow.

## Proposed Changes

- Identify the TUI feedback behavior and required transport.
- Add GUI feedback capture UI.
- Include useful context such as app version, current workspace, active view,
  and recent error if the TUI does.
- Submit or prepare feedback using the same semantics as the TUI.

## Acceptance Criteria

- `/feedback` opens a real GUI flow.
- Feedback includes the same required context as the TUI.
- Submission/preparation succeeds or reports an actionable error.
- Placeholder status text is removed.

