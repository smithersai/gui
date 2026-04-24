# plue: devtools_snapshots has schema + queries but no HTTP route

## Context

Agent 10 (devtools snapshots e2e) found ticket 0107 shipped the
`devtools_snapshots` table + queries but never wired an HTTP handler.
No route under `plue/internal/routes/` matches `devtools_snapshots`,
and `cmd/server/main.go` does not mount one. The `devtools_snapshot_enabled`
feature flag is also absent from the `/api/feature-flags` response.

## Plan

- Add `internal/routes/devtools_snapshots.go` with
  `POST /api/repos/{owner}/{repo}/devtools/snapshots` (write) and
  `GET .../latest?kind=...` (latest-per-kind read).
- Register in `cmd/server/main.go`.
- Expose `devtools_snapshot_enabled` in `internal/routes/flags.go`.
- iOS `ContentShell.iOS.swift:151` is intentionally absent a devtools
  route — follow-up UI ticket separate from this one.

## Acceptance criteria

- `POST` + `GET latest` return the documented shapes.
- `SmithersiOSE2EDevtoolsSnapshotTests.swift` scenarios 1–9 go green
  without XCTSkip.
- `/api/feature-flags` lists `devtools_snapshot_enabled`.
