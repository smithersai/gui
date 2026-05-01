# Plue: clean up divergent jj change on main bookmark

## Context

During ticket 0106 (P-OAUTH-SRV) orchestration, a migration-rename +
atlas.sum regen created a jj divergent change: the original commit
with the pre-rename migration name (`000035_seed_first_party_oauth2_client.sql`)
and the amended commit with the renamed migration
(`000037_seed_first_party_oauth2_client.sql`) both carry the same
change_id `rvpmrllp`, visible as two commits when running
`jj log -r 'change_id(rvpmrllp)'`.

Plue's `main` bookmark points at the amended commit (correct). The
original coexists in the op log and would be confusing to future
users.

## Goal

Abandon the duplicate divergent change so `jj log` shows one canonical
0106 commit.

## Scope

- `jj abandon <sha-of-divergent-non-main>` once confirmed.
- Verify `jj log -r 'change_id(rvpmrllp)'` shows one revision.
- Verify main still points at the right commit and plue still builds.

## Acceptance criteria

- `jj log` clean.
- No disruption to plue main.
- Cosmetic only.
