# Port Smithers Chat Target Picker To GUI

## Problem

The TUI has a Smithers chat target picker that lets users choose built-in
Smithers chat or an installed external CLI agent. The GUI currently goes
straight to Codex chat and does not expose this target selection.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- TUI source of truth: `../tui/internal/ui/views/chat.go`.
- TUI registration: `chat` in `../tui/internal/ui/views/registry.go`.
- GUI `ChatView.swift` is Codex-focused and does not list Smithers/external
  chat targets.

## Goal

Port the chat target picker to the GUI so users can choose the chat backend
using the same availability and usability rules as the TUI.

## Proposed Changes

- Add a GUI target picker before launching/activating a chat surface.
- Reuse the same agent discovery semantics as the TUI.
- Show recommended Smithers target and usable external agents.
- Launch or route into the selected target.
- Record failures clearly when a target cannot be started.

## Acceptance Criteria

- GUI users can choose Smithers built-in chat.
- GUI users can choose supported external agents discovered by Smithers.
- Unusable agents are hidden or clearly disabled according to TUI behavior.
- Selection semantics match the TUI.

