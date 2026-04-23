# Plue: `agent_messages` production Electric shape

## Context

The spec expects chat transcripts to live in synced client SQLite and be read back through APIs like `getMessages(sessionId, limit, offset)` (`.smithers/specs/ios-and-remote-sandboxes.md:186-194`). Plue already exposes `GET/POST /api/repos/{owner}/{repo}/agent/sessions/{id}/messages` via `cmd/server/main.go:1174-1175` and `internal/routes/agent_sessions.go:222-340`, backed by exact table `agent_messages` in `db/migrations/000001_baseline.sql:745-754` and queries in `internal/db/agent.sql.go:321-401`.

## Problem

- `agent_messages` does **not** carry `repository_id`, so the current Electric auth proxy would reject any raw-table shape for it (`internal/electric/auth.go:47-50`, `85-100`, `250-282`).
- Repo-wide subscription would be the wrong cardinality anyway; message volume is per-session and can be hundreds or more.
- The table only stores envelope data (`session_id`, `role`, `sequence`, `created_at`). Actual content lives in `agent_parts`, so this ticket has to stay clear about what it does and does not sync.
- There is no independent delete/edit surface for messages today. Rows are append-only unless the parent session is deleted.

## Goal

Ship a production Electric shape for exact table `agent_messages` so open chat tabs can sync ordered message envelopes into local SQLite without polling.

## Scope

- **In scope**
  - Shape exact table `agent_messages`.
  - Add `repository_id BIGINT NOT NULL` to `agent_messages`, backfilled from `agent_sessions.repository_id`.
  - Populate `repository_id` on every insert path. That includes user/appended messages and runner-emitted assistant messages, because `IngestRunnerEvent` goes through `AppendMessage` (`internal/services/agent.go:748-795`).
  - Add an index supporting the production filter, e.g. `(repository_id, session_id, sequence)` while keeping replay-friendly `(session_id, id)` behavior.
  - Shape where-clause template: `repository_id IN (<repo_ids>) AND session_id IN (<open_session_ids>)`.
  - Subscription policy:
    - Never subscribe repo-wide to all messages.
    - One shape per open chat tab / actively inspected session.
    - Apply the spec’s LRU-at-shape level on tab close (`.smithers/specs/ios-and-remote-sandboxes.md:186-187`).
  - Client consumers:
    - Transcript ordering / pagination in the chat view.
    - Local replay after reconnect.
    - Bounded-SQLite backing for the FFI `getMessages(sessionId, limit, offset)` contract.
  - Delete semantics for this table stay append-only in v1. Session deletion is handled by the `agent_sessions` tombstone from 0114; clients purge child rows when they observe the parent tombstone.
  - Tests:
    - Migration/backfill test proving old rows gain the right `repository_id`.
    - Service unit tests proving new inserts populate `repository_id`.
    - Shape auth tests for good repo, bad repo, and missing repo filter.
    - Multi-client fan-out test: two subscribers on the same session both receive user and assistant message inserts in sequence order.
    - High-cardinality test with 500+ messages confirming subscription stays session-scoped.
- **Out of scope**
  - Syncing message content (`agent_parts`); that is 0118.
  - Message edit/delete semantics; there is no public route for that today.
  - Changing the current repo-readable chat privacy contract.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md:186-194`, `266-269`
- `plue/internal/electric/auth.go:47-50`, `85-100`, `250-282`
- `plue/cmd/server/main.go:1174-1175`
- `plue/internal/routes/agent_sessions.go:222-340`
- `plue/internal/services/agent.go:471-795`
- `plue/internal/db/agent.sql.go:30-84`, `321-401`
- `plue/db/migrations/000001_baseline.sql:745-754`

## Acceptance criteria

- `agent_messages` has a documented production shape definition on the exact table, not a joined view.
- The table carries `repository_id`, existing rows are backfilled, and new inserts populate it on every path.
- The shape definition is session-scoped: production examples and tests use `repository_id IN (...) AND session_id IN (...)`, not repo-wide message sync.
- A plue integration test appends messages through the existing public route and through runner event ingestion, then verifies two subscribed clients receive ordered inserts.
- Electric auth tests confirm raw `agent_messages` shapes are rejected without the repo filter and accepted only for authorized repos.

## Independent validation

See ticket 0099. Until 0099 lands, reviewer verifies:

- The migration backfills live data by joining through `agent_sessions`, not by leaving old rows null.
- The fan-out test uses the actual route/service path that writes `agent_messages`, not direct SQL fixtures only.
- The ticket does not claim transcript sync is complete by itself; `agent_parts` is explicitly wired in as the companion ticket.

## Risks

- This table is only the transcript envelope. If 0118 slips, the client will have order/role metadata but not message bodies.
- Repo-readable transcript visibility is already the current plue contract; if that changes later, both the routes and the shapes must change together.
- Backfilling a large `agent_messages` table can be expensive; stage the migration and indexing carefully.
