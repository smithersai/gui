# Plue/oss: fix alpha_access.sql drift blocking sqlc regen

## Context

Discovered during tickets 0110, 0107, 0134 (all plue-side). Running
`make sqlc` (or `sqlc generate -f db/sqlc.yaml`) fails because
`oss/db/queries/alpha_access.sql` references columns
(`github_username`, `github_avatar_url`) that don't exist in
`oss/db/schema.sql`. The above tickets worked around by hand-writing
`internal/db/*.sql.go` files. That pattern is unsustainable.

## Goal

Reconcile `oss/db/schema.sql` with `oss/db/queries/alpha_access.sql` so
`sqlc generate` runs clean. All future plue tickets regain the ability
to regenerate sqlc code normally.

## Scope

- Add columns to `alpha_waitlist_entries` (and wherever else is
  drifted) via a new oss migration.
- Regenerate atlas.sum if atlas is used on oss.
- Run `sqlc generate` in plue — must exit 0.
- Diff the hand-written shims (from 0110/0107/0134) against the freshly
  generated files — fix any divergence.
- Commit to the oss repo (it is a separate git repository).

## Acceptance criteria

- `cd /Users/williamcory/plue && make sqlc` runs clean.
- Hand-written `internal/db/approvals.sql.go`,
  `internal/db/devtools_snapshots.sql.go`,
  `internal/db/audit_log.sql.go` match sqlc-generated output
  (byte-for-byte or with a one-time PR to match).
- plue main passes `go build ./...` after regen.
