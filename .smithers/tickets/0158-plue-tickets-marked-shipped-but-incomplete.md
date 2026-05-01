# plue: multiple "shipped" initiative tickets never actually landed backend work

## Status (audited 2026-04-24) — PARTIAL

- Done: 4308aefb8 resolved most of the gaps this ticket flagged — 0105 migrations, 0107/0110/0134/0154/0155/0157 routing all landed.
- Remaining: 0130 (SSH host-key verification), 0131 (protocol negotiation), 0139 (where-clause parser hardening), 0145 (workspace_snapshots shape), 0146 (iOS cell renderer) still INCOMPLETE and contribute to the original "shipped but incomplete" concern.

## Context

Attempting to run the full e2e suite (now 108 scenarios after the 10-agent
codex batch) surfaced that the following tickets are marked "Merged" /
shipped but did NOT land their plue-side work:

### Confirmed incomplete

1. **0149 atlas migration renumber**: renames never committed to plue.
   Fixed in this session (`plue@07e5d001e`) by actually renaming +
   rehashing `atlas.sum`.

2. **0105 workspace quota + soft-delete**: `workspaces.deleted_at`
   column exists in `oss/db/schema.sql` but NO migration adds it to
   `plue/db/migrations/`. Live seed fails with
   `ERROR: column "deleted_at" does not exist`. The plue runtime DB
   is seeded from `db/migrations/`, not `db/schema.sql`, so the column
   never materialises.

3. **0107 devtools snapshots**: schema + queries shipped, HTTP route
   never wired (see ticket 0154).

4. **0110 approvals**: handler grep-invisible (see ticket 0155).

5. **0112 feature flags**: flag registrations missing from
   `/api/feature-flags` (see ticket 0157). The five initiative flags
   (`remote_sandbox_enabled`, `electric_client_enabled`,
   `approvals_flow_enabled`, `devtools_snapshot_enabled`,
   `run_shape_enabled`) are absent.

6. **0132 rate limits** and **0105 quota** enforcement: middleware
   not mounted on the six documented routes (see ticket 0153).

### Probably also affected (not yet verified)

- 0111 run shape / canonical routes
- 0114 agent_sessions shape + tombstone
- 0115+0118 agent_messages + parts shape
- 0116 workspaces shape
- 0117 workspace_sessions shape
- 0134 approval audit

Pattern: the ticket doc was written, ticket was checked off, but the
runtime-observable behaviour (migration, route handler, flag
registration) never actually reached `plue/db/migrations/`,
`plue/internal/routes/`, or `plue/cmd/server/main.go`.

## Plan

This is the umbrella for a validation pass:

1. For each "shipped" initiative ticket, write a concrete runtime
   assertion (HTTP call, SQL query, or shape subscription) that MUST
   pass on a fresh `make docker-up`.
2. Fix the actually-missing pieces. Smallest-blast-radius pieces first:
   migration-only tickets (0105 workspaces.deleted_at), then handlers.
3. Track via sub-tickets 0151–0157 already filed.

## Acceptance criteria

- `ios/scripts/run-e2e.sh` runs the full suite without XCTSkipping on
  missing routes / flags / columns.
- `make docker-up` + `make seed` succeed from a clean slate without
  SQL errors.
- A follow-up CI job runs the suite on every PR touching
  `plue/internal/routes/` or `plue/db/migrations/`.
