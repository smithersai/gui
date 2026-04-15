# Fix Streaming SSE Ignores runId and Inherits Wrong Timeout

## Problem

The SSE streaming transport ignores the `runId` field on events, so events
from different runs can bleed into the wrong view. It also inherits a
generic HTTP timeout that is too short for long-running streams.

Review: streaming_ffi.

## Current State

- SSE event parsing does not filter or tag by `runId`.
- The URLSession timeout applies to the SSE stream, causing premature
  disconnects.

## Proposed Changes

- Parse and route SSE events by `runId`.
- Use a stream-appropriate timeout (or no timeout) for SSE connections.

## Files

- `SmithersClient.swift`
- SSE/streaming transport files

## Acceptance Criteria

- SSE events are routed to the correct run context by `runId`.
- Long-running streams do not time out prematurely.
