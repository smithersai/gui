# Port Agents View To GUI

## Problem

The Go TUI includes an `agents` Smithers view. The Swift GUI has no matching
navigation destination, view, model, or client method.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- TUI source of truth: `../tui/internal/ui/views/agents.go`.
- TUI registration: `../tui/internal/ui/views/registry.go` registers `agents`.
- GUI navigation in `SidebarView.swift` does not include `agents`.
- `SmithersClient.swift` does not expose `ListAgents` parity.

## Goal

Add a native GUI agents view that matches the TUI feature set closely enough
for users to inspect available Smithers/external agents and their status.

## Proposed Changes

- Add `NavDestination.agents`.
- Add an `AgentsView.swift`.
- Add Smithers client support for agent discovery/status.
- Show agent name, roles, command/binary, availability, and usability.
- Wire refresh/loading/error states.
- Add a sidebar row and slash-command navigation entry if consistent with the
  existing GUI command palette.

## Acceptance Criteria

- Agents appear in the GUI sidebar.
- The GUI can list the same usable agents the TUI lists.
- Agent status and role metadata are visible.
- Empty, loading, and error states are handled.
- The GUI does not invent semantics that conflict with the TUI.

