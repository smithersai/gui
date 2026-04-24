# plue Electric shape authorization audit

## Status (audited 2026-04-24)

- Scope: `internal/electric/*.go` and `cmd/electric-proxy/main.go`.
- Findings: 1 Critical / 2 High / 1 Medium / 0 Low.
- Review mode only. No code changes, git staging, commits, or pushes.

## Findings

### F1. Raw SQL `where` clauses can add unauthorized predicates after the checked repo ID

- Severity: Critical
- File:line: `internal/electric/where_normalizer.go:16`, `internal/electric/where_normalizer.go:18`, `internal/electric/auth.go:107`, `internal/electric/auth.go:120`, `internal/electric/auth.go:271`, `internal/electric/auth.go:272`, `internal/electric/auth.go:288`, `internal/electric/proxy.go:171`
- Problem statement: the allowlist only runs for clauses containing `=eq.`. Any SQL-style Electric `where` clause without `=eq.` is returned unchanged by `normalizeShapeWhere`, then `AuthMiddleware` only extracts IDs from the first `repository_id IN (...)` match and checks ACLs for those parsed IDs. It does not prove that the full predicate is only a conjunction over the allowed columns, and it does not require the forwarded predicate to be semantically limited to the checked repo IDs.
- Exploit shape: a user who can read repo 42 can request `where=repository_id IN (42) OR TRUE` or `where=repository_id IN (42) OR repository_id IN (99)`. `parseRepoIDs` authorizes only repo 42, while the reverse proxy forwards the full `where` to Electric. Electric's initial snapshot and subsequent stream are then evaluated against the broadened predicate, so rows outside repo 42 can be returned.
- Impact: cross-repo data exposure for every registered production shape, including initial snapshots. This also means the shape registry's documented conjunction allowlist is not actually enforced for raw SQL-form clauses.
- Fix recommendation: replace the regex extractor with a real allowlist parser for the full accepted `where` grammar, require a top-level `AND` conjunction only, reject `OR`/comments/functions/subqueries/unknown columns, and authorize the exact normalized repo ID set that will be forwarded upstream. Add regression tests for `OR TRUE`, trailing second repo clauses, nested parens, comments, and quoted strings.

### F2. User-private workspace shapes do not bind `user_id` to the bearer

- Severity: High
- File:line: `internal/electric/shapes.go:75`, `internal/electric/shapes.go:77`, `internal/electric/shapes.go:81`, `internal/electric/shapes.go:83`, `internal/electric/shapes.go:87`, `internal/electric/shapes.go:89`, `internal/electric/auth.go:120`, `internal/electric/auth.go:147`, `internal/electric/where_normalizer.go:79`
- Problem statement: `workspace_sessions`, `workspaces`, and `workspace_snapshots` are described as user-private and list `user_id` as an allowed conjunction, but the proxy neither requires a `user_id` filter nor verifies a provided `user_id` equals the authenticated bearer user. The only enforced ACL is repo readability.
- Exploit shape: any user with read access to repo 42 can subscribe to `table=workspaces&where=repository_id=eq.42` and receive all workspace rows for that repo, not just their own. They can also ask for `user_id=eq.<other-user-id>`; the normalizer converts it to `user_id = <id>`, but no authz check compares it to `authed.User.ID`.
- Impact: user-private workspace metadata, session metadata, and snapshot metadata can leak among all users who can read the same repo. This leak happens in the initial Electric snapshot as well as streaming updates.
- Fix recommendation: make per-shape authz explicit. For user-private shapes, require `user_id == authenticated user ID` in the normalized predicate and reject missing or mismatched user filters. If repo-wide sharing is intended for any of these shapes, rename/document them accordingly and remove the "User-private" contract.

### F3. Electric proxy accepts scoped PAT/OAuth tokens without enforcing repository-read scope

- Severity: High
- File:line: `internal/electric/auth.go:33`, `internal/electric/auth.go:212`, `internal/electric/auth.go:233`, `internal/electric/auth.go:241`, `internal/electric/auth.go:257`, `internal/electric/proxy.go:56`
- Problem statement: the proxy authenticates personal access tokens and OAuth2 access tokens, but `authenticatedUser` stores only `User` and `TokenID`. `GetAuthInfoByTokenHash` returns token scopes and `GetOAuth2AccessTokenByHash` returns OAuth scopes, yet both are discarded before repository data is exposed through `/v1/shape`. The route stack has no equivalent of the main API's `read:repository` token-scope gate.
- Exploit shape: an OAuth app or PAT granted only `read:user` can open repo-scoped Electric shapes for every repository the underlying user can read. Repo ACLs still run, but token-scoped delegation is bypassed.
- Impact: third-party or narrowly scoped tokens can be upgraded into long-lived repo data subscriptions, including initial snapshots.
- Fix recommendation: carry parsed scopes through `authenticatedUser` and require `read:repository` (or a dedicated Electric shape read scope) for token-authenticated requests before proxying to Electric. Cover PAT and OAuth2 tokens in tests.

### F4. OAuth2 shape auth does not reject inactive users

- Severity: Medium
- File:line: `internal/electric/auth.go:241`, `internal/electric/auth.go:249`, `internal/electric/auth.go:257`, `internal/electric/auth.go:258`, `internal/electric/auth.go:90`
- Problem statement: the personal-token path uses `GetAuthInfoByTokenHash`, whose SQL filters inactive/prohibited users, but the OAuth2 path loads the user with `GetUserByID` and `AuthMiddleware` only rejects `ProhibitLogin`. It does not reject `IsActive == false`.
- Impact: if a user account can become inactive without also setting `prohibit_login`, an unexpired OAuth2 access token can still open Electric shape streams for that user.
- Fix recommendation: mirror the main auth loader and reject OAuth2 bearer tokens when `!user.IsActive || user.ProhibitLogin`.

## Checklist

### 1. Per-user scoping

- Finding: F2. Repo ACLs are enforced, but user-private workspace shapes are not scoped to the bearer user.
- Repo readability is checked for each parsed repo ID in `AuthMiddleware` through `userCanReadRepo` (`internal/electric/auth.go:120`, `internal/electric/auth.go:314`). That check covers owner, org owner, team permission, direct collaborator, admin, and public repos (`internal/electric/auth.go:323`, `internal/electric/auth.go:333`, `internal/electric/auth.go:346`, `internal/electric/auth.go:359`, `internal/electric/auth.go:371`).

### 2. WHERE clause bypass

- Finding: F1. SQL-form `where` clauses bypass the allowlist and can smuggle broadening predicates after an authorized `repository_id IN (...)`.
- The `=eq.` path is narrower: anchored regexes reject unsupported `=eq.` conjunctions (`internal/electric/where_normalizer.go:11`, `internal/electric/where_normalizer.go:45`). The bypass is that SQL-form clauses skip that path entirely.

### 3. Initial snapshot leak

- Finding: F1 and F2. The proxy performs a one-time request authorization, then forwards the client `where` to upstream Electric. There is no separate ACL filter around Electric's initial snapshot or streaming response body in `newElectricReverseProxy` (`internal/electric/proxy.go:83`, `internal/electric/proxy.go:85`, `internal/electric/proxy.go:117`).

### 4. Shape keys

- Finding: F1. The registry rejects unregistered `table` values (`internal/electric/proxy.go:128`, `internal/electric/proxy.go:136`), but the documented `AllowedWhereConjunctions` are only applied to recognized `=eq.` fragments. Raw SQL-form conjunctions are not enforced, and required shape-specific keys such as workspace `user_id` are not enforced.

### 5. Rate limits

- No finding for per-IP scoping in the Electric proxy. `AuthMiddleware` sets the Electric user ID in context before the limiter runs (`internal/electric/auth.go:147`, `internal/electric/proxy.go:56`), and `ShapeRateLimit` converts that to the shared middleware user context before `ElectricShapeOpenRateLimit` computes its key (`internal/electric/rate_limit.go:53`, `internal/electric/rate_limit.go:55`). The active subscription cap also keys by `userID` (`internal/electric/rate_limit.go:29`, `internal/electric/rate_limit.go:30`).
- Residual operational note, not counted as a finding here: the active counter is in-process, so it is per-user per proxy instance rather than cluster-wide. That is already documented in the shared `ActiveCounter` implementation outside this audit scope.

### 6. Proxy auth

- The proxy does validate a bearer before passing registered shape requests upstream: `/v1/shape` is mounted through `registryMW(whereMW(authMW(shapeHandler)))` (`internal/electric/proxy.go:56`), `AuthMiddleware` rejects missing/invalid bearer tokens (`internal/electric/auth.go:73`, `internal/electric/auth.go:79`), and the reverse proxy strips `Authorization` before forwarding (`internal/electric/proxy.go:91`, `internal/electric/proxy.go:93`).
- Findings: F3 and F4 cover scope and inactive-user gaps in that bearer validation.
