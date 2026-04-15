# Fix Prompts Async Loading Overwrites User Edits

## Problem

When a prompt file finishes async loading, it overwrites whatever the user
has typed in the editor buffer, discarding their work.

Review: prompts.

## Current State

- Async file load sets the editor text unconditionally on completion.

## Proposed Changes

- Track whether the user has made edits since the load was initiated.
- Skip overwriting the buffer if the user has made changes (or show a
  conflict prompt).

## Files

- Prompts view files

## Acceptance Criteria

- User edits are preserved when an async load completes after editing begins.
- Fresh loads (no user edits) still populate the editor correctly.
