# Fix Codex Cancel Race with Bridge Creation

## Problem

If a cancel or new turn is requested while `codex_create` is still running,
the cancel has no effect because `activeBridge` has not been set yet. The
old bridge can overwrite the new one when it finally returns.

Review: streaming_ffi.

## Current State

- `AgentService.swift:116` cancels via `activeBridge.take()` which is nil
  during `codex_create`.
- `AgentService.swift:157` creates the bridge before registering at line 168.

## Proposed Changes

- Use a cancellation token or task-based cancellation that covers the
  `codex_create` phase.
- Ensure a late-returning bridge does not overwrite a newer one.

## Files

- `AgentService.swift`
- Codex bridge files

## Acceptance Criteria

- Cancel during `codex_create` aborts the pending bridge creation.
- A stale bridge never overwrites an active one.
- Rapid turn submission does not leak Codex processes.
