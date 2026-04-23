# Design: observability and error conditions

## Context

From `.smithers/specs/ios-and-remote-sandboxes-execution.md`, task D2. Design-only. The spec introduces new transports (Electric, WebSocket, SSE), a new client-side cache, and a new auth path. Without an observability plan, we ship opaque production code where the same bug class (e.g. a shape stuck at an offset) is undiagnosable.

## Goal

A written observability document at `.smithers/specs/ios-and-remote-sandboxes-observability.md` that prescribes structured logging, metrics, error taxonomy, rate limits, and what shows up to the user vs. what silently retries.

## Scope of the output doc

- **Structured logging.** Field schema for logs emitted by `libsmithers-core`, plue engine routes, the Electric proxy, and the guest-agent. At minimum: `trace_id`, `session_id`, `sandbox_id`, `user_id`, `component`, `level`, `event`, `duration_ms`. Levels: debug/info/warn/error. No PII beyond user_id.
- **Metrics.** What to emit and where:
  - Client-side (`libsmithers-core`): Electric shape subscription count (gauge), shape lifetime (histogram), shape reconnect count (counter), WebSocket connection count (gauge), WS reconnect count (counter), PTY bytes/sec (rate), SQLite cache size in MB (gauge), SQLite cache hit rate (gauge), auth 401 count (counter), refresh attempt count (counter).
  - Server-side (plue): per-route latency (histogram), auth success/fail rate (counter), shape subscription requests (counter), open WebSocket count (gauge), sandbox boot duration by mode (histogram — cold/warm/snapshot-restore), quota rejections (counter).
- **Existing plue observability surface.** Anchor the doc to what plue already emits: per-route metrics in `internal/routes/metrics*.go`, log fields in `middleware/`, existing trace/request IDs. The client-side observability must **extend** this taxonomy, not invent a parallel one. The doc names, per client-side signal, whether plue already has an analog and how the two map.
- **Error taxonomy.** Define error classes with: machine-readable code, whether it's retryable, whether it surfaces to the user, and user-facing copy.
  - `network_transient`: auto-retry with backoff, user sees subtle "reconnecting" indicator.
  - `auth_expired`: single refresh attempt, escalate to sign-out if refresh fails.
  - `auth_revoked`: immediate sign-out, user told access was revoked.
  - `quota_exceeded`: not retried; user told the limit and suggested action.
  - `sandbox_unavailable`: retryable with user-visible message after N seconds.
  - `schema_mismatch`: not retried; app prompts update.
  - `origin_rejected`: WebSocket handshake failure from plue's `workspace_terminal.go:84` `checkOrigin`. Not retried; logged; indicates client bug or misconfiguration. (Note: a `subprotocol_invalid` error class is NOT in v1 — `coder/websocket` does not reject missing/wrong subprotocols server-side. If plue later adds this enforcement, add the error class then.)
  - `shape_where_denied`: Electric shape subscription rejected because the `where` clause doesn't match repo ACLs. Surfaces as "you don't have access."
  - `internal_error`: retried once; if persistent, user sees "something went wrong, please try again" with a trace_id they can share.
- **Rate limits.** Per-user limits worth enforcing on the plue side: max concurrent Electric shapes, max concurrent WebSockets, shape-subscribe rate (to prevent thrash), sandbox-create rate. Numbers are TBD and can remain so, but the categories must be listed.
- **Crash reporting.** Minimum: Sentry (or equivalent) on iOS/macOS, structured panics with stack in plue logs. No PII.
- **Debug surface.** Developer-only "telemetry" view in the app that shows live values of the client-side metrics above — critical for field debugging without requiring a full instrumentation pipeline.

## Acceptance criteria

- Doc lives at `.smithers/specs/ios-and-remote-sandboxes-observability.md`, structured per sections above.
- Every metric and error class named has a one-sentence rationale.
- Error taxonomy is cross-referenced from the client architecture section of the main spec (reviewer should add those links).
- Reviewed and approved before any Stage 1 PoC begins.

## Independent validation

See D3 (`ticket 0099`). Until D3 lands: reviewer verifies every error class from the main spec (auth, network, quota, sandbox, schema) appears in the taxonomy with all required fields, and that the metrics list distinguishes client-side from server-side correctly.

## Out of scope

- Implementing any telemetry pipeline. This is purely a design doc.
- Picking a specific metrics backend (Prometheus vs. OTel vs. something else). The doc can be agnostic.
