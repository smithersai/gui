# SmithersStore

Ticket 0124. Shared, platform-neutral observable store layer that sits on top
of `SmithersRuntime` (ticket 0120) and exposes Electric-backed state to the
SwiftUI view layer. Cross-platform (macOS + iOS) by design — no AppKit, no
UIKit, no CLI, no local-only fallbacks.

## Layout

- `SmithersStore.swift` — entry point: `SmithersStore` root that owns the
  `RuntimeSession` and vends entity stores + a pessimistic-write dispatcher.
- `StoreEntities.swift` — DTO shapes that correspond to the production
  Electric shape slices (0114–0118, 0110, 0111, 0107). Decoded from the
  JSON envelopes emitted by `smithers_core_cache_query`.
- `RunsStore.swift` — `workflow_runs` shape subscription + cache reads.
- `ApprovalsStore.swift` — `approvals` shape (pinned).
- `WorkspacesStore.swift` — `workspaces` + `workspace_sessions` shapes.
- `AgentSessionsStore.swift` — `agent_sessions`, `agent_messages`,
  `agent_parts` shapes.
- `DevToolsSnapshotsStore.swift` — `devtools_snapshots` shape (per-run pin).
- `SessionLifecycle.swift` — auth token injection, reconnect, sign-out wipe.

## Data plane

- STATE: Electric shape subscriptions (via `RuntimeSession.subscribe`) feed
  a bounded SQLite cache in Zig. Stores re-query the cache on every
  `.shapeDelta` event for their table.
- WRITES: `SmithersStore.dispatch(_:echoTable:)` goes through
  `smithers_core_write` (HTTP). UI state is NOT updated optimistically —
  the store only publishes the new row after the matching `.shapeDelta`
  arrives (pessimistic-write rule from the initiative spec).
- SSE: intentionally NOT used here. Per-run event traces belong to the
  terminal / live-run layer (ticket 0123) which opens its own SSE stream.

## Fake transport caveat

`libsmithers-core` today ships a FAKE transport (ticket 0120 note). End-to-end
tests that actually exercise the shape subscriptions and HTTP writes must be
guarded behind `POC_ELECTRIC_STACK=1`. Until a real plue stack is reachable,
this module compiles, wires, and unit-tests the Swift-side state machine; the
last mile is validated by 0126 when the runtime is switched over.
