# 0169 - Observability Gap Audit

Scope: `/Users/williamcory/plue` and `/Users/williamcory/gui`

Date: 2026-04-24

## Severity Counts

- Critical: 0
- High: 4
- Medium: 5
- Low: 0

## Findings

### High - PLUE-OBS-001 - HTTP access logs do not reliably include authenticated `user_id`, and logs record raw paths instead of route templates

The server has structured request logging, but the access log cannot reliably answer "which user hit which route" for authenticated API traffic. `StructuredLogger` is installed globally before `/api` auth loading, and it builds the final log attributes from the original request after the downstream handler returns. `AuthLoader` adds auth by calling `next.ServeHTTP(w, r.WithContext(...))`, so the authenticated context is only on the child request passed downstream, not the outer request later inspected by `StructuredLogger`.

Evidence:

- `/Users/williamcory/plue/cmd/server/main.go:687` installs `InjectLogger`, and `/Users/williamcory/plue/cmd/server/main.go:688` installs `StructuredLogger` globally.
- `/Users/williamcory/plue/cmd/server/main.go:881` installs `AuthLoader` inside the `/api` route group, after the global logging middleware.
- `/Users/williamcory/plue/internal/middleware/auth.go:164` and `/Users/williamcory/plue/internal/middleware/auth.go:172` pass authenticated requests downstream via `r.WithContext(...)`.
- `/Users/williamcory/plue/internal/middleware/structured_logging.go:247` builds log attributes from the outer request, and `/Users/williamcory/plue/internal/middleware/structured_logging.go:286` tries to read `AuthInfo` from that outer context.
- `/Users/williamcory/plue/internal/middleware/structured_logging.go:267` logs `requestUrl` as `r.URL.Path`, not the matched route template.

Impact: production HTTP logs include request id, status, and duration, but authenticated user correlation is missing from the top-level access log. Raw paths also create high-cardinality log fields for repository/user/resource ids and make route-level aggregation harder than the Prometheus metrics path labels.

### High - PLUE-OBS-002 - Client-visible error taxonomy is incomplete and not consistently branchable

`APIError` supports a `code`, but most constructors omit it. The iOS app can branch on `rate_limit_exceeded`, `quota_exceeded`, and field validation details, but common failures such as bad request, unauthorized, forbidden, not found, conflict, payload too large, gateway timeout, and internal error are returned without a stable top-level code.

Evidence:

- `/Users/williamcory/plue/pkg/errors/errors.go:29` through `/Users/williamcory/plue/pkg/errors/errors.go:66` define common error constructors without setting `Code`.
- `/Users/williamcory/plue/pkg/errors/errors.go:73` through `/Users/williamcory/plue/pkg/errors/errors.go:75` define only `quota_exceeded` and `rate_limit_exceeded` as top-level error codes.
- `/Users/williamcory/plue/internal/routes/json_body.go:43` through `/Users/williamcory/plue/internal/routes/json_body.go:49` map JSON decode failures to `BadRequest(...)`, which has no code.
- `/Users/williamcory/plue/internal/routes/auth.go:582` through `/Users/williamcory/plue/internal/routes/auth.go:591` writes route errors as-is or wraps them in uncoded internal errors.

Impact: mobile clients must infer behavior from HTTP status or message strings for most failures. That is brittle for retry, reauth, conflict, validation, and user-facing recovery flows.

### High - PLUE-OBS-003 - Audit logging exists, but approval decisions and revoke flows are not audited

The audit table, service, and admin read API exist, but several security-sensitive actions from the checklist are not written to `audit_log`.

Evidence:

- `/Users/williamcory/plue/internal/services/audit.go:59` writes audit records via `InsertAuditLog`.
- `/Users/williamcory/plue/internal/routes/admin_audit.go:23` through `/Users/williamcory/plue/internal/routes/admin_audit.go:61` exposes `GET /api/admin/audit-logs`.
- `/Users/williamcory/plue/cmd/server/main.go:1454` through `/Users/williamcory/plue/cmd/server/main.go:1455` mounts the admin audit API.
- `/Users/williamcory/plue/cmd/server/main.go:390` through `/Users/williamcory/plue/cmd/server/main.go:392` constructs `ApprovalHandler` with only `Service`, not `AuditService`.
- `/Users/williamcory/plue/internal/routes/approvals.go:120` through `/Users/williamcory/plue/internal/routes/approvals.go:125` decides an approval and returns the item without audit logging.
- `/Users/williamcory/plue/internal/routes/user.go:197` through `/Users/williamcory/plue/internal/routes/user.go:202` revokes a user session without audit logging.
- `/Users/williamcory/plue/internal/routes/oauth2.go:354` through `/Users/williamcory/plue/internal/routes/oauth2.go:360` revokes an OAuth token without audit logging.
- `/Users/williamcory/plue/internal/routes/oauth2.go:378` through `/Users/williamcory/plue/internal/routes/oauth2.go:384` revokes all OAuth tokens for an app/user without audit logging.

Impact: incident response cannot reconstruct who approved a gate or revoked credentials from the durable audit trail, even though those actions are security-sensitive.

### High - GUI-OBS-001 - No automatic crash or error reporter is wired for the app, and the existing server telemetry endpoint cannot accept iOS reports

The GUI repository has no wired Sentry, Crashlytics, or custom remote error reporter. The documented bug-reporting path is manual log/crash-report collection. Runtime failures in the iOS auth and chat flows are converted to local UI state, but there is no remote error submission path. The backend has `/api/telemetry/errors`, but it currently accepts only `web` and `cli`, so an iOS client report would be dropped.

Evidence:

- `/Users/williamcory/gui/project.yml:14` through `/Users/williamcory/gui/project.yml:17` list only the `ViewInspector` package dependency, with no crash/error reporter SDK.
- `/Users/williamcory/gui/README.md:41` documents manual collection of `app.log` and native crash reports.
- `/Users/williamcory/gui/Shared/Sources/SmithersAuth/AuthViewModel.swift:93` through `/Users/williamcory/gui/Shared/Sources/SmithersAuth/AuthViewModel.swift:109` convert sign-in errors to local auth phase state.
- `/Users/williamcory/gui/ios/Sources/SmithersiOS/Chat/AgentChatView.swift:227` through `/Users/williamcory/gui/ios/Sources/SmithersiOS/Chat/AgentChatView.swift:237` convert chat send errors to local `errorMessage`.
- `/Users/williamcory/plue/cmd/server/main.go:902` through `/Users/williamcory/plue/cmd/server/main.go:905` mounts `/api/telemetry/errors`.
- `/Users/williamcory/plue/internal/routes/telemetry.go:53` through `/Users/williamcory/plue/internal/routes/telemetry.go:56` drops any telemetry report whose `client` is not `web` or `cli`.

Impact: production crashes and high-value client errors are not visible unless a user or developer manually collects and sends logs. The existing backend telemetry path is not currently usable by the iOS app.

### Medium - PLUE-OBS-004 - Request ids are generated and propagated, but DB-level telemetry is not request-correlated

Request ids are generated at the HTTP edge, echoed in the response, attached to request loggers, and propagated to repo-host calls. At the database layer, however, the pgx tracer records only aggregate query-duration metrics. There are no DB-level logs or spans carrying request id, route, trace id, or user context.

Evidence:

- `/Users/williamcory/plue/cmd/server/main.go:682` installs `chiMiddleware.RequestID`.
- `/Users/williamcory/plue/cmd/server/main.go:684` installs response header echoing for `X-Request-Id`.
- `/Users/williamcory/plue/internal/middleware/structured_logging.go:351` through `/Users/williamcory/plue/internal/middleware/structured_logging.go:354` attaches `request_id` to request-scoped loggers.
- `/Users/williamcory/plue/internal/repohost/client.go:1244` through `/Users/williamcory/plue/internal/repohost/client.go:1250` propagates `X-Request-Id` to repo-host.
- `/Users/williamcory/plue/internal/database/pool.go:31` through `/Users/williamcory/plue/internal/database/pool.go:32` installs `NewMetricsTracer` as the pgx tracer.
- `/Users/williamcory/plue/internal/database/tracer.go:31` through `/Users/williamcory/plue/internal/database/tracer.go:58` records only classified query duration metrics.

Impact: a slow or failed production request can be correlated through HTTP logs and some outbound HTTP, but individual database activity cannot be tied back to the request id or trace during debugging.

### Medium - PLUE-OBS-005 - OpenTelemetry hooks cover HTTP, but DB and internal slow paths do not create spans

The server initializes OpenTelemetry and instruments inbound/outbound HTTP. There are no manual spans around database calls, approval/workflow decisions, or other internal slow paths, and the pgx tracer is metrics-only.

Evidence:

- `/Users/williamcory/plue/cmd/server/main.go:79` through `/Users/williamcory/plue/cmd/server/main.go:93` initializes OpenTelemetry.
- `/Users/williamcory/plue/cmd/server/main.go:686` installs inbound `otelhttp` middleware.
- `/Users/williamcory/plue/cmd/server/main.go:1586` through `/Users/williamcory/plue/cmd/server/main.go:1613` configures the Cloud Trace exporter and global tracer provider when enabled.
- `/Users/williamcory/plue/internal/repohost/client.go:182` through `/Users/williamcory/plue/internal/repohost/client.go:190` wraps repo-host HTTP transport in `otelhttp`.
- `/Users/williamcory/plue/internal/sandbox/client.go:61` through `/Users/williamcory/plue/internal/sandbox/client.go:66` wraps sandbox HTTP transport in `otelhttp`.
- `/Users/williamcory/plue/internal/database/tracer.go:19` through `/Users/williamcory/plue/internal/database/tracer.go:58` implements query duration metrics, not OTEL spans.

Impact: traces show request entry and instrumented outbound HTTP, but the trace waterfall will not identify database or internal service work as the source of latency.

### Medium - PLUE-OBS-006 - Rate-limit rejects are only inferable from generic HTTP 429 metrics

Prometheus metrics and the `/metrics` endpoint are present, and HTTP requests are counted by method, route template, and status. Rate-limit middleware returns structured 429s, but it does not increment a dedicated limiter rejection counter with limiter scope. Different limiter scopes therefore collapse into generic HTTP 429 observations.

Evidence:

- `/Users/williamcory/plue/cmd/server/main.go:690` through `/Users/williamcory/plue/cmd/server/main.go:694` installs HTTP metrics middleware.
- `/Users/williamcory/plue/cmd/server/main.go:713` through `/Users/williamcory/plue/cmd/server/main.go:718` exposes `/metrics`.
- `/Users/williamcory/plue/internal/middleware/metrics.go:90` through `/Users/williamcory/plue/internal/middleware/metrics.go:103` records request counts and durations by route/status.
- `/Users/williamcory/plue/internal/middleware/rate_limit.go:121` through `/Users/williamcory/plue/internal/middleware/rate_limit.go:133` returns `rate_limit_exceeded` without recording a rate-limit-specific metric.
- `/Users/williamcory/plue/internal/middleware/rate_limit.go:192` through `/Users/williamcory/plue/internal/middleware/rate_limit.go:201` defines distinct limiter scopes that are not visible in the metrics emitted at rejection time.

Impact: operators can alert on 429s per route, but cannot directly tell which limiter scope is rejecting, distinguish quota from limiter behavior, or measure reject volume by limiter.

### Medium - GUI-OBS-002 - iOS target bypasses the app logging facade and mixes `NSLog` with direct `Logger`

The macOS app has an `AppLogger` facade with a consistent subsystem and categories, and it also writes structured file logs. The iOS target does not include `AppLogger.swift`. Shared/iOS code uses `NSLog` in several paths, while terminal code uses a direct `Logger(subsystem:category:)`.

Evidence:

- `/Users/williamcory/gui/AppLogger.swift:147` through `/Users/williamcory/gui/AppLogger.swift:180` define `CategoryLogger`, OSLog emission, and file logging.
- `/Users/williamcory/gui/AppLogger.swift:186` through `/Users/williamcory/gui/AppLogger.swift:224` define subsystem `com.smithers.gui` and standard categories.
- `/Users/williamcory/gui/project.yml:25` through `/Users/williamcory/gui/project.yml:33` include `AppLogger.swift` in the macOS target.
- `/Users/williamcory/gui/project.yml:253` through `/Users/williamcory/gui/project.yml:287` define the iOS target sources and do not include `AppLogger.swift`.
- `/Users/williamcory/gui/ios/Sources/SmithersiOS/ContentShell.iOS.swift:386` logs terminal bootstrap failure with `NSLog`.
- `/Users/williamcory/gui/Shared/Sources/SmithersStore/SmithersStore.swift:118`, `/Users/williamcory/gui/Shared/Sources/SmithersStore/SmithersStore.swift:127`, and `/Users/williamcory/gui/Shared/Sources/SmithersStore/SmithersStore.swift:246` use `NSLog`.
- `/Users/williamcory/gui/TerminalSurface.swift:295` creates a direct `Logger` for terminal logs.

Impact: iOS logs do not consistently flow through the app logging facade, standard categories, metadata formatting, or file writer. Developers must search mixed log sources and formats during production debugging.

### Medium - GUI-OBS-003 - iOS has no local telemetry counters for reconnects, chat sends, or auth failures

The macOS devtools store has local counters, but the iOS target does not include that store. iOS/shared runtime paths log or update UI state, but they do not expose counters a developer can check during a dev session for websocket/runtime reconnects, chat sends, or auth failures.

Evidence:

- `/Users/williamcory/gui/LiveRunDevToolsStore.swift:91` through `/Users/williamcory/gui/LiveRunDevToolsStore.swift:93` define local counters for events, reconnects, and decode errors.
- `/Users/williamcory/gui/LiveRunDevToolsStore.swift:236` increments `eventsApplied`, and `/Users/williamcory/gui/LiveRunDevToolsStore.swift:552` increments `reconnectCount`.
- `/Users/williamcory/gui/project.yml:25` through `/Users/williamcory/gui/project.yml:33` include `LiveRunDevToolsStore.swift` in the macOS target, while `/Users/williamcory/gui/project.yml:253` through `/Users/williamcory/gui/project.yml:287` define the iOS target without it.
- `/Users/williamcory/gui/TerminalSurface.swift:290` keeps `reconnectAttempts` private, and `/Users/williamcory/gui/TerminalSurface.swift:438` through `/Users/williamcory/gui/TerminalSurface.swift:442` increments/logs it without exposing a dev-readable telemetry surface.
- `/Users/williamcory/gui/Shared/Sources/SmithersStore/SmithersStore.swift:124` through `/Users/williamcory/gui/Shared/Sources/SmithersStore/SmithersStore.swift:132` handles reconnect events by posting notifications and refreshing cache, with no counter.
- `/Users/williamcory/gui/ios/Sources/SmithersiOS/Chat/AgentChatView.swift:210` through `/Users/williamcory/gui/ios/Sources/SmithersiOS/Chat/AgentChatView.swift:239` sends chat messages without incrementing success/failure counters.
- `/Users/williamcory/gui/Shared/Sources/SmithersAuth/AuthViewModel.swift:70` through `/Users/williamcory/gui/Shared/Sources/SmithersAuth/AuthViewModel.swift:109` handles auth failures by setting phase state, with no auth failure counter.

Impact: during development or a field debugging session, there is no simple local telemetry readout for reconnect churn, chat send volume/failures, or auth failure frequency on iOS.

## Coverage Observed

- `plue` has structured JSON request logging and request ids at the HTTP edge.
- `plue` echoes request ids in response headers and propagates them to repo-host HTTP calls.
- `plue` exposes Prometheus metrics at `/metrics` and records route/status HTTP counters and duration histograms.
- `plue` initializes OpenTelemetry when configured and instruments inbound HTTP plus repo-host/sandbox outbound HTTP.
- `plue` has an `audit_log` table, `AuditService`, and admin API for reading audit records.
- `gui` macOS has an `AppLogger` facade with OSLog categories and structured file logging.
