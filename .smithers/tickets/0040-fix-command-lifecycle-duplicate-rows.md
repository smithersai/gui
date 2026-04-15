# Fix Command Lifecycle Duplicate Rows in Chat

## Problem

When a command completes, duplicate chat rows appear. The lifecycle events
(start, progress, completion) each insert a row instead of updating the
existing one.

Reviews: chat, codex_events, platform.

## Current State

- Command events are appended as new `ChatBlock` entries rather than updating
  the in-flight block.
- The chat view shows redundant entries for a single command.

## Proposed Changes

- Track in-flight command blocks by a stable ID.
- On progress/completion events, update the existing block instead of
  appending a new one.
- Deduplicate on render as a safety net.

## Files

- `SmithersClient.swift`
- `SmithersModels.swift` (ChatBlock)
- Chat view files

## Acceptance Criteria

- A single command produces exactly one chat row that updates in place.
- No duplicate rows for command start/progress/complete lifecycle.
