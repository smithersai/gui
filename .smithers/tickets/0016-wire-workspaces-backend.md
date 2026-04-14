# Wire Workspaces Backend In GUI

## Problem

The GUI has a `WorkspacesView`, but all workspace and snapshot backend methods
are stubs. Lists return empty arrays and mutations throw `notAvailable`.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI stubs: `listWorkspaces`, `createWorkspace`, `deleteWorkspace`,
  `suspendWorkspace`, `resumeWorkspace`, `listWorkspaceSnapshots`, and
  `createWorkspaceSnapshot`.
- TUI source of truth: `../tui/internal/ui/views/workspaces.go`.
- TUI JJHub client support: workspace and workspace snapshot methods in
  `../tui/internal/jjhub/client.go`.

## Goal

Replace GUI workspace stubs with real JJHub-backed behavior.

## Proposed Changes

- Implement list/view/create/delete/suspend/resume/fork workspace operations.
- Implement list/view/create/delete workspace snapshot operations.
- Update the GUI view to expose any TUI actions not currently visible.
- Preserve action-in-flight states and error handling.

## Acceptance Criteria

- `WorkspacesView` lists real workspaces.
- Users can create, delete, suspend, and resume workspaces.
- Users can list and create snapshots.
- Users can create/fork/restore from snapshots according to TUI semantics.

