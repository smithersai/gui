# SmithersAuth

OAuth2 PKCE sign-in module shared between the macOS and iOS Smithers apps
(ticket 0109). Sibling of plue ticket 0106 (the server-side authorize flow
that this module talks to).

## Files

- `PKCE.swift` — RFC 7636 verifier/challenge generation. Uses
  `SecRandomCopyBytes` + `CryptoKit.SHA256`. Base64url without padding.
- `TokenStore.swift` — Keychain-backed token store with an in-memory fake
  for tests. Access class is
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; sync explicitly
  disabled. Tokens have a redacted `CustomStringConvertible` to keep them
  out of crash/debug logs.
- `OAuth2Client.swift` — wire-level `/api/oauth2/authorize` URL builder,
  `/api/oauth2/token` exchange + refresh, `/api/oauth2/revoke-all`
  sign-out, plus `/api/oauth2/revoke` fallback. Network I/O injected via
  `HTTPTransport`.
- `TokenManager.swift` — sign-in lifecycle, atomic refresh rotation
  (write-before-retry), concurrent-401 deduplication, sign-out that
  prefers `/api/oauth2/revoke-all` and falls back to revoking both the
  current access token and refresh token before invoking
  `SessionWipeHandler.wipeAfterSignOut()` to drop the SQLite cache (per
  ticket 0133).
- `AuthorizeSessionDriver.swift` — `ASWebAuthenticationSession` wrapper
  (iOS + macOS) + a `MockAuthorizeSessionDriver` for tests.
- `AuthViewModel.swift` / `SignInView.swift` — SwiftUI shell, identical
  on both platforms. Renders static `WhitelistDeniedView` on
  `access_not_yet_granted` (no retry loop).

## URL scheme / loopback setup

### iOS

`smithers://auth/callback` — registered via `CFBundleURLTypes` in
`ios/Sources/SmithersiOS/Info.plist`. Defense-in-depth against scheme
hijacking: every callback URL is validated against the `state` parameter
we generated for that authorize attempt.

### macOS

Two options, both supported:
- Custom scheme `smithers://auth/callback` (identical to iOS).
- RFC 8252 loopback: `http://127.0.0.1:<port>/callback`. Use
  `LoopbackCallbackServer` in `macos/Sources/Smithers/Auth/` — binds to
  127.0.0.1, accepts exactly one request, returns a plaintext "done"
  page, and shuts down. Port is ephemeral per sign-in.

Plue's registered redirect URIs (set by 0106) must include both.

## Resetting the Keychain during testing

Nuke the service item from the command line:

```sh
security delete-generic-password -s "com.smithers.oauth2.ios"    || true
security delete-generic-password -s "com.smithers.oauth2.macos"  || true
```

The in-app `Sign out` button revokes + wipes via
`TokenManager.signOut()`.

## Whitelist rejection UX

When plue returns `access_not_yet_granted` (or the legacy
`whitelist_denied`) from `/api/oauth2/token`, the view model transitions
to `.whitelistDenied(message)`. That phase is terminal — `signIn()` is a
no-op while in this state. The static page asks the user to contact their
administrator. The only escape is app-restart after plue adds them to
the whitelist.

## Env-pollution gotcha

The user's shell sets `SDKROOT`, `LIBRARY_PATH`, and `RUSTFLAGS` from
Rust tooling. iOS builds break with "wrong SDK" errors unless those are
unset. Any `swift` / `xcodebuild` invocation from this directory must be
prefixed with `env -u SDKROOT -u LIBRARY_PATH -u RUSTFLAGS …`.

## Tests

```sh
# Unit + mocked-integration suite. Runs in seconds. Hermetic — no
# plue dependency.
cd Shared && env -u SDKROOT -u LIBRARY_PATH -u RUSTFLAGS swift test

# iOS simulator suite (includes UI launch test):
env -u SDKROOT -u LIBRARY_PATH -u RUSTFLAGS xcodebuild \
  -project SmithersGUI.xcodeproj -scheme SmithersiOS \
  -destination 'platform=iOS Simulator,name=iPhone 16' test

# macOS app suite:
env -u SDKROOT -u LIBRARY_PATH -u RUSTFLAGS xcodebuild \
  -project SmithersGUI.xcodeproj -scheme SmithersGUI \
  -destination 'platform=macOS' test
```

The real-integration tests (`RealIntegrationTests.swift`) are gated on
`PLUE_DEV_URL`, `PLUE_DEV_CLIENT_ID`, `PLUE_DEV_REFRESH`. Without them
the test bodies no-op (no `XCTSkip`, per ticket). They light up when
0106 merges and a dev instance is reachable.
