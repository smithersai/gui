# 0187 iOS Sign-Out Runtime Cache Wipe

Audit date: 2026-04-30

## Summary

`TokenManager` now has stronger local sign-out semantics, but the iOS runtime/session/cache path still needs an explicit production wipe owner. Sign-out must cancel runtime transports, drop shape subscriptions, clear cached workspace/run/session state, and prevent stale data from surviving account transitions.

## Parallel Ownership

Primary owner writes:

- new iOS runtime/session wipe coordinator file under `ios/Sources/SmithersiOS/`
- `ios/Sources/SmithersiOS/SmithersApp.swift`
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift` only for coordinator injection
- focused tests under `ios/Tests/SmithersiOSTests`

Coordinate with ticket 0186 if both need to touch `SmithersApp.swift`.

## Requirements

- Install a `SessionWipeHandler` for iOS production `TokenManager`.
- On sign-out or refresh lockout, stop active runtime sessions/transports and wipe runtime cache directories.
- Clear in-memory iOS shell state that is scoped to the signed-in user: open workspace, switcher rows, terminal mount state, approval focus, deep-link focus if user-scoped.
- Ensure sign-out local effects happen before best-effort network revocation.
- Keep E2E synthetic token mode working.

## Acceptance Criteria

- [ ] Unit tests prove `TokenManager.localSignOut()` calls the iOS wipe handler.
- [ ] Unit tests prove the iOS wipe handler clears runtime/session host state.
- [ ] Unit tests prove stale workspace rows are not visible after sign-out/sign-in as another synthetic user.
- [ ] Manual test notes or automated test cover sign-out while terminal transport is active.
- [ ] No production path creates persistent per-user cache without being reachable from the wipe handler.

## Verification

```sh
cd Shared && swift test
xcodebuild -project SmithersGUI.xcodeproj -scheme SmithersiOS -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -configuration Debug CODE_SIGNING_ALLOWED=NO test
```
