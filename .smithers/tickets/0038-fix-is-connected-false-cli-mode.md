# Fix isConnected Stays False in CLI-Only Mode

## Problem

When no HTTP/SSE server is configured and the app uses CLI-only transport,
`isConnected` remains false. This disables UI features that should work in
CLI mode.

Review: platform.

## Current State

- `isConnected` is only set to true when the SSE/HTTP connection succeeds.
- CLI-only mode never flips the flag.

## Proposed Changes

- After a successful CLI probe (e.g., `smithers version`), set `isConnected`
  to true.
- Distinguish between "no transport" and "CLI transport active" states.

## Files

- `SmithersClient.swift`
- Platform/connection state management

## Acceptance Criteria

- `isConnected` is true when the CLI transport is available and responding.
- UI features gated on `isConnected` work in CLI-only mode.
