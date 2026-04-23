# Plue: Electric WHERE-clause parser hardening

## Context

Discovered during ticket 0096 (P-POC-ELECTRIC). The where-clause parser in
`plue/internal/electric/auth.go` extracts `repository_id IN (...)` predicates
to enforce per-repo ACLs on Electric shape subscriptions. Two bugs locked in
by `TestParseRepoIDs_ParserGaps` as regression fixtures:

1. **Case sensitivity:** `REPOSITORY_ID IN ('42')` (uppercase) is rejected
   even though Postgres would accept it. Minor UX papercut.
2. **Compound `OR` bypass (real security issue):** clauses like
   `repository_id IN ('42') OR deleted_at IS NULL` are accepted by the
   parser, which finds the IDs and scopes to them. But
   `repository_id IN ('42') OR repository_id IN ('99')` — the regex only
   captures the **first** `IN (...)` set, so '99' never gets a repo-access
   check. A crafted compound `where` can slip an unauthorized repo past
   auth.

## Problem

Security regression waiting to happen. Current mitigation is "subsequent
repo-access checks run per extracted ID," but extraction is incomplete on
compound clauses.

## Goal

Replace the regex-based parser with either (a) a real SQL-subset walker
(pg_query_go), or (b) a strict allowlist that rejects anything that isn't
exactly `repository_id IN (...)` plus a fixed set of known-safe
conjunctions (e.g. `deleted_at IS NULL`, `session_id IN (...)`, `user_id = ...`).

Option (b) is the pragmatic v1 choice — all current production shapes only
use those three conjunctions. Option (a) is architecturally nicer but adds
a cgo dep.

## Scope

- **In scope**
  - Implement stricter validator in `plue/internal/electric/auth.go` —
    either the allowlist approach or pg_query_go walker.
  - All existing production shape `WhereTemplate` values must continue to
    pass. Verify against every shape in `internal/electric/shapes.go`.
  - `TestParseRepoIDs_ParserGaps` must FLIP from documenting-the-bug to
    asserting the bug is GONE (case-insensitive accepted; compound OR
    rejected).
  - Add negative tests for known attack patterns: OR-chained
    repository_id, UNION SELECT injection, subselects, function calls.
- **Out of scope**
  - New allowed conjunctions beyond what current shapes use.
  - Dropping the regex fallback for non-shape Electric endpoints.

## References

- `plue/internal/electric/auth.go:44-136, 250-282` — current parser.
- `plue/internal/electric/auth_test.go` (added in ticket 0096) —
  `TestParseRepoIDs_ParserGaps` fixture.
- `plue/internal/electric/shapes.go` — inventory of production
  `WhereTemplate` patterns.

## Acceptance criteria

- All existing tests pass.
- `TestParseRepoIDs_ParserGaps` negations succeed (bug patterns rejected).
- Compound-OR-bypass negative test passes with distinct error class.
- Production shape auth round-trips (0114/0115/0116/0117/0118/0110/0111/0107) all stay green.
- `go vet` clean.

## Independent validation

See 0099. Until 0099 lands: reviewer runs the full
`internal/electric/` test suite + grep for any new regex in auth.go
(should not exist if using allowlist/walker approach).

## Risks / unknowns

- pg_query_go is cgo — complicates cross-compile. Prefer allowlist.
- Allowlist approach may reject future shape features (joins, CTEs);
  revisit when a new shape needs them.
