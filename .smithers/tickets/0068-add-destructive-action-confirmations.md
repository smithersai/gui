# Add Confirmation Dialogs for Destructive Actions

## Problem

Destructive actions (delete workflow, cancel run, clear memories, etc.)
execute immediately without confirmation, risking accidental data loss.

Review: ui_build_theme.

## Current State

- Buttons trigger destructive actions directly with no confirmation step.

## Proposed Changes

- Add `.confirmationDialog` or `.alert` before all destructive actions.
- Use consistent wording and styling across the app.

## Files

- All view files with destructive actions

## Acceptance Criteria

- Every destructive action shows a confirmation dialog before executing.
- Users can cancel the action from the dialog.
