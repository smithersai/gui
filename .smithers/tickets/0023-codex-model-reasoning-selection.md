# Add Codex Model And Reasoning Selection

## Problem

The TUI exposes model and reasoning effort selection. The GUI slash command
currently reports that model switching is not exposed.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI placeholder: `ChatView.swift` appends "Model switching is not exposed by
  this GUI yet."
- TUI source of truth: model dialog and reasoning dialog under
  `../tui/internal/ui/dialog/`.
- TUI key bindings include model selection shortcuts.

## Goal

Add GUI controls for model and reasoning effort selection.

## Proposed Changes

- Add a model/reasoning picker UI.
- Load available providers/models from the same configuration semantics the TUI
  uses.
- Persist selection for new and current sessions according to TUI behavior.
- Replace the slash-command placeholder with real behavior.

## Acceptance Criteria

- `/model` opens a real GUI selection flow.
- Reasoning effort can be changed where supported.
- The selected model is reflected in subsequent Codex turns.
- Behavior matches TUI config/session semantics.

