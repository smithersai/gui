# Plue: OAuth2 browser-native authorize flow (server-side)

## Context

From `.smithers/specs/ios-and-remote-sandboxes.md` (Auth → Identity). The main spec commits to mobile and desktop-remote clients signing in via plue and storing refreshable bearer + refresh tokens. This ticket owns the plue-server-side work required to support that. The client-side (iOS + macOS sign-in UI) is ticket 0109.

**What plue already has (confirmed by reading the code):**
- Full PKCE support at `/api/oauth2/token` — S256 challenge validation, refresh-token rotation on use, revoke (`plue/internal/services/oauth2.go:283, 368, 417, 481`; tests at `internal/services/oauth2_service_test.go:158, 285`).
- Browser-based Auth0 and WorkOS IdP flows that today terminate in session cookies or one-off CLI tokens for `callback_port` flows (`internal/routes/auth.go:245, 416`).

**What plue does NOT have:**
- A public OAuth2 client registered for the gui/iOS apps.
- A **browser-native `/api/oauth2/authorize` redirect/callback flow** — the current handler (`internal/routes/oauth2.go:161`) is a headless JSON endpoint behind `RequireAuth + ScopeReadUser` (`cmd/server/main.go:1248`), not something an `ASWebAuthenticationSession` or loopback browser flow can talk to unauthenticated.

## Goal

Upgrade `/api/oauth2/authorize` into a real browser-native OAuth2 authorize flow that completes upstream IdP authentication, validates PKCE, issues an authorization code, and redirects back to the client's registered URI. Register a public OAuth2 client for our apps. Token exchange/refresh/revoke already work and don't need reimplementation.

## Scope

- **In scope**
  - Upgrade `/api/oauth2/authorize` to a browser-facing flow:
    - If caller has no valid session, redirect to the upstream Auth0 or WorkOS login flow, carry state + PKCE challenge through, catch the IdP callback, then resume.
    - Validate PKCE challenge on the incoming request.
    - Issue an authorization code bound to the registered redirect URI.
    - Redirect back to the client's registered URI with the code + state.
  - **Trust boundary decision.** Today the route is gated by `RequireAuth + ScopeReadUser`. A mobile/browser flow cannot meet that precondition. Decide and document: (a) make the route fully public (standard OAuth2 authorize), or (b) gate via `RequireFirstPartyAuth` (exists today — see `cmd/server/main.go:1245`) once a session is established. Whichever is chosen must be explicitly justified in the PR.
  - Seed one OAuth2 public client with the right redirect URIs (custom URL scheme for iOS, `127.0.0.1` loopback for desktop). Document client ID, scopes, redirect URI contract. If plue lacks a public-client registration path, add one.
  - **Revoke hardening.** Current revoke (`internal/services/oauth2.go:432`) accepts a raw token and deletes any matching hash with no client/app ownership check. Decide whether public-client revoke needs to be bound to the originating client ID and tighten accordingly (RFC 7009 recommends this). If tightening, ship it in this ticket; if not, document the justification.
  - Consent UI decisions: first-party app skips consent? Always show? Document and implement.
  - **Whitelist check.** If the authenticated user is not on the whitelist, plue refuses to issue a code and surfaces a structured error the client can render as "access not yet granted."
  - Tests (plue): integration coverage for the new authorize flow — valid PKCE round-trip, invalid PKCE rejected, wrong redirect URI rejected, unwhitelisted user rejected, revoke behavior.
- **Out of scope**
  - Any client-side sign-in UI (that's ticket 0109).
  - Keychain / secure-store wrapper on the client side (that's 0109).
  - Token exchange / refresh / rotation — already works, covered by existing tests (`oauth2_service_test.go:158, 285`).
  - Multi-account support.
  - Biometric token gate.

## References

- `plue/cmd/server/main.go:917, 918` — `/api/oauth2/token`, `/api/oauth2/revoke` registration.
- `plue/cmd/server/main.go:1248` — current `/api/oauth2/authorize` registration (`RequireAuth + ScopeReadUser`).
- `plue/cmd/server/main.go:1245` — existing `RequireFirstPartyAuth` middleware, candidate for the new flow's gating.
- `plue/internal/routes/oauth2.go:161` — current headless JSON `/api/oauth2/authorize` handler.
- `plue/internal/services/oauth2.go:283, 368, 417, 481` — existing PKCE validation, token exchange, refresh, revoke.
- `plue/internal/services/oauth2.go:432` — revoke handler (hardening candidate).
- `plue/internal/routes/auth.go:245, 416` — existing browser flows for Auth0/WorkOS terminating in session cookies or callback_port tokens.
- RFC 7636 (PKCE), RFC 6749 (OAuth2), RFC 7009 (Token Revocation), RFC 8252 (Native App OAuth).

## Acceptance criteria

- `/api/oauth2/authorize` serves a real browser flow: unauthenticated caller → upstream IdP → back to plue → code + state redirect to client URI.
- Trust boundary decision documented in the PR description and enforced in the route registration.
- OAuth2 public client registered with iOS + desktop redirect URIs; documented.
- PKCE enforced: valid round-trip succeeds, invalid rejected, wrong redirect URI rejected.
- Whitelist negative path: unwhitelisted user gets a clear structured error.
- Revoke behavior decision documented and implemented.
- Integration tests cover all of the above.
- README documents: client ID, how to add a new redirect URI, how to revoke a token from plue admin.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the test actually exercises the real `/api/oauth2/authorize` → upstream IdP → code path (not a stub); wrong-redirect-URI test uses a value not in the registered client's URI list; whitelist test uses a real unwhitelisted user, not a mocked auth service.

## Risks / unknowns

- The headless-to-browser upgrade of `/api/oauth2/authorize` is the bulk of the work and is substantially larger than "register a client." Budget this ticket accordingly.
- Consent UI: first-party app may or may not want a consent screen. Upstream IdP already shows one; doubling up is annoying. Document the choice.
- Refresh token rotation is already enabled (`internal/services/oauth2.go:417`); client-side atomicity is 0109's problem.
- Revoke hardening may affect existing revoke consumers; check for breakage before tightening.
