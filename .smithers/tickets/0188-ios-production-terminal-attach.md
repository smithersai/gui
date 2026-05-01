# 0188 iOS Production Terminal Attach

Audit date: 2026-04-30

## Summary

The iOS terminal can build, but the production attach path is still too coupled to E2E seeded session environment variables and route assumptions. External users need a workspace detail flow that can discover or create/select a workspace session and attach the terminal without `PLUE_E2E_WORKSPACE_SESSION_ID`.

## Parallel Ownership

Primary owner writes:

- `ios/Sources/SmithersiOS/ContentShell.iOS.swift`
- `Shared/Sources/SmithersStore/WorkspaceSessionPresenceProbe.swift`
- `TerminalSurface.swift` only for terminal state/reporting needed by attach
- `libsmithers/src/core/transport.zig` only if URL construction must change
- focused iOS tests under `ios/Tests/SmithersiOSTests` and E2E tests under `ios/Tests/SmithersiOSE2ETests`

Coordinate with ticket 0185 before changing PTY lifetime behavior.

## Requirements

- Remove seeded-only terminal discovery from the production path.
- Use workspace/repo context from the selected workspace or backend response, not process environment.
- Resolve the correct terminal WebSocket URL contract. Prefer backend-provided URL if available; otherwise centralize route construction so it cannot drift.
- Render clear states: no session yet, checking session, session missing, attach failed, terminal active, kill-switch disabled.
- Keep the E2E seeded path as an explicit test shortcut, not the production default.

## Acceptance Criteria

- [ ] Opening a workspace from `/api/user/workspaces` can reach terminal probing without seeded env vars.
- [ ] Tests cover workspace with no session and show a production CTA or empty state.
- [ ] Tests cover workspace with a session and mount `TerminalSurface`.
- [ ] Route construction is covered by unit tests and documented in one place.
- [ ] E2E terminal scenario still works with seeded env vars.

## Verification

```sh
xcodebuild -project SmithersGUI.xcodeproj -scheme SmithersiOS -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -configuration Debug CODE_SIGNING_ALLOWED=NO test
cd libsmithers && zig build test --summary all
```

## Related

- `.smithers/tickets/0164-ssh-wspty-production-audit.md`
- `.smithers/tickets/0171-client-runtime-pty-retry-clock-injection.md`
