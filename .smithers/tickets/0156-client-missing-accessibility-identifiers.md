# client: missing accessibility identifiers + stale doc comments

## Context

Three UI accessibility gaps surfaced across the 10 codex agents:

1. **SignInView** (`Shared/Sources/SmithersAuth/SignInView.swift:22`):
   no stable accessibility identifier on the signed-out shell. Auth
   e2e tests have to anchor on the localized copy `"Sign in to Smithers"`,
   which will break on translation.

2. **ContentShell.iOS stale comment**
   (`ios/Sources/SmithersiOS/ContentShell.iOS.swift:21`): references
   `switcher.state.*` identifiers that no longer exist. The actual
   identifiers in `WorkspaceSwitcherView.swift:39` are `switcher.loading`,
   `switcher.empty.{signedIn,signedOut,backendUnavailable}`,
   `switcher.rows`.

3. **Terminal reconnect/status surface** has no accessibility id;
   terminal mount is env-gated (PLUE_E2E_WORKSPACE_SESSION_ID) rather
   than backend-lifecycle-gated, so tombstone on the server won't
   unmount the UI. See
   `SmithersiOSE2ETerminalExtendedTests.swift` scenario 10 for the
   concrete failure surface.

## Plan

- Add `.accessibilityIdentifier("auth.signin.root")` or similar to
  `SignInView`.
- Update the stale comment in `ContentShell.iOS.swift` to match
  current identifiers.
- Add `terminal.status.<connected|reconnecting|disconnected>`
  identifiers on the terminal surface's state chrome; drive mount
  from the workspace_session lifecycle instead of the launch env key.

## Acceptance criteria

- Auth tests anchor on a stable id rather than display copy.
- Terminal extended tests 10 runs without XCTSkip.
- `grep switcher.state` in `ios/Sources/` returns 0 hits.
