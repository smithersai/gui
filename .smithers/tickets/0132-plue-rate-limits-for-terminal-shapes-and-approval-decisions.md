# Plue: rate limits for terminal, Electric shapes, and approval decisions

## Status (audited 2026-04-24) — PARTIAL

- Done: Rate-limit middleware mounted on terminal, shape, approval, message, dispatch routes per 0153; Retry-After headers present.
- Remaining: Per-surface tuning (terminal-specific token buckets vs generic middleware), abuse-specific metrics, and load-test validation not complete.

## Context

The execution plan already calls out rate limits for these surfaces in D2 (`/Users/williamcory/gui/.smithers/specs/ios-and-remote-sandboxes-execution.md:115-119`), and plue has reusable HTTP token-bucket middleware in `plue/internal/middleware/rate_limit.go:40-248`. But the new remote-client surfaces are not actually covered in a targeted way yet:

- The API server applies only a coarse global bucket of `5000/hr` auth or `60/hr` anon (`plue/cmd/server/main.go:857-867`).
- The terminal WebSocket route is long-lived and SSH-expensive, but it only inherits that coarse global limit (`plue/cmd/server/main.go:984-999`).
- The Electric auth proxy serves `/v1/shape` with auth only (`plue/internal/electric/proxy.go:41-66`); there is no shape-specific rate or concurrency control.
- Ticket 0110 will add `POST /approvals/{id}/decide`, but no ticket owns decision-rate limiting.

## Goal

Put dedicated abuse controls on the new terminal, Electric shape, and approval-decision surfaces instead of relying on the generic API rate limit and SSH backend connection caps.

## Scope

- **In scope**
  - Reuse the existing rate-limit infrastructure for **open-rate** controls by introducing explicit scopes such as:
    - `workspace_terminal_open`
    - `electric_shape_open`
    - `approval_decide`
  - Add **active-connection/subscription caps** for long-lived surfaces:
    - per-user active terminal WebSockets.
    - per-user active Electric shape streams.
  - Enforce the terminal limits before `WorkspaceTerminalHandler` dials SSH (`plue/internal/routes/workspace_terminal.go:153-159`) so rejected clients do not consume sandbox SSH capacity.
  - Enforce Electric limits in the proxy path around `/v1/shape`, which currently only authenticates then forwards (`plue/internal/electric/proxy.go:43-44`).
  - Define default thresholds and config knobs for dev/prod. Exact numbers can be tuned later, but the ticket must land with explicit defaults and docs.
  - Add metrics for rate-limit hits and active counts so operators can tune without guessing.
- **Out of scope**
  - Per-byte PTY bandwidth throttling.
  - Full distributed lease coordination across multiple API proxy instances if plue does not need that yet.
  - Generic rate limits for every future route. This ticket is specifically for the new remote-client attack surfaces.

## Proposed design

- **Open-rate limits:** use the existing DB-backed token bucket (`internal/middleware/rate_limit.go`) with new scopes so limits survive restarts and work consistently across instances.
- **Active caps for long-lived streams:** add small, explicit counters keyed by authenticated user ID in the serving process.
  - Terminal route: process-local cap is acceptable for v1 because it is protecting expensive SSH dials on that same process.
  - Electric proxy: process-local cap is acceptable as a first step if the proxy is single-instance; if it is already horizontally scaled, this ticket should promote the counter to shared storage or call that out as a follow-up.
- **Approval decision route:** apply a dedicated auth-user limiter so a buggy client cannot spam repeated decisions even if idempotency exists.
- **Do not rely on the SSH server’s existing caps alone.** `plue/internal/ssh/server.go:148-156` protects inbound SSH connection counts per IP, but the abuse entry point for the app is the API/WebSocket layer, not raw SSH.

## References

- `/Users/williamcory/gui/.smithers/specs/ios-and-remote-sandboxes-execution.md:115-119` — D2 already calls out shape and WS rate limits.
- `plue/internal/middleware/rate_limit.go:40-248` — existing reusable token-bucket middleware.
- `plue/cmd/server/main.go:857-867` — current global API rate limit.
- `plue/cmd/server/main.go:984-999` — terminal WebSocket route today.
- `plue/internal/routes/workspace_terminal.go:153-159` — SSH dial should happen only after limits pass.
- `plue/internal/electric/proxy.go:41-66` — `/v1/shape` proxy currently has no rate limiting.
- `plue/internal/electric/auth.go:44-136` — authenticated Electric requests already resolve user/token context and are the right place to hang per-user keys.
- `plue/internal/ssh/server.go:148-156` — existing SSH backend caps are too coarse to replace API-layer limits.

## Acceptance criteria

- Terminal WebSocket connects have a dedicated open-rate limit and an active-connection cap, both tested.
- Electric `/v1/shape` requests have a dedicated subscribe/open rate limit and an active-stream cap, both tested.
- Approval decision route introduced by 0110 has a dedicated per-user limiter and a test that repeated requests hit `429`.
- Limit rejections happen before SSH dial or upstream Electric proxying.
- Metrics and logs distinguish terminal, Electric, and approval limit hits.
- Config/README documents default thresholds and how to tune them.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the Electric proxy test exercises the real `/v1/shape` handler path rather than a helper function, confirms the terminal limiter fires before `dialSSH`, and checks that the new scopes are not silently sharing the generic `api` bucket.

## Risks / unknowns

- Active-count caps are harder than simple token buckets on horizontally scaled services. If the chosen implementation is process-local, document that tradeoff explicitly.
- Mobile reconnect storms can look like abuse. The defaults should tolerate normal app resume behavior.
- Approval decisions are logically idempotent, but rate limiting still matters to protect logs, audit trails, and any downstream notifications.
