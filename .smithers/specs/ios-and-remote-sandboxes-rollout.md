# iOS And Remote Sandboxes — Rollout Plan

Companion to `ios-and-remote-sandboxes.md` and `ios-and-remote-sandboxes-execution.md` (task **D5**). Produced by ticket [0101](../tickets/0101-design-rollout-plan.md).

This doc says **how the internal changes from the migration plan (D4) reach real users** — the phase order, the feature flags that gate each phase, the canary cohorts per phase, the kill-switch policy, the per-phase machine-checkable acceptance gates, and the comms / deprecation shape. It composes with:

- [`ios-and-remote-sandboxes-migration.md`](ios-and-remote-sandboxes-migration.md) — says *in what code-surface order* we migrate. Rollout says *when each migrated surface reaches which users*.
- [`ios-and-remote-sandboxes-observability.md`](ios-and-remote-sandboxes-observability.md) — defines the metric names and error codes the per-phase gates reference.
- [`ios-and-remote-sandboxes-validation.md`](ios-and-remote-sandboxes-validation.md) — enforces universal check #8 (feature-flag gate), which every gated ticket in this initiative must satisfy.

## 0. Summary of choices

- **Five phases, not six.** Desktop-remote private → desktop-remote alpha → iOS alpha → desktop-local migration (blocked on a separate spec) → GA. All five remain whitelist-gated per the main spec's "access is always gated by JJHub whitelist" constraint.
- **Android has no user-facing phase.** Canary-only build in CI. Relaxation requires a new phase; this doc does not schedule one.
- **Feature-flag granularity is global on/off, not per-user.** We pick **Option (a)** from the ticket — scope rollout to what plue's existing global env-backed booleans can do. Per-user/per-cohort scoping is its own piece of infra (server-side flag-store, evaluator, client change, UI). Alpha cohorts are achieved by distributing different **builds** (TestFlight on iOS; signed internal archive for desktop) to the whitelist subset, not by flipping per-user flags. Rationale in §4.
- **Kill-switch is flag-off + plue restart.** Rollback latency is seconds-to-minutes depending on plue deploy restart time; the machinery is already there (ticket 0112 lands the five flags as plue's standard env-backed booleans).
- **Per-phase acceptance gates are machine-checkable.** Every gate cites named metrics from the observability doc §2 or error codes from §4.

## 1. Phase list

Phases are **sequential for a given user population**: a user moves from "no remote mode" through the phase their build supports. The desktop-remote alpha phase may overlap with iOS alpha (different builds to the same whitelist subset) but does not precede desktop-remote private.

**Owner** is intentionally blank — filled in when the initiative lead assigns.

### Phase 1 — Desktop-remote, private build (internal-only)

| Field | Value |
|---|---|
| **Population** | JJHub engineers + designated testers with the signed internal macOS archive. No TestFlight, no public builds. |
| **Flag defaults (plue)** | `remote_sandbox_enabled=true`, `electric_client_enabled=true`, `approvals_flow_enabled=true`, `devtools_snapshot_enabled=true`, `run_shape_enabled=true`. All **true only on the internal plue environment.** Staging / prod defaults stay `false`. |
| **Entry criteria** | (a) All Stage 0 PoCs green on trunk: 0092, 0093, 0094, 0095, 0096, 0102, 0103, 0104. (b) Migration (D4) through Step 7 (first cutover: workspaces-list read routed through runtime when `remote_sandbox_enabled=true`). (c) 0106 (OAuth2 PKCE) + 0109 (client sign-in UI) landed. (d) 0112 (flags) landed on plue main. (e) 0120 production runtime landed; 0126 desktop-remote productization landed. |
| **Exit criteria** | Internal smoke flow green for ≥5 consecutive business days on the internal plue environment: sign in, open one remote sandbox, open terminal, send one chat message with a run dispatched, approve one approval, inspect one devtools snapshot. Each machine-checkable gate in §7 satisfies its threshold. |
| **Kill switch** | Flip `remote_sandbox_enabled=false` on internal plue → restart. Client sees flag off; remote entry points disappear; legacy local-mode path resumes (see migration §4 dual-path window). Latency: as fast as the plue deploy restart (~60–120s on internal; up to several minutes on larger deploys). |
| **Comms** | Internal Linear status update on phase entry. No external comms. No changelog. |
| **Owner** | *(blank — assigned at phase start)* |

### Phase 2 — Desktop-remote alpha (whitelist subset)

| Field | Value |
|---|---|
| **Population** | A named subset of the JJHub whitelist — the "alpha whitelist" — who have signed an internal-alpha acknowledgement. Distributed via signed macOS archive delivered through the internal distribution channel, not the Mac App Store. Size target: first ~10 users initially, grow to ~50 over the phase if gates hold. |
| **Flag defaults (plue)** | Same five flags stay `true` on internal; on **alpha plue** (if we run a separate alpha environment) also `true`; on prod, **`false`** until Phase 5. If there is only one plue prod environment, the alpha whitelist gets the flag-on build; non-alpha users on the same plue host run flag-off clients, and never hit the gated endpoints. |
| **Entry criteria** | Phase 1 exit criteria hold. **Additionally:** (a) D2 observability signals are actually flowing from the client builds (smoke check: §7 gate names appear in the metrics backend with non-zero reported samples from alpha builds). (b) 0125 iOS release plumbing is either landed (if iOS alpha is about to start) or tracked as Phase 3's prerequisite. (c) Sign-out + secure-store wipe path (0133) verified on desktop. (d) Crash reporting (observability §6) live on alpha builds. |
| **Exit criteria** | Alpha population has been on the flag-on build for ≥14 calendar days with no kill-switch trip. All §7 gates hold at the alpha population volume. Internal retro captures at least one user-reported friction item — "no reports at all" usually means "nobody used it." |
| **Kill switch** | Same path: `remote_sandbox_enabled=false` on the plue environment serving alpha → restart. Builds stop seeing remote mode entry points. Finer-grained kill paths for individual features (`approvals_flow_enabled=false` etc.) listed in §6. |
| **Comms** | Phase-entry message to the alpha whitelist via the internal comms channel (Slack/Linear). No public changelog; no release notes on the main Smithers website until GA. |
| **Owner** | *(blank)* |

### Phase 3 — iOS alpha (same whitelist)

| Field | Value |
|---|---|
| **Population** | The **same** alpha whitelist as Phase 2, receiving the iOS app via TestFlight internal testing (not external testing, not App Store). A user may be on iOS alpha without being on desktop-remote alpha and vice-versa, but the whitelist set is the same underlying set. |
| **Flag defaults (plue)** | Unchanged from Phase 2. The iOS client obeys the same `remote_sandbox_enabled` flag read from `/api/feature-flags`. iOS has no local-mode fallback, so flag-off on iOS means "sign-in screen says remote mode is disabled; try again later" — explicit, not silent. |
| **Entry criteria** | (a) Phase 2 has held all §7 gates at ≥20 users for ≥14 days. (b) 0121 (macOS+iOS target/build), 0125 (TestFlight plumbing), 0122 (shared navigation refactor), 0123 (terminal portability via libghostty pipes), 0124 (remote data wiring) all landed. (c) iOS-specific smoke flow from [`ios-and-remote-sandboxes-testing.md`](ios-and-remote-sandboxes-testing.md) passes on both simulator and physical device. (d) Crash reporting verified on iOS TestFlight build. (e) PoC 0103 (Zig+SQLite on iOS) confirmed size-overhead + on-device performance within budget. |
| **Exit criteria** | iOS alpha population at target size (~25 users) has held all §7 gates for ≥14 days. iOS-specific gates in §7.2 (crash rate, memory pressure, SQLite size growth) hold alongside the shared gates. At least one alpha user has completed a full "create sandbox → run → approve → sign out" flow end-to-end on iOS and the trace is recoverable via the observability doc's telemetry screen (§7). |
| **Kill switch** | iOS cannot be silently rolled back the way desktop-remote can, because Apple ships the build, not us. Two kill paths: (i) plue-side — flip `remote_sandbox_enabled=false`; the iOS app renders the "remote mode disabled" screen with no workaround. (ii) TestFlight-side — expire the current build; no new installs, existing installs continue to hit flag-off plue. Latency: (i) seconds-to-minutes; (ii) effective on new installs only. |
| **Comms** | Private message to the whitelist with the TestFlight invite. No external press, no App Store listing, no blog post. |
| **Owner** | *(blank)* |

### Phase 4 — Local-desktop-only user migration

| Field | Value |
|---|---|
| **Population** | Existing desktop-local users who have never touched remote mode. This phase is about **migrating their local-mode UX off the legacy code paths** that D4 Steps 10–12 deleted, not about getting them to start using remote sandboxes. |
| **Blocked on** | **The separate desktop-local spec (`ios-and-remote-sandboxes-desktop-local.md`, TBD).** Main spec: "Desktop-local mode — tracked in a separate spec." Migration §Appendix A.c gates D4 Steps 10–12 on desktop-local's Step 1 shipping. This phase cannot enter without that spec's implementation having landed a replacement for local-terminal / local-recents / local-persistence. |
| **Flag defaults (plue)** | N/A for this phase — `remote_sandbox_enabled` does not gate local-mode behavior. The flag relevant to this phase is the desktop-local spec's own rollout flag (not yet named; defined by that spec). |
| **Entry criteria** | Desktop-local spec's rollout section exists, its implementation has shipped Steps 1+, its own acceptance gates are green. Phase 2 has GA'd (or is in its GA cohort). |
| **Exit criteria** | Defined by the desktop-local spec. This doc defers. |
| **Kill switch** | Defined by the desktop-local spec. This doc defers. |
| **Comms** | Handed off to the desktop-local spec. |
| **Owner** | *(blank — may be held by desktop-local spec's author rather than this initiative)* |

**Why this phase is called out explicitly:** D4's migration commit sequence deletes code that local-only users still rely on. The deletion is gated on desktop-local's replacement landing (migration §Appendix A.c). Without naming this phase in the rollout plan, we'd have a window where desktop-local users' app breaks because a sibling spec's work hasn't shipped. The explicit block here is the contract between the two specs.

### Phase 5 — General availability (still whitelist-gated)

| Field | Value |
|---|---|
| **Population** | The **full** JJHub whitelist (not just the alpha subset). "Whitelist is always on" per the main spec — this is not "public launch," it's "every whitelisted user can turn it on." |
| **Flag defaults (plue)** | `remote_sandbox_enabled=true` and the four sub-flags `true` on **prod plue**. Internal and alpha environments unchanged. |
| **Entry criteria** | Phase 2 and Phase 3 have each held gates at their respective target sizes for ≥30 days. No kill-switch trip in the prior 30 days. Support-load during Phase 2/3 has been characterized (per-user tickets per week below an agreed threshold — set by the initiative owner, not this doc). Phase 4 (local-migration) is either complete or not a blocker for GA users (if their build never exercises the deleted paths). |
| **Exit criteria** | N/A — GA is terminal for this initiative. Follow-up initiatives (new features on top, non-whitelist launch, mobile store listings) are separate specs. |
| **Kill switch** | Same flag-off-and-restart path, now with prod blast radius. Any GA kill is a rollback to Phase 2/3 state for the flag that got flipped. Higher cost to trip — the rollout-plan-owner role is expected to sign off before flipping a flag at GA. |
| **Comms** | Internal changelog entry. No public marketing; "access always gated by JJHub whitelist" per the main spec means a public announcement is out of scope. |
| **Owner** | *(blank)* |

## 2. Android — not in the phase list

Explicit guardrail from the main spec: Android exists as a **continuous build canary** (PoC 0104), nothing more. `libsmithers-core` must compile for `aarch64-linux-android` and link into a minimal Kotlin test app on every PR. If that build breaks, the PR is blocked. That is the only load-bearing role Android plays.

This rollout plan does **not** schedule an Android user phase. Reasons:

- No Android app exists.
- No TestFlight-analog distribution set up.
- The main spec's non-goals explicitly exclude a polished Android app and a user-facing release.
- The observability, crash-reporting, and auth surfaces on Android are stubs (no Sentry, no secure-store integration beyond the canary).

**Relaxation procedure.** If the product decision to ship Android changes, a new phase (Phase 3b or Phase 6, depending on ordering) is added to this doc. That addition requires, at minimum: Android build of `libsmithers-core` + UI app; Android Keystore integration for tokens; Android Studio / Google Play distribution path; crash reporting on Android; validation/testing doc updates. Nothing in the current plan should be interpreted as implicit scaffolding for Android shipment.

## 3. Feature flag → owning ticket mapping

Every flag the rollout uses has a **named owning ticket** for the behavior it gates. No holes. Flag names match those shipped by [0112](../tickets/0112-plue-add-new-feature-flags.md).

| Flag | Owned by | What it gates | Default, per phase |
|---|---|---|---|
| `remote_sandbox_enabled` | [0113](../tickets/0113-client-ios-productization.md) umbrella + [0109](../tickets/0109-client-oauth2-signin-ui.md) + [0120](../tickets/0120-client-libsmithers-core-production-runtime.md) + [0121](../tickets/0121-client-macos-ios-target-build-system.md) + [0122](../tickets/0122-client-shared-navigation-state-refactor.md) + [0123](../tickets/0123-client-terminal-portability-libghostty-pipes.md) + [0124](../tickets/0124-client-remote-data-wiring.md) + [0125](../tickets/0125-client-ios-release-plumbing.md) + [0126](../tickets/0126-client-desktop-remote-productization.md) | All remote-mode client behavior: sign-in-to-remote entry points, remote workspace picker, runtime session construction targeting a JJHub sandbox, remote terminal, remote run/approval UI. When off, clients behave exactly as today (local-only on desktop; iOS shows a "remote mode disabled" screen). | P1: **on** (internal). P2: **on** (alpha plue). P3: **on** (same). P4: N/A. P5: **on** (prod). |
| `electric_client_enabled` | [0114](../tickets/0114-plue-agent-sessions-production-shape.md) (`agent_sessions`) + [0115](../tickets/0115-plue-agent-messages-production-shape.md) (`agent_messages`) + [0116](../tickets/0116-plue-workspaces-production-shape.md) (`workspaces`) + [0117](../tickets/0117-plue-workspace-sessions-production-shape.md) (`workspace_sessions`) + [0118](../tickets/0118-plue-agent-parts-production-shape.md) (`agent_parts`) | Shape subscriptions **in production** — the five production-shape tickets. Explicitly **not** the PoCs [0093](../tickets/0093-poc-zig-electric-shape-client.md) (Zig client) or [0096](../tickets/0096-poc-electric-go-consumer.md) (Go consumer), which prove the machinery but are not gated features. When off, plue's shape endpoints refuse the subscriptions (the client can still render cached state but gets no live deltas). | P1: **on**. P2: **on**. P3: **on**. P4: N/A. P5: **on**. |
| `approvals_flow_enabled` | [0110](../tickets/0110-plue-approvals-implementation.md) | Approval write path (`POST .../approvals/{id}/decide`), the `approvals` Electric shape, the client approvals UI surfaces (approvals list, decide action, pending-approvals pinned shape). When off, approval requests never emit, clients never subscribe to the approvals shape, the decide endpoint returns 404/disabled. | P1: **on**. P2: **on**. P3: **on**. P4: N/A. P5: **on**. |
| `devtools_snapshot_enabled` | [0107](../tickets/0107-plue-devtools-snapshot-surface.md) | Devtools snapshot writer on the guest-agent side, the `devtools_snapshots` Electric shape, the client devtools snapshot UI. When off, no snapshots are written and the shape is rejected. | P1: **on**. P2: **on**. P3: **on**. P4: N/A. P5: **on**. |
| `run_shape_enabled` | [0111](../tickets/0111-plue-run-shape-route-reconciliation.md) | The `workflow_runs` Electric shape + the canonical `/api/repos/.../runs/{id}[/cancel]` + `/api/repos/.../runs/{id}/events` route aliases. When off, existing `/actions/runs/...` + `/workflows/runs/...` paths continue working (preserved by 0111), but the Electric shape is not served and clients fall back to polling the REST routes. | P1: **on**. P2: **on**. P3: **on**. P4: N/A. P5: **on**. |

**Completeness check.** Every flag named in 0112's Scope appears here. Every owning ticket for a flag's gated behavior appears in the "Owned by" column. No flag has a missing owner; no gated behavior is listed without a flag.

## 4. Per-user / per-cohort gating — chosen: Option (a)

**Decision: Option (a). Scope rollout to what plue's current global env-backed booleans can do.**

### Rationale

- Plue today (`/api/feature-flags` via `internal/routes/flags.go`, backed by `internal/config/config.go`) exposes flags as **global booleans keyed off process env vars**. There is no per-user evaluator, no server-side flag store, no client-side flag evaluation context. Ticket 0112 continues this shape for the five new flags. Building per-user scoping is a real piece of infra: server-side flag-store DB or YAML, evaluator with a user-id context, client-side flag-evaluation API, and UI for someone to turn it on per user. All of that is a scoped project of its own, easily the size of two or three implementation tickets from this initiative.
- The alpha whitelist mechanism **already exists** in the form of JJHub's whitelist: being whitelisted is the same thing as having an account that can obtain a bearer token. Non-alpha whitelist users never get the new builds (no TestFlight invite on iOS; no signed internal archive on desktop), so they can never exercise the flag-on path even if the flag is technically on. Cohort gating is implemented by **build distribution**, not by per-user flag evaluation. This is crude but sufficient for ≤50-user alphas.
- Deferring per-user scoping to **GA if needed** means we only build it when the problem is concrete. If GA reveals that we want 10% of users on an experimental flag and 90% on the stable one, that's when a named follow-up ticket lands — not before.

### What this choice means operationally

- **Alpha = build + whitelist**, not flag-per-user. Getting into Phase 2 means getting a signed macOS archive; getting into Phase 3 means getting a TestFlight invite. Getting out of the cohort means having the invite revoked or declining to update.
- **Kill switches are coarse.** Flag flips are all-users-on-the-environment or nothing. For finer-grained rollback, the environments-as-cohorts trick applies: if internal plue is its own environment, flipping a flag there doesn't affect alpha/prod.
- **Comms must be explicit about this.** An alpha user experiences the feature via their build; non-alpha users have no observable difference.
- **If per-user scoping later becomes necessary**, a named follow-up ticket lands **before** the phase that needs it. Until that ticket ships, this doc's gating policy is (a).

### Rejected: Option (b)

- (b) would list "plue gains per-user feature-flag scoping" as a Phase 2 prerequisite. Rejected because (i) it's infra we don't yet need, (ii) it delays Phase 2 by the delivery time of that infra (weeks), and (iii) the whitelist + build distribution mechanism already does the cohort job.

## 5. Canary cohorts

### Selection — Phase 2 (desktop-remote alpha)

- **First 5 users:** JJHub engineers + initiative leads. These are the "break it aggressively" cohort. Selected by direct ask in the internal channel.
- **Grow to ~20 over 2 weeks:** whitelist members who have opted in via an internal form. Consent captured in the form ("I understand this is an alpha, features may be removed, my session data is subject to the migration plan's compatibility shim"). The form also captures the telemetry-opt-in (see below).
- **Grow to ~50 if §7 gates hold:** broader JJHub-adjacent population on the whitelist. Same consent form.
- **Telemetry prerequisite for eligibility:** the alpha build must have crash reporting + client metrics enabled (observability §6, §2.1). Users who run with telemetry disabled are still whitelist-eligible but are **not** counted in Phase 2's machine-checkable gate evaluation (we can't see their traffic).

### Selection — Phase 3 (iOS alpha)

- **Same underlying whitelist as Phase 2**, but TestFlight has its own invite mechanism (80 internal testers or 10k external testers; we use internal).
- **First ~5 users:** same people as Phase 2's first 5, confirming cross-platform consistency.
- **Grow to ~25 over 2 weeks:** whitelist members with an iOS device who have opted in.
- **Consent:** TestFlight's own terms plus an internal acknowledgement. Same telemetry prerequisite.

### Phase 4 — deferred to desktop-local spec.

### Phase 5 — GA

- No cohort selection; the full whitelist is eligible.
- Consent is implicit in whitelist membership — "you signed up knowing features would change."

### Consent capture — common shape

- Internal form with: (i) understanding that this is pre-GA, (ii) agreement that local state is subject to the migration plan's data-migration constraint (§5 of migration), (iii) telemetry opt-in status. Stored in JJHub's own user records (no new infra for this), under a new `alpha_cohorts` field or equivalent — proposed naming; exact field is a plue follow-up if needed. No PII beyond what JJHub already stores.

## 6. Kill switches

Every flag in §3 has an independent kill path. The general shape:

1. **Operator** flips the corresponding env var to `false` on the plue environment serving the cohort being rolled back.
2. **Operator** restarts plue (process restart or rolling deploy).
3. **Client** reads the updated `/api/feature-flags` on next refresh (client re-reads on session start and periodically — cadence TBD by 0120, default 60s in `libsmithers-core`).
4. **Client** observes the flag is now off and:
   - For `remote_sandbox_enabled`: removes all remote entry points, closes active remote tabs with a "remote mode has been disabled" toast, preserves local state on desktop.
   - For `electric_client_enabled`: shape subscriptions are not re-issued; currently-open shapes drain to timeout (Electric shapes are server-side killed by the auth proxy returning 403 `shape_where_denied` on the next poll).
   - For `approvals_flow_enabled`: approvals UI goes read-only; decide button disabled.
   - For `devtools_snapshot_enabled`: snapshot feed closes; already-rendered snapshots stay.
   - For `run_shape_enabled`: run list falls back to REST polling (existing `/actions/runs/...` routes).

### Rollback latency

| Step | Typical latency |
|---|---|
| Env var flip + plue restart (internal) | 60–120s |
| Env var flip + plue restart (prod rolling deploy) | 2–10 minutes |
| Client re-reads `/api/feature-flags` | up to the client poll interval (default 60s after plue finishes the restart) |
| **Total, prod** | **≈3–12 minutes** from decision to flag reaching every active client |

This is coarse by infra standards — a dedicated feature-flag service would be faster. It's **adequate** because:

- The observability doc's acceptance gates (§7 below) fire **before** user-visible impact cascades in most cases: crash rate, auth-revoked spike, shape-reconnect thrash all trip well ahead of user-visible outages.
- The blast radius at Phase 2 (≤50 users) and Phase 3 (≤25 users) is small enough that a 10-minute window of misbehavior is recoverable.

If this latency becomes unacceptable (e.g., during Phase 5 at full whitelist scale), the follow-up is either (i) reduce plue restart time via rolling deploys with health gates, or (ii) introduce a cheaper flag-flip path (signed config-reload endpoint). Both are follow-up tickets, not scope for this doc.

### Per-phase kill ordering

| Phase | Primary kill | Escalation |
|---|---|---|
| 1 (private) | Flip any single flag on internal plue. | If internal plue is unreachable, pull the internal build from distribution. |
| 2 (desktop alpha) | Flip `remote_sandbox_enabled=false` on the plue environment serving alpha. | If the problem is narrower (e.g. approvals only), flip that specific sub-flag. If the problem is deeper (runtime bug), also revoke the signed archive via internal distribution. |
| 3 (iOS alpha) | Same flag flip. | TestFlight expire the current build as a secondary path (blocks new installs). |
| 4 | Per desktop-local spec. | — |
| 5 (GA) | Flag flip with rollout-owner sign-off. | Flag flip across all five is the "nuclear" option; partial flips (e.g. leave runtime on, turn off approvals) are preferred. |

## 7. Per-phase acceptance gates

Every gate references metrics from [`ios-and-remote-sandboxes-observability.md` §2](ios-and-remote-sandboxes-observability.md#2-metrics) and error codes from [§4](ios-and-remote-sandboxes-observability.md#4-error-taxonomy). Thresholds are starting values — tighter numbers are locked at phase entry.

### 7.1 Shared gates (every phase)

1. **`smithers_core_auth_unauthorized_total` (client) not above baseline.** Specifically: 401s labeled `source=shape|ws|http|sse` per active session per hour does not exceed the Phase 0 (pre-rollout) internal-build baseline by more than 2× over a 15-minute rolling window. A spike here usually means tokens rotated or refresh is broken; we don't advance until it's quiet.
2. **`auth_revoked` error code rate below `auth_expired` rate.** Formally: the ratio `auth_revoked / (auth_expired + auth_revoked)` over a 24-hour window is <10%. `auth_revoked` is the hard-fail case — a surge means we're incorrectly invalidating tokens.
3. **`smithers_core_electric_shape_reconnect_total` (client) per shape per hour.** Below 5 reconnects/shape/hour at the 95th percentile across the cohort. A hot shape points at server-side churn or client offset-resume bugs.
4. **`smithers_core_ws_reconnect_total` (client) per session.** Below 10 reconnects/session/hour at p95. Mobile networks legitimately flap; this is the threshold that distinguishes "network flap" from "client bug."
5. **Crash rate below threshold.** Client crashes per 100 active sessions < 1.0% (Phase 1/2), < 0.5% (Phase 3), < 0.2% (Phase 5). Measured via observability §6 crash reporting.
6. **`jjhub_http_requests_total{status="5xx"}` (plue) per route per minute below baseline.** No new route from this initiative is producing 5xx at > 2× the pre-phase baseline. Tracked via plue's existing metrics middleware.
7. **`jjhub_electric_shape_subscribe_total{result="denied"}` (plue) per user per hour.** Below 5. A higher rate usually means a client is asking for a shape it doesn't have access to — a client bug that could otherwise be missed because the user sees a generic error.
8. **`jjhub_sandbox_quota_rejections_total` below baseline.** No surge (unless the surge is explained by a known load test).
9. **No surge in `schema_mismatch` errors.** Zero tolerance for the flag-on cohort: if schema_mismatch fires, a shape evolved past what the local SQLite can handle, and we force-update via the error's user-facing copy. A single occurrence in Phase 2 does not trip the gate, but >5 distinct users seeing it in a 24-hour window does.
10. **`origin_rejected` rate at zero for the flag-on cohort.** Any non-zero rate means a build-configuration bug; does not trip the gate automatically but is treated as a P1 triage item.

### 7.2 iOS-specific gates (Phase 3)

1. **`smithers_core_sqlite_bytes` (client) per session.** Stays below 500 MB on iOS over the phase. iOS has stricter memory pressure semantics than macOS; runaway cache growth shows up here first. Ties to observability §2.1's rationale for this gauge.
2. **`smithers_core_sqlite_cache_hit_ratio` not below 0.85.** A drop means pinned shapes are getting evicted (default 25 concurrent shapes on iOS per the main spec's bounded-cache config) — which means the UX is thrashing.
3. **App-background-to-foreground reconnect time.** Median time from app-foreground to "first shape delta received" below 3s; p95 below 8s. Matches the main spec's sandbox-lifecycle "block workspace UI until connected" commitment for the backgrounded case. Emitted as a derived histogram from `smithers_core_electric_shape_subscribe_duration_seconds` on foreground events.
4. **Sandbox-boot p95 (`jjhub_sandbox_boot_duration_seconds{mode=snapshot_restore}`) below 8s.** The main spec's "slow-boot escape hatch" threshold. If p95 regresses above this, users start seeing "taking longer than expected" more often than designed for.

### 7.3 Phase-advance rule

- **Phase 1 → 2:** §7.1 gates 1–8 hold on internal plue for 5 consecutive business days.
- **Phase 2 → 3:** §7.1 gates 1–10 hold on alpha for 14 consecutive days at the target population size.
- **Phase 3 → GA:** §7.1 + §7.2 gates hold on iOS alpha for 14 consecutive days at the target population size, AND Phase 2 gates still hold.
- **Phase 4:** Gate set defined by the desktop-local spec.
- **Phase 5 entry:** as above, no additional gates beyond the Phase 2/3 merge.

## 8. Internal vs. external comms

| Surface | Phase 1 | Phase 2 | Phase 3 | Phase 4 | Phase 5 |
|---|---|---|---|---|---|
| Linear status update (internal only) | Y | Y | Y | per desktop-local spec | Y |
| Internal Slack announcement | Y (engineering) | Y (whitelist subset) | Y (whitelist subset) | per desktop-local spec | Y (full whitelist) |
| TestFlight release notes (iOS alpha only) | — | — | Y | — | Y |
| Signed-archive release notes (desktop) | internal only | internal distribution channel | — | per desktop-local spec | internal distribution channel |
| Public changelog on smithers.com | — | — | — | — | — (GA is still whitelist-gated) |
| Public blog / marketing | — | — | — | — | — |
| App Store listing | — | — | — | — | — |

**Key principle:** "Whitelist is always on" (main spec). There is no public launch in this rollout. External comms remain out of scope until the whitelist constraint is relaxed — and relaxation is outside this initiative.

### Messaging voice

- **Phase 1–3 announcements** name the feature, list known rough edges, point at the observability telemetry screen for bug reports, and state the kill-switch plan ("if this goes wrong, we flip a flag and it's gone").
- **Phase 4** messaging is handled by the desktop-local spec's rollout section; this doc does not prescribe copy.
- **Phase 5** announcement is short: "remote mode is now the default for the whitelist." Does not mention iOS specifically — iOS users at Phase 5 are just the subset of the whitelist on TestFlight.

## 9. Deprecation of today's features

Aligned with migration [D4's Step 10–12 deletions](ios-and-remote-sandboxes-migration.md#3-sequenced-commit-plan-gui-side).

### What goes away, and when the user is told

| Current behavior | Changes at | What we tell users |
|---|---|---|
| Local PTY via `session/pty.zig` + daemon binaries | Migration Step 10 lands. Desktop-local spec owns the replacement. | **Deferred to desktop-local spec.** This rollout doc does not commit copy; migration §5 locks the non-destruction of `recent_workspaces` data. |
| Local workspace list on `App.zig` + `workspace/manager.zig` | Migration Step 9 / Step 12. | Same — desktop-local spec owns. |
| `client/client.zig` as the CLI shell-out transport | Migration Step 11. | No direct user-visible message; the Swift shell is already the visible surface and it migrates to the runtime session in 0120 / 0126. Users see no change if the flag-off path continues to work during the dual-path window. |
| Legacy `workspace_sessions.ssh_connection_info` secret material (0117) | When 0117 lands on plue. | Internal communication to alpha cohort if the redaction changes any visible field; no external copy. |
| Legacy run route namings `/actions/runs/...` vs `/workflows/runs/...` | 0111 reconciles. Both paths continue to work. | None — existing scripts/automation continue. Canonical paths are documented; old ones stay as aliases. |

### Timeline for removing legacy code paths

- Follows migration §4's dual-path window: each gate (§3 Steps 7, 11, 12) holds the legacy path alive for **at least one successful production release** after the flag-on path ships. "Successful" = no kill-switch trip.
- This doc's phases consume those windows:
  - Desktop-remote alpha (Phase 2) entry = migration Step 7's dual-path window opens.
  - Desktop-remote GA (Phase 5) entry = migration Step 11 and Step 12 are clear to land.
- The legacy-desktop-local paths (Steps 10+) wait on **Phase 4**, whose entry is gated on the desktop-local spec. The deprecation of local-mode surfaces is therefore deferred to that spec and not promised on any timeline here.

### What we explicitly do NOT tell users

- We do not message "we are deprecating local mode" to users who only ever use local mode. Local mode's fate is the desktop-local spec's story; anything this rollout says about it would be premature.
- We do not claim "remote mode is faster" or similar performance messaging. Sandboxes have cold-start tails (main spec's slow-boot escape hatch) and nothing about the rollout improves that.
- We do not claim "offline mode" on iOS. The main spec's non-goals exclude offline beyond a graceful empty state.

## 10. Cross-references (maintained in lockstep with this doc)

- [Main spec](ios-and-remote-sandboxes.md) — cross-link added in §Related documents (drive-by edit in this ticket).
- [Execution plan](ios-and-remote-sandboxes-execution.md) — cross-link added near D5 (drive-by edit in this ticket).
- [Migration strategy](ios-and-remote-sandboxes-migration.md) — this doc's Phase 2 / Phase 5 entries gate on migration Steps 7 / 11 / 12 respectively.
- [Observability](ios-and-remote-sandboxes-observability.md) — every §7 gate cites metrics / error codes defined there.
- [Validation checklist](ios-and-remote-sandboxes-validation.md) — universal check #8 (feature-flag gate) enforces every gated ticket in this initiative reads the corresponding flag.
- [Testing strategy](ios-and-remote-sandboxes-testing.md) — Phase 3 iOS-specific smoke flow references the iOS device-vs-simulator matrix there.
- [0112 (feature flags)](../tickets/0112-plue-add-new-feature-flags.md) — shipped prerequisite; the five flags this doc references exist in `plue/internal/config/config.go` and `/api/feature-flags` as of 0112 landing.
- Owner tickets per §3: [0107](../tickets/0107-plue-devtools-snapshot-surface.md), [0110](../tickets/0110-plue-approvals-implementation.md), [0111](../tickets/0111-plue-run-shape-route-reconciliation.md), [0113](../tickets/0113-client-ios-productization.md), [0114](../tickets/0114-plue-agent-sessions-production-shape.md)–[0118](../tickets/0118-plue-agent-parts-production-shape.md), [0120](../tickets/0120-client-libsmithers-core-production-runtime.md)–[0126](../tickets/0126-client-desktop-remote-productization.md).

## 11. Self-check (D-VAL universal checks applied to this doc)

1. **Reference integrity.** Every cited ticket number exists in `.smithers/tickets/` (verified by filename prefix); every cited spec exists in `.smithers/specs/`; every cited flag name matches 0112's Scope bullets. ✔
2. **Scope match.** Ticket 0101 Scope: phase list (§1), Android not in phases (§2), feature-flag mapping table (§3), per-user gating decision (§4 — Option a chosen), canary cohorts (§5), kill switches (§6), per-phase acceptance gates (§7), internal vs external comms (§8), deprecation (§9). Each has a named section. ✔
3. **RPC / wire format.** None introduced. ✔
4. **Error taxonomy.** None introduced; references existing taxonomy from observability §4. ✔
5. **Metric presence.** None introduced; references existing metrics from observability §2. ✔
6. **Mock discipline.** N/A; no tests introduced. ✔
7. **Commit / PR hygiene.** Doc-only; standard commit flow. ✔
8. **Feature flag gate.** This doc *defines* the flag gating policy; 0112 lands the flags; gated tickets honor the flags via universal check #8. ✔
9. **Cross-link coherence.** No references to tombstoned tickets (0119, 0127–0129, 0137). Main spec and execution plan gain cross-links in drive-by edits. ✔
10. **No forbidden assumption.** Desktop-local is Phase 4 and is **explicitly blocked on a separate spec**; this doc does not prescribe its rollout. ✔
