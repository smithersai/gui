# Live Run Header with Dual Heartbeats

> Quality bar: spec §9.

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §2.3 and §5.

Header for the new live-run view. Status pill, workflow name + runId,
elapsed, dual heartbeats, overflow menu.

## Scope

### `LiveRunHeaderView`

Layout (left → right): status pill · workflow name + runId · elapsed ·
heartbeat cluster · overflow menu.

### Dual heartbeat

**Engine heartbeat**:

- Green — last event within `heartbeatMs * 2`.
- Amber — within `heartbeatMs * 5`.
- Red — older.
- One-shot pulse animation on every event (subscribe to
  `store.lastEventAt`).
- Tooltip: last timestamp, interval, last seq.

**UI heartbeat**:

- Fixed 1s cadence via `TimelineView(.periodic)` (no `Timer` that can
  stall on main loop blockage).
- Stops pulsing if SwiftUI main thread stalls.
- Renders as a second, smaller dot.

### Elapsed time

`TimelineView(.periodic(from: start, by: 1))`. Format:

- `< 60s`: `SS` seconds.
- `< 1h`: `MM:SS`.
- `≥ 1h`: `HH:MM:SS`.

### Status pill

Same color map as tree rows. Click → menu: Cancel, Hijack, Copy runId,
Open logs.

## Files (expected)

- `LiveRunHeaderView.swift` (new)
- `HeartbeatIndicator.swift` (new)
- `HeartbeatState.swift` (new — pure function of (now, lastEventAt,
  heartbeatMs))
- `RunStatusPill.swift` (new)
- `ElapsedTimeView.swift` (new)
- `Tests/SmithersGUITests/HeartbeatStateTests.swift`
- `Tests/SmithersGUITests/ElapsedTimeFormatTests.swift`
- `Tests/SmithersGUITests/RunStatusPillTests.swift`
- `Tests/SmithersGUITests/LiveRunHeaderViewTests.swift`
- `Tests/SmithersGUIUITests/HeartbeatIndicatorE2ETests.swift`

## Testing & Validation

### Unit tests — HeartbeatState

Pure function: `(now, lastEventAt, heartbeatMs) → HeartbeatColor`.

- lastEventAt = nil → red.
- now - lastEventAt < heartbeatMs * 2 → green.
- exactly at heartbeatMs * 2 boundary → green (inclusive) or amber?
  decide + test the exact boundary.
- now - lastEventAt = heartbeatMs * 3 → amber.
- now - lastEventAt = heartbeatMs * 5 → red (or amber on boundary;
  decide + test).
- now - lastEventAt > heartbeatMs * 5 → red.
- heartbeatMs = 0 (degenerate) → immediately red + warn log.
- heartbeatMs = very large (24h) → handles overflow gracefully.

### Unit tests — ElapsedTimeFormat

- 0s → "00:00" (or "0s" if minutes flavor preferred).
- 59s → "00:59".
- 60s → "01:00".
- 3599s → "59:59".
- 3600s → "01:00:00".
- 86401s (> 24h) → "24:00:01".
- Negative (clock skew) → "00:00" + log warn.

### Unit tests — RunStatusPill

- Every `RunStatus` maps to the documented color and label.
- Menu actions fire correct store callbacks (verified via mock).
- Copy runId → pasteboard check.

### Unit tests — LiveRunHeaderView

- Renders with nil store state (still-loading) → neutral placeholders,
  no crash.
- lastEventAt changes → triggers pulse (verified via animation state
  observer).
- UI heartbeat keeps pulsing even when engine heartbeat is red.
- Tooltip content rebuilt on state change.

### Input-boundary tests

| Case                                  | Expected                          |
|---------------------------------------|-----------------------------------|
| store disconnected, no events ever    | engine red, UI green pulsing      |
| events every 500ms                    | engine green, pulse per event     |
| events every 10s with heartbeatMs=1000 | amber → red transitions correctly |
| heartbeatMs = 100 (fast)              | visible pulses don't stack        |
| heartbeatMs = 60,000 (slow)           | pulses are spaced, no flicker     |
| clock skew (lastEventAt in future)    | engine green; log warn            |
| reduceMotion on                        | no pulse animation; state colors still change |
| VoiceOver on                           | state changes announced          |

### UI / E2E tests

- Heartbeat transitions visible in a UI test with fixture event
  timestamps (advance fake time).
- Tooltip appears on hover; shows correct text.
- Status pill menu opens; each action dispatches.
- Elapsed time advances in real time over a short test window.

### Accessibility

- Both dots have accessibility labels: "Engine heartbeat — last event
  2 seconds ago, healthy." / "UI heartbeat — responding."
- Status changes announce via VoiceOver (announcement notification).
- Contrast on every heartbeat state passes WCAG AA.
- `reduceMotion` → skip pulse animations, keep state color changes.

### Performance

- Pulse animation is lightweight; does not cause hitches.
- Header rebuild on every event < 5ms.

## Observability

- `debug` every 60s: heartbeat state transition log (only on change).
- `warn` on clock skew detected.
- Signpost around header render for Instruments.

## Error handling

- Store state inconsistencies rendered neutrally; never crash the
  header (it's the user's last line of sight when things are wrong).

## Acceptance

- [ ] HeartbeatState tests cover every region including boundaries.
- [ ] ElapsedTimeFormat covers documented edge cases.
- [ ] UI tests verify transitions.
- [ ] Accessibility tests pass.
- [ ] `reduceMotion` respected.
- [ ] Manual verification: disconnect network mid-run, watch state
      transition green → amber → red; reconnect → green.

## Blocked by

- gui/0074
