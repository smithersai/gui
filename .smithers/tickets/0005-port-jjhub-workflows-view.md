# Port JJHub Workflows View To GUI

## Problem

The TUI has a `jjhub-workflows` view for listing and triggering JJHub
workflows. The GUI has only Smithers workflow listing/running and no JJHub
workflow surface.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- TUI source of truth: `../tui/internal/ui/views/jjhub_workflows.go`.
- TUI JJHub client support: `ListWorkflows` and `TriggerWorkflow` in
  `../tui/internal/jjhub/client.go`.
- GUI has no `NavDestination.jjhubWorkflows`.

## Goal

Add a GUI JJHub workflows view matching the TUI behavior.

## Proposed Changes

- Add navigation for JJHub workflows.
- Add client methods for current repo, workflow list, and workflow trigger.
- Render workflow metadata and relative timestamps.
- Prompt for ref when triggering where the TUI does.
- Show trigger result/errors.

## Acceptance Criteria

- GUI can list JJHub workflows for the current repo.
- GUI can trigger a JJHub workflow with the same inputs as the TUI.
- Loading, empty, and error states are handled.

