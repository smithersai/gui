# plue rate-limit + quota correctness audit

## Status (audited 2026-04-24)

- Scope: `internal/middleware/rate_limit.go`, `internal/middleware/active_limits.go`, `internal/electric/rate_limit.go`, `internal/electric/proxy.go`, `cmd/electric-proxy/main.go`, `cmd/server/main.go`, and workspace quota paths in `internal/services/workspace.go` / `internal/services/workspace_provisioning.go`.
- Findings: 0 Critical / 3 High / 1 Medium / 1 Low.
- Review mode only. No implementation changes, git staging, commits, or pushes.

## Findings

### F1. Concurrent first requests can bypass the token bucket

- Severity: High
- File:line: `oss/db/queries/rate_limits.sql:10`, `oss/db/queries/rate_limits.sql:23`, `oss/db/queries/rate_limits.sql:29`, `oss/db/queries/rate_limits.sql:40`, `oss/db/queries/rate_limits.sql:83`, `internal/db/rate_limits.sql.go:22`, `internal/db/rate_limits.sql.go:35`, `internal/db/rate_limits.sql.go:41`, `internal/db/rate_limits.sql.go:52`, `internal/middleware/rate_limit.go:94`, `internal/middleware/rate_limit.go:101`, `internal/middleware/rate_limit.go:102`
- Problem statement: the limiter is atomic for an existing row because it uses `FOR UPDATE`, but bucket creation is not safe under concurrent first requests for the same `(scope, principal_key)`. The query does `INSERT ... ON CONFLICT DO NOTHING`, then reads the existing row only when the current statement's `inserted` CTE is empty. In Postgres, a concurrent loser can observe the unique conflict, do nothing, and still not see the winner's just-committed row in the same statement snapshot. The final `SELECT` can return no rows.
- Impact: `ConsumeSearchRateLimitToken` returns `pgx.ErrNoRows`, and `rateLimiter.middleware` treats any store error as fail-open. A parallel flood against a new user/IP bucket can let substantially more than `N` requests through before the bucket exists, violating the "never more than N in the window" requirement.
- Fix recommendation: make the SQL a single atomic upsert/update path that always returns one row. Prefer `INSERT ... ON CONFLICT (scope, principal_key) DO UPDATE` and compute/refill/decrement in the conflict update while holding the row lock, or retry the statement when `pgx.ErrNoRows` is returned. Do not fail open for `pgx.ErrNoRows`; it is a limiter consistency error, not a backend outage. Add a DB concurrency test that starts many goroutines on a never-before-seen key and asserts at most `capacity` are allowed.

### F2. Store errors disable all route-level rate limits

- Severity: High
- File:line: `internal/middleware/rate_limit.go:86`, `internal/middleware/rate_limit.go:101`, `internal/middleware/rate_limit.go:102`, `internal/middleware/rate_limit.go:103`, `internal/middleware/rate_limit_test.go:304`, `internal/middleware/rate_limit_test.go:318`, `internal/middleware/rate_limit_test.go:627`, `internal/middleware/rate_limit_test.go:643`
- Problem statement: the middleware fails open whenever the store is nil or `ConsumeSearchRateLimitToken` returns any error. That includes transient DB errors, pool exhaustion, statement timeouts, and the `ErrNoRows` race in F1.
- Impact: the routes Agent F mounted are protected only while the database-backed rate-limit store is healthy. During DB degradation, high-cost endpoints such as workflow dispatch, agent message posts, terminal opens, auth endpoints, and Electric shape opens all proceed with headers claiming full remaining quota.
- Fix recommendation: split expected limiter misses from true storage failures. Return 429 or 503 for store failures on abuse-sensitive routes, or make fail-open an explicit per-route policy with alerts and metrics. At minimum, fail closed for `pgx.ErrNoRows` and instrument fail-open events so production can detect that limits are not being enforced.

### F3. The 100-workspace cap is a non-atomic count-then-insert

- Severity: High
- File:line: `internal/services/workspace.go:257`, `internal/services/workspace.go:262`, `internal/services/workspace.go:266`, `internal/services/workspace_provisioning.go:148`, `internal/services/workspace_provisioning.go:157`, `internal/services/workspace_provisioning.go:187`, `internal/services/workspace_provisioning.go:200`, `internal/services/workspace_provisioning.go:359`, `internal/services/workspace_provisioning.go:364`, `oss/db/queries/workspace.sql:54`, `oss/db/queries/workspace.sql:57`, `oss/db/queries/workspace.sql:60`
- Problem statement: `enforceWorkspaceQuota` correctly counts `workspaces` with `deleted_at IS NULL`, but that count is separate from the later `CreateWorkspace` insert. Two concurrent creates/forks/snapshot-based creates can both observe `N=99`, both pass, and both insert.
- Impact: a user can exceed `MaxActiveWorkspacesPerUser` under parallel creation. The existing `uq_workspaces_active` index does not close this hole because it only constrains non-fork reusable workspaces by `(repository_id, user_id)`; fork and snapshot-created workspaces are not constrained by a per-user count.
- Fix recommendation: enforce the quota inside the database transaction that creates the workspace. Options: lock the user row or use a per-user advisory transaction lock before count+insert; maintain a quota counter table updated transactionally; or replace `CreateWorkspace` with an insert CTE that locks the user, counts `deleted_at IS NULL`, inserts only when count `< 100`, and returns a distinguishable quota miss. Add a parallel integration test that starts at 99 and races two creates.

### F4. Electric active subscription cap is per process, not per user globally

- Severity: Medium
- File:line: `internal/middleware/active_limits.go:5`, `internal/middleware/active_limits.go:8`, `internal/middleware/active_limits.go:11`, `internal/middleware/active_limits.go:12`, `cmd/electric-proxy/main.go:84`, `cmd/electric-proxy/main.go:86`, `cmd/electric-proxy/main.go:88`, `internal/electric/rate_limit.go:29`, `internal/electric/rate_limit.go:30`, `internal/electric/rate_limit.go:45`
- Problem statement: `ActiveCounter` is an in-memory map protected by a mutex. That makes `Acquire`/`Release` race-safe within one process, but the cap is not shared across Electric proxy replicas. `cmd/electric-proxy/main.go` creates a fresh counter per process.
- Impact: if the Electric proxy runs with multiple replicas, one user can hold up to `ticket0153ShapeActiveMax` active shape streams per replica. The cap is connection/request-lifetime based, not a cluster-wide active subscription cap.
- Fix recommendation: move active shape accounting to a shared store with leases/TTL, for example Redis `INCR` with expiry or Postgres rows keyed by user and connection ID. Release on disconnect and let TTL clean up abandoned leases. If per-instance limiting is intentional, rename/configure it as such and set deployment replica expectations.

### F5. Active-cap 429 retry hint is misleading

- Severity: Low
- File:line: `internal/electric/rate_limit.go:30`, `internal/electric/rate_limit.go:32`, `internal/electric/rate_limit.go:35`, `internal/electric/rate_limit.go:36`
- Problem statement: when the active shape cap is exceeded, the response always sets `Retry-After: 1`. This value is syntactically a delay in seconds, but the cap clears only when an existing long-lived SSE request disconnects. There is no reason to believe one second is enough.
- Impact: well-behaved clients can retry once per second while the user remains at the active stream cap, creating avoidable auth, DB, and log traffic. It also communicates a precision the server does not have.
- Fix recommendation: omit `Retry-After` for active-connection caps, return a larger conservative backoff, or include a documented client backoff policy. Keep precise `Retry-After` for token-bucket denials where the next-token time is calculable.

## Checklist

### 1. Race conditions

- Finding: F1. Existing bucket updates serialize through `FOR UPDATE`, but concurrent first requests can produce no returned row and then fail open.
- The active subscription counter itself is race-safe inside one process because `Acquire`, `Release`, and `Count` hold `ActiveCounter.mu` around the `counts` map (`internal/middleware/active_limits.go:27`, `internal/middleware/active_limits.go:42`, `internal/middleware/active_limits.go:58`).

### 2. Per-user scoping

- No finding for authenticated API routes. `searchRateLimitKey` uses `UserFromContext` first and falls back to IP only when no authenticated user is present (`internal/middleware/rate_limit.go:167`, `internal/middleware/rate_limit.go:168`, `internal/middleware/rate_limit.go:172`).
- `cmd/server/main.go` runs `AuthLoader` before the global API limiter (`cmd/server/main.go:881`, `cmd/server/main.go:882`), and the mounted sensitive route limiters are inside authenticated route stacks.
- No finding for Electric open-rate scoping. `AuthMiddleware` stores the Electric bearer user ID before the limiter runs (`internal/electric/auth.go:147`, `internal/electric/proxy.go:56`), and `ShapeRateLimit` converts it into the shared middleware user context before calling `ElectricShapeOpenRateLimit` (`internal/electric/rate_limit.go:53`, `internal/electric/rate_limit.go:55`).

### 3. Window boundaries

- No fixed-window boundary found. The route limiter is a token bucket with continuous refill: `refillPerSecond = limit / window.Seconds()` (`internal/middleware/rate_limit.go:74`), and the SQL adds elapsed-time refill capped at capacity (`oss/db/queries/rate_limits.sql:48`, `oss/db/queries/rate_limits.sql:50`). This avoids fixed-window thundering herds, subject to F1.

### 4. 429 response contract

- Token-bucket denials set `Retry-After` as integer seconds until the next token using `math.Ceil` (`internal/middleware/rate_limit.go:122`, `internal/middleware/rate_limit.go:123`, `internal/middleware/rate_limit.go:160`, `internal/middleware/rate_limit.go:164`).
- Finding: F5 for the active subscription cap's hard-coded one-second retry hint.
- Workspace quota uses a 429 `quota_exceeded` API error (`pkg/errors/errors.go:69`, `pkg/errors/errors.go:70`). It does not set `Retry-After`, which is reasonable because the user must delete workspaces rather than wait for a timed window.

### 5. Memory growth

- No finding for DB-backed buckets. `maybeCleanup` schedules cleanup every five minutes (`internal/middleware/rate_limit.go:140`, `internal/middleware/rate_limit.go:146`) and deletes rows not updated within 24 hours (`internal/middleware/rate_limit.go:151`, `oss/db/queries/rate_limits.sql:95`, `oss/db/queries/rate_limits.sql:97`).
- No local leak found in `ActiveCounter` on normal disconnect. `ShapeRateLimit` defers `Release(userID)` after successful acquire (`internal/electric/rate_limit.go:44`, `internal/electric/rate_limit.go:45`), and `Release` deletes the map entry when the count drops to zero (`internal/middleware/active_limits.go:45`, `internal/middleware/active_limits.go:47`).

### 6. 100-workspace cap

- Finding: F3. The count query is correctly `COUNT(*) WHERE deleted_at IS NULL` (`oss/db/queries/workspace.sql:57`, `oss/db/queries/workspace.sql:60`), but count and insert are not atomic.

### 7. Active subscription cap

- Finding: F4. "Active" is measured as the lifetime of the proxied `/v1/shape` request in the current Electric proxy process (`internal/electric/rate_limit.go:27`, `internal/electric/rate_limit.go:47`). That lines up with SSE connection lifetime in normal operation, but it is not cross-process.
- No local disconnect leak found: `defer Release` should run when `next.ServeHTTP` returns on client disconnect/upstream completion. A shared-store implementation should still use leases/TTL so abnormal termination does not strand counts.
