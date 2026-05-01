# Plue: guest-agent protocol version negotiation

## Context

The guest-agent protocol is currently append-only in the most brittle possible way. `plue/internal/sandbox/guest/protocol.go:15-31` defines a fixed set of string method names, `Request`/`Response` have no protocol-version field (`protocol.go:37-50`), and `plue/internal/sandbox/guest/handler.go:81-243` falls through to `unknown method: ...` for anything new. `cmd/guest-agent/main.go:117-148` simply relays requests and responses over vsock; there is no handshake.

That is already blocking clean rollout planning. Ticket 0107 wants a devtools snapshot method, and ticket 0110 wants an approval-emission method. Without negotiation, any new RPC method requires a coordinated sandbox-image and server deployment, or worse, runtime failure after the server has already shipped.

## Goal

Introduce an explicit compatibility mechanism so plue can detect guest-agent capabilities up front, soft-fail unsupported methods, and treat protocol extensions as normal staged rollouts instead of lockstep deploys.

## Proposed design

- **Handshake shape:** add a new guest RPC `MethodHello`.
  - Request: empty or `{min_version, max_version}`.
  - Response: `{protocol_version, min_compatible_version, guest_agent_version, capabilities}`.
- **Bootstrap compatibility rule:** the host always probes `MethodHello` first.
  - If the guest understands it, the host records the negotiated version and advertised capabilities.
  - If the guest replies with `unknown method`, the host treats it as legacy protocol `v1` with a fixed legacy capability set covering only today's methods.
- **Capability gating:** all new behavior in 0107, 0110, and future tickets must be keyed off capability names, not just a version integer.
  - Example capabilities: `devtools_snapshots.write`, `approvals.emit`.
  - This prevents overloading one version number with multiple optional rollouts.
- **Structured soft-fail:** extend `guest.Response` with an optional machine-readable error code, for example `error_code`.
  - New guests should return `error_code="unknown_method"` or `error_code="unsupported_capability"` where appropriate.
  - Old guests will still only populate `error`, so the host must retain the legacy string-match fallback for the initial `MethodHello` probe.
- **Rollout contract:** server-side code must not invoke a new guest method unless the negotiated capability is present. Missing capability should become a feature-unavailable path, not a broken run.

## Scope

- **In scope**
  - Add the protocol handshake and version/capability response types to `internal/sandbox/guest/protocol.go`.
  - Implement `MethodHello` in `internal/sandbox/guest/handler.go`.
  - Update the host-side guest client to probe once per connection and cache the result for that guest session.
  - Add explicit capability checks around any new method introduced after this ticket.
  - Document the legacy `v1` fallback behavior for older sandbox images.
  - Patch dependent tickets so they treat this as a hard prerequisite, not a “whoever lands first” decision.
- **Out of scope**
  - Rewriting the transport off vsock or changing the framing format.
  - Backfilling capabilities for every historical sandbox image; the legacy fallback is enough.
  - Solving application-level schema migration inside each new method payload. This ticket only negotiates whether the method exists and is safe to call.

## References

- `plue/internal/sandbox/guest/protocol.go:15-31` — fixed method enum today.
- `plue/internal/sandbox/guest/protocol.go:37-50` — request/response envelope lacks versioning.
- `plue/internal/sandbox/guest/handler.go:81-243` — dispatch table and unknown-method fallback.
- `plue/cmd/guest-agent/main.go:117-148` — request/response relay loop.
- `/Users/williamcory/gui/.smithers/tickets/0107-plue-devtools-snapshot-surface.md:23-28` — devtools snapshot writer depends on a new guest method.
- `/Users/williamcory/gui/.smithers/tickets/0110-plue-approvals-implementation.md:19-25` — approvals emission depends on a new guest method.

## Acceptance criteria

- `MethodHello` exists and returns protocol version plus capability advertisement from new guest-agent builds.
- Host-side guest client probes `MethodHello` before using optional methods and falls back cleanly when talking to older guests that return `unknown method`.
- New methods are guarded by named capabilities rather than unconditional dispatch.
- Unknown or unsupported methods fail as feature-unavailable errors; they do not crash the guest connection or require a coordinated deploy.
- Tests cover at least:
  - new host -> new guest: handshake succeeds, capabilities advertised.
  - new host -> old guest: `MethodHello` missing, legacy fallback selected.
  - host attempts gated method without capability: request is not sent or is translated into a clear compatibility error.
  - unknown method response remains backward compatible with old guests.
- Tickets 0107 and 0110 explicitly call out 0131 as a prerequisite.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the compatibility test matrix includes a simulated old guest that does not implement `MethodHello`, and checks that 0107/0110-style methods are actually gated by capability presence rather than comments alone.

## Risks / unknowns

- A version number without capabilities is too coarse for the expected rollout pattern. If the ticket collapses back to “single protocol int, no capability list,” it should explain why 0107 and 0110 can still ship independently.
- The bootstrap fallback relies on either a structured `error_code` or a stable `unknown method` string for old guests. Keep that fallback small and isolated so it can be deleted once all images speak `MethodHello`.
- If future guest methods need payload-schema negotiation, that should layer on top of capability names, not replace them.
