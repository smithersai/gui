# 0180 - Privacy / PII Audit

Date: 2026-04-24
Scope: `/Users/williamcory/gui` and `/Users/williamcory/plue`
Status: App Store / GDPR / CCPA responses are blocked until the High findings below are resolved or explicitly accepted with legal/product sign-off.

Apple reference used for the App Store draft: https://developer.apple.com/app-store/app-privacy-details/. Apple defines collected data as data transmitted off-device and retained by the developer or third-party partners beyond real-time request handling, and requires declaration even when data is only used for app functionality.

## Severity Counts

- Critical: 0
- High: 4
- Medium: 5
- Low: 1

## High Findings

### H1. No user-initiated account deletion; admin delete only tombstones the user

Current state:

- No self-service delete-account route was found in `plue`.
- Admin deletion is `DELETE /api/admin/users/{username}`, but `internal/db/users.sql.go` implements it as an `UPDATE` that sets `is_active=false` and `prohibit_login=true`.
- Because the user row is not hard-deleted, `ON DELETE CASCADE` references do not run for email addresses, OAuth accounts, tokens, sessions, workspaces, agent sessions, billing rows, or related content.
- `gui` sign-out clears local auth/cache state, but it does not request account deletion or server-side PII deletion.

Impact:

- Blocks GDPR / CCPA deletion readiness.
- Likely blocks App Store account-deletion expectations if account creation/sign-in is available in the app.
- A "deleted" account can still leave email, username, display name, billing metadata, OAuth profile data, user content, audit names, logs, and soft-deleted agent data in Postgres.

### H2. App Store privacy declaration is under-scoped

Current state:

- `gui/ios/Sources/SmithersiOS/PrivacyInfo.xcprivacy` declares only `EmailAddress` and `UserID`.
- Actual repo evidence shows collection or retention of account names, GitHub identity, avatar URLs, OAuth/integration tokens, app/API tokens, billing/subscription data, IP addresses, user-agent/device/OS diagnostics, workflow/user content, repo/workspace metadata, audit events, telemetry, logs, webhook payloads, and possibly search/browser data depending on shipped browser-surface behavior.

Impact:

- Blocks accurate App Store Privacy Nutrition Label answers.
- The manifest and App Store Connect answers need to be reconciled with the server-side collection map, not only native local storage.

### H3. Audit logs, service logs, and client telemetry can contain PII

Current state:

- `audit_log` stores `actor_name`, `target_name`, `metadata`, and `ip_address` for 90 days. `actor_id` is `ON DELETE SET NULL`, but names/IP/metadata remain.
- `internal/services/email.go` logs raw email addresses in multiple success/failure paths.
- `internal/routes/telemetry.go` accepts client error reports and logs `error_message`, `stack`, `url`, `user_agent`, `user_id`, `username`, `command`, `os`, and `arch`.
- `gui/Shared/Sources/SmithersLogging/AppLogger.swift` redacts sensitive metadata keys such as token/secret/password, but the free-form log message string and non-sensitive metadata keys such as `email`, `workspace`, and `path` are not generally value-redacted.
- Workflow runner logs redact known repository secrets and the agent token before insertion, but this is exact-value secret redaction only; arbitrary PII in prompts, command output, error text, URLs, or payloads is not generally removed.

Impact:

- A forensic dump of audit logs, app logs, Cloud Logging, or telemetry can leak PII.
- Blocks a confident "logs redact PII" answer.

### H4. Retention and deletion rules are incomplete for several PII-bearing tables

Current state:

- `access_tokens` has no `expires_at`; an existing test is skipped because the schema does not support token expiry.
- OAuth2 access/refresh/authorization-code cleanup queries exist, but no runtime caller was found in the auth cleaner path.
- `agent_sessions` has `deleted_at`, so delete is a soft tombstone while `agent_messages`, `agent_parts`, and related devtools snapshots can still retain content.
- No clear retention sweeper was found for workflow logs, workflow task payloads, agent messages/parts, devtools snapshots, webhook payloads/deliveries, billing raw payloads, repository variables, or workspace session SDP/ICE data.

Impact:

- Blocks retention-period answers for GDPR / CCPA and App Store review.
- Makes account deletion semantics ambiguous because soft-deleted content can remain linked to a user or workspace.

## Medium Findings

### M1. Postgres PII columns are mostly plaintext at the application layer

Current state:

- Sensitive tokens/secrets are often hashed or encrypted: OAuth account access/refresh tokens, Linear OAuth payloads, user AI keys, webhook secrets, repository secrets, OAuth2 token hashes, session keys, and API token hashes.
- Core PII columns are plaintext: `users.email`, `users.display_name`, `users.avatar_url`, `users.username`, `email_addresses.email`, waitlist GitHub username/avatar, billing customer email/name, audit names/IP, workflow/user content, webhook payloads, logs, and repo/change author emails.
- Terraform config shows Cloud SQL connection encryption and the app uses Cloud SQL Auth Proxy in Kubernetes. The repo does not define per-column encryption for ordinary PII, nor a customer-managed key policy for database-at-rest encryption.

Impact:

- "Encrypted at rest" should be answered as platform-managed database/disk encryption only, not app-level encrypted PII columns.
- Column-level PII inventory should be maintained before privacy questionnaire submission.

### M2. GUI local data is protected unevenly

Current state:

- OAuth2 access/refresh tokens are stored in Keychain using `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and non-synchronizable storage.
- UserDefaults/AppStorage usage reviewed is preferences only: vim mode, developer tools, sidebar, search engine, shortcut settings, onboarding state, remote sandbox flag, layout/log UI preferences.
- Local SQLite at Application Support stores recent workspace paths/display names, workspace sessions, chat session JSON, run IDs, terminal tab metadata, titles/previews/snapshots, and working directories. No SQLite encryption was found.
- Local file logs live under `~/Library/Logs/SmithersGUI/app.log`, rotate at 5 MB, and prune after 7 days.

Impact:

- Token storage is appropriate, but local paths/session/chat/log data are readable to the local user/processes with filesystem access.
- This is likely not App Store "collection" when it never leaves device, but it is still user data at rest for the security review.

### M3. Data in transit is mostly TLS, with documented plaintext exceptions

Current state:

- Production GUI endpoints use HTTPS (`https://app.smithers.sh`, `https://jjhub.smithers.ai`) and iOS ATS disallows arbitrary loads.
- iOS ATS exceptions allow insecure loads for `localhost` and `127.0.0.1` for E2E/local flows.
- OAuth loopback callbacks and local workflow previews use `http://127.0.0.1`.
- Helm ingress is TLS-enabled. Inside Kubernetes, the repo-host service URL is HTTP, and the app connects plaintext to the local Cloud SQL proxy on `127.0.0.1`; proxy-to-Cloud SQL transport is configured encrypted.
- The embedded browser can navigate to user-entered `http://` URLs, and localhost-style inputs resolve to HTTP.
- SMTP transport requires SMTPS or STARTTLS.

Impact:

- Public user data paths appear TLS-protected, but plaintext loopback/dev/internal-cluster exceptions must be documented and scoped.

### M4. Third-party sharing map is broad and not centralized

Third parties and likely data flows:

- GitHub: OAuth profile/email, GitHub App installation/repo metadata, webhooks, repository/user identifiers.
- WorkOS/Auth0: identity profile, email, name, avatar, access tokens during login.
- Linear: encrypted OAuth payloads and integration metadata.
- Stripe: customer ID, email, name, subscription/purchase/usage status, raw webhook/subscription payloads.
- SendGrid/AWS SES/SMTP: recipient email, subject/body for transactional mail.
- Sentry in the web UI when enabled: user id, username, email, viewer context, errors, stack traces, URLs with query stripped.
- Google Cloud: Cloud SQL, Cloud Storage, Cloud Logging, Cloud Trace/OpenTelemetry, Secret Manager.
- Freestyle/sandbox infrastructure: workspace/VM/provisioning metadata, repo access material as configured.
- User-selected search providers/websites from the embedded browser surface.

Impact:

- App Store answers must include third-party partners whose code/services collect data through the app.
- No ad network or data broker path was found in the reviewed code.

### M5. Browser/search disclosure needs a product decision

Current state:

- `BrowserSurfaceView` can navigate the open web, preserves explicit schemes, uses HTTP for localhost-style targets, uses HTTPS for normal domains, and sends typed searches to the selected search provider.
- The WebKit view uses the default website data store, so website cookies/storage can exist locally.
- No evidence was found that Smithers backend intentionally collects browser history or search history, but surface/session persistence may retain URLs locally and search providers receive queries directly.

Impact:

- Apple guidance says data collected via web traffic must be declared unless the app is enabling navigation of the open web.
- Decide whether the shipped feature is "open web navigation" only, or whether Smithers collects/persists browser/search data in a way that needs declaration.

## Low Finding

### L1. Reviewed plue auth route contains merge conflict markers

Current state:

- `plue/internal/routes/auth.go` contains unresolved conflict markers around the WorkOS/Auth0 callback region in the reviewed working tree.

Impact:

- This does not change the PII inventory by itself, but the auth flow should be re-reviewed after the merge conflict is resolved because login/profile fields may change.

## User Data Inventory

| Data type | Where collected / stored | Current retention | Access / sharing |
| --- | --- | --- | --- |
| Email address | `users.email`, `email_addresses.email`, verification/reset token rows, billing customer email, waitlist, Sentry user context when enabled, transactional email providers | User/account rows retained indefinitely under current tombstone delete; verification/reset/session-like rows cleaned when expired; audit/log copies vary | App/backend operators and DB admins; email provider; Stripe; Sentry if enabled; public APIs do not expose email except authenticated `/api/user` |
| Display name / real name | `users.display_name`, WorkOS/Auth0/GitHub profile import, Stripe customer name, public profile response | Retained with user row; admin delete does not clear | Public profile can expose display name/avatar/bio; backend operators; Stripe/Sentry where configured |
| Username / GitHub username | `users.username`, GitHub OAuth profile, waitlist GitHub username, audit actor/target names, logs | Retained with user row; audit 90 days; logs vendor/local retention | Public profile and repo/workflow collaboration surfaces; backend operators; GitHub |
| Avatar URL | `users.avatar_url`, `oauth_accounts.profile_data`, waitlist GitHub avatar URL | Retained with user/profile rows | Public profile; backend operators; GitHub/identity providers |
| OAuth and integration tokens | GUI Keychain access/refresh tokens; plue encrypted upstream OAuth tokens; Linear encrypted payloads; OAuth2 token hashes; session cookies; API token hashes; SSE ticket hashes | GUI until sign-out/local deletion; server session default 30 days; OAuth2 access 1 hour and refresh 90 days but cleanup wiring incomplete; GitHub/Linear upstream tokens retained until disconnect/hard delete | Local device Keychain; app backend; identity/integration providers; DB admins see ciphertext/hashes for protected columns |
| API keys/secrets | `user_ai_keys.api_key_encrypted`, repository secrets encrypted, webhook secrets encrypted, repository variables plaintext, SSH public keys | No unified retention beyond owner/resource lifetime | Backend operators; external LLM/AI providers if user key is used; repo/workflow runtime |
| IP address / network / device info | `audit_log.ip_address`, structured request logs `remoteIp`, telemetry `user_agent`/OS/arch/command, workspace session SDP/ICE candidates | Audit 90 days; Cloud Logging retention not defined in repo; workspace session retention unclear | Backend operators; Google Cloud Logging/Trace; may expose network candidates in DB dumps |
| Billing / purchase data | `billing_accounts`, `billing_subscriptions`, `billing_usage_counters`, Stripe payloads | Retention unclear; no delete/account cascade under tombstone delete | Stripe; backend operators; billing/admin surfaces |
| User content | Repositories/issues/changes, workflow task payloads, workflow logs, agent sessions/messages/parts, approvals, tickets, devtools snapshots, webhook payloads, workspace sessions | Mostly indefinite or unclear; agent sessions soft-delete; artifact/cache cleaners do not cover all tables | Backend operators; collaborators depending on repo/workspace access; external workflow tools/providers as configured |
| Diagnostics / usage events | audit log, request logs, telemetry endpoint, local GUI logs, Sentry web UI when enabled, Cloud Trace/Prometheus | Audit 90 days; GUI logs 7 days/5 MB; cloud/vendor retention not defined in repo | Backend operators; Google Cloud; Sentry if enabled |
| Browser/search data | WebKit default website data store; typed searches sent to selected provider; possible local session persistence of URLs | Local WebKit/store retention; Smithers server collection not confirmed | User-selected websites/search providers; local device user/processes |
| Local workspace paths/session state | GUI SQLite `recent_workspaces`, `workspace_sessions`, `workspace_chat_sessions`; GUI logs | Local until app cleanup/sign-out/cache wipe; SQLite retention not time-bound | Local device user/processes; not App Store-collected unless transmitted off-device |

## Data In Transit

- Public app/API traffic: HTTPS in production.
- iOS ATS: arbitrary loads disabled; explicit insecure exceptions for localhost and `127.0.0.1`.
- OAuth loopback/local preview: plaintext HTTP on loopback only.
- Backend-to-database: app connects to local Cloud SQL Auth Proxy over loopback; Cloud SQL transport is configured encrypted.
- Backend internal services: at least repo-host traffic uses HTTP inside the cluster.
- Email: SMTPS or STARTTLS required.
- Embedded browser: user-directed HTTP/HTTPS web navigation is possible.

## Data At Rest

### plue / Postgres

PII-bearing columns include:

- `users`: username, lower_username, email, lower_email, display_name, bio, search_vector, avatar_url, wallet_address, status/admin flags, notification preference, last_login_at.
- `email_addresses`, `email_verification_tokens`: email/lower_email and token hashes.
- `oauth_accounts`: provider user id, encrypted access/refresh tokens, profile JSON including GitHub id/login/name/avatar.
- `auth_sessions`: username, session data, user id.
- `access_tokens`: token hash, token suffix, token name, scopes, last_used_at.
- `audit_log`: actor/target names, target ids, metadata JSON, IP address.
- `billing_*`: Stripe customer id/email/name, subscription ids/status/raw payloads, usage counters.
- `workflow_tasks`, `workflow_logs`, `agent_sessions`, `agent_messages`, `agent_parts`, `devtools_snapshots`: user/workflow content, prompts, tool output, logs, payload JSON.
- `workspace_sessions`: SDP/ICE/network data and terminal/session metadata.
- `webhook_deliveries` / GitHub webhook jobs: payloads, response bodies, repo/user metadata.
- `repositories` / `changes`: owner/repo metadata, author name/email.
- waitlist and GitHub App tables: GitHub username/avatar/account/repo metadata.

Encryption notes:

- Token/secret protection is mixed: some columns are encrypted or hashed, but ordinary PII and user content are plaintext to the application.
- Infrastructure indicates Cloud SQL-managed storage and encrypted network transport, but no app-level column encryption for general PII was found.

### gui / local device

- Tokens: Keychain, `WhenUnlockedThisDeviceOnly`, non-synchronizable.
- UserDefaults: reviewed keys are preferences only; no email/token/avatar/user id found.
- SQLite: workspace paths, display names, sessions, chat/session JSON, run metadata in plaintext.
- Logs: local JSON log file, plaintext with partial metadata redaction.

## User-Initiated Deletion

Current support:

- Local sign-out clears Keychain tokens and store/cache state.
- Server-side self-service delete account was not found.
- Admin user delete is a tombstone and does not delete/anonymize PII.

Required gap closure:

- Add a documented user deletion flow or data-request process.
- Decide hard delete vs anonymization per table.
- Ensure audit/legal retention exceptions are explicit.
- Add cascades or scrubbers for content tables, soft-deleted agent sessions, billing data, webhook payloads, devtools snapshots, logs, and third-party provider data.

## Audit Log PII

`audit_log` contains PII by design: actor names, target names, metadata, IP address, and timestamps. Retention is configured as 90 days. A DB dump would expose historical usernames, target names, IP addresses, and possibly metadata values after user deactivation because the row keeps name/IP fields even if `actor_id` is nulled.

## Logs / Redaction

Current protections:

- Structured request logging avoids request bodies and query strings.
- Workflow log insertion redacts known repository secret values and agent token values.
- GUI log metadata redacts keys containing token/secret/password-like names.

Gaps:

- No general PII scrubber for log messages, error strings, stack traces, telemetry payloads, audit metadata, or non-secret metadata keys.
- Email service logs include raw email addresses.
- Client telemetry can include URLs, stack traces, commands, user agent, user id, and username.
- Vendor log retention and access policy are not documented in repo.

## Third-Party Sharing

No advertising SDK or ad network was found. Third-party/service-provider sharing that should be disclosed or documented:

- GitHub: OAuth identity, email/profile, repository and webhook data.
- WorkOS/Auth0: login identity profile and tokens.
- Linear: OAuth/integration data.
- Stripe: billing/customer/subscription data.
- SendGrid, AWS SES, or SMTP provider: transactional email data.
- Sentry, if enabled in the web UI: diagnostics plus user id/username/email context.
- Google Cloud: database, storage, logging, tracing, secrets, metrics.
- Freestyle/sandbox infrastructure: VM/workspace provisioning metadata and access material.
- User-selected websites/search engines through the embedded browser/open-web surface.

## App Store Questionnaire Draft

Conservative draft based on repo evidence. "Linked" is generally Yes for server-side data because it is tied to user id/account unless explicitly noted.

| Category | Draft answer | Notes / purpose |
| --- | --- | --- |
| Tracking | No | No ad network, data broker, or cross-app targeted advertising path found. Reconfirm Sentry/search providers are not used for tracking. |
| Contact Info - Name | Yes | Display name, identity-provider name, Stripe customer name. App functionality, account, billing. |
| Contact Info - Email Address | Yes | Account email, verification, notifications, billing, Sentry/email providers. App functionality, security, billing. |
| Contact Info - Phone Number | No | Not found. |
| Contact Info - Physical Address | No | Not found. |
| Contact Info - Other Contact Info | No | Not found beyond email/name/avatar/profile URLs. |
| Health & Fitness | No | Not found. |
| Financial Info - Payment Info | No | Payment card/bank details appear handled by Stripe outside the app; not stored by Smithers. |
| Financial Info - Credit Info | No | Not found. |
| Financial Info - Other Financial Info | Yes | Stripe customer/subscription/usage/billing records, but not card data. |
| Location - Precise | No | No GPS/precise location collection found. |
| Location - Coarse | No | No explicit geolocation or IP geolocation found. If IP is used for location, change to Yes. |
| Sensitive Info | No | No special-category sensitive data collection found. |
| Contacts | No | Address book/contact collection not found. |
| User Content - Emails or Text Messages | No | No in-app private messaging or email-content collection found; transactional email body is app-generated. |
| User Content - Photos or Videos | No | No user media upload found; avatar is a URL from identity provider. |
| User Content - Audio Data | No | Not found. |
| User Content - Gameplay Content | No | Not applicable. |
| User Content - Customer Support | No | Not found in app flow; update if support forms are added. |
| User Content - Other User Content | Yes | Repos, workflow prompts/payloads/logs, agent messages/parts, tickets, devtools snapshots, webhook payloads. |
| Browsing History | Yes, conservative | No Smithers server collection found, but the app includes open-web/browser surfaces and local WebKit storage. Product/legal can downgrade to No only if shipped behavior is open-web navigation with no Smithers retention/transmission of viewed URLs. |
| Search History | Yes, conservative | Typed searches are sent to selected third-party search providers. Product/legal can downgrade to No only if this is treated as user-directed open-web traffic and Smithers does not retain/transmit queries beyond real-time handling. |
| Identifiers - User ID | Yes | Smithers user id, username, provider ids, Stripe customer id. |
| Identifiers - Device ID | No | No advertising ID/vendor ID collection found. Recheck telemetry before final submission. |
| Purchases - Purchase History | Yes | Stripe subscriptions/plans/status/usage. |
| Usage Data - Product Interaction | Yes | Audit events, workspace/run/session activity, usage counters. |
| Usage Data - Advertising Data | No | Not found. |
| Usage Data - Other Usage Data | Yes | Metrics, workflow usage, billing usage counters, operational events. |
| Diagnostics - Crash Data | Yes, conservative | Native crash reporter not found, but web Sentry/client error reporting can collect errors/stacks when enabled. Native-only App Store build can downgrade to No if no crash/error reporter ships. |
| Diagnostics - Performance Data | Yes | Cloud Trace/OpenTelemetry/Prometheus/latency metrics and diagnostics. |
| Diagnostics - Other Diagnostic Data | Yes | Server/client error logs, local app logs, telemetry, user-agent/OS/arch. |
| Surroundings - Environment Scanning | No | Not found. |
| Body - Hands | No | Not found. |
| Body - Head | No | Not found. |
| Other Data Types | Yes | IP address, user agent, SDP/ICE/network candidates, local workspace path data if transmitted. |

Default purposes to select where applicable: App Functionality, Security, Diagnostics, Billing/Commerce, Product Personalization where display profile/session continuity is used, and Analytics only if Cloud Trace/metrics/Sentry/client metrics are used to evaluate product behavior rather than only service health.

## Draft Privacy Policy Snippet

Smithers collects account information such as your email address, username, display name, GitHub identity and avatar URL; authentication and integration tokens; billing and subscription records; IP address, user-agent, device/OS, diagnostic and usage data; and the repository, workspace, workflow, prompt, chat, log, ticket, webhook, browser/search, and collaboration content you submit or generate while using the app. We use this information to authenticate you, operate and synchronize workspaces and AI workflows, provide collaboration, billing, support, security and abuse prevention, and diagnose reliability issues; we share it with service providers that perform those functions, including cloud hosting/logging providers, identity and OAuth providers, GitHub/Linear integrations, transactional email providers, Stripe, Sentry when enabled, Freestyle/sandbox infrastructure, and websites or search providers you choose to access from the app. Tokens and secrets are stored in the macOS/iOS Keychain or encrypted/hashed server-side where implemented, while other account, content, billing, audit, and diagnostic records remain in our databases and logs according to operational retention; based on the code reviewed, Smithers does not sell personal data or use it for cross-app tracking or advertising.
