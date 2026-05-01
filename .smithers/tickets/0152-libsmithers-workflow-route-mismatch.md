# libsmithers: workflow cancel/rerun/resume route mismatch

## Context

Agent 6 (workflow runs e2e) found that libsmithers' canonical route
resolver emits `/api/repos/{owner}/{repo}/runs/{id}/cancel|rerun|resume`
but plue only registers `/workflows/runs/{id}/...` and
`/actions/runs/{id}/...`. Any iOS client call through the canonical
action kinds will 404.

## Plan

Pick one:

**Option A (preferred — thin):** add `/runs/` aliases to the same
handlers in `plue/internal/routes/workflows.go`. Smallest-blast-radius
fix; matches the name libsmithers already ships.

**Option B:** change the canonical action kind in
`libsmithers/src/core/transport.zig` from `/runs/` to `/workflows/runs/`
and bump ActionKind. Requires a client round-trip + re-release.

## Acceptance criteria

- iOS client cancel / rerun / resume of a workflow_run succeeds against
  a real plue (no 404).
- `SmithersiOSE2EWorkflowRunsTests.swift` scenarios 2/3/4 go green
  without XCTSkip.
