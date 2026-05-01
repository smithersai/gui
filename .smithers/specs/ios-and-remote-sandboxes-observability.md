# iOS And Remote Sandboxes — Observability & Error Conditions

Companion to `ios-and-remote-sandboxes.md` and `ios-and-remote-sandboxes-execution.md` (task **D2**). Produced by ticket [0098](../tickets/0098-design-observability.md). Consumed by validation [universal checks #4 and #5](ios-and-remote-sandboxes-validation.md) — every new metric or structured error class introduced by a ticket in this initiative must be declared here (name, type, unit, labels, emission site for metrics; code, retryable, user-visible, user-facing copy for errors). Tickets that add signals before this doc is updated are out of policy.

This is a design doc. No telemetry pipeline picks here, no backend lock-in. The only opinion we hold is on *naming conventions* (so metrics from libsmithers-core and plue read as one taxonomy) and on *what we refuse to emit* (so PII doesn't leak via field drift).

## 0. Conventions

- **Metric naming:** OpenMetrics / Prometheus style, snake_case, unit suffixes. Plue's existing convention is `jjhub_{subsystem}_{name}_{unit}` (see `plue/internal/routes/metrics.go:11-16`). New client-side metrics use `smithers_core_{subsystem}_{name}_{unit}`. New plue metrics for this initiative continue the `jjhub_` prefix. Example: `smithers_core_electric_shape_subscribe_duration_seconds`. This naming is OpenTelemetry-compatible (OTel accepts Prometheus exposition; instrument names translate one-to-one when shipping through an OTel collector).
- **Error codes:** snake_case, stable, surfaced both in logs (`event` / `error_code` field) and in API error bodies where applicable. No format strings in the code field.
- **Log format:** JSON, GCP-compatible (`severity`/`message` keys on plue — see `plue/internal/middleware/structured_logging.go:94-112`). libsmithers-core emits the same shape so logs merge cleanly in the aggregator.
- **PII baseline:** `user_id` (integer) is the *only* principal identity logged. Email, display name, repo contents, chat text, PTY bytes, OAuth tokens, and refresh tokens are never logged and never emitted as metric labels.

## 1. Structured logging

### 1.1 Field schema

Every log line from every component in this initiative — `libsmithers-core` (Zig), plue engine HTTP routes (Go), the Electric auth proxy (Go), and the sandbox guest-agent (Go) — emits JSON with the following baseline fields:

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `time` | RFC3339 ns | yes | Existing in plue's slog handler. |
| `severity` | enum | yes | `DEBUG` / `INFO` / `WARNING` / `ERROR` / `CRITICAL` (GCP spelling, matches `middleware.MapSeverity`). |
| `message` | string | yes | Human-readable short description. No PII. |
| `event` | string | yes | Machine-readable event name, snake_case (e.g. `shape_subscribe`, `ws_origin_rejected`, `pty_attach`). Used for indexed search. |
| `component` | enum | yes | One of: `libsmithers_core`, `plue_route`, `electric_proxy`, `guest_agent`. |
| `trace_id` | hex | when available | OTel trace ID. Plue already extracts this in `middleware.TraceFieldsFromContext` (`structured_logging.go:56-62`); libsmithers-core generates one per session and propagates on outbound HTTP/WS. |
| `span_id` | hex | when available | Same source as `trace_id`. |
| `session_id` | string | when scoped | Smithers engine-session ID (one per connected client). |
| `sandbox_id` | string | when scoped | Present for workspace-terminal / guest-agent events. |
| `user_id` | int64 | when authenticated | Already in plue's structured logs. Never email, never display name. |
| `duration_ms` | number | on operation-complete events | Latency of the operation the event represents. |
| `level` | shortname | yes | Lowercase mirror of `severity` (`debug`/`info`/`warn`/`error`) for non-GCP consumers. slog emits severity; a handler-level `ReplaceAttr` also emits `level`. |
| `error_code` | string | on failures | Matches the taxonomy in Section 4. |

Levels guidance:

- `debug`: per-delta shape traffic, per-byte-chunk PTY frames, per-SQL-statement core DB ops. Off in production.
- `info`: shape subscribe/unsubscribe, WS connect/disconnect, PTY attach/detach, auth login/logout, cache compaction start/end, sandbox boot complete.
- `warn`: retryable failure, degraded mode, slow operation (>2s for what should be fast), quota near limit.
- `error`: non-retryable failure, protocol violation, assertion failure, panic recovered.

### 1.2 What is NOT logged

Explicit denylist. Any addition here is a review rejection:

- Email address (we carry only `user_id`).
- Display name.
- OAuth access token, OAuth refresh token, or any `jjhub_*` bearer.
- Repository file contents, diffs, or git blobs.
- Chat/message body text (`agent_messages.body`), approval prompt text, or any user-authored prose.
- PTY bytes — neither stdin nor stdout. Terminals go through `workspace_terminal.go` with no content logging. Only frame counts/sizes.
- SSH private keys, agent forwarding material, cloud-init secrets.

Rationale: PII is logged once and forever. A deny-first posture is cheaper than auditing post-hoc.

## 2. Metrics

### 2.1 Client-side (`libsmithers-core`)

All client metrics are surfaced via the core's telemetry FFI (see Section 7) and optionally uploaded to plue's metrics ingest if a user opts in. Emission site "new, in 0120" means: no code exists yet; the named ticket owns creating it.

| Name | Type | Unit | Labels | Rationale | Emission site |
| --- | --- | --- | --- | --- | --- |
| `smithers_core_electric_shape_active` | gauge | shapes | — | How many shapes are currently subscribed; saturates the concurrent-shape cap (default 25 iOS / 50 desktop — see main spec §Client Architecture). | new, in [0120](../tickets/0120-client-libsmithers-core-production-runtime.md) |
| `smithers_core_electric_shape_lifetime_seconds` | histogram | seconds | `shape` | How long shapes live before unsubscribe — distinguishes "opened briefly" from "pinned forever" and catches leaks. | new, in [0120](../tickets/0120-client-libsmithers-core-production-runtime.md) |
| `smithers_core_electric_shape_reconnect_total` | counter | reconnects | `shape`, `reason` | Shape reconnect count — a hot shape points at either a server-side churn bug or a client offset-resume bug. | new, in [0120](../tickets/0120-client-libsmithers-core-production-runtime.md) |
| `smithers_core_electric_shape_subscribe_duration_seconds` | histogram | seconds | `shape` | Time from subscribe request to first-delta received — detects slow shapes and initial-snapshot-size regressions. | new, in [0120](../tickets/0120-client-libsmithers-core-production-runtime.md) |
| `smithers_core_ws_active` | gauge | connections | `purpose` (`pty`) | Open WebSocket count — paired with the server gauge in 2.2; mismatch means half-open connections. | new, in [0120](../tickets/0120-client-libsmithers-core-production-runtime.md) |
| `smithers_core_ws_reconnect_total` | counter | reconnects | `purpose`, `reason` | WS reconnect count — network flake vs. server-initiated vs. idle-timeout. | new, in [0120](../tickets/0120-client-libsmithers-core-production-runtime.md) |
| `smithers_core_pty_bytes_per_second` | gauge (rate-derived) | bytes/s | `direction` (`in`/`out`) | Throughput per active PTY — surfaces runaway output (`yes` in a loop) and stuck-renderer cases. | new, in [0120](../tickets/0120-client-libsmithers-core-production-runtime.md) |
| `smithers_core_sqlite_bytes` | gauge | bytes | — | Local SQLite size on disk — drives compaction triggers and is the iOS memory-pressure signal. | new, in [0120](../tickets/0120-client-libsmithers-core-production-runtime.md) |
| `smithers_core_sqlite_cache_hit_ratio` | gauge | ratio | — | Hit rate over a sliding window — a drop signals evicted pinned shapes or a shape-schema mismatch. | new, in [0120](../tickets/0120-client-libsmithers-core-production-runtime.md) |
| `smithers_core_auth_unauthorized_total` | counter | events | `source` (`shape`/`ws`/`http`/`sse`) | 401s received by the core — a surge means tokens rotated or clock skew. | new, in [0120](../tickets/0120-client-libsmithers-core-production-runtime.md) |
| `smithers_core_auth_refresh_attempt_total` | counter | events | `result` (`ok`/`fail`) | Refresh-token attempts — climbing failures mean refresh-token revocation, force sign-out. | new, in [0120](../tickets/0120-client-libsmithers-core-production-runtime.md) |

### 2.2 Server-side (plue)

| Name | Type | Unit | Labels | Rationale | Emission site |
| --- | --- | --- | --- | --- | --- |
| `jjhub_http_request_duration_seconds` | histogram | seconds | `method`, `path`, `status` | Per-route latency — already emitted; new routes from this initiative inherit it via existing chi middleware. | `plue/internal/routes/metrics.go` (HTTPMetrics), wired by `middleware/metrics.go` |
| `jjhub_http_requests_total` | counter | requests | `method`, `path`, `status` | Auth success/fail is derivable from 200 vs. 401/403 on `/api/oauth2/*` — no new counter needed for baseline auth. | `plue/internal/routes/metrics.go` (existing) |
| `jjhub_oauth2_auth_result_total` | counter | events | `result` (`ok`/`expired`/`revoked`/`invalid`) | Finer-grained auth outcome than HTTP status alone — distinguishes refresh-ok from re-login-required at the dashboard level. | new, in [0106](../tickets/0106-plue-oauth2-pkce-for-mobile.md) |
| `jjhub_electric_shape_subscribe_total` | counter | events | `table`, `result` (`ok`/`denied`/`malformed`) | Shape subscription requests hitting the Electric auth proxy — pairs with `electric_shape_where_denied` for ACL-rejection rate. | new, in [0111](../tickets/0111-plue-run-shape-route-reconciliation.md); emission in `plue/internal/electric/auth.go` |
| `jjhub_workspace_ws_active` | gauge | connections | — | Open terminal WebSockets — paired with the client gauge; diff diagnoses half-open. | new, in workspace_terminal route (0123 client, plue existing) |
| `jjhub_workspace_ws_origin_rejected_total` | counter | events | — | Origin-rejected handshake count — already emitted via `IncWebSocketOriginRejection` at `routes/metrics.go:397-399`. | `plue/internal/routes/workspace_terminal.go:92-94` (existing) |
| `jjhub_sandbox_boot_duration_seconds` | histogram | seconds | `mode` (`cold`/`warm`/`snapshot_restore`) | Sandbox boot latency by mode — snapshot-restore is the main UX lever; regressing cold is tolerable, regressing snapshot-restore is not. | extends `jjhub_sandbox_vm_create_duration_seconds` (`plue/internal/sandbox/metrics.go:107`) with a `mode` label; plumbed in [0107](../tickets/0107-plue-devtools-snapshot-surface.md). |
| `jjhub_sandbox_quota_rejections_total` | counter | events | `reason` (`per_user_cap`/`global_cap`) | Quota hits — tells us when to raise the cap vs. when a runaway client is spamming creates. | new, in [0105](../tickets/0105-plue-sandbox-quota-enforcement.md) |
| `jjhub_rate_limit_rejections_total` | counter | events | `category` (see §5) | Per-category rate-limit trips — sized against the caps defined in [0132](../tickets/0132-plue-rate-limits.md). | new, in [0132](../tickets/0132-plue-rate-limits.md) |

## 3. Existing plue observability surface — anchor table

Each new client signal maps to a plue analog where one already exists. Where no analog exists, emission is net-new and the ticket listed in §2 owns it. This table is the source of truth for "does plue already see this?"

| Client-side signal | plue analog exists? | plue metric / log field | Notes |
| --- | --- | --- | --- |
| Shape subscribe attempt | partial | access-log line via `middleware/structured_logging.go` on `/v1/shape`; no counter | 0111 adds `jjhub_electric_shape_subscribe_total`. |
| Shape authorization deny | partial | `http.Error` with 401/403 in `electric/auth.go:62, 90, 119`; counted only via generic `jjhub_http_requests_total{status="403"}` | 0111 adds table-labeled counter so we can page on repo-ACL surges without false positives from other 403s. |
| Shape lifetime / reconnect | no | — | Net-new; emission is client-side only (the proxy can't observe clean client-side unsubscribe because Electric shapes are pull-based). |
| WebSocket connect | yes | `jjhub_workspace_ws_origin_rejected_total` (`routes/metrics.go:397`) captures the reject path; handshake-success path not counted today | 0123 adds `jjhub_workspace_ws_active` gauge. |
| WebSocket reconnect | no | — | Net-new; emission is client-side. Server sees a new connect, not a reconnect — reconnect semantics live only on the client. |
| PTY bytes/sec | no | — | Server does not count bytes (we deliberately do not log content); throughput is observable only on the client end. |
| SQLite cache size / hit ratio | no | — | Net-new; local-only by definition. |
| 401 count | yes | `jjhub_http_requests_total{status="401"}` | Client still counts its own 401s because the client sees the 401 before the network retry ladder decides; rates diverge intentionally. |
| Refresh-token attempts | no | — | 0106 adds `jjhub_oauth2_auth_result_total` (server-side view); client-side `smithers_core_auth_refresh_attempt_total` is separate. Two emitters for the same event is intentional — the difference between the two counts *is* the information (network-dropped refreshes). |
| Sandbox boot latency | partial | `jjhub_sandbox_vm_create_duration_seconds` histogram exists (no `mode` label) | 0107 adds `mode` label. |
| Quota rejections | no | — | 0105 adds `jjhub_sandbox_quota_rejections_total`. |

## 4. Error taxonomy

All structured errors surfaced to clients by plue, and all error conditions handled by `libsmithers-core`, map to one of the codes below. The table is the *complete* v1 set — anything not in it is `internal_error` by default. New tickets that introduce a genuinely new failure mode amend this table.

| Code | Retryable | User-visible | User-facing copy | Rationale |
| --- | --- | --- | --- | --- |
| `network_transient` | yes (auto, backoff) | subtle | "Reconnecting…" inline indicator, no modal. | Common case on mobile. Silently recovering is the whole point of the reconnect ladder; a modal on every subway tunnel is worse than useless. |
| `auth_expired` | yes (one refresh attempt) | no unless refresh fails | If refresh fails: "Your session expired. Please sign in again." | Refresh-token path is the happy path on 401; surfacing to the user only when refresh itself fails avoids gratuitous sign-in screens. |
| `auth_revoked` | no | yes, forced | "Your access was revoked. Contact support if this is unexpected." | Distinct from expiry so we don't invite the user to re-sign-in when the server says no. Drives a forced local wipe. |
| `quota_exceeded` | no | yes | "You've reached the limit of N concurrent sandboxes. Close one to create another." | Retrying without action won't help; the message has to name both the cap and the remediation or users will assume we're broken. |
| `sandbox_unavailable` | yes (backoff, user-visible after ~15s) | yes after delay | "Your sandbox is taking longer than usual to start…" then "Sandbox unavailable. Try again in a minute." | Cold-boot and snapshot-restore both have plausible multi-second tails; short retries should stay silent, long ones shouldn't pretend nothing's wrong. |
| `schema_mismatch` | no | yes | "Please update the app to keep using remote sandboxes." | When shape schema shifts past what the local SQLite migrated to, silently retrying corrupts state. Better to block the client cleanly and force an update. |
| `origin_rejected` | no | rarely (dev builds) | Production: swallowed with "Couldn't connect, please reinstall the app." Dev: explicit "Origin X rejected, check `workspace_terminal.go` checkOrigin." | Emitted by `plue/internal/routes/workspace_terminal.go:84-97` via `checkOrigin` + `IncWebSocketOriginRejection`. Indicates a client build bug or CORS misconfiguration, not a user error — but we still tell the user *something* so they're not staring at a blank terminal. |
| `shape_where_denied` | no | yes | "You don't have access to this repository." | Emitted by `plue/internal/electric/auth.go:118-121` when `userCanReadRepo` returns false. Not retryable — ACL won't change on retry. Distinct code so the client can present a clean "not authorized" state instead of a generic network error. |
| `internal_error` | yes (once) | yes after retry | "Something went wrong. Reference: `<trace_id>`." Trace ID copyable. | Default bucket for panics, 500s, and contract violations. Surfacing `trace_id` lets us act on a user report without asking for a screen recording. |

### 4.1 Explicitly NOT in v1

- **`subprotocol_invalid`.** `plue/internal/routes/workspace_terminal.go` wires `coder/websocket` without enforcing a `Sec-WebSocket-Protocol` match. A client that sends a wrong or missing subprotocol is *not* rejected at the protocol layer today — the handshake completes. Declaring an error code we cannot actually produce would be noise; when plue adds subprotocol enforcement (and it probably should, for client-version pinning), we add the error class then. Until then, any "wrong protocol version" failure manifests as `internal_error` after the first malformed frame.

### 4.2 Server-side mapping

The plue routes emit these codes via `pkg/errors` bodies (e.g. `pkgerrors.Forbidden`, `pkgerrors.BadRequest`). Each new route in this initiative that can fail in a novel way MUST add its code to this table before landing (see validation universal check #4). The mapping is one error code per response body, not per log line — logs may be more granular.

## 5. Rate limits

Per-user enforcement on the plue side. Numbers are deferred to [ticket 0132](../tickets/0132-plue-rate-limits.md); this section defines only the *categories* so tickets know what to target. When a category trips, plue emits `jjhub_rate_limit_rejections_total{category=...}` and returns `quota_exceeded` (for sustained caps) or `network_transient` with a `Retry-After` header (for burst caps).

| Category | Signal | Enforcement Kind |
| --- | --- | --- |
| Max concurrent Electric shapes per user | gauge cap | sustained |
| Max concurrent WebSockets per user | gauge cap | sustained |
| Shape subscribe rate (new subscribes per minute) | token bucket | burst |
| Sandbox create rate (new sandboxes per minute) | token bucket | burst |
| Approval decide rate (decisions per minute) | token bucket | burst |

These exist to bound blast radius from a runaway client (or a scripted abuser), not to gate normal interactive use. If a real user hits any of these, the cap is wrong. Cross-reference: [0132](../tickets/0132-plue-rate-limits.md) owns implementation; the sandbox-create cap interacts with [0105](../tickets/0105-plue-sandbox-quota-enforcement.md) (quota is hard-cap absolute; rate limit is the derivative).

## 6. Crash reporting

- **iOS / macOS:** Sentry (or the equivalent already approved by JJHub infra — final pick in the implementing ticket). Captures stack traces, Swift/Objective-C exceptions, and Zig-level aborts bubbled up through FFI. Filters: we attach `user_id`, `session_id`, `sandbox_id`, and the most recent 50 `event=*` log lines as breadcrumbs. We do NOT attach: OS username, device identifiers beyond make/model/OS version, request bodies, or any chat/PTY content.
- **Android canary:** no crash reporting in v1. The canary is a build-gate, not a user-facing build; crashes on the canary show up in CI logs.
- **plue server:** panic recovery middleware emits `severity=CRITICAL` with stack trace and `trace_id`. No user-content fields allowed in the panic payload — the recover handler scrubs request body before logging. Panics additionally increment `jjhub_http_requests_total{status="500"}` via the existing metrics middleware, so crash rate is already a graphable quantity.
- **guest-agent:** crashes are captured by the sandbox supervisor and posted back to plue as a sandbox `unhealthy` event; the plue route re-emits the stack in its own log with the same scrubbing rules.

Rationale for Sentry-class tooling: the client runs on untrusted networks, on devices we can't SSH into, and the existing plue log aggregator only sees what the device chooses to send. Without crash-native capture, field crashes appear as silent disconnects and nothing else.

## 7. Debug surface (developer telemetry view)

Every non-release build of the client ships a hidden "Telemetry" screen (gesture-activated — long-press on the About dialog, say) that renders the *live* client-side metrics from §2.1 as a table, plus the last ~200 log lines (filtered to `level>=info`). This is the difference between "user reports the app feels laggy on the subway" and "user sends us a screenshot showing `ws_reconnect_total=47` and `sqlite_bytes=820MB`."

Contents:

- Live values of every `smithers_core_*` metric.
- A rolling log tail.
- Active shape list with lifetimes.
- Active WebSocket list with reconnect counts.
- Current `session_id`, `user_id`, platform, build SHA — for pasting into bug reports.

Must NOT contain: tokens, keychain material, chat content, PTY frames, file paths from user repos.

This surface is explicitly not a replacement for a proper metrics ingest — it exists because during the iOS beta and the first few weeks after launch, we will not have the ingest pipeline yet, and field debugging cannot block on it. Once ingest lands, the telemetry screen stays (it remains useful for in-person debugging), but it stops being the only window into production behavior.

## 8. Cross-references

- [Main spec §Client Architecture](ios-and-remote-sandboxes.md#client-architecture) — the four network surfaces whose behavior the §2.1 metrics instrument. The error taxonomy in §4 is the canonical list for any "what does this failure look like to the user" question raised in the client-architecture section.
- [Execution plan D2](ios-and-remote-sandboxes-execution.md) — this doc is the deliverable.
- [Validation checklist universal checks #4 and #5](ios-and-remote-sandboxes-validation.md) — error-taxonomy and metric-presence gates reference this doc.
- [0132 — plue rate limits](../tickets/0132-plue-rate-limits.md) — owns the numbers behind §5.
- [0105 — sandbox quota enforcement](../tickets/0105-plue-sandbox-quota-enforcement.md) — owns `jjhub_sandbox_quota_rejections_total`.
- [0106 — OAuth2 PKCE for mobile](../tickets/0106-plue-oauth2-pkce-for-mobile.md) — owns `jjhub_oauth2_auth_result_total`.
- [0107 — devtools snapshot surface](../tickets/0107-plue-devtools-snapshot-surface.md) — adds `mode` label to sandbox boot histogram.
- [0111 — run shape route reconciliation](../tickets/0111-plue-run-shape-route-reconciliation.md) — owns `jjhub_electric_shape_subscribe_total`.
- [0120 — libsmithers-core production runtime](../tickets/0120-client-libsmithers-core-production-runtime.md) — owns every `smithers_core_*` emission.
