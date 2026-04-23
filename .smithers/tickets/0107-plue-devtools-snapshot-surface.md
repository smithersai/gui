# Plue: generic devtools snapshot surface

## Context

From `.smithers/specs/ios-and-remote-sandboxes.md` (Changes Needed In Plue → Additions #4) and `.smithers/tickets/0101-design-rollout-plan.md` (flag `devtools_snapshot_enabled`). The main spec commits to a "generic devtools surface" — a live view of whatever the agent is currently looking at (screen, file tree, command output) — that isn't `diffview/`'s VCS-tied diff. The rollout plan allocates a feature flag for it. But there's no implementation ticket owning the feature, and the rollout doc rule (every flag must have an owning ticket) is currently violated.

Ticket 0131 is a hard prerequisite for this work. The writer path in this ticket adds a new guest-agent RPC, so protocol negotiation and capability advertisement must land before any new snapshot method ships.

## Problem

Clients need a way to see live agent-authored context beyond chat messages and terminal bytes:

- Agent's current working-directory file tree.
- Last screenshot or rendered output.
- Tool-call intermediate state.

`diffview/` is jj-VCS-specific. `WorkflowRunLogsStream` is a log stream, not a general-purpose context feed. There's no existing plue route that fits.

## Goal

A plue-side endpoint + shape combo that lets a client subscribe to a live, structured snapshot of agent-context data for a workspace session, and an Electric shape that syncs the latest snapshot to all connected clients.

## Scope

- **In scope**
  - **Decide the payload schema first** (in this ticket). Required fields: `session_id`, `repository_id` (necessary — see next bullet), `timestamp`, `kind` (enum: file-tree, screenshot, command-output, tool-state), `payload` (JSON blob per `kind`).
  - Postgres table `devtools_snapshots` storing the latest snapshot per `(session_id, kind)`, with `repository_id` denormalized onto every row. Old snapshots may be pruned aggressively; this is not a history log.
  - **Writer path (guest-agent):** new method — e.g. `MethodWriteDevtoolsSnapshot` — that the agent runtime calls whenever it produces a new snapshot. Guest-agent forwards to plue; plue writes the row with the correct `repository_id` from context.
  - **Reader path (clients):** Electric shape `devtools_snapshots WHERE repository_id IN (...) AND session_id IN (...)`. The `repository_id` filter is **required** — plue's Electric auth proxy (`internal/electric/auth.go:47, 85`) rejects shape subscriptions whose `where` clause doesn't filter by `repository_id`. A session-only filter would be rejected.
  - Tests: writer writes, shape delivers, client reads, ACL enforced.
- **Out of scope**
  - Deciding what specific agent runtimes produce what `kind`s of snapshots. This ticket defines the pipe; individual agents fill it.
  - Client-side rendering. That's a gui-side follow-up.
  - Full snapshot history / diffing. Latest-per-kind is enough for v1.
  - Large binary payloads (screenshots > 1 MB) — use blob storage or defer; this ticket stays JSON.

## References

- `plue/internal/diffview/` — VCS-tied diff; NOT what this ticket replicates.
- `plue/internal/routes/workflow_runs.go:36` — `WorkflowRunLogsStream`; reference for SSE lifecycle if Electric shape isn't a good fit.
- `plue/internal/sandbox/guest/handler.go` — where a new guest-agent method lives.
- `plue/internal/electric/auth.go` — how shapes are scoped by repo.

## Acceptance criteria

- Schema for `devtools_snapshots` documented and migrated.
- Ticket 0131 has landed, and the snapshot write path is gated by the negotiated guest-agent capability it defines.
- Guest-agent protocol extended with a write method; docs updated.
- Electric shape subscription works end-to-end from test client (a Go or TS test using the B1 harness pattern).
- Unit + integration tests covering: ACL enforcement (wrong repo rejected), latest-wins (second write for same `(session_id, kind)` replaces the first), fan-out to multiple subscribers.
- README documents: snapshot schema, how a new `kind` is added, retention policy.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies snapshot writes from the guest-agent actually round-trip to Postgres (not stubbed), the shape filter enforces `repository_id`, and the schema doesn't leak session contents across repos.

## Risks / unknowns

- **Depends on 0131.** This ticket must not introduce a new guest-agent method until ticket 0131's handshake/capability negotiation is available. Snapshot writes should be keyed off the negotiated capability, not on deploy ordering.
- Cardinality: how many snapshots per second per session? Bound the write rate or batch at the guest-agent to avoid hammering Postgres.
- Large payloads: screenshots are big. Decide now whether to offload to blob storage (plue has `internal/blob/`) or keep everything inline.
- Pruning: define a retention policy — delete snapshots older than a session's terminal state.
