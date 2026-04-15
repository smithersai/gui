# Enable Text Selection on Command/Diff Displays

## Problem

Command output and diff displays do not support text selection, preventing
users from copying content.

Review: ui_build_theme.

## Current State

- Text is rendered in non-selectable views.

## Proposed Changes

- Use `.textSelection(.enabled)` on command output and diff text views.
- Ensure code blocks and diffs are selectable.

## Files

- Chat/command output view files
- Diff view files

## Acceptance Criteria

- Users can select and copy text from command output and diff displays.
