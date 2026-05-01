# plue: rate limits + quotas not actually enforced on documented routes

## Context

Agent 9 (rate-limits e2e) exercised six endpoints that tickets 0132
(rate limits) and 0105 (quota) were supposed to cap and observed NONE
return 429 under load:

- `POST /api/repos/{owner}/{repo}/workspaces` — 100-workspace cap absent.
- `GET /api/repos/{owner}/{repo}/workspace/sessions/{id}/terminal` — no
  terminal-open limiter.
- `GET /v1/shape` — no active-subscription cap.
- `POST /api/repos/{owner}/{repo}/approvals/{id}/decide` — no decide limiter.
- `POST /api/repos/{owner}/{repo}/agent/sessions/{id}/messages` — no limiter.
- `POST /api/repos/{owner}/{repo}/workflows/{id}/dispatches` — no limiter.

This is a regression across two shipped tickets.

## Plan

- Inspect `plue/internal/middleware/ratelimit.go` (if present) to see
  whether the limiter exists but isn't mounted, or whether the limiter
  implementation is incomplete.
- Mount against the routes above with per-user buckets + the thresholds
  documented in 0132/0105.
- Ensure the `Retry-After` header is set on 429 responses.

## Acceptance criteria

- All six scenarios in
  `ios/Tests/SmithersiOSE2ETests/SmithersiOSE2ERateLimitsTests.swift`
  observe 429 after the documented threshold.
- 429 responses include `Retry-After`.
- Workspace creation fails cleanly at the 100-cap boundary.
