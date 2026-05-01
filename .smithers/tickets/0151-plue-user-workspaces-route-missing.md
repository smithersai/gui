# plue: `/api/user/workspaces` route missing

## Context

Surfaced by the e2e harness (ticket 0141) after 10 codex agents wrote
expanded XCUITest coverage. Agent 3 (workspace lifecycle) traced the
iOS app's `URLSessionRemoteWorkspaceFetcher` to `GET /api/user/workspaces`
but this route is not registered under `plue/internal/routes/`.

The existing iOS e2e suite passes workspace-switcher scenarios, so the
call is either (a) served by a path handler not grep-visible, (b) 404ing
and the client silently falls back to empty state, or (c) served from
the OSS/Electric side of the stack. Unknown which without tracing a live
request.

## Plan

- Start the stack, `curl -i -H 'Authorization: Bearer …' http://localhost:4000/api/user/workspaces` and record the exact response.
- If 404: add a root-scoped handler that unions cross-repo workspaces
  for the authenticated user (OSS has `user_workspaces_*` queries from
  tickets 0135/0136 that can back it).
- If 200 from a different mux: document the mount site + align with the
  ticket 0135/0136 spec.

## Acceptance criteria

- `GET /api/user/workspaces` returns 200 with the documented envelope.
- iOS switcher loads cross-repo workspaces without hitting the
  backend-unavailable state in the absence of stubs.
- `ios/Tests/SmithersiOSE2ETests/SmithersiOSE2EWorkspaceLifecycleTests.swift`
  scenarios that XCTSkip on missing routes unskip.
