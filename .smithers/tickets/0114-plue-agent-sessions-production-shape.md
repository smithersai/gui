# Plue: `agent_sessions` production Electric shape

## Context

The main spec commits the remote client to Electric-synced engine state for chats, workspaces, approvals, and runs, backed by bounded client SQLite instead of ad hoc polling (`.smithers/specs/ios-and-remote-sandboxes.md:42`, `171-194`, `264-269`). Plue already has the repo-scoped agent session API registered at `cmd/server/main.go:1169-1175`, with handlers in `internal/routes/agent_sessions.go:62-338`, backed by the real `agent_sessions` table in `db/migrations/000001_baseline.sql:730-743` and list/detail queries in `internal/db/agent.sql.go:183-220` and `404-473`.

## Problem

- There is no production shape ticket for chat-session metadata, so the client has no authoritative synced source for the repo chat list.
- `agent_session_stream.go` is a single-session SSE feed, not the initial snapshot + resumable local cache the spec requires.
- `DeleteSession` is a hard delete today (`internal/db/agent.sql.go:169-180`, `internal/services/agent.go:1085-1110`), which gives no durable tombstone for cross-device cache cleanup.
- Current plue behavior is repo-readable, not user-private: `ListSessions` filters only on `repository_id` (`internal/services/agent.go:436-468`, `internal/db/agent.sql.go:450-473`). The shape must either mirror that contract or deliberately change it.

## Goal

Ship a production Electric shape for exact table `agent_sessions` so clients can keep chat-session metadata in bounded SQLite and render the repo chat list without polling.

## Scope

- **In scope**
  - Shape exact table `agent_sessions`.
  - Shape where-clause template: `repository_id IN (<repo_ids>)`.
  - No repository denormalization is needed; `agent_sessions` already stores `repository_id`.
  - Mirror the current plue visibility model first: repo-scoped session metadata. Do not silently tighten this to `user_id = authed.User.ID` in the shape unless the HTTP API is changed in the same work, because that would be a product behavior change.
  - Client consumers:
    - Repo chat list / session picker.
    - Per-session header metadata (`title`, `status`, `started_at`, `finished_at`).
    - Restore/reopen flow replacing the current local-only persisted chat-session state (`.smithers/specs/ios-and-remote-sandboxes.md:186-194`; current legacy test at `libsmithers/test/integration/workspace.zig:172-231`).
  - Add a synced tombstone for delete. Preferred shapeable model: `deleted_at TIMESTAMPTZ NULL` on `agent_sessions`, with `DeleteSession` changing from `DELETE` to an in-place tombstone update.
  - Keep the shape on the exact table. Do not introduce a joined pseudo-shape for `message_count`; clients can derive counts locally from synced child tables if needed.
  - Tests:
    - Service unit tests for create, list, status transition, and delete-tombstone behavior.
    - Shape auth tests for good repo, bad repo, and missing `repository_id IN (...)`.
    - Multi-client fan-out test: two subscribed clients see create, terminal status change, and delete tombstone in order.
- **Out of scope**
  - Message-row sync (`agent_messages`) and content sync (`agent_parts`); those land in 0115 and 0118.
  - Any privacy-model change from repo-readable chats to per-user chats.
  - Client UI work.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md:42`, `171-194`, `264-269`
- `plue/internal/electric/auth.go:47-50`, `85-100`, `250-282`
- `plue/cmd/server/main.go:809`, `1169-1175`
- `plue/internal/routes/agent_sessions.go:62-338`
- `plue/internal/routes/agent_session_stream.go:36-90`
- `plue/internal/services/agent.go:382-468`, `1085-1110`
- `plue/internal/db/agent.sql.go:131-220`, `404-473`
- `plue/db/migrations/000001_baseline.sql:730-743`

## Acceptance criteria

- `agent_sessions` has a documented production shape definition, including exact table name and `where` template.
- Delete behavior is shape-safe: either a tombstone field exists and the public delete route updates it, or the PR explicitly proves Electric delete fan-out is sufficient and updates this ticket/spec accordingly. Do not leave the answer implicit.
- Session list/detail queries exclude tombstoned rows by default.
- A plue integration test creates a session through the existing route, subscribes two clients to the shape, and verifies both clients see:
  - The initial insert.
  - A later status change (`active` to terminal).
  - The deletion tombstone or delete event.
- Electric auth tests confirm the proxy rejects shape requests without `repository_id IN (...)` and rejects repos the caller cannot read.

## Independent validation

See ticket 0099. Until 0099 lands, reviewer verifies:

- The route registration at `cmd/server/main.go:1169-1175` is still the surface exercised by the shape-backed flow.
- Delete no longer depends on one client polling or reloading the list to notice removal.
- The test harness uses the real Electric proxy path, not a fake in-memory broadcaster.

## Risks

- The current repo-readable chat model may be more permissive than the eventual product wants. This ticket should mirror current plue behavior and call out that mismatch, not smuggle in a privacy change.
- Soft-deleting sessions means child data (`agent_messages`, `agent_parts`) needs a deterministic local purge story; 0115 and 0118 must reference the session tombstone.
- If `message_count` becomes hot in list UIs, deriving it locally may be too expensive; do not denormalize it here unless benchmarks justify it.
