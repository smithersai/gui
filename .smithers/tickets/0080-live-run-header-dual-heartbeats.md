# Live Run Header with Dual Heartbeats

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §2.3 and §5.

Header for the new live-run view. Run status pill, workflow name + runId,
elapsed time, the two-heartbeat indicator, and an overflow menu.

## Scope

### 1. `LiveRunHeaderView`

Layout (left → right):
- Run status pill.
- Workflow name + runId (click runId to copy).
- Elapsed time (live-ticking every 1s while run is active).
- Heartbeat indicator (see §2 below).
- Overflow menu: refresh, hijack, open logs, cancel (existing actions,
  lifted from `LiveRunChatView`).

### 2. Dual heartbeat indicator

Two dots side by side.

**Engine heartbeat** (left dot):
- Green if last stream event / `TaskHeartbeat` arrived within
  `heartbeatMs * 2`.
- Amber if within `heartbeatMs * 5`.
- Red if older.
- One-shot pulse animation every time a heartbeat event arrives (subscribe
  to `LiveRunDevToolsStore.lastEventAt`).

**UI heartbeat** (right dot, smaller):
- Pulses on a fixed 1s cadence using a SwiftUI `Timer`/`TimelineView`.
- If the SwiftUI main thread stalls, it stops pulsing — visibly frozen.

**Tooltip** (on hover of the indicator cluster):
- Last heartbeat at: {timestamp}
- Heartbeat interval: {heartbeatMs}ms
- Last seq: {seq}

### 3. Elapsed time

Live-ticking. Use `TimelineView(.periodic)` at 1s cadence. Format:
`HH:MM:SS` for > 1h, `MM:SS` otherwise.

### 4. Run status pill

Same color map as tree rows (running=blue, failed=red, etc.). Tap opens
a quick menu: Cancel / Hijack / Copy runId.

## Files (expected)

- `LiveRunHeaderView.swift` (new)
- `HeartbeatIndicator.swift` (new)
- `RunStatusPill.swift` (new)
- `Tests/SmithersGUITests/HeartbeatIndicatorTests.swift` (new)

## Acceptance

- Engine heartbeat transitions green → amber → red at the right thresholds
  when frames stop.
- UI heartbeat continues to pulse even if engine heartbeat is red.
- Pulse animation triggers on every new event.
- Elapsed time updates every second.
- Tooltip shows current values.

## Blocked by

- gui/0074 (store — needs `lastEventAt`, `heartbeatMs`).
