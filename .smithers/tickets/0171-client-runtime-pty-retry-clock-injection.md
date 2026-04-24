# 0166 — Client Runtime PTY Retry Clock Injection

## Problem

`RuntimePTYTransport` schedules reconnect backoff with direct `Task.sleep` calls. Swift integration tests for WebSocket PTY reconnect behavior therefore need to wait through the real 1, 2, 4, 8, and 16 second retry schedule.

## Goal

Add an internal clock/sleeper seam that preserves production behavior while letting tests advance retry delays deterministically.

## Acceptance

- Production retry behavior remains unchanged: 1s, 2s, 4s, 8s, 16s, max 5 attempts.
- Tests can inject a manual or immediate sleeper without relying on wall-clock time.
- Existing `RuntimePTYTransport` public API remains source-compatible.
- `RuntimePTYTransportTests` no longer need multi-second waits for retry-budget and backoff assertions.
