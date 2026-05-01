# Plue: workspace_snapshots production Electric shape

## Context

Discovered during ticket 0124 (C-DATA). The SmithersStore has a stub
`listWorkspaceSnapshots()` that returns `[]` in remote mode with a
`TODO(0126)` — except 0126 landed without addressing it. Workspace
snapshots (used for fork-from-snapshot workflows) aren't in the initial
shape set from 0114–0118, so the client can't enumerate them remotely.

## Goal

Add a production Electric shape for workspace snapshots so the client
can list + consume them without polling.

## Scope

- Verify the underlying table name (`workspace_snapshots`? some other?)
  and its FK relationship to `workspaces`.
- Add `ShapeWorkspaceSnapshots` to
  `plue/internal/electric/shapes.go`:
  - Where template: `repository_id IN ({repo_ids}) AND user_id = {authed_user_id}`
    (user-private, matching workspaces).
  - Register in `UserPrivateShapes()` helper.
  - Feature-gated on `electric_client_enabled`.
- Tests: shape registry + auth round-trip.
- Add `repository_id` + `user_id` denorm to the snapshot row if it
  doesn't already carry them (similar pattern to 0115/0118).
- Commit in both plue main + oss (coordinate with 0143 drift fix).

## Acceptance criteria

- Shape registered.
- Auth round-trip tests pass.
- `SmithersStore.listWorkspaceSnapshots()` in remote mode returns the
  seeded snapshot set in the iOS e2e harness (ticket 0141).

## Out of scope

- UI for snapshot management.
- Snapshot creation/deletion HTTP routes (they exist today).
