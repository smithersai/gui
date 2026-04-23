# Plue: last-accessed tracking for workspaces

## Context

From `.smithers/specs/ios-and-remote-sandboxes.md:256-260`. The switcher is recent-first by last-accessed, not by creation time. Plue already stores `last_activity_at` on both `workspaces` and `workspace_sessions` (`/Users/williamcory/plue/oss/db/schema.sql:1301-1317`, `/Users/williamcory/plue/oss/db/schema.sql:1343-1358`) and updates it from provisioning, session creation, and SSH attach paths (`/Users/williamcory/plue/internal/services/workspace_provisioning.go:491-507`, `/Users/williamcory/plue/internal/services/workspace_provisioning.go:530-547`, `/Users/williamcory/plue/internal/services/workspace_provisioning.go:580-597`, `/Users/williamcory/plue/internal/services/workspace_exec.go:99-108`, `/Users/williamcory/plue/internal/services/workspace_ssh.go:74-88`).

That field is currently load-bearing for idle detection (`/Users/williamcory/plue/oss/db/queries/workspace.sql:196-199`, `/Users/williamcory/plue/oss/db/queries/workspace.sql:221-242`) and therefore should not become the UI's only recency source by accident.

## Problem

`last_activity_at` is close, but it is the wrong contract for the switcher.

It exists to drive suspend/idle policy, it is touched from backend lifecycle flows, and it does not clearly mean "the user intentionally opened this workspace most recently." Reusing it for switcher ordering would couple a user-facing list order to VM liveness heuristics.

## Goal

Add an explicit `last_accessed_at` signal for workspace recency and update it server-side on real workspace-entry flows.

The implementation should choose a new column on `workspaces`, not a separate `workspace_access` table.

## Decision

Use `workspaces.last_accessed_at TIMESTAMPTZ`.

Do **not** introduce a separate `workspace_access` table in this pass.

Why:

- The current workspace model is already owner-scoped. `workspaces.user_id` is required in schema (`/Users/williamcory/plue/oss/db/schema.sql:1303-1305`) and service reads are all `GetWorkspaceForUserRepo`/`GetWorkspaceSessionForUserRepo` (`/Users/williamcory/plue/internal/services/workspace.go:252-294`).
- The schema pattern for mutable runtime metadata is "store the current value on the resource row" (`status`, `vm_id`, `last_activity_at`, `suspended_at`) rather than in append-only side tables.
- The switcher needs one current timestamp per workspace, not a history log and not multi-user shared-access fan-out.
- A separate table only pays off if plue later supports shared workspaces or audited access history. That is not today's model.

## Scope

- **In scope**
- Add `last_accessed_at` to `workspaces` via schema migration, backfill from `last_activity_at`, then set an index suitable for `user_id + recency` scans.
- Extend `oss/db/queries/workspace.sql` with `TouchWorkspaceLastAccessed` and regenerate sqlc output in `internal/db/`.
- Update the workspace listing query from 0135 to sort on `COALESCE(last_accessed_at, last_activity_at, created_at)` during rollout.
- Touch `last_accessed_at` server-side on workspace-entry flows:
- `POST /api/repos/{owner}/{repo}/workspace/sessions` (`/Users/williamcory/plue/internal/routes/workspace.go:486-520`, `/Users/williamcory/plue/cmd/server/main.go:833-839`).
- `GET /api/repos/{owner}/{repo}/workspace/sessions/{id}/ssh` (`/Users/williamcory/plue/internal/routes/workspace.go:583-610`, `/Users/williamcory/plue/cmd/server/main.go:1204-1207`).
- `GET /api/repos/{owner}/{repo}/workspaces/{id}/ssh` (`/Users/williamcory/plue/internal/routes/workspace.go:163-190`, `/Users/williamcory/plue/cmd/server/main.go:1195-1200`).
- Factor the touch into a helper so future "open workspace" routes can reuse it without re-arguing semantics.
- Do **not** update `last_accessed_at` from passive reads such as list endpoints, shape polling, SSE reconnects, or generic `GET /workspaces/{id}` prefetches.
- Do **not** make this client-driven. No `PATCH last_accessed_at`; the server should derive access from real attach/open paths so older clients and malicious clients cannot skew ordering.
- Add tests for migration backfill, attach-path updates, and "list endpoint does not mutate recency."
- **Out of scope**
- Full access history or audit reporting.
- Replacing idle detection to use `last_accessed_at`; `last_activity_at` remains the idle-policy input.
- Client UI changes.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md:256-260` — last-accessed switcher requirement.
- `/Users/williamcory/plue/oss/db/schema.sql:1301-1317` — current workspace row shape.
- `/Users/williamcory/plue/oss/db/schema.sql:1321-1326` — one active primary workspace per `(repository_id, user_id)` reinforces owner-scoped semantics.
- `/Users/williamcory/plue/internal/services/workspace.go:252-294` — service layer always loads workspace/session through `(repo_id, user_id)`.
- `/Users/williamcory/plue/oss/db/queries/workspace.sql:196-199`, `/Users/williamcory/plue/oss/db/queries/workspace.sql:221-242` — current `last_activity_at` usage is for activity/idle tracking.
- `/Users/williamcory/plue/internal/services/workspace_exec.go:99-108` — session creation already has a clear server-observed "workspace entered" point.
- `/Users/williamcory/plue/internal/services/workspace_ssh.go:74-88` — SSH attach path already centralizes workspace/session touches.

## Acceptance criteria

- Schema migration adds `workspaces.last_accessed_at` and backfills existing rows from `last_activity_at`.
- sqlc exposes a dedicated `TouchWorkspaceLastAccessed` query.
- `CreateSession`, `GetSSHConnectionInfo`, and `GetWorkspaceSSHConnectionInfo` update `last_accessed_at`.
- Passive list/detail reads do not update `last_accessed_at`.
- 0135 can order by `last_accessed_at` without needing client-side patch calls.
- Tests cover backfill, update paths, and non-update paths.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies that attaching to an existing session moves the workspace to the top without changing idle-policy semantics, verifies list calls do not rewrite timestamps, and verifies a migrated database preserves old relative ordering via the backfill.

## Risks / unknowns

- Some future client flow may "open" a workspace without going through session creation or SSH attach. That flow must call the shared touch helper or recency will look stale.
- Backfilling to `last_activity_at` is an approximation for old rows, not perfect historical truth. That is acceptable as a one-time migration tradeoff.
- If anyone later tries to reuse `last_accessed_at` for idle suspend logic, they will collapse two intentionally different semantics back into one field.
