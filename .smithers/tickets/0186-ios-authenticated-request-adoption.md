# 0186 iOS Authenticated Request Adoption

Audit date: 2026-04-30

## Summary

After ticket 0184 lands the shared refresh-aware HTTP client, migrate iOS feature fetchers/mutators away from raw bearer closures plus direct `URLSession` calls. This ticket owns the iOS user-facing HTTP surfaces that currently fail or sign out on access-token expiry.

## Parallel Ownership

Primary owner writes:

- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift`
- `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift`
- corresponding tests in `ios/Tests/SmithersiOSTests`

Do not edit `Shared/Sources/SmithersAuth` except to consume the ticket 0184 API.

## Requirements

- Use the shared authenticated HTTP client for approvals, workflow runs, repo selection, workspace creation, workspace delete/suspend/resume/snapshot/fork actions.
- Preserve current domain-specific error handling, especially `429 Retry-After`, quota, missing repo context, and backend-unavailable states.
- Convert auth-expired from the shared client into the same signed-out/auth-expired state the UI already expects.
- Do not silently swallow refresh failures.
- Keep E2E environment support intact.

## Acceptance Criteria

- [ ] Tests prove approvals list and decision requests retry once after a synthetic `401`.
- [ ] Tests prove workflow runs list/cancel/rerun/resume retry once after a synthetic `401`.
- [ ] Tests prove repo/workspace actions preserve `429 Retry-After` behavior.
- [ ] Tests prove missing bearer still maps to auth-expired/signed-out.
- [ ] No raw `try? tokenManager.currentAccessToken()` style request path remains in the files owned by this ticket, except test fixtures.

## Verification

```sh
cd Shared && swift test
xcodebuild -project SmithersGUI.xcodeproj -scheme SmithersiOS -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

## Dependency

Depends on ticket 0184 or an agreed stub of its public API.
