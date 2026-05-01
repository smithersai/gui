# Plue: fix duplicate atlas migration version numbers on main

## Context

Discovered during ticket 0142 (docker-up fix). Atlas refuses to run
migrations because multiple files share the same version prefix:

```
000025_add_billing_tables.sql
000025_add_sse_tickets.sql
000027_add_agent_session_timeouts.sql
000027_add_canary_results.sql
000027_add_releases.sql
000027_add_repo_config_as_code.sql
```

This is pre-existing on plue main — several parallel ticket branches
landed migrations with overlapping numbers. `atlas migrate hash` fails
loudly; so does the Docker `migrate` service in `make docker-up`.

**Blocks every integration test** that depends on a running plue
stack (0141 iOS e2e, 0140 transport live tests, 0145/0147 shape
tickets).

## Goal

Renumber the colliding files so the sequence has no duplicates.
Regenerate `atlas.sum`. Verify `make docker-up` completes through the
`migrate` service.

## Scope

- Choose a deterministic renumbering:
  - 000025 stays `add_billing_tables` (chronological first per git history).
  - 000025 → 000029 `add_sse_tickets`.
  - 000027 stays `add_agent_session_timeouts`.
  - 000027 → 000029 `add_canary_results` — actually 000029 now taken; use 000030...
- Better: push the five duplicate-colliders up past the existing top
  (currently 000038 devtools_snapshots after my initiative):
  - 000025 (sse_tickets) → 000039
  - 000027 (canary_results) → 000040
  - 000027 (releases) → 000041
  - 000027 (repo_config_as_code) → 000042
  - Leave 000025 add_billing_tables and 000027 add_agent_session_timeouts
    alone.
- OR: compact by renumbering the entire sequence — but that conflicts
  with the sqlc output depending on file-order-derived state. Prefer
  the "push duplicates up" approach.
- Run `atlas migrate hash --dir file://db/migrations`.
- Verify the SQL inside each moved file doesn't depend on any adjacent
  migration (quick read of dependencies).
- Run `make docker-up` end-to-end; `migrate` service exits 0; api
  service comes up healthy.

## Acceptance criteria

- `ls db/migrations/ | awk -F_ '{print $1}' | sort | uniq -d` returns
  empty.
- `atlas migrate hash` succeeds.
- `make docker-up` runs migrate to completion.
- No production data migration is reordered in a way that breaks SQL
  semantics (these are forward-only migrations — reordering is safe
  if none of the colliders depend on each other's output).

## Risks / unknowns

- If any of the 6 colliding migrations reference tables/columns from
  each other, the renumber preserves the intended apply order and
  everything is fine. Quick inspection suggests they're independent
  (billing ≠ sse-tickets, etc.). Verify.
- Atlas sum regeneration invalidates any existing deployed databases
  tracking this sum; this is a development-machine fix, not a
  production hot-patch.

## Dependencies

- 0142 (docker-up bun lockfile patch) for end-to-end verification.
- 0143 (alpha_access sqlc drift) — already landed in oss/dff7c2f.
