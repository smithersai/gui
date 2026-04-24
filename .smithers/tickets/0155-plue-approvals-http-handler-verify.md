# plue: approvals HTTP handler grep-invisible — verify or add

## Context

Agent 5 (approvals-flow e2e) could not grep the approvals GET or decide
handler under `plue/internal/routes/`. The existing
`SmithersiOSE2EApprovalsTests.swift` passes, which means either:

1. The handler is registered from a file that matches a different
   keyword — e.g. via a generic REST registrar.
2. It's served from a mount not under `internal/routes/` (cmd/server
   main? a dedicated package?).
3. It was inlined into the approvals service and accidentally mounted.

Need to confirm + document.

## Plan

- `rg -n 'approvals' plue/cmd plue/internal` to locate the mount site.
- If handler is present but unreachable from the agent's search: update
  package layout comment / add a README pointer.
- If handler is partial (e.g. decide works but list doesn't): finish it.
- Repo-scoped `GET /api/repos/{owner}/{repo}/approvals` listing is
  required by `SmithersiOSE2EApprovalsFlowTests.swift` scenarios 1/10.

## Acceptance criteria

- `GET /api/repos/{owner}/{repo}/approvals` returns seeded rows.
- All 10 scenarios in the new approvals flow bundle run without XCTSkip
  on “route not found”.
