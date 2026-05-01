# iOS And Remote Sandboxes — Independent Validation Checklist

Companion to `ios-and-remote-sandboxes.md` and `ios-and-remote-sandboxes-execution.md`. Produced by ticket [0099](../tickets/0099-design-independent-validation.md). Consumed by the `ticket-implement` workflow's review step (`.smithers/workflows/ticket-implement.tsx`) — the review agent loads this doc, finds the ticket under review in the per-ticket table, and runs the applicable universal + per-category + per-ticket checks in addition to "tests pass."

"Tests pass" is necessary but not sufficient. A ticket can pass its own tests without proving what it claimed. The checks below are the counter. They describe what an independent reviewer — human or agent — looks at beyond the implementer's own assertions.

## 1. Universal checks

Applied to every ticket in this initiative, regardless of category.

1. **Reference integrity.** Every file path, line reference, route path, function/method name, Postgres table, Postgres column, SQL query name, migration filename, or external symbol cited in the ticket's Context / Problem / References / Scope sections must actually exist and say what the ticket claims. A simple grep (or `Read` at the cited line) against the current tree (`/Users/williamcory/gui/` for gui tickets, `/Users/williamcory/plue/` for plue tickets) must succeed for each. This check was missed in an early pass; 0095 originally cited the wrong header location. If a referenced line has since moved, the ticket must be updated, not the check waived.
2. **Scope match.** The diff matches the ticket's stated Scope. No new files outside the declared scope, no Scope bullet left unimplemented. Scope creep and scope cut are both rejections.
3. **RPC / wire-format documentation.** Any new RPC, HTTP route, SSE event kind, WebSocket control message, guest-agent method, or Electric shape is documented in the spec it touches — either the main spec (`ios-and-remote-sandboxes.md`), the production-shapes note (`ios-and-remote-sandboxes-production-shapes.md`), or a named sibling doc. Code-only additions with no spec entry are rejected.
4. **Error-taxonomy presence.** Any new structured error class is listed in the observability doc produced by [0098](../tickets/0098-design-observability.md) (`ios-and-remote-sandboxes-observability.md`). If that doc does not yet exist, the ticket declares the new error class(es) in its own body, and the reviewer opens a tracking note so 0098 picks them up.
5. **Metric presence.** Any new metric (counter, gauge, histogram) is listed in the observability doc with name, type, unit, labels, and emission site. Same backfill rule as #4 while 0098 is in flight.
6. **Mock discipline.** Review every test introduced by the ticket:
   - Tests that exercise a real integration (real plue + Postgres, real Electric stack, real SSH into a sandbox, real PTY bytes) must NOT stub the thing being proved. Mocking the surface under test is a rejection.
   - Tests that cross an expensive boundary the ticket is NOT claiming to prove (e.g. a unit test that happens to need a sandbox boot) must mock that boundary. Unmocked heavy dependencies in tests that claim to be unit tests are a rejection.
   - Specifically flagged: PTY byte streams (mocking is correct for FFI unit tests, incorrect for the terminal integration PoC); network disconnect (mocking the socket close is correct for logic tests, incorrect for reconnection PoCs).
7. **Commit / PR hygiene.** Every commit message and the PR description references the ticket number (e.g. `0110`). Co-authored-by trailers are preserved. No `--amend` of landed commits. No hook skips.
8. **Feature flag gate (when required).** If the ticket implements behavior that the rollout plan ([0101](../tickets/0101-design-rollout-plan.md)) says is gated, the code reads the corresponding flag name from plue's `/api/feature-flags` (registered by [0112](../tickets/0112-plue-add-new-feature-flags.md)) and defaults to off. No hardcoded `true`.
9. **Cross-link coherence.** Anything the ticket claims is covered by a sibling ticket (e.g. "see 0131 for protocol negotiation") must be accurate: the sibling exists, its Scope actually covers the claim, and it is not tombstoned (no 0119 / no 0127–0129 / no 0137 references).
10. **No forbidden assumption.** Tickets must not assume desktop-local work is in this initiative. Desktop-local lives in a sibling spec (see `ios-and-remote-sandboxes.md` — "Desktop-local mode — tracked in a separate spec"). References to desktop-local are allowed as out-of-scope notes; implementation that depends on it blocks.

## 2. Per-category checks

Ticket categories (mirrors the structure in [0099's Scope](../tickets/0099-design-independent-validation.md) and the [execution plan](ios-and-remote-sandboxes-execution.md)):

- **PoC** — 0092, 0093, 0094, 0095, 0096, 0102, 0103, 0104.
- **Design** — 0097, 0098, 0099, 0100, 0101, 0108, 0133.
- **Plue implementation** — 0105, 0106, 0107, 0110, 0111, 0112, 0114, 0115, 0116, 0117, 0118, 0130, 0131, 0132, 0134, 0135, 0136.
- **Client implementation** — 0109, 0113 (umbrella), 0120, 0121, 0122, 0123, 0124, 0125, 0126, 0138.

### 2.1 PoC tickets

A PoC exists to make an architectural claim cheap to falsify. A PoC without a sharp test is not a PoC.

- **Proves the claim end-to-end.** The PoC's test reaches from the claim's starting edge to its ending edge. No stubbed middles. For PoC-A1 (0092) that means real libghostty XCFramework → SwiftUI view → canned PTY bytes → asserted terminal-cell-buffer state. For PoC-A2 (0093) that means real plue + Postgres + Electric → bearer-token-authed shape subscribe → delta delivery → offset resume. If a layer is stubbed, the stub must be between the claim's ending edge and the rest of the system, never inside the claim.
- **Deterministic tests.** No flakes tolerated. Tests use canned inputs (byte recordings, fixed fixtures, synthetic tables) so re-running without code changes never changes the verdict. Pixel hashing and wall-clock-sensitive timing assertions are banned unless the PoC is specifically about perf.
- **Minimal implementation.** No premature abstraction. The PoC does exactly what the ticket's Scope lists, nothing more. A PoC that grows a generic framework around the thing being proved is rejected — that code lives in Stage 2 implementation tickets, not in the PoC.
- **README at `poc/<name>/README.md`** with three named sections:
  - **What this proves.** One paragraph, plain English, match the ticket's Goal.
  - **How to run.** Exact commands. CI job name if any.
  - **Prerequisites.** Tool versions, backend services, env vars.
- **Lives in the right repo.** `plue/poc/<name>/` if it proves a plue surface; `gui/poc/<name>/` otherwise. No cross-repo symlinks.
- **Test runs in CI or has a written exception.** On-device iOS runs may be developer-local (documented in README). Everything else runs in CI.

### 2.2 Design tickets

- **Doc exists at the exact path** stated in the ticket's Goal / Acceptance criteria. Exact filename, exact directory.
- **Every Scope bullet appears in the doc.** Grep-verifiable: reviewer reads the ticket's Scope section and finds a corresponding section or clearly-labeled bullet in the doc. "Implied by context" is not acceptable.
- **Cross-links in and out.** The main spec (`ios-and-remote-sandboxes.md`) or the execution plan (`ios-and-remote-sandboxes-execution.md`) gains a link to the new doc. The new doc links back to the ticket and to sibling specs it depends on (e.g. observability, validation, testing).
- **No implementation work snuck in.** Design tickets produce docs. If the diff includes code changes outside trivial cross-link edits, the code belongs in a sibling ticket.
- **Decisions recorded, not punted.** Where the ticket says "decide", the doc picks one option with a rationale. "Left for follow-up" is only acceptable if the ticket's own Scope labels the decision as follow-up.

### 2.3 Plue implementation tickets

- **Upstream PoC dependency referenced and green.** If the ticket builds on a PoC (e.g. 0110 builds on 0093's shape protocol, 0111 builds on PoC-B5), the ticket body names the PoC and the PoC's CI job is still passing on trunk.
- **Migration paired with down-migration.** New schema (table, column, index) lands as a numbered migration under `plue/db/migrations/`. A down-migration exists where plue's migration tool supports one. Backfills for denormalized columns (e.g. `agent_messages.repository_id` in 0115, `agent_parts.repository_id` + `session_id` in 0118) run inside the migration, not in application startup.
- **Electric auth contract honored.** Any new shape includes `repository_id IN (...)` in its `where` template. Shapes claimed to be user-private additionally require a table-aware `user_id = authed.User.ID` check in `internal/electric/auth.go` — trusting a client-supplied `user_id` is a rejection (see 0116, 0117).
- **Error taxonomy entry hit in tests.** Any structured error class the ticket introduces has a test that asserts plue returns it under the stated condition. Code that declares the error without an exercising test is a rejection.
- **Metric emission verified.** If the ticket introduces a metric, a test (or instrumentation snapshot) confirms it is emitted. Tests may read `/metrics` on the test server or intercept the emit.
- **Feature flag gate present** where the rollout plan requires one (see universal check #8). Specifically: 0107 reads `devtools_snapshot_enabled`; 0110 reads `approvals_flow_enabled`; 0111 reads `run_shape_enabled`; shape-producing tickets (0114–0118) read `electric_client_enabled`.
- **No PII in logs.** Only `user_id` as the principal identity. No email, no display name, no repo contents, no chat messages, no PTY bytes.
- **Route tests cover the full matrix:** auth missing → 401; wrong scope → 403; wrong repo → 403; correct path → success; duplicate/idempotent repeat → documented behavior; malformed body → 400.

### 2.4 Client implementation tickets

- **PoC dependency referenced and green.** 0120 depends on 0093 + 0094 + 0095; 0123 depends on 0092; 0125 depends on 0106 + 0109.
- **FFI surface matches `libsmithers-core`'s production contract.** The C header (`libsmithers/include/smithers.h`) changes are centered on the connection-scoped runtime session from 0120; no new entry points on the legacy `smithers_app_t` / `smithers_client_t` / `smithers_session_t` split.
- **Cross-platform build.** Any change to shared Swift files compiles for both macOS and iOS targets (once 0121 lands). Any change to Zig core compiles for `aarch64-ios`, `aarch64-ios-simulator`, `aarch64-linux-android` (canary from 0104), and current desktop targets.
- **No AppKit imports in shared files.** `import AppKit` stays in `macos/Sources/Smithers/` and the macOS-only shell. Shared SwiftUI files are `#if os(macOS)` / `#if os(iOS)` adapter-gated at most.
- **Token never leaves core.** Auth tokens are read by core from the platform-injected secure-store callback, never passed back out to Swift or logged.
- **Feature flag gate** read via the runtime's flag-query surface (not hardcoded env variables) where the rollout plan demands it.

### 2.5 Design tickets — decision docs

A subset of design tickets (0108, 0133) exist specifically to make a decision the code would otherwise encode implicitly. For these, additionally:

- The doc states the chosen option in its first paragraph.
- The rejected options are named with rationale.
- The follow-up implementation tickets named by the doc exist and reference the decision doc.

## 3. Per-ticket expected-artifact table

Columns: **Ticket**, **Category**, **Expected artifacts** (what a reviewer confirms exists). Reference paths are gui-repo-rooted unless prefixed `plue/`. Tests reference the file(s) a reviewer greps for.

### 3.1 PoC tickets

| Ticket | Title | Expected artifacts |
|---|---|---|
| 0092 | libghostty iOS | `poc/libghostty-ios/` with README "What this proves"; Xcode project or XcodeGen spec building `aarch64-ios-simulator` + `aarch64-ios`; XCTest asserting **terminal-cell-buffer** state (not pixel hash) after deterministic PTY replay; canned PTY-byte fixture. |
| 0093 | Zig Electric shape client | `poc/zig-electric-client/`; Zig unit tests against in-process fake Electric server (chunked snapshots, mid-stream close, delta reordering); integration test harness that stands up plue + Postgres + Electric via docker-compose; negative test for wrong-repo `where` clause rejection; README. |
| 0094 | Zig WebSocket PTY | `poc/zig-ws-pty/`; Zig unit tests for frame encode/decode (fragmented frames, close codes, ping/pong); integration test spawning plue + test sandbox asserting `echo hello` round-trip; negative test for bad-Origin rejection; Origin + `terminal` subprotocol + bearer in handshake; README. |
| 0095 | Zig ↔ Swift FFI | `poc/zig-swift-ffi/`; Zig FFI functions `ffi_new_session`, `ffi_subscribe`, `ffi_unsubscribe`, `ffi_close_session`, `ffi_tick`; SwiftUI mini-app; XCTest asserting N updates observed on main thread within bounded time; TSan + ASan + leak-checker clean; README. |
| 0096 | Electric Go consumer | `plue/poc/electric-go-consumer/` runnable binary; docker-compose fragment in PoC dir (not plue root); `plue/internal/electric/*_test.go` covering valid/invalid bearer, wrong-repo `where`, upstream 502; integration test with fixture insert + delta observed; README. |
| 0102 | Multi-client PTY attach | `plue/poc/multi-client-pty/`; two simulated clients attaching to one `session_id`; test exercising chosen write policy (one-writer / both-writers / last-writer-wins); clean detach without killing peer; **written rationale in README** picking handler-side multiplex vs. guest-agent attach mode or "too expensive for v1"; spec update in `ios-and-remote-sandboxes.md` reflecting the outcome. |
| 0103 | Zig + SQLite on iOS | `poc/zig-sqlite-ios/` adapting `libsmithers/src/persistence/sqlite.zig`; build products for `aarch64-ios-simulator` AND `aarch64-ios`; XCTest passing on simulator; documented on-device smoke run; size-overhead measurement in README. |
| 0104 | Android core canary | `poc/android-core/` Gradle project; Zig build target `aarch64-linux-android` via NDK; JNI bindings for `ffi_*` from 0095; Kotlin emulator app; **CI job that blocks PR on Android build failure**; `.so` size recorded in README. |

### 3.2 Design tickets

| Ticket | Title | Expected artifacts |
|---|---|---|
| 0097 | Testing strategy | `.smithers/specs/ios-and-remote-sandboxes-testing.md` with sections: per-component test layers; boundary conditions (shape reconnect edges, WS handshake failures, SQLite eviction, token expiry mid-request, approval race); iOS device-vs-simulator matrix; Android canary job definition. Cross-linked from main spec. |
| 0098 | Observability | `.smithers/specs/ios-and-remote-sandboxes-observability.md` with: structured log field schema (`trace_id`, `session_id`, `sandbox_id`, `user_id`, `component`, `level`, `event`, `duration_ms`); client + server metric list; mapping to existing `plue/internal/routes/metrics*.go`; error taxonomy enumerating at minimum `network_transient`, `auth_expired`, `auth_revoked`, `quota_exceeded`, `sandbox_unavailable`, `schema_mismatch`, `origin_rejected`; rate-limit policy inputs for 0132. |
| 0099 | Validation (this doc) | `.smithers/specs/ios-and-remote-sandboxes-validation.md`; main spec + execution plan link to it; per-ticket table covering 0092–0118, 0120–0126, 0130–0138. |
| 0100 | Migration strategy | `.smithers/specs/ios-and-remote-sandboxes-migration.md`; file-by-file inventory of `libsmithers/src/`; per-commit sequence keeping desktop app green; per-stage rollback; desktop-app compatibility gates. |
| 0101 | Rollout plan | `.smithers/specs/ios-and-remote-sandboxes-rollout.md`; phase list (desktop-remote private → alpha → iOS alpha → GA); five flag names mapped to owning tickets; explicit "no Android user phase"; kill-switch policy. |
| 0108 | Dispatch-run semantics | `.smithers/specs/ios-and-remote-sandboxes-dispatch-run.md`; Option A or B chosen in first paragraph; client contract described; main spec updated; plue follow-up ticket named if Option B. |
| 0133 | Secure-store threat model | `.smithers/specs/ios-and-remote-sandboxes-secure-store.md` (or agreed path); threat model (assets, trust boundaries, scenarios); decisions on what belongs in 0109 vs. plue vs. new follow-ups; named follow-up tickets if server-side revoke-other-sessions or device list is required. |

### 3.3 Plue implementation tickets

| Ticket | Title | Expected artifacts |
|---|---|---|
| 0105 | Sandbox quota enforcement | Soft-delete state OR hard-delete path decision implemented in `plue/internal/services/workspace_lifecycle.go`; count query called from `workspace_provisioning.go` (`CreateWorkspace`, `ForkWorkspace`); reuse path (`workspace_provisioning.go:131`) does not count; `quota_exceeded` structured error; `*_test.go` covering 100/101 boundary on every create path; spec UX copy updated to match delete choice. |
| 0106 | OAuth2 PKCE for mobile | Browser-facing `/api/oauth2/authorize` in `plue/internal/routes/oauth2.go`; upstream Auth0/WorkOS redirect + resume; PKCE S256 validation; auth-code + redirect-URI binding; public OAuth2 client seeded (migration or seed script) with iOS custom URL scheme + `127.0.0.1` loopback; revoke hardening per RFC 7009; route tests covering code flow + state mismatch + PKCE failure. |
| 0107 | Devtools snapshot surface | Migration creating `devtools_snapshots` with `session_id`, `repository_id`, `timestamp`, `kind`, `payload`; guest-agent `MethodWriteDevtoolsSnapshot` gated on 0131 capability; Electric shape with `repository_id IN (...) AND session_id IN (...)`; `devtools_snapshot_enabled` flag gate; service + route tests; depends-on 0131 referenced. |
| 0110 | Approvals implementation | Migration creating `approvals` (fields per ticket body); `POST /api/repos/{owner}/{repo}/approvals/{id}/decide`; guest-agent `MethodEmitApprovalRequest` gated on 0131 capability; Electric shape `approvals WHERE repository_id IN (...)`; expiry policy implemented; `approvals_flow_enabled` flag gate; fan-out integration test (two fake clients); idempotent-same / conflicting-different decide behavior tested. |
| 0111 | Run shape + route reconciliation | Electric shape on `workflow_runs` (real table name; spec note about "runs"); canonical `/api/repos/.../runs/{id}[/cancel]` + `/api/repos/.../runs/{id}/events` aliases; existing `/actions/runs/...` + `/workflows/runs/...` preserved; `run_shape_enabled` flag gate; tests covering status transition delivery and wrong-repo rejection; spec's Run-control row updated. |
| 0112 | New feature flags | Five bool fields in `plue/internal/config/config.go` (`RemoteSandboxEnabled`, `ElectricClientEnabled`, `ApprovalsFlowEnabled`, `DevtoolsSnapshotEnabled`, `RunShapeEnabled`); env var names per ticket; defaults `false`; `/api/feature-flags` exposes them via `plue/internal/routes/flags.go`; `flags_test.go` asserts each flag round-trips through env override. |
| 0114 | `agent_sessions` shape | Shape definition on exact table; `where`: `repository_id IN (...)`; `deleted_at TIMESTAMPTZ NULL` migration + `DeleteSession` changed from `DELETE` to tombstone update; `electric_client_enabled` flag gate; integration test asserting tombstone delivered; no silent tightening to user-private without API co-change. |
| 0115 | `agent_messages` shape | Migration adding `repository_id BIGINT NOT NULL` with backfill; insert-path coverage including `IngestRunnerEvent` → `AppendMessage`; index `(repository_id, session_id, sequence)`; shape `where`: `repository_id IN (...) AND session_id IN (...)`; no repo-wide subscription path; `electric_client_enabled` flag gate; tests covering insert-path backfill. |
| 0116 | `workspaces` shape | Shape on exact table `workspaces`; `where`: `repository_id IN (...) AND user_id = <authed_user_id>`; Electric auth extension enforcing `user_id = authed.User.ID` in `internal/electric/auth.go`; `electric_client_enabled` flag gate; delete/tombstone alignment with 0105; integration test asserting wrong-`user_id` rejection. |
| 0117 | `workspace_sessions` shape | Row sync-safety fix (stop persisting secret SSH material in `ssh_connection_info`, or split into non-shaped side table); Electric auth extension per 0116; shape `where` with repo + user filter; `electric_client_enabled` flag gate; integration test asserting `ssh_connection_info` redaction never reaches shape output. |
| 0118 | `agent_parts` shape | Migration adding `repository_id BIGINT NOT NULL` + `session_id UUID NOT NULL` with backfill; insert-path coverage including `CreateAgentPart` call sites (`internal/services/agent.go:526-541, 588-600, 748-795`); index `(repository_id, session_id, message_id, part_index)`; shape `where`: `repository_id IN (...) AND session_id IN (...)`; `electric_client_enabled` flag gate. |
| 0130 | SSH host-key verification | `WorkspaceSSHConnectionInfo` extended with `host_keys` (algorithm + public key + SHA-256 fingerprint); `buildWorkspaceSSHConnectionInfo` populates from real gateway host key(s); `WorkspaceTerminalHandler.dialSSH` strict `HostKeyCallback` rejecting mismatches; `InsecureIgnoreHostKey()` removed; rotation support for two valid keys; tests for match + mismatch. |
| 0131 | Guest-agent protocol version negotiation | `MethodHello` RPC in `plue/internal/sandbox/guest/protocol.go`; handshake probe in host code with legacy-`v1` fallback on `unknown method`; `capabilities` in response; `error_code` field on `guest.Response`; tests for new-new, new-old (legacy fallback), and missing-capability soft-fail. Blocker-referenced by 0107 + 0110. |
| 0132 | Rate limits | New scopes `workspace_terminal_open`, `electric_shape_open`, `approval_decide` using `plue/internal/middleware/rate_limit.go`; per-user active-connection caps for terminals + shape streams; metrics emission on rejection; tests covering below-limit, at-limit, over-limit behavior per scope. |
| 0134 | Approval audit logging | Audit events emitted via `services.AuditService` at approval create / approved / rejected / expired; query extension in `audit_log.sql.go` to retrieve by `approval_id`; tests asserting presence after each decide path; no mutation of audit rows. |
| 0135 | Global cross-repo workspace listing | `GET /api/user/workspaces` route registered in `cmd/server/main.go`; handler + service adding a user-scoped list-across-repos query; response payload carrying repo owner/name + recency metadata; `RequireAuth` + `ScopeReadRepository`; tests covering multiple repos, pagination, 0-result case. |
| 0136 | Last-accessed tracking | New `workspaces.last_accessed_at TIMESTAMPTZ` column migration; update on real workspace-entry flows (not idle/suspend flows); query / endpoint from 0135 orders by it; `last_activity_at` left alone for idle heuristic; tests asserting column updates exactly on entry events. |

### 3.4 Client implementation tickets

| Ticket | Title | Expected artifacts |
|---|---|---|
| 0109 | OAuth2 sign-in UI | SwiftUI sign-in view + view-model (iOS + macOS targets); PKCE verifier generation with RFC 7636 test vectors in unit tests; `ASWebAuthenticationSession` integration; custom URL scheme (iOS) + `127.0.0.1` loopback (macOS) matching 0106; Keychain wrapper with atomic refresh-token update; 401 → refresh-once → retry flow; sign-out wipes Keychain + bounded SQLite + session state; whitelist-denied static message branch. |
| 0113 | iOS productization umbrella | No code changes under 0113. Splits verified: 0120, 0121, 0122, 0123, 0124, 0125, 0126 exist; dependency ordering documented (0120 first; 0121 parallel; others after). |
| 0120 | libsmithers-core production runtime | Rewritten `libsmithers/include/smithers.h` centered on one connection-scoped session; old `smithers_app_t` / `smithers_client_t` / `smithers_session_t` split removed; Zig implementation of Electric / WebSocket PTY / HTTP / SSE + event-loop thread; bounded SQLite cache under `persistence/sqlite.zig`; platform-injected credentials surface; subscribe/unsubscribe/pin/unpin/write/attachPTY FFI entry points; unit + integration tests. |
| 0121 | macOS+iOS target/build-system | `Package.swift` lists iOS alongside macOS; `project.yml` defines iOS app target + iOS unit/UI test bundles + shared source membership; `libsmithers-core` + libghostty build for macOS + iOS (simulator + device); `smithers-session-daemon` / `smithers-session-connect` removed from iOS target resources; CI matrix builds both targets per PR. |
| 0122 | Shared navigation / state refactor | `ContentView.swift` decomposed: route/state model extracted; `detailContent` route switch extracted; loading/bootstrap extracted; macOS container keeps `NavigationSplitView`; iOS container uses `NavigationStack`; app-entry types moved out of `ContentView.swift`; AppKit actions (`NSOpenPanel`, `NSWorkspace`, `NSApplication`, `NSPasteboard`) confined to `macos/Sources/Smithers/`. |
| 0123 | Terminal portability via libghostty pipes | `TerminalView.swift` split: shared SwiftUI surface + macOS AppKit adapter; `NSViewRepresentable` moved behind `#if os(macOS)`; shared surface driven by byte streams + resize + focus + title + bell callbacks from 0120 runtime; remote terminal no longer depends on `SessionController` / daemon binaries; libghostty pipes backend in use. |
| 0124 | Remote data wiring | `SmithersClient` refactored to thin facade over 0120 runtime for remote mode; shared observable stores for workspaces, agent sessions, messages, parts (0118), runs, approvals; core product views (`DashboardView`, `RunsView`, `RunInspectView`, `ApprovalsView`, `LiveRunView`, `WorkspacesView`, `JJHubWorkflowsView`) bound to stores; writes use HTTP JSON, not local. |
| 0125 | iOS release plumbing | Bundle identifier + signing team/profile in `project.yml`; Info.plist keys for OAuth callback + secure store; entitlements; TestFlight archive/export/upload automation; version/build-number rule preventing collisions; docs for repeatable internal distribution. |
| 0126 | Desktop-remote productization | Sign-in entry path from 0109 in macOS app; remote workspace/sandbox picker; local vs. remote mode indicator in shell; route back to local-folder flow preserved; `WelcomeView.swift` + `SmithersRootView` + `SidebarView.swift` + `WorkspacesView.swift` extended for remote; desktop-local path preserved until separate track lands. |
| 0138 | Workspace switcher | iOS + macOS workspace switcher view + state; consumes 0135's cross-repo listing; ordered by 0136's `last_accessed_at`; desktop separates local vs. remote visually (per spec); remote not split by repo; model types enriched (repo owner/name + recency) beyond current `WorkspacesView.swift` shape. |

## 4. Review workflow hooks

The `ticket-implement` workflow (`.smithers/workflows/ticket-implement.tsx`) uses a `ValidationLoop` that runs `implement → validate → review`, with review-agent approval as a required gate. This doc plugs into the review step.

### 4.1 Contract

The review agent is given:
- the ticket file path (under `.smithers/tickets/`);
- the diff / commits produced by the implement step;
- the validation output;
- **this file** (`.smithers/specs/ios-and-remote-sandboxes-validation.md`).

The review prompt MUST:
1. Identify the ticket's category (PoC / Design / Plue implementation / Client implementation).
2. Look up the ticket in Section 3's per-ticket table to fetch the expected artifacts.
3. Apply Section 1's universal checks.
4. Apply the relevant Section 2 subsection.
5. Apply the Section 3 row's artifact list.
6. Produce a verdict matching `reviewOutputSchema` (`.smithers/components/Review.ts`): `approved: true | false`, `feedback: string`, `issues: [{severity, title, description, file?}]`.

### 4.2 Prompt template shape

The review step SHOULD load this doc into the review agent's context and then use a prompt of roughly this shape (filled in by `ticket-implement.tsx` when the validation-doc hook lands):

```
You are reviewing the implementation of <TICKET_PATH>.

VALIDATION DOC (load in full): .smithers/specs/ios-and-remote-sandboxes-validation.md

Steps:
1. Read the ticket at <TICKET_PATH>. Identify its category using Section 2 of the validation doc.
2. Apply every universal check in Section 1. For each, state pass/fail with the specific evidence.
3. Apply the per-category subsection in Section 2 for the ticket's category.
4. Look up the ticket's row in Section 3. Confirm each listed artifact exists in the diff or in the repository at the expected path. Cite the path + line(s).
5. Run reference-integrity checks: grep every path/line/route/function the ticket cites against the current tree and confirm each exists.
6. If any check fails, set approved=false and list each failure as an issue with {severity, title, description, file?}.
7. If all checks pass, set approved=true with a one-paragraph summary of why.

Do NOT approve based solely on tests passing. The validation step already handles that; your job is the complement.
```

### 4.3 Implementing the hook

A follow-up ticket (not this one — see `0099 → Out of scope`) edits `.smithers/workflows/ticket-implement.tsx` or the shared `ValidationLoop` / `Review` component to:
- Load this doc into the review agent's prompt as a named context file.
- Derive `<TICKET_PATH>` from `ctx.input.prompt` or an explicit workflow input.
- Gate `done` on `anyApproved && !anyRejected` as today — no change to the loop's shape.

Until that hook lands, the review step still runs against this doc but relies on the reviewer (agent or human) having it in context manually.

## 5. Escalation

`ValidationLoop` already enforces `maxIterations={3}`. The escalation rules stack on top:

1. **Iteration 1 fails.** Feedback (universal/per-category/per-ticket issues) is returned to the implement agent. Loop re-runs.
2. **Iteration 2 fails.** Same. The review output SHOULD restate issues that were already raised in iteration 1 and are still unaddressed — these are harder signals than newly-discovered issues.
3. **Iteration 3 fails.** Workflow stops. `done=false`. The ticket is flagged for human review. The review output MUST include:
   - which universal/per-category/per-ticket check failed;
   - whether the failure looked like scope-creep, scope-cut, or genuine confusion;
   - a recommendation: either "ticket Scope is wrong, edit ticket" or "implementation is wrong, new iteration needed after human steer."
4. **Reference-integrity failure on iteration 1.** Does NOT consume an iteration — it is cheap to fix and the implementer should be told immediately. Review may loop back to implement with just the reference-fix ask.
5. **Ticket-external failure** (e.g. the referenced sibling ticket no longer exists because it was tombstoned). Escalate to human immediately; do not burn iterations on what is not an implementation problem.

Hard stop conditions (workflow halts without further iterations):
- Test suite broke a file outside the ticket's Scope.
- Secret material appears in commits, logs, or fixtures.
- Migration without down-migration on a schema that supports one (plue DB).
- Any change to tombstoned ticket files (0119, 0127–0129, 0137).

## 6. Scope of this ticket vs. siblings

This ticket (0099) produces this document plus drive-by cross-link edits to:
- `.smithers/specs/ios-and-remote-sandboxes.md` — link added in the initiative spec's index / related-docs.
- `.smithers/specs/ios-and-remote-sandboxes-execution.md` — link added near D3.

**Not in scope of 0099:**
- Substantive edits to any sibling ticket. If Section 3 reveals an artifact gap in a sibling ticket, file it as a follow-up and do not edit the sibling in this ticket.
- Editing `.smithers/workflows/ticket-implement.tsx` or `.smithers/components/ValidationLoop.ts` — that is a follow-up implementation ticket (see Section 4.3).
- Retroactively validating already-landed tickets — the checklist applies going forward.

## Self-check

Applying Section 1's universal checks to this ticket:

1. **Reference integrity.** Every cited path exists: main spec, execution plan, production-shapes doc, all 41 ticket files, `.smithers/workflows/ticket-implement.tsx` (57 lines), `.smithers/components/Review.ts` referenced abstractly. Line citations in Section 3 mirror ticket-body citations — reviewer should grep-verify each row's paths. ✔
2. **Scope match.** Matches 0099's Scope bullets: universal checks (Section 1), per-category checks (Section 2), per-ticket table (Section 3 with PoC / Plue-impl / Client-impl / Design rows), review workflow hooks (Section 4), escalation (Section 5), scope vs. siblings (Section 6). ✔
3. **RPC / wire format.** None introduced; doc-only. ✔
4. **Error taxonomy.** None introduced. ✔
5. **Metric presence.** None introduced. ✔
6. **Mock discipline.** No tests introduced. ✔
7. **Commit / PR hygiene.** Enforced by commit step. ✔
8. **Feature flag gate.** N/A — no runtime behavior. ✔
9. **Cross-link coherence.** 0119 and 0127–0129 and 0137 explicitly excluded; 0113 correctly flagged as umbrella. ✔
10. **No forbidden assumption.** Desktop-local called out as sibling-spec-owned. ✔
