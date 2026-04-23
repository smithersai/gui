# PoC: Zig ElectricSQL shape client

## Context

From `.smithers/specs/ios-and-remote-sandboxes-execution.md`, PoC-A2. Stage 0 foundation. The client-side Electric implementation is the core's main state-sync surface. If we can't implement Electric's HTTP shape protocol in Zig reasonably, the whole client architecture breaks.

## Problem

`libsmithers-core` (Zig) needs to subscribe to ElectricSQL shapes, store rows in a bounded local SQLite, and survive reconnection with no gaps or duplicates. No Zig Electric client exists; the TypeScript `@electric-sql/client` and plue's `oss/packages/sdk/src/services/sync.ts` are the references. This PoC proves it's a bounded piece of work, not months of effort.

## Goal

A minimal Zig library that talks Electric's HTTP shape protocol end-to-end, proven against two test tiers: (1) a fake protocol server that asserts protocol correctness, and (2) the real plue + Postgres + Electric stack that asserts the auth proxy integration works.

## Scope

- **In scope**
  - Zig library at `poc/zig-electric-client/`.
  - Supports: initial snapshot fetch, long-poll for deltas, offset / shape-handle persistence, resume-after-disconnect, unsubscribe.
  - **Tier 1 tests — fake server.** Unit-style Zig tests against a minimal in-process HTTP server that emits crafted Electric protocol responses (including edge cases: chunked snapshots, delta reordering attempts, unexpected close mid-stream).
  - **Tier 2 tests — real stack.** Integration test harness runs plue + Postgres + upstream Electric service via docker-compose. Auth: mint a real bearer token, subscribe to a synthetic table whose shape `where` clause filters by `repository_id IN (...)` matching a repo the token has access to.
  - **Auth constraints the ticket must honor.** Plue's proxy (`plue/internal/electric/auth.go:44, 250`) parses the `where` clause and enforces per-repo ACLs. The PoC's shape must include `repository_id` filtering; a second test case confirms a request with a wrong-repo `where` is rejected.
  - Bounded local cache: rows stored via the existing SQLite wrapper (`libsmithers/src/persistence/sqlite.zig`). The PoC can adapt that wrapper rather than writing a new one.
- **Out of scope**
  - Full Electric protocol coverage — we only need what the spec's shape list actually uses.
  - Any FFI surface (separate PoC).
  - Write queue / upstream sync — plue does writes over plain REST; the client is read-only via Electric.
  - Real plue shape definitions for production data — use a throwaway `poc_items` table with `repository_id` for the test.
  - iOS-specific SQLite integration — covered by PoC-A6.

## References

- `@electric-sql/client` — the reference TypeScript implementation.
- `plue/oss/packages/sdk/src/services/sync.ts` — the battle-tested pattern from plue's deprecated TS sync daemon; read this for lifecycle and edge cases.
- `plue/internal/electric/` — the auth proxy we'll be authenticating against.

## Acceptance criteria

- Docker-compose file brings up plue + Postgres + Electric upstream locally.
- Zig client subscribes to a synthetic shape, receives rows.
- Test: writer inserts, updates, and deletes rows in a background goroutine/process; client observes each delta in order, no duplicates, no gaps.
- Test: client disconnects mid-stream, reconnects, picks up exactly where it left off.
- Test: unsubscribe releases all resources; no goroutine/thread leaks reported by Zig's test allocator.
- README covers: prerequisites, how to bring up the stack, how to run tests.

## Independent validation

See D3 (`ticket 0099`). Until D3 lands: reviewer verifies the reconnect test actually exercises a real TCP disconnect (not a graceful close), shape-handle token is persisted across restart, and no rows are "seen" before the server confirms them.

## Risks / unknowns

- Electric's protocol may have backpressure or chunk-sequencing subtleties the reference TS client hides behind library abstractions. Expect to read `@electric-sql/client` source.
- Authentication: plue's proxy expects a bearer token that has repo access. Test harness needs to mint a valid one up front.
