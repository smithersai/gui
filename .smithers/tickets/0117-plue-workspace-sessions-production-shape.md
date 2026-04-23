# Plue: `workspace_sessions` production Electric shape

## Context

The spec distinguishes workspace execution sessions from chat sessions and expects their state to be synced into local SQLite for reconnect UI and workspace-tab state (`.smithers/specs/ios-and-remote-sandboxes.md:42`, `171-194`, `266-271`). Plue already has create/list/get/destroy session surfaces registered at `cmd/server/main.go:839`, `1204-1205`, plus SSE endpoints at `cmd/server/main.go:979-980`, backed by exact table `workspace_sessions` in `db/migrations/000015_repair_legacy_workspace_schema.sql:87-130` and queries in `internal/db/workspace.sql.go:156-195`, `358-400`, `638-689`, and `918-947`.

## Problem

- There is no production shape ticket for workspace execution sessions.
- Like `workspaces`, current HTTP/query behavior is user-private: list/get/destroy all filter on both `repository_id` and `user_id` (`internal/db/workspace.sql.go:384-400`, `638-689`; `internal/services/workspace_exec.go:113-197`). Electric auth does not enforce that today.
- The raw table is **not sync-safe as written**. `GetSSHConnectionInfo` persists a full `WorkspaceSSHConnectionInfo` blob into `ssh_connection_info`, and that blob includes a minted access token and an executable SSH command (`internal/services/workspace_ssh.go:64-79`, `93-120`). A raw shape on the current table would leak fresh SSH credentials into every subscribed client cache.
- Session “delete” is currently a status transition to `stopped`, not row removal (`internal/services/workspace_exec.go:165-197`). The ticket must treat that as intentional terminal state, not pretend a delete route exists.

## Goal

Ship a production Electric shape for exact table `workspace_sessions`, but only after the row is made safe to replicate into client SQLite.

## Scope

- **In scope**
  - Shape exact table `workspace_sessions`.
  - Make the row sync-safe before enabling the shape. Acceptable approaches:
    - Stop persisting secret-bearing SSH material in `ssh_connection_info`.
    - Split secret connection data into a non-shaped side table.
    - Persist only a redacted/public subset in `workspace_sessions` and keep token issuance on the existing on-demand route.
  - Shape where-clause template: `repository_id IN (<repo_ids>) AND user_id = <authed_user_id>`.
  - Active-workspace detail views may add `AND workspace_id IN (<open_workspace_ids>)`, but the auth-critical part is the repo + authed-user predicate.
  - Extend Electric auth so user-private session shapes cannot be requested with an arbitrary `user_id`.
  - Client consumers:
    - Workspace tab list / current workspace execution-session list.
    - Session status chips (`pending`, `starting`, `running`, `stopped`, `failed`).
    - Reconnect UI state distinct from PTY byte streaming.
  - Delete/tombstone semantics:
    - Reuse the existing row-retained model.
    - `stopped` and `failed` are terminal states the client can observe and age out locally.
    - No new hard-delete route is required for v1.
  - Tests:
    - Service tests proving persisted session state no longer contains access tokens or ready-to-run SSH commands.
    - Shape auth tests proving same-repo different-user access is rejected.
    - Multi-client same-user fan-out: create session, transition to `running`, then `stopped`.
    - Security regression test: shaped row payload never includes credential material.
- **Out of scope**
  - PTY WebSocket bytes and resize control traffic.
  - Credential issuance itself; that continues to use the existing HTTP route on demand.
  - Workspace metadata; that is 0116.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md:42`, `171-194`, `241-242`, `266-271`
- `plue/internal/electric/auth.go:47-50`, `85-100`, `250-282`
- `plue/cmd/server/main.go:839`, `979-980`, `1204-1205`
- `plue/internal/routes/workspace.go:641-723`
- `plue/internal/routes/workspace_terminal.go:117-155`
- `plue/internal/services/workspace_exec.go:13-210`
- `plue/internal/services/workspace_ssh.go:35-120`
- `plue/internal/db/workspace.sql.go:156-195`, `358-400`, `638-689`, `885-947`
- `plue/db/migrations/000015_repair_legacy_workspace_schema.sql:87-130`

## Acceptance criteria

- `workspace_sessions` has a documented production shape definition with exact table name and safe-column story.
- The production row replicated by Electric does not contain minted SSH credentials.
- Electric auth rejects `workspace_sessions` shape requests where the `user_id` predicate does not match the authenticated user.
- A plue integration test subscribes two same-user clients and verifies create, `running`, and `stopped` transitions fan out through the shape.
- A regression test proves the existing `GetSSHConnectionInfo` route still works after the secret-bearing data is removed or split out of the shaped row.

## Independent validation

See ticket 0099. Until 0099 lands, reviewer verifies:

- The test inspects actual shape payloads or replicated rows, not just Go structs before serialization.
- The security regression covers both `access_token` and `command`, not only one field.
- The session terminal WebSocket still obtains SSH info via the existing route after the shape-safe refactor.

## Risks

- This ticket touches a security-sensitive path; a naive “just shape the table” implementation would leak live credentials.
- Auth work overlaps with 0116 because both tables are user-private.
- If product later wants session sharing across users, the user-private shape contract changes and must be revisited explicitly.
