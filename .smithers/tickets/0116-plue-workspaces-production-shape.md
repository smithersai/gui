# Plue: `workspaces` production Electric shape

## Context

The spec’s remote mode depends on synced workspace metadata for the workspace switcher, first-run create flow, and pinned “current workspace summary” state (`.smithers/specs/ios-and-remote-sandboxes.md:48-49`, `186-187`, `253-260`, `266-269`). Plue already has the repo-scoped workspace routes registered at `cmd/server/main.go:833-838` and `1195-1203`, backed by exact table `workspaces` in `db/migrations/000015_repair_legacy_workspace_schema.sql:24-68` and list/detail queries in `internal/db/workspace.sql.go:100-153` and `742-795`.

## Problem

- There is no production shape ticket for workspace metadata, so the client still has no synced source for the remote workspace list.
- Current HTTP/query behavior is **user-private**, not merely repo-private. `ListWorkspacesByRepo` and `GetWorkspaceForUserRepo` filter by both `repository_id` and `user_id` (`internal/db/workspace.sql.go:284-312`, `742-795`; `internal/services/workspace.go:252-347`).
- Electric auth does **not** enforce that user-private filter. Today it only requires `repository_id IN (...)` and checks repo read access (`internal/electric/auth.go:47-50`, `85-100`, `250-282`). A client could ask for another user’s workspace rows within the same repo.
- Delete semantics are not settled. `DeleteWorkspace` only stops the VM and leaves the row at `status='stopped'` (`internal/services/workspace_lifecycle.go:53-108`), while the main spec and ticket 0105 require a true “delete one to continue” story.

## Goal

Ship a production Electric shape for exact table `workspaces` that preserves current user-private workspace visibility and gives the client a reliable synced workspace list.

## Scope

- **In scope**
  - Shape exact table `workspaces`.
  - Shape where-clause template: `repository_id IN (<repo_ids>) AND user_id = <authed_user_id>`.
  - No repository denormalization is needed; `workspaces` already stores `repository_id`.
  - Extend Electric auth so user-private tables cannot be queried with arbitrary client-supplied `user_id`. The production shape must not ship until `internal/electric/auth.go` can verify `user_id = authed.User.ID` for `workspaces`.
  - Client consumers:
    - Remote workspace switcher / workspace list.
    - First-run empty-state to created-workspace transition.
    - Pinned current-workspace summary (`.smithers/specs/ios-and-remote-sandboxes.md:186-187`).
  - Subscription policy: pin the current user’s workspace list for the active signed-in session. The spec caps active workspaces at 100 (`.smithers/specs/ios-and-remote-sandboxes.md:246-249`), so this is a low-cardinality pinned shape.
  - Delete/tombstone semantics must align with 0105:
    - Do not treat `status='stopped'` as “deleted.”
    - Preferred production model: add a terminal deleted state or `deleted_at` tombstone on the row and exclude it from the shape’s default list predicate.
    - If 0105 insists on hard delete, this ticket must explicitly prove the client still gets reliable removal and quota semantics before enabling the shape.
  - Tests:
    - Service tests for create, suspend, resume, delete/tombstone transitions.
    - Shape auth tests proving same-repo different-user access is rejected.
    - Multi-client same-user fan-out: create on one device, see list update on another; suspend/resume/delete propagate too.
- **Out of scope**
  - Local workspaces on desktop.
  - Workspace session / terminal state; that is 0117.
  - Snapshot-template sync; that remains a separate decision.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md:48-49`, `186-187`, `246-260`, `266-269`
- `.smithers/tickets/0105-plue-sandbox-quota-enforcement.md`
- `plue/internal/electric/auth.go:47-50`, `85-100`, `250-282`
- `plue/cmd/server/main.go:833-838`, `1195-1203`
- `plue/internal/routes/workspace.go:67-319`
- `plue/internal/services/workspace.go:252-347`
- `plue/internal/services/workspace_lifecycle.go:15-108`
- `plue/internal/db/workspace.sql.go:100-153`, `258-312`, `742-795`, `950-980`
- `plue/db/migrations/000015_repair_legacy_workspace_schema.sql:24-68`

## Acceptance criteria

- `workspaces` has a documented production shape definition with exact table name and `where` template.
- Electric auth rejects `workspaces` shape requests where the `user_id` predicate does not match the authenticated user.
- Delete semantics are explicit and tested; the shape does not ship against the current ambiguous “stopped but not deleted” behavior.
- A plue integration test subscribes two same-user clients and verifies create, suspend, resume, and delete/tombstone all fan out through the shape.
- A companion auth test proves a collaborator with repo read access still cannot shape-subscribe another user’s workspaces.

## Independent validation

See ticket 0099. Until 0099 lands, reviewer verifies:

- The shape and the HTTP list route agree on privacy: user-private in both places.
- Delete really removes the row from the rendered workspace list on another client without a manual refresh.
- The test that rejects other-user access goes through the Electric proxy, not just a service helper.

## Risks

- This ticket depends on 0105 settling workspace delete semantics cleanly enough for sync.
- Electric auth is currently repo-scoped only; adding table-aware user checks will touch shared proxy code.
- If the product later wants shared multi-user workspaces, the privacy model for this shape changes again and must be deliberate.
