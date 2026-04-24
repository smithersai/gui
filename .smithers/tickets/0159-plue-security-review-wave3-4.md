# plue security review: wave 3+4 HTTP routes

## Status (audited 2026-04-24)

- Scope: `internal/routes/user_workspaces.go`, `internal/routes/devtools_snapshots.go`, `internal/routes/approvals.go`, `internal/services/approvals.go`, `internal/routes/flags.go`, `/runs/` aliases in `cmd/server/main.go`, and the ticket 0153 rate-limit mounts in `cmd/server/main.go`.
- Findings: 1 Critical / 2 High / 0 Medium / 1 Low.

## Findings

### F1. Missing repo authorization on workflow log/event stream aliases

- Severity: Critical
- Route + file:line: `GET /api/repos/{owner}/{repo}/runs/{id}/logs` and `GET /api/repos/{owner}/{repo}/workflows/runs/{id}/events` - `cmd/server/main.go:797`, `cmd/server/main.go:801`, `internal/routes/workflow_runs.go:70`, `internal/services/workflow_api.go:124`, `internal/middleware/repo_context.go:137`, `cmd/server/main.go:1315`
- Problem statement: the top-level SSE group loads repo context, but it never applies `RequireRepoPermission(middleware.PermissionRead)`. `LoadRepoContext` resolves private repos even when the caller's permission is `none`, and `WorkflowRunLogsStream` only checks that the run belongs to the resolved repo. That means any authenticated session user, or any token with `read:repository`, can stream workflow logs/events for repos they do not belong to if they know `owner/repo` and a run ID. Workflow logs routinely contain sensitive build output and can include secrets.
- Fix recommendation: mount these SSE routes with the same repo-read middleware stack used by the normal repo routes, or append `middleware.RequireRepoPermission(middleware.PermissionRead)` after `LoadRepoContext` in the SSE group. Add a regression test that proves a non-member gets `403` on a private repo while an authorized member still receives the stream.

### F2. Devtools snapshot POST does not bind `session_id` to the route repo or actor

- Severity: High
- Route + file:line: `POST /api/repos/{owner}/{repo}/devtools/snapshots` - `internal/routes/devtools_snapshots.go:115`, `internal/routes/devtools_snapshots.go:133`, `internal/db/devtools_snapshots.sql.go:78`, `db/migrations/000047_ticket_0107_devtools_snapshots.sql:1`
- Problem statement: the handler validates `session_id` only as a UUID, then writes directly with `repo.ID`. It never resolves the referenced `agent_sessions.id`, never verifies that the session belongs to the route repo, and never verifies that the authenticated actor owns that session. Because the table is keyed by `(session_id, kind)` and the UPSERT updates `repository_id`, any repo writer can forge or overwrite latest-per-kind snapshots for any known session ID. If a foreign repo's session UUID leaks, this becomes a cross-repo snapshot hijack that can move or corrupt payloads across repos.
- Fix recommendation: resolve the agent session before upsert and require `agent_sessions.repository_id == repo.ID`. If human-auth writes are not intended, require a session-bound or agent-scoped credential instead of generic `write:repository`; otherwise at minimum require `agent_sessions.user_id == caller.ID` for user-authenticated writes. Back this with a schema-level invariant tying `session_id` and `repository_id` together, such as a composite foreign key or equivalent check.

### F3. Legacy workflow dispatch alias bypasses the dedicated dispatch limiter

- Severity: High
- Route + file:line: `POST /api/repos/{owner}/{repo}/workflows/{name}/dispatch` - `cmd/server/main.go:1176`, `cmd/server/main.go:1179`, `internal/routes/workflow_inspection.go:259`, `internal/routes/workflows.go:456`, `internal/middleware/rate_limit.go:296`
- Problem statement: `POST /workflows/{id}/dispatches` is mounted with `WorkflowDispatchRateLimit(...)`, but the legacy name-based alias is mounted with plain `writeRepo...` while performing the same `DispatchForEvent` action. A repo writer can bypass the intended 10/minute limiter simply by dispatching through `/workflows/{name}/dispatch`, which leaves only the much looser global API limit in place.
- Fix recommendation: apply the same `WorkflowDispatchRateLimit` middleware to `/workflows/{name}/dispatch`, or collapse both dispatch paths behind one shared route stack so they cannot drift. Add a regression test that exhausts the limiter through both endpoints.

### F4. Approval IDs are not UUID-validated before UUID-backed queries

- Severity: Low
- Route + file:line: `GET /api/repos/{owner}/{repo}/approvals/{id}` and `POST /api/repos/{owner}/{repo}/approvals/{id}/decide` - `internal/routes/approvals.go:69`, `internal/routes/approvals.go:109`, `internal/services/approvals.go:103`, `internal/services/approvals.go:150`, `db/migrations/000048_ticket_0110_approvals.sql:2`
- Problem statement: the route only checks that `{id}` is non-empty. It then passes the raw string into UUID-backed queries. Invalid UUID strings therefore hit Postgres, and the service wraps the resulting parse failure into a client-visible `500` message such as `load approval: invalid input syntax for type uuid`. This creates a trivial bad-input 500 path and leaks raw database error details.
- Fix recommendation: validate approval IDs with `uuid.Parse` before the DB call and return `400` or `422` for malformed IDs. Also stop concatenating raw database error text into client-facing `Internal(...)` messages.

## Checklist by category

### 1. Auth

- Finding: F1. The workflow log/event stream aliases require authentication, and only token-authenticated callers get a scope check; neither caller type gets the resolved repo-permission check that actually gates private repo access.
- No findings for `GET /api/user/workspaces`, `GET/POST /api/repos/{owner}/{repo}/devtools/snapshots*`, `GET/POST /api/repos/{owner}/{repo}/approvals*`, `/runs/{id}/cancel|rerun|resume`, or the ticket 0153 terminal/approval/devtools/agent-message mounts. Those routes all require `RequireAuth` where expected.
- No finding for `GET /api/feature-flags`: it is intentionally public and still sits behind the shared `/api` middleware stack.

### 2. Authorization

- Finding: F1. Private repo workflow logs/events can be read without `RequireRepoPermission`.
- Finding: F2. Devtools snapshot writes are not bound to the actual agent session's repo or owner.
- No findings for `GET /api/user/workspaces`: both queries constrain `workspaces.user_id = caller.id`, so the route does not leak other users' workspaces.
- No findings for approval decisions crossing repos: the mutation SQL is scoped with `WHERE id = $1 AND repository_id = $4`.
- No findings for the `/runs/{id}/cancel|rerun|resume` aliases: they inherit the same `writeRepo` middleware stack as the canonical write routes.

### 3. Input validation

- Finding: F4. Approval `{id}` is not UUID-validated before the database call.
- No body-size-cap findings. All reviewed JSON endpoints sit under `/api` `MaxBodySize`, and handlers using `decodeJSONBody` reapply `http.MaxBytesReader`.
- No path-param/query-param validation findings for devtools snapshots or workflow run aliases. Devtools validates `session_id`, `workspace_id`, `kind`, and optional `repository_id`; workflow run handlers parse positive integer run IDs before service calls.
- The legacy `/workflows/{name}/dispatch` handler does not use `decodeJSONBody`, but the global `/api` body limit still applies, so I did not count that as a separate security finding.

### 4. SQL injection

- No findings. All reviewed data access paths use sqlc-generated queries with positional parameters.
- No audited route in this scope builds SQL by string concatenation.
- No audited route in this scope accepts or forwards Electric `where` clauses, so the ticket 0139 parser hardening is not exercised here.

### 5. Rate limit bypass

- Finding: F3. `POST /workflows/{name}/dispatch` bypasses the dedicated workflow-dispatch limiter.
- No bypass found for `POST /approvals/{id}/decide`, `POST /devtools/snapshots`, `POST /agent/sessions/{id}/messages`, or `GET /workspace/sessions/{id}/terminal`. Each dedicated limiter is mounted directly on the route that performs the operation.
- No bypass found for the `/runs/{id}/cancel|rerun|resume` aliases. Those aliases inherit the same middleware stack as their canonical write routes.

### 6. Secrets in logs / responses

- Finding: F1. The workflow log/event stream authz gap can expose sensitive workflow log content to non-members.
- Finding: F2. The devtools snapshot session-binding gap can move or expose snapshot payloads across repos if a foreign session ID is known.
- No direct bearer-token, OAuth token, or secret echo found in `user_workspaces.go`, `flags.go`, or the approvals/devtools route wrappers themselves.

### 7. CORS

- No findings. All reviewed `/api` routes in scope inherit the shared `apiCORS` policy from `cmd/server/main.go:875`.
- No finding on the ticket 0153 terminal WebSocket route: it is outside the `/api` timeout group, but it uses the same `apiAllowedOrigins(cfg)` allowlist via `WorkspaceTerminalHandler.AllowedOrigins` and `checkOrigin`.
