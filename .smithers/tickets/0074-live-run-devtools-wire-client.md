# Live Run DevTools Wire Client and Store

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` (in the smithers repo) §3
and §4.3.

Replacement for the current `LiveRunChatView` starts with a new data layer:
a store that owns the `DevToolsSnapshot`, subscribes to `streamDevTools`,
applies `DevToolsDelta` ops, and exposes SwiftUI-observable state. All
other gui tickets depend on this.

## Scope

### 1. Swift types

Mirror the protocol types from `packages/protocol/src/devtools.ts`:

- `DevToolsNode` (struct, `Codable`, stable `id: Int`).
- `DevToolsSnapshot`.
- `DevToolsDelta` with `DevToolsDeltaOp` enum covering `addNode`,
  `removeNode`, `updateProps`, `updateTask`.
- `DevToolsEvent` enum — `.snapshot(DevToolsSnapshot)` or
  `.delta(DevToolsDelta)`.

Prop values can be arbitrary JSON. Use an `AnyCodable` wrapper (or
`JSONValue`) in `props` so we can round-trip unknown shapes.

### 2. `LiveRunDevToolsStore` (ObservableObject)

Responsibilities:

- Own the current snapshot + `seq`.
- `connect(runId:)`: call `streamDevTools(runId, fromSeq: seq)`, apply
  events as they arrive, update `@Published var tree: DevToolsNode?`.
- Reconnect with backoff on stream error. Use stored `seq` to resume.
- `applyDelta(_:)` — pure function, unit-testable. Mutates a tree by
  `node.id`.
- Expose `lastEventAt: Date` so the header can compute heartbeat state.
- Expose `selectedNodeId: Int?` + `selectedNode: DevToolsNode?` (with
  **ghost state**: if the selected id disappears from the tree, keep
  returning the last-known node and set `isGhost = true` until the user
  selects something else).

### 3. `SmithersClient` additions

Wire methods in `SmithersClient.swift`:

- `streamDevTools(runId, fromSeq:) -> AsyncThrowingStream<DevToolsEvent, Error>`
- `getDevToolsSnapshot(runId, frameNo:) async throws -> DevToolsSnapshot`

Match existing client conventions (transport selection, timeouts,
cancellation via `Task.cancel()`).

## Files (expected)

- `Models.swift` or new `DevToolsModels.swift` — Swift types.
- `LiveRunDevToolsStore.swift` (new).
- `SmithersClient.swift` — add two methods.
- `Tests/SmithersGUITests/LiveRunDevToolsStoreTests.swift` (new).

## Acceptance

- Unit test: `applyDelta` round-trips with fixtures that exercise each op
  kind.
- Unit test: disappearing selected node flips `isGhost = true` while
  preserving the last-known node.
- Unit test: reconnect replays from stored `seq` (fixture server stub).
- No view changes yet — just data layer.

## Blocked by

- smithers/0010 (needs the gateway RPC + wire types shipped).

## Blocks

- gui/0075, 0076, 0080, 0081 (all consume the store).
