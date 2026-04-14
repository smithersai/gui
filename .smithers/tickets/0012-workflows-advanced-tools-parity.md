# Add Advanced Workflow Tools To GUI

## Problem

The GUI workflows view can list workflows, display basic input fields, and run a
workflow. It lacks the TUI's advanced workflow tools: DAG visualization, schema
toggle, doctor diagnostics, run confirmation, last-run status badges, and
robust form fallback behavior.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- TUI source of truth: `../tui/internal/ui/views/workflows.go`.
- GUI source: `WorkflowsView.swift`.
- TUI implements `RunWorkflowDoctor`, DAG overlays, schema visibility toggles,
  run confirmation, dynamic forms, and run status feedback.

## Goal

Port advanced TUI workflow behavior to the GUI.

## Proposed Changes

- Add workflow doctor diagnostics.
- Add DAG visualization/details.
- Add schema/agent detail toggle.
- Add run confirmation when appropriate.
- Preserve dynamic launch form behavior and default handling.
- Show last-run status per workflow.
- Surface run errors in the selected workflow context.

## Acceptance Criteria

- Users can inspect workflow DAG details in the GUI.
- Users can run workflow doctor diagnostics.
- Users see clear run confirmation/status/error feedback.
- Dynamic input forms follow TUI fallback semantics.

