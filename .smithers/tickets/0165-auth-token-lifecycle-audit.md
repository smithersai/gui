# Auth + token lifecycle audit

## Status (audited 2026-04-24)

- Scope: `/Users/williamcory/gui` auth clients and `/Users/williamcory/plue` OAuth2 provider/middleware paths listed in the review request.
- Findings: 2 Critical / 4 High / 1 Medium / 0 Low.
- Review mode only. No product code changes, git staging, commits, or pushes.

## Findings

### F1. `/api/oauth2/authorize` is not browser-native and cannot complete the native app sign-in flow

- Severity: Critical
- File:line: `/Users/williamcory/plue/internal/routes/oauth2.go:162`, `/Users/williamcory/plue/internal/routes/oauth2.go:164`, `/Users/williamcory/plue/internal/routes/oauth2.go:210`, `/Users/williamcory/plue/internal/routes/oauth2.go:217`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/AuthViewModel.swift:84`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/AuthorizeSessionDriver.swift:91`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/AuthorizeSessionDriver.swift:109`
- Problem statement: the GUI opens the authorize URL with `ASWebAuthenticationSession` and waits for a callback URL containing `code` and `state`. The plue authorize handler still implements the old headless MVP behavior: it returns JSON `{ "code": ... }` and optionally echoes `state`, but never redirects to `redirect_uri`. A native browser session will show a JSON response or an auth error and will not invoke the app callback.
- Security/lifecycle impact: OAuth2 sign-in is effectively nonfunctional for the intended browser-native PKCE flow. The server also never binds or validates `state` as part of a redirect response; the client-side `parseCallback` state check only runs if a callback happens.
- Fix recommendation: make `/api/oauth2/authorize` a real browser flow. After user authentication/consent, redirect to the registered `redirect_uri` with `code` and `state` query parameters, and return OAuth error redirects for denials. Keep exact redirect URI validation before redirecting. If `state` remains client-owned, document that explicitly; otherwise persist it with the authorization code and verify it on exchange.

### F2. Sign-out is not a hard local barrier and an in-flight refresh can resurrect tokens after sign-out

- Severity: Critical
- File:line: `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenManager.swift:89`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenManager.swift:123`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenManager.swift:141`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenManager.swift:146`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenManager.swift:177`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenManager.swift:180`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenManager.swift:186`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenManager.swift:196`
- Problem statement: `TokenManager.signOut()` snapshots the current token and awaits server revocation before `localSignOut()` clears Keychain and memory. It also does not cancel or invalidate `inFlightRefresh`. If a refresh task has already passed its network call, it can still `store.save(newTokens)` and `setCached(newTokens)` after sign-out clears local state.
- Impact: a user can tap sign out while a 401 refresh is in flight and later be silently signed back in with a newly rotated token pair. Separately, while revocation is slow or hung, `currentAccessToken()` continues to return the old bearer and new requests are still possible.
- Fix recommendation: make sign-out set a locked terminal/signing-out generation before any network call, clear cached/store state immediately, cancel or poison `inFlightRefresh`, and make refresh tasks check the generation before saving. Server revoke should be best-effort after local refusal, not before local refusal.

### F3. The serialized refresh path is not used by production request paths

- Severity: High
- File:line: `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenManager.swift:159`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenManager.swift:166`, `/Users/williamcory/gui/Shared/Sources/SmithersStore/SessionLifecycle.swift:48`, `/Users/williamcory/gui/Shared/Sources/SmithersStore/SessionLifecycle.swift:55`, `/Users/williamcory/gui/macos/Sources/Smithers/Smithers.RemoteMode.swift:690`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/FeatureFlagsClient.swift:146`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/FeatureFlagsClient.swift:158`, `/Users/williamcory/gui/Shared/Sources/SmithersStore/WorkspaceSwitcherModel.swift:191`, `/Users/williamcory/gui/Shared/Sources/SmithersStore/WorkspaceSwitcherModel.swift:211`, `/Users/williamcory/gui/ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:344`, `/Users/williamcory/gui/ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:356`
- Problem statement: `TokenManager.refresh()` correctly deduplicates concurrent refreshes, and the test suite exercises that helper. The production fetchers and runtime bridge usually pull `currentAccessToken()` through bearer-provider closures, send raw `URLSession` requests, and convert 401/403 directly into `authExpired`/`unauthorized`. They do not call `performWithRetry` or `refresh()`.
- Impact: after the one-hour access token TTL, real app surfaces can sign the user out or fail instead of rotating the refresh token. The earlier serialized-refresh fix prevents duplicate refreshes only for code paths that opt into the helper, so the end-to-end lifecycle still does not meet "two concurrent 401s collapse into one refresh" for most app requests.
- Fix recommendation: route authenticated HTTP clients and the runtime credential provider through one refresh-aware token source. On first 401, call the serialized refresh once, persist write-before-retry, then retry the original request. Treat refresh failure as the sign-out path.

### F4. Tokens are in Keychain, but not protected by biometric or current-device-unlock access control

- Severity: High
- File:line: `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenStore.swift:4`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenStore.swift:77`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenStore.swift:119`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenStore.swift:120`, `/Users/williamcory/gui/Shared/Sources/SmithersAuth/TokenStore.swift:121`
- Problem statement: access and refresh tokens are not stored in `UserDefaults`; production uses a single Keychain generic password item with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and `kSecAttrSynchronizable=false`. That is device-local Keychain storage, but it is weaker than "biometric/device-unlock protection": no `SecAccessControl`, no biometric requirement, and no `WhenUnlocked`/passcode-gated class.
- Impact: once the device has been unlocked after boot, the item is available to the app even while the device is later locked. This does not meet the requested biometric/current-unlock-at-rest bar for long-lived refresh tokens.
- Fix recommendation: store refresh tokens under a stricter access policy such as `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` or a `SecAccessControl` policy appropriate for the product requirement. If background refresh is required, explicitly document that risk acceptance and consider splitting access-token and refresh-token storage policies.

### F5. macOS OAuth config mixes loopback and custom-scheme callbacks, so it is broken even if plue redirects

- Severity: High
- File:line: `/Users/williamcory/gui/macos/Sources/Smithers/Smithers.RemoteMode.swift:236`, `/Users/williamcory/gui/macos/Sources/Smithers/Smithers.RemoteMode.swift:239`, `/Users/williamcory/gui/macos/Sources/Smithers/Smithers.RemoteMode.swift:247`, `/Users/williamcory/gui/macos/Sources/Smithers/Smithers.RemoteMode.swift:252`, `/Users/williamcory/gui/macos/Sources/Smithers/Auth/LoopbackCallbackServer.swift:42`, `/Users/williamcory/gui/macos/Sources/Smithers/Auth/LoopbackCallbackServer.swift:71`
- Problem statement: macOS registers `redirectURI: "http://127.0.0.1:0/callback"` but starts `ASWebAuthenticationSession` with `callbackScheme: "smithers"`. The `LoopbackCallbackServer` exists and can bind an ephemeral port, but `RemoteModeController` never starts it and never substitutes the bound port into the redirect URI.
- Impact: a standards-compliant server redirect would target port `0` or a registered literal URI, while the client is waiting for the `smithers` scheme. macOS remote sign-in cannot reliably complete.
- Fix recommendation: choose one callback mode. For loopback, start `LoopbackCallbackServer`, build the authorize request with the actual bound `127.0.0.1:<port>/callback`, and wait on that server. For custom scheme, register/use `smithers://auth/callback` consistently.

### F6. `AuthLoader` prefers session cookies over bearer tokens, causing bearer/session confusion

- Severity: High
- File:line: `/Users/williamcory/plue/internal/middleware/auth.go:149`, `/Users/williamcory/plue/internal/middleware/auth.go:164`, `/Users/williamcory/plue/internal/middleware/auth.go:169`, `/Users/williamcory/plue/internal/middleware/auth.go:172`, `/Users/williamcory/plue/internal/middleware/scope.go:124`, `/Users/williamcory/plue/internal/middleware/scope.go:159`, `/Users/williamcory/plue/cmd/server/main.go:881`, `/Users/williamcory/plue/cmd/server/main.go:1289`, `/Users/williamcory/plue/cmd/server/main.go:1290`
- Problem statement: when a request carries both a valid session cookie and an `Authorization` bearer, `AuthLoader` authenticates the cookie and returns before inspecting the bearer. Token scope gates then bypass checks for session-authenticated requests. The separate `TokenAuth` middleware can override when explicitly composed after `AuthLoader`, but normal API groups use `AuthLoader` only.
- Impact: browser/API contexts can see a different principal and trust level than the `Authorization` header indicates. OAuth2 third-party scope restrictions and `TokenSourceOAuth2AccessToken` checks can be bypassed or, for `/oauth2/revoke-all`, the request can be rejected because the handler sees a session instead of the OAuth access token the client sent.
- Fix recommendation: define one precedence rule and enforce it globally. For API routes, prefer `Authorization` over cookies when present, or reject ambiguous requests with both credentials. Keep route tests for `session only`, `bearer only`, and `both`.

### F7. Server refresh-token rotation is not transactionally atomic across consume and reissue

- Severity: Medium
- File:line: `/Users/williamcory/plue/internal/services/oauth2.go:417`, `/Users/williamcory/plue/internal/services/oauth2.go:418`, `/Users/williamcory/plue/internal/services/oauth2.go:429`, `/Users/williamcory/plue/internal/services/oauth2.go:490`, `/Users/williamcory/plue/internal/services/oauth2.go:509`, `/Users/williamcory/plue/oss/db/queries/oauth2.sql:147`, `/Users/williamcory/plue/oss/db/queries/oauth2.sql:148`
- Problem statement: replay prevention is good: `ConsumeOAuth2RefreshToken` deletes the old refresh token atomically, so concurrent refreshes cannot both use it. However, the service then creates the new access token and new refresh token as separate operations with no transaction wrapping the delete and inserts.
- Impact: a DB/process failure after old-token deletion can strand the client without a valid refresh token; a failure after access-token creation but before refresh-token creation can leave an orphan access token. The client-side write-before-retry contract cannot recover from a server-side half-rotation.
- Fix recommendation: perform refresh rotation in one database transaction: consume old refresh token, create access token, create replacement refresh token, and commit as one unit. Return no new credentials unless all writes succeed.

## Checklist

### 1. Token storage at rest

- Finding: F4.
- Positive: production token persistence uses `KeychainTokenStore`, not `UserDefaults`, for iOS and default macOS paths (`ios/Sources/SmithersiOS/SmithersApp.swift:74`, `ios/Sources/SmithersiOS/SmithersApp.swift:79`, `macos/Sources/Smithers/Smithers.RemoteMode.swift:229`, `macos/Sources/Smithers/Smithers.RemoteMode.swift:233`). Tokens are redacted in `CustomStringConvertible` (`Shared/Sources/SmithersAuth/TokenStore.swift:43`).

### 2. Token refresh races

- Finding: F2 and F3.
- Positive: `TokenManager.refresh()` itself serializes concurrent refresh callers through `inFlightRefresh` (`Shared/Sources/SmithersAuth/TokenManager.swift:90`, `Shared/Sources/SmithersAuth/TokenManager.swift:91`, `Shared/Sources/SmithersAuth/TokenManager.swift:98`) and tests cover concurrent dedupe (`Shared/Tests/SmithersAuthTests/MockedServerIntegrationTests.swift:195`, `Shared/Tests/SmithersAuthTests/MockedServerIntegrationTests.swift:218`).

### 3. PKCE code verifier

- No finding. GUI generates 32 CSPRNG bytes with `SecRandomCopyBytes`, base64url encodes to 43 characters, and derives an S256 challenge (`Shared/Sources/SmithersAuth/PKCE.swift:57`, `Shared/Sources/SmithersAuth/PKCE.swift:60`, `Shared/Sources/SmithersAuth/PKCE.swift:68`, `Shared/Sources/SmithersAuth/PKCE.swift:85`). Server requires S256 for public clients and verifies SHA-256/base64url (`internal/services/oauth2.go:289`, `internal/services/oauth2.go:292`, `internal/services/oauth2.go:376`, `internal/services/oauth2.go:577`).

### 4. State param

- Finding: F1.
- Positive: the native client generates random state and validates callback state before exchanging the code (`Shared/Sources/SmithersAuth/AuthViewModel.swift:83`, `Shared/Sources/SmithersAuth/AuthorizeSessionDriver.swift:55`, `Shared/Sources/SmithersAuth/AuthorizeSessionDriver.swift:56`). The server currently only echoes state in JSON, so there is no redirect-side server validation/binding.

### 5. Redirect URI validation

- Finding: F1 and F5 for broken redirect behavior/wiring.
- Positive: plue enforces exact registered redirect URI matching on authorize (`internal/services/oauth2.go:246`, `internal/services/oauth2.go:247`) and exact authorization-code redirect URI matching during token exchange (`internal/services/oauth2.go:357`, `internal/services/oauth2.go:358`).

### 6. Refresh token rotation

- Finding: F7.
- Positive: plue issues a new refresh token on refresh and invalidates the old one via delete-before-return (`internal/services/oauth2.go:417`, `internal/services/oauth2.go:429`, `internal/services/oauth2.go:501`, `internal/services/oauth2.go:524`). Concurrent replay of the same refresh token should fail after the first delete.

### 7. Revocation path

- No finding for server semantics. `/api/oauth2/revoke` is idempotent for unknown tokens (`internal/services/oauth2.go:451`) and `/api/oauth2/revoke-all` deletes both refresh and access tokens for the OAuth app/user pair (`internal/services/oauth2.go:455`, `internal/services/oauth2.go:458`, `internal/services/oauth2.go:465`). The route requires an OAuth2 access token context (`internal/routes/oauth2.go:372`, `internal/routes/oauth2.go:373`).
- Client caveat is covered by F2: revocation is awaited before local refusal.

### 8. Session cookie vs bearer

- Finding: F6.

### 9. Sign-out

- Finding: F2.
- Positive: the happy path calls server-side revoke-all when available, falls back to revoking access and refresh tokens, clears the store, clears in-memory cache, and sets UI phase to signed out (`Shared/Sources/SmithersAuth/TokenManager.swift:177`, `Shared/Sources/SmithersAuth/TokenManager.swift:180`, `Shared/Sources/SmithersAuth/TokenManager.swift:182`, `Shared/Sources/SmithersAuth/TokenManager.swift:183`, `Shared/Sources/SmithersAuth/TokenManager.swift:197`, `Shared/Sources/SmithersAuth/TokenManager.swift:203`, `Shared/Sources/SmithersAuth/AuthViewModel.swift:112`).

## Verification

- Static audit only. I did not run test suites or modify product code.
