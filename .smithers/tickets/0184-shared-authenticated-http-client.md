# 0184 Shared Authenticated HTTP Client

Audit date: 2026-04-30

## Summary

Production iOS/shared HTTP paths still pull a bearer token directly and map `401` to signed-out or generic error. `TokenManager.performWithRetry` exists and is tested, but most app requests do not use it. Add one refresh-aware HTTP client abstraction that every authenticated request can share.

This is a Tier 0 unblocker for tickets 0186, 0187, and 0188.

## Parallel Ownership

Primary owner writes:

- `Shared/Sources/SmithersAuth/AuthenticatedHTTPClient.swift` or equivalent new file
- `Shared/Tests/SmithersAuthTests/*AuthenticatedHTTPClient*`
- minimal package/project wiring only if needed

Do not migrate every caller in this ticket. Other tickets own adoption by surface.

## Requirements

- Expose a small API that accepts a `URLRequest` or request builder and performs the request with a valid bearer.
- On first `401`, call the existing serialized refresh path exactly once, persist refreshed tokens before retry, and replay the original request.
- Treat refresh failure as auth-expired/sign-out signal, not as a generic backend error.
- Preserve response body/status so callers can still parse `429`, validation errors, and quota errors.
- Keep the type platform-neutral: no UIKit/AppKit imports.
- Support dependency injection for tests: fake transport/session, fake token manager, deterministic responses.

## Acceptance Criteria

- [ ] New unit tests prove two concurrent `401` requests collapse to one refresh.
- [ ] New unit tests prove a successful refresh retries the original request with the new access token.
- [ ] New unit tests prove a failed refresh returns an auth-expired error and does not retry indefinitely.
- [ ] New unit tests prove non-auth errors such as `429` and `500` are returned to callers without forcing sign-out.
- [ ] Public caller-facing API is documented in comments with the intended adoption pattern.

## Verification

```sh
cd Shared && swift test
swift test
```

## Notes

Agents implementing surface-specific migration should wait for this interface or agree on the exact API name before editing their callers.
