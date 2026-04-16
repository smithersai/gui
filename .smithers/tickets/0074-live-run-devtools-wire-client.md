# Live Run DevTools Wire Client and Store

> Quality bar: spec §9. Every tier required. Data-layer ticket — correctness
> is paramount since every downstream view depends on this.

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §3 and §4.3.

The new live-run UI starts with a data layer: a store that owns the
`DevToolsSnapshot`, subscribes to `streamDevTools`, applies
`DevToolsDelta` ops, and exposes SwiftUI-observable state.

## Scope

### 1. Swift types

Mirror protocol types from `packages/protocol/src/devtools.ts`:

- `DevToolsNode` (`Codable`, stable `id: Int`, `Hashable` by id).
- `DevToolsSnapshot`.
- `DevToolsDelta` with `DevToolsDeltaOp` enum covering `addNode`,
  `removeNode`, `updateProps`, `updateTask`.
- `DevToolsEvent` enum.
- `JSONValue` (or equivalent `AnyCodable`) for arbitrary prop payloads.

### 2. `LiveRunDevToolsStore` (`@MainActor` `ObservableObject`)

Responsibilities:

- `@Published` state: `tree`, `seq`, `lastEventAt`, `selectedNodeId`,
  `isGhost`, `connectionState` (`.disconnected | .connecting |
  .streaming | .error(code)`).
- `connect(runId:)` — subscribes to `streamDevTools(runId, fromSeq: seq)`.
- `applyEvent(_ event: DevToolsEvent)` — pure, unit-testable. Mutates
  tree via `applyDelta` or replaces via snapshot.
- `applyDelta(_ delta: DevToolsDelta, to tree: DevToolsNode?) throws ->
  DevToolsNode` — pure function, separated for testability.
- Ghost state: if `selectedNodeId` is not findable in tree after an
  event, set `isGhost = true`. Re-selecting or selected node
  reappearing clears ghost.
- Reconnect on stream error with exponential backoff (1s, 2s, 4s, 8s,
  16s, cap at 30s; reset on successful event).
- Cancellation: `disconnect()` tears down the stream; idempotent.
- Expose `heartbeatAgeMs` computed property (read by 0080).

### 3. `SmithersClient` additions

- `streamDevTools(runId:, fromSeq:) -> AsyncThrowingStream<DevToolsEvent, Error>`
- `getDevToolsSnapshot(runId:, frameNo:) async throws -> DevToolsSnapshot`
- Typed error bridge: map server error codes (`RunNotFound`,
  `FrameOutOfRange`, `InvalidRunId`, `SeqOutOfRange`,
  `BackpressureDisconnect`) to Swift `DevToolsClientError` enum.

## Files (expected)

- `DevToolsModels.swift` (new)
- `LiveRunDevToolsStore.swift` (new)
- `DevToolsClientError.swift` (new)
- `SmithersClient.swift` (extend)
- `Tests/SmithersGUITests/LiveRunDevToolsStoreTests.swift`
- `Tests/SmithersGUITests/ApplyDeltaTests.swift`
- `Tests/SmithersGUITests/DevToolsClientErrorMappingTests.swift`
- `Tests/SmithersGUITests/ReconnectBackoffTests.swift`
- `Tests/SmithersGUITests/StoreSoakTests.swift` (opt-in, `SMITHERS_SOAK=1`)

## Testing & Validation

### Unit tests — `applyDelta`

Round-trip every op. Specific cases:

- Base tree = nil, op = addNode(root) → tree = single node.
- Base tree populated, op = addNode(existing parent, index) → inserted
  at correct index.
- op = addNode targeting unknown parent → throws `UnknownParent`; tree
  unchanged.
- op = removeNode existing → removed; children removed with parent.
- op = removeNode unknown id → throws `UnknownNode`; tree unchanged.
- op = updateProps on existing → props merged (not replaced? verify
  protocol contract; test both).
- op = updateProps unknown id → throws `UnknownNode`.
- op = updateTask on non-task node → throws or no-ops (protocol decides;
  test matches).
- 100-op delta applied in order; result matches expected fixture.
- Delta with opCount = 0 → tree unchanged, no throw.

### Unit tests — snapshot handling

- Snapshot replaces tree wholesale; `seq` updated.
- Snapshot with new runId vs current → treated as error (should not
  happen; log + disconnect).
- Snapshot with same seq twice → second is ignored (no double-apply).

### Unit tests — ghost state

- Select nodeId, snapshot arrives where node still exists → `isGhost`
  false.
- Select nodeId, event arrives that removes it → `isGhost` true,
  selectedNode still accessible.
- While ghost, re-selecting a live node → ghost false.
- While ghost, a later event re-adds the node (same id) → ghost
  auto-clears.
- Deselect (nil selectedNodeId) → ghost false.

### Unit tests — reconnect backoff

- First failure → 1s delay.
- Sequential failures → 2s, 4s, 8s, 16s, 30s, 30s, 30s.
- Success after N failures → resets timer; next failure starts at 1s.
- Backoff interrupted by `disconnect()` → no retry.
- Backoff cap enforced.

### Unit tests — error mapping

- Every server error code maps to exactly one `DevToolsClientError`
  case.
- Unknown error code → `.unknown(String)` catch-all.
- Network errors (URLError) → `.network(URLError)`.
- Decode errors → `.malformedEvent(DecodingError)` + log + request
  resync (by reconnecting without `fromSeq`).

### Input-boundary tests

| Case                                          | Expected                         |
|-----------------------------------------------|----------------------------------|
| snapshot with 0 nodes                          | tree is root-only, no crash      |
| snapshot with 10,000 nodes                     | applied, memory stable           |
| snapshot with 1 MB prop string                 | tree holds; no clipping          |
| snapshot with unicode / emoji                  | round-trips                      |
| delta addNode at index 0, 1, end               | each inserts at correct position |
| delta addNode at index > children.count        | throws `IndexOutOfBounds`        |
| delta removeNode of root                       | tree = nil                       |
| 100 consecutive deltas in 1s                   | all applied in order             |
| event with seq that goes backwards             | ignored + log warn               |
| event with seq that skips forward by 1000      | request resync                   |

### Concurrency / thread safety

- Every tree mutation on `@MainActor`. Attempt to mutate from
  background → compile error (verified by existence of `@MainActor`).
- Simultaneous connect + disconnect → disconnect wins, no leaked Task.
- Two connect calls in a row (without disconnect) → second cancels
  first cleanly.

### Soak test (opt-in)

`SMITHERS_SOAK=1`: run a mock stream emitting 100 events/sec for 10
minutes. Assert:

- No Task leaks (XCTest `addTeardownBlock` counts).
- Memory footprint stable (no monotonic growth).
- Final tree equals expected fixture.

### Performance baselines

- applyDelta on 500-node tree: < 5ms p95.
- Full snapshot decode + store: < 50ms for 500-node tree.
- applyDelta on 100 consecutive events in a loop: < 500ms total.

## Observability

### Logs (`os_log` unified logging)

- `info` on connect: `runId`, `fromSeq`.
- `info` on disconnect: duration, events applied.
- `debug` on every event received: `kind`, `seq`, `bytes`.
- `warn` on seq anomaly (backwards / large gap).
- `warn` on reconnect attempt, with attempt number + delay.
- `error` on applyDelta failure, decode error, unrecoverable server
  error.
- Never log prop values / prompts.

### Metrics / Swift instruments

- Record signposts around connect, disconnect, applyDelta, snapshot
  decode — profileable in Instruments.
- Simple counters in store (events applied, reconnects, decode errors)
  exposed as read-only `@Published` for developer-debug view
  (`DeveloperDebugView` already exists).

## Error handling

- Every error is a typed `DevToolsClientError` case.
- UI surfaces errors via `connectionState` enum; downstream views read
  it and render banners (in 0075+).
- Never crash on malformed input; always downgrade + log.

## Accessibility

N/A at this layer (no UI), but expose `connectionState` in a form
downstream views can announce to VoiceOver.

## Acceptance

- [ ] Every unit test above passes.
- [ ] Every boundary case returns documented state.
- [ ] Reconnect backoff exact timings verified.
- [ ] Ghost state transitions verified end-to-end.
- [ ] Error code mapping exhaustive (one test per server error code).
- [ ] Store is `@MainActor`; no data-race warnings under
      `-strict-concurrency=complete`.
- [ ] Soak test passes locally.
- [ ] Performance budgets met.
- [ ] No prop values appear in any log.
- [ ] Swift concurrency annotations (`Sendable`, `@MainActor`) correct.

## Blocked by

- smithers/0010

## Blocks

- gui/0075, 0076, 0080, 0081 (consumers of the store)
