# Plue: global cross-repo workspace listing endpoint

## Status (audited 2026-04-24) — PARTIAL

- Done: `GET /api/user/workspaces` endpoint + listing logic landed in 4308aefb8 per 0151.
- Remaining: `GET /api/user/readable-repos` endpoint; full `last_accessed_at` wiring depends on 0136 (still partial).

## Context

From `.smithers/specs/ios-and-remote-sandboxes.md:256-260`. The spec requires a single recent-first workspace switcher across repos. Today plue only mounts repo-scoped workspace listing at `GET /api/repos/{owner}/{repo}/workspaces` (`/Users/williamcory/plue/cmd/server/main.go:1195-1207`), the handler requires repo context (`/Users/williamcory/plue/internal/routes/workspace.go:132-160`), the service only lists by `(repository_id, user_id)` (`/Users/williamcory/plue/internal/services/workspace.go:311-346`), and the SQL orders by `created_at DESC` (`/Users/williamcory/plue/oss/db/queries/workspace.sql:28-40`).

`WorkspaceResponse` also omits the repo-owner/name and recency metadata the switcher needs (`/Users/williamcory/plue/internal/services/workspace.go:41-57`).

## Problem

The main-spec switcher cannot be implemented against the current surface.

The client would need to know every accessible repo up front, then fan out one request per repo, then merge and sort locally on incomplete metadata. That is the opposite of the promised "single list across repos" UX and it bakes `created_at` ordering drift into the client.

## Goal

Add a current-user endpoint that returns the user's remote workspaces across all repos they can still read, already ordered for the switcher and already carrying the repo metadata the row renderer needs.

Recommended route: `GET /api/user/workspaces`.

Recommended auth: `RequireAuth` + `RequireScope(middleware.ScopeReadRepository)`, matching the repo-scoped workspace read surface and `/api/user/repos` conventions.

## Scope

- **In scope**
- Add a new non-repo-scoped route registration near the existing `/api/user/...` endpoints in `/Users/williamcory/plue/cmd/server/main.go:1212-1214`.
- Add a dedicated handler/service/query path; do not overload the existing repo-scoped `ListWorkspaces`.
- Return a dedicated DTO for switcher rows instead of reusing `WorkspaceResponse`, because the current type lacks repo owner/name and recency fields (`/Users/williamcory/plue/internal/services/workspace.go:41-57`).
- Include, at minimum: `workspace_id`, `repository_id`, `repository_owner`, `repository_name`, `workspace_title`, `state`, `last_accessed_at`, `created_at`, and a stable derived `sort_timestamp`.
- Define `workspace_title` as `NULLIF(workspaces.name, '')` with a repo-name fallback so unnamed primary workspaces still render cleanly.
- Pagination is still required for API hygiene even though the product cap is 100 workspaces. Reuse the existing cursor/limit helpers and cap `limit` at 100 so the switcher can usually load in one request.
- Ordering must be `COALESCE(last_accessed_at, last_activity_at, created_at) DESC, id DESC` so the endpoint behaves sensibly before and during 0136 rollout.
- Authorization behavior must be explicit:
- Show only workspaces where `workspaces.user_id = current_user`.
- Additionally require that the current user still has read access to the underlying repo, using the same read semantics plue already applies in repo middleware and Electric auth (`/Users/williamcory/plue/internal/middleware/repo_context.go:170-231`, `/Users/williamcory/plue/internal/electric/auth.go:47-50`, `/Users/williamcory/plue/internal/electric/auth.go:85-122`).
- Do **not** expose other users' workspaces just because the repo is readable. The current workspace/session model is owner-scoped throughout the service layer.
- Add SQL/sqlc coverage for owner repo, collaborator repo, org/team-access repo, public repo, and repo-access-revoked cases.
- Add route/service tests for pagination headers, fallback ordering when `last_accessed_at` is null, and stable tie-breaking.
- **Additional: readable-repos discovery endpoint.** The switcher needs to subscribe to `workspaces` via the Electric shape from 0116, whose `where` clause requires `repository_id IN (<repo_ids>)`. The client can't know those repo IDs without plue telling it. Today `/api/user/repos` only lists **owned** repos (`plue/internal/services/user.go:259`), not collaborator/org/public-readable repos. Add:
  - `GET /api/user/readable-repos` returning `{id, owner, name}` for every repo the current user can read (owner + collaborator + org-access + public-accessible, matching the same read semantics as `repo_context.go:170-231`).
  - Auth: `RequireAuth` + `RequireScope(ScopeReadRepository)`.
  - Pagination: cursor/limit, cap 200.
  - Tests mirror the scenarios listed above.
  
  This endpoint is also consumed by 0138 (client switcher) to populate the shape filter.
- **Out of scope**
- Client-side switcher UI or local-workspace merging.
- Recording `last_accessed_at`; that belongs to 0136.
- Electric shape definition for workspaces — closed in 0137 (tombstone); the shape is owned by 0116.
- Any widening of workspace visibility beyond owner-scoped rows.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md:256-260` — switcher contract.
- `/Users/williamcory/plue/cmd/server/main.go:1195-1207` — current repo-scoped workspace routes.
- `/Users/williamcory/plue/internal/routes/workspace.go:132-160` — handler requires repo context and repo-local pagination.
- `/Users/williamcory/plue/internal/services/workspace.go:41-57` — current response shape is too thin for the switcher.
- `/Users/williamcory/plue/internal/services/workspace.go:311-346` — service is scoped to one repo and one user.
- `/Users/williamcory/plue/oss/db/queries/workspace.sql:21-40` — current SQL filters by repo and orders by `created_at DESC`.
- `/Users/williamcory/plue/internal/middleware/repo_context.go:170-231` — canonical repo-read authorization rules.
- `/Users/williamcory/plue/internal/electric/auth.go:47-50`, `/Users/williamcory/plue/internal/electric/auth.go:85-122` — same repo-read semantics already enforced in sync surfaces.

## Acceptance criteria

- `GET /api/user/workspaces` exists and is mounted behind auth + read-repository scope.
- `GET /api/user/readable-repos` exists with the same auth, returning `{id, owner, name}` for every repo the user can read.
- The endpoints return only data the authenticated user is authorized to see; repo-access-revoked rows disappear.
- Workspace rows include repo owner/name, workspace title, state, and a recency/sort field.
- Ordering uses `COALESCE(last_accessed_at, last_activity_at, created_at) DESC, id DESC`. If 0136 has not landed yet, the endpoint silently falls back through `last_activity_at` / `created_at` — the contract is "best-available recency," not "last_accessed_at specifically." Once 0136 lands, `last_accessed_at` becomes the primary sort key automatically via COALESCE; no separate 0135 change is needed.
- Pagination headers emitted using existing helper path, with `limit <= 100` for workspaces and `<= 200` for readable-repos.
- Route, service, and SQL tests cover both endpoints' authorization and ordering behavior.

## Dependencies

- **0136 is a soft prerequisite**, not a hard one: 0135 ships with the COALESCE-based ordering and works correctly with only `last_activity_at`/`created_at` available. Full `last_accessed_at`-driven recency lights up automatically once 0136 has migrated the column and is writing updates.
- If the acceptance tests are written assuming `last_accessed_at` is populated, they gate on 0136 having landed.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the workspace query cannot leak another user's workspace through collaborator/public repo access, verifies revoked repo access hides an otherwise-owned workspace, verifies the readable-repos endpoint matches the repo-read semantics plue already enforces elsewhere, and verifies sort-key behavior is documented for both the pre-0136 and post-0136 case.

## Risks / unknowns

- Re-encoding repo-read ACLs in a new SQL query can drift from `resolveRepoPermission` if done carelessly. Prefer one well-documented query over ad hoc post-filtering.
- Existing rows may have empty `workspaces.name`; the DTO needs an explicit title fallback or the switcher will render blank labels.
- Readable-repos listing can be expensive for users in many orgs; if performance bites, add caching keyed by user+modified-timestamp before expanding scope.
