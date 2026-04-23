# libsmithers-core: promote Electric + WebSocket transports from fake to real

## Context

Ticket 0120 shipped the libsmithers-core production runtime skeleton
(`libsmithers/src/core/`) with a FAKE transport layer
(`libsmithers/src/core/transport.zig`). Swift consumers — `SmithersStore`
(0124), `RemoteModeController` (0126), `WorkspaceSwitcherViewModel`
(0138) — all call into the FFI correctly, but subscribed shapes and
HTTP writes never reach a real plue instance because the transport is
stubbed.

Meanwhile:
- PoC 0093 (`poc/zig-electric-client/`, ~1100 LOC, 45/45 tests) has a
  working Electric shape protocol client.
- PoC 0094 (`poc/zig-ws-pty/`, ~500 LOC, 39/39 tests) has a working
  WebSocket PTY client.

Both sit in `poc/` but aren't wired into the core runtime's transport
coordinator. This ticket promotes them.

## Goal

Replace `libsmithers/src/core/transport.zig`'s fake paths with the real
implementations adapted from `poc/zig-electric-client/` and
`poc/zig-ws-pty/`. After this, iOS + macOS clients actually talk to
plue.

## Scope

- **In scope**
  - Adapt `poc/zig-electric-client/src/*.zig` into `libsmithers/src/core/`:
    - Namespace collisions resolved (probably `core/electric/` submodule).
    - Offset + shape-handle persistence hooks use the bounded SQLite
      cache from `cache.zig`.
    - Reconnection / 401 / `must-refetch` behavior wired to the session
      event bus (`session.zig` EventTag).
  - Adapt `poc/zig-ws-pty/src/*.zig` into `libsmithers/src/core/`:
    - PTY handle lifecycle (attach/detach/write/resize) hooks the existing
      `smithers_core_attach_pty` FFI.
    - `Origin` + `Sec-WebSocket-Protocol: terminal` + bearer auth forward
      from the session's credentials provider.
  - HTTP JSON write path: `smithers_core_write` actually issues a real
    POST to plue's REST endpoint derived from `action.kind`.
  - Token refresh handoff: when plue returns 401, core calls the
    credentials-provider callback once to get a fresh bearer, retries.
- **Out of scope**
  - New Electric features beyond what PoCs prove (chunked transfers,
    must-refetch, long-poll are all in 0093).
  - Multi-client PTY reattach (deferred to v2 per 0102).
  - SSE fallback — add once a run-trace consumer demands it.

## Acceptance criteria

- `zig build test` passes all existing 116+ tests plus new integration
  tests for the real transport.
- New Zig integration test that exercises the full loop:
  1. Spin up plue docker stack (or gate on `POC_ELECTRIC_STACK=1`).
  2. Mint a test token.
  3. Subscribe to `agent_sessions` shape.
  4. Insert a row via direct Postgres fixture.
  5. Observe the delta arrive via core's cache_query FFI.
- SmithersStore tests (Swift, `Shared/Tests/SmithersStoreTests/`) that
  were previously gated on `POC_ELECTRIC_STACK=1` now light up and pass.
- iOS e2e harness (ticket 0141) that was previously showing "empty
  workspaces" now shows seeded workspaces because the real shape is
  delivering rows.
- `libsmithers/src/core/transport.zig` no longer contains any function
  with `_ = args; // TODO(0140): real transport`.

## Risks / unknowns

- Zig version pinning: 0093 and 0094 are at Zig 0.15.2; libsmithers
  proper has its own pin. Coordinate.
- Memory ownership across FFI boundary when the core session owns the
  Electric client's allocator vs. the PoCs' independent allocators.
- Keeping `poc/` intact after promotion — these stay as reference
  harnesses + their unit tests; production lives in `libsmithers/src/`.
