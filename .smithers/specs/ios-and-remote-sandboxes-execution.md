# iOS And Remote Sandboxes — Execution Plan

Companion to `ios-and-remote-sandboxes.md`. That spec says *what* we're building. This doc says *how it gets broken up into work*.

Every item below is a task. Each becomes a ticket in `.smithers/tickets/` (gui-side) or `plue/.smithers/tickets/` (plue-side). Tickets get implemented via the `ticket-implement` smithers workflow. Nothing implementation-heavy starts until its task's PoC is green.

## Conventions

- **PoCs live in `poc/<name>/`** in whichever repo owns the change (usually plue, sometimes gui). The `plue/poc/` tree has precedent but no enforced convention — we standardize it here: each PoC has a `README.md` (what it proves + how to run + prerequisites), minimal code files only, and tests that actually exercise the claim.
- **PoCs may be TypeScript** when the language isn't what's being proved. If a PoC is proving a *Zig* capability (libghostty-on-iOS, Zig Electric client, Zig+SQLite-on-iOS), the PoC must be in Zig. If it's proving a *protocol shape* (Electric auth + shapes, multi-client PTY semantics, approval flow), TypeScript is fine.
- **Every PoC has tests that run in CI.** A PoC without passing tests is not a finished PoC. Tests must actually exercise the claim the PoC makes — not stub it.
- **Every non-PoC task has written acceptance criteria.** Design tasks end in a document; implementation tasks end in code + tests.
- **Every ticket cites paths that actually exist.** A reviewer (or ticket 0099's validation step) should be able to grep every file/line cited in Context and References.

## PoCs

Each is its own ticket. Ordered within groups, but groups can progress in parallel.

### Group A — core-side foundation (Zig, must be Zig)

**PoC-A1: libghostty on iOS — pipes-backend rendering.**
- *Proves:* libghostty can be built for `aarch64-ios`, embedded in a minimal SwiftUI app, and render from a byte stream handed in by Swift.
- *Scope:* build using ghostty's existing `GhosttyXCFramework` path (`ghostty/src/build/GhosttyXCFramework.zig` already targets iOS + iOS simulator); minimal SwiftUI app with a single view hosting the renderer; a test harness that feeds a canned PTY byte stream.
- *Reference:* `ghostty-org/ghostty` iOS target, `vivy-company/vvterm`, `ghostty/build.zig:213`.
- *Done when:* XCFramework build succeeds, minimal Xcode app renders a known-good PTY recording on simulator *and* builds for device, XCTest asserts terminal cell buffer state (not Metal-pixel hash — pixel hashes are flaky across simulator/device/font stacks) matches expected after deterministic playback.

**PoC-A2: Zig Electric shape client.**
- *Proves:* Electric's HTTP shape protocol (initial snapshot + long-poll deltas + offset/shape-handle resume) can be implemented in Zig against plue's `/v1/shape` proxy. Note plue's proxy requires shape `where` clauses to filter by `repository_id` and enforces per-repo ACLs (`plue/internal/electric/auth.go:44, 250`); the PoC must exercise this.
- *Scope:* minimal Zig library; two test tiers: (1) unit tests against a fake Electric protocol server for protocol correctness; (2) integration tests against real plue+Postgres+Electric with a synthetic table filtered by `repository_id IN (...)` and a valid bearer token.
- *Done when:* unit tests exercise subscribe, delta delivery, reconnection at stored offset, unsubscribe; integration test passes end-to-end against a real upstream Electric service with the auth proxy in front.

**PoC-A3: Zig WebSocket PTY client.**
- *Proves:* a Zig WebSocket client can connect to plue's `workspace_terminal.go`, passing a valid `Origin` header and the `terminal` WebSocket subprotocol (`workspace_terminal.go:84, 141`), send/receive binary frames for bytes, and text-JSON frames for resize.
- *Scope:* Zig library; against a running plue instance.
- *Done when:* unit tests cover connect (with correct Origin + subprotocol), write stdin, read stdout, resize, graceful close. Reconnect acceptance: client detects close cleanly and can establish a **fresh** connection (note: plue does not support reattach-to-live-session today; that's PoC-B4's problem, not this one's).

**PoC-A4: Zig ↔ Swift FFI for observable state.**
- *Proves:* the FFI pattern in the spec — Zig owns an event loop, fires callbacks into Swift on state change, callbacks marshal to the main thread, SwiftUI re-renders correctly.
- *Scope:* minimal Zig core with one synthetic observable counter, a SwiftUI app that subscribes, an XCTest that verifies the UI updates in under N ms after a Zig-side mutation.
- *Done when:* tests pass, there are no retained-cycle or thread-safety warnings under Xcode's sanitizers.

**PoC-A5 (optional, after A1+A3): terminal integration demo.**
- *Proves:* A1 + A3 + A4 compose — a SwiftUI view subscribes to a PTY byte stream from plue and renders it via libghostty.
- *Scope:* combines the three above into one Xcode target.
- *Done when:* e2e test launches plue locally, connects, runs `ls -la`, verifies output rendered.

**PoC-A6 (new, Stage 0): Zig + SQLite on iOS.**
- *Proves:* the existing Zig SQLite wrapper (`libsmithers/src/persistence/sqlite.zig`) builds and runs against iOS's system SQLite on both simulator and device, read/write works, no cgo or vendoring needed.
- *Scope:* minimal Zig wrapper at `poc/zig-sqlite-ios/`; Xcode target that opens a SQLite file, inserts, reads, closes; asserts via XCTest.
- *Done when:* tests pass on simulator and device; measured size overhead of linking system SQLite is recorded in the README.

### Group B — plue-side backend

**PoC-B1: Electric Go consumer against plue's proxy.**
- *Proves:* plue's existing `cmd/electric-proxy/` can serve shapes to a Go client end-to-end, including auth handshake and SSE stream.
- *Scope:* `plue/poc/electric-go-consumer/` in Go; subscribes to one synthetic shape (on a throwaway `poc_items` table with `repository_id`), writes rows in another goroutine via direct Postgres fixtures (since the production write surface for the PoC table doesn't exist — writes-through-REST are tested once real shape-backed entities land), verifies deltas arrive over the shape stream.
- *Done when:* Go unit tests exercise auth (good + bad token), shape subscribe, delta delivery, reconnection, unsubscribe.

**PoC-B2: desktop-local engine binary — DEFERRED to separate spec.**
- Moved out of this execution plan. Tracked in a sibling spec (TBD: `ios-and-remote-sandboxes-desktop-local.md`). Any migration step (D4) that would block on desktop-local must be deferred or reworked.

**PoC-B3: Approval flow end-to-end.**
- *Proves:* the pattern we'll use for human-in-the-loop — a pending `approvals` row appears via Electric shape to every connected client, one client POSTs a decision, all clients see the updated state.
- *Scope:* language flexible (TS or Go); minimal implementation of the approvals table + create + decide endpoints + shape. Two fake clients in the test harness.
- *Done when:* test verifies fan-out: both clients see the pending approval, only one decides, both see the decided state.

**PoC-B4: Multi-client PTY attach — PROMOTED to Stage 0.**
- *Proves:* whether and how two WebSocket clients can attach to one underlying PTY session. Plue's current handler (`workspace_terminal.go:124, 203, 251, 324`) creates one SSH session per WebSocket and tears it down on close, so this is a real architectural change, not a small feature.
- *Scope:* language flexible (Go or TS on the plue side). Evaluate both options explicitly: (a) session multiplexing in the HTTP handler, (b) "attach existing PTY" mode in the guest-agent protocol. Pick one with a written rationale.
- *Done when:* test confirms simultaneous view, chosen write policy (one writer vs. both writers vs. last-writer-wins), clean detach of one client without killing the other. A design-decision note is recorded in the spec updating what "multi-device same-user" actually means.

**PoC-B5: Run shape + route reconciliation.**
- *Proves:* plue's existing run routes (`GET /api/repos/{owner}/{repo}/actions/runs/{id}`, `POST .../actions/runs/{id}/cancel`, `GET /api/repos/{owner}/{repo}/runs/{id}/logs`, `/workflows/runs/{id}/events`) can be exposed to clients as a combination of (a) an Electric shape for run status + metadata and (b) the existing SSE for the per-run event trace. Also reconciles the two existing path namings (`/actions/runs/...` vs. `/workflows/runs/...`) into a single canonical surface for new clients.
- *Scope:* plue-side shape definition on the `runs` (or equivalent) table; a thin typed Go client that subscribes to the shape + the SSE trace for one run.
- *Done when:* tests dispatch a synthetic long-running run, observe status transitions via the Electric shape, observe event-trace chunks via SSE, cancel mid-run, verify both the shape and the SSE reflect the final state. A short note in the spec locks in the canonical route/shape naming.

**PoC-B6: Sandbox boot UX timing measurements.**
- *Proves:* instrumentation captures cold-boot, warm-resume, and snapshot-restore times on real Freestyle VMs so the 8s "taking longer than expected" threshold is evidence-based.
- *Scope:* runs a workload N times per mode, emits histogram metrics.
- *Done when:* a report exists with p50/p95/p99 for each mode; threshold in the spec is updated if wrong.

### Group C — cross-platform canary (Stage 0 — promoted)

**PoC-C1: Android build of `libsmithers-core` — PROMOTED to Stage 0.**
- *Proves:* the Zig core compiles for `aarch64-linux-android`, links into a minimal Kotlin app via JNI, and runs the same FFI smoke test as PoC-A4. Must land in Stage 0 because the main spec commits to Android as a continuous build canary; if we wait until Stage 2 we'll discover architecture-foreclosing decisions after they're set in concrete.
- *Scope:* new Gradle project at `poc/android-core/`, NDK integration, minimal Kotlin UI that exercises the counter from A4.
- *Done when:* CI builds the Android target alongside iOS on every PR; sanity test passes on an emulator. If Android build breaks, PR is blocked.

## Design-only tasks (no code, just docs)

**D1: Testing strategy.**
- Per component (engine, core, platform UI), what layers of test exist: unit, integration, e2e, fuzz, benchmark.
- Boundary conditions: shape reconnect at byte offset 0, at the middle of a delta, across token expiry; PTY write during disconnect; Electric deltas during local SQLite compaction.
- Android WIP canary: CI job that *only* checks the Android core build still compiles. If it breaks, the offending PR is flagged.
- *Done when:* doc lives at `.smithers/specs/ios-and-remote-sandboxes-testing.md`, reviewed.
- *Status:* landed. The testing strategy doc is at `.smithers/specs/ios-and-remote-sandboxes-testing.md` and is the per-component / per-boundary-condition / per-PoC testing reference for every ticket in this initiative.

**D2: Observability & error conditions.**
- Structured log taxonomy (what fields, what levels, what contexts).
- Metrics: Electric shape subscription count + lifetime histogram, WebSocket reconnect count, PTY byte throughput, SQLite cache hit rate + bytes, 401/refresh/failure counts.
- Error taxonomy: network transient vs. auth hard-fail vs. quota exceeded vs. sandbox unavailable vs. schema mismatch. Which errors show to user, which retry silently.
- Rate limits (per-user shape subscription count, WS open rate).
- *Done when:* doc lives at `.smithers/specs/ios-and-remote-sandboxes-observability.md`, reviewed.
- *Status:* landed. The doc is at [`ios-and-remote-sandboxes-observability.md`](ios-and-remote-sandboxes-observability.md) and is the source of truth for metric and error-code additions for every ticket in this initiative (referenced by validation universal checks #4 and #5).

**D3: Independent validation checklist.**
- For each ticket, what does a reviewing agent check to independently confirm "done" beyond "tests pass"?
- Example categories: new RPC has schema doc'd + both sides updated + shape subscribed by at least one client + metric added + error taxonomy entry + spec row checked off.
- Per-PoC entry: "what should the agent look for to confirm this PoC actually proves what it claims?"
- *Done when:* doc lives at `.smithers/specs/ios-and-remote-sandboxes-validation.md`; gets fed into the `ticket-implement` workflow's review step.
- *Status:* landed. The checklist is at `.smithers/specs/ios-and-remote-sandboxes-validation.md` and is the review-step reference for every ticket in this initiative.

**D4: Migration strategy.**
- How today's `libsmithers/src/` tree evolves into `libsmithers-core` + deprecated engine bits. Per-commit ordering so the current desktop app keeps working at every step.
- Which current features get deleted, which move, which rewrite; dependencies between migrations.
- *Done when:* doc lives at `.smithers/specs/ios-and-remote-sandboxes-migration.md`, reviewed.
- *Status:* landed. The gui-tree-only migration plan is at `.smithers/specs/ios-and-remote-sandboxes-migration.md`; it carries a file-by-file inventory of `libsmithers/src/`, a 12-step commit sequence, per-stage rollback, desktop-app compatibility gates, and a prerequisites appendix for cross-repo blockers.

**D5: Rollout plan.**
- What ships in what order to real users: desktop-remote-only first? iOS private build second?
- Feature flags — anchored to plue's existing global env-backed booleans (`plue/internal/routes/flags.go:10`, `plue/internal/config/config.go:53`). If per-cohort or kill-switch infra doesn't exist, the doc either scopes the rollout to what global flags can do, or it proposes the flag-infra upgrade as a named prerequisite.
- Android timing: already decided in the main spec — continuous build canary only, no user-facing release. Rollout plan must not schedule Android user phases. If that ever changes, a new phase is added.
- *Done when:* doc lives at `.smithers/specs/ios-and-remote-sandboxes-rollout.md`, reviewed.

## Implementation ordering

```
Stage 0 (mostly parallel — real dependencies annotated)

Truly independent, start anywhere:
├─ PoC-A1  libghostty iOS build                   [ticket 0092]
├─ PoC-A3  Zig WebSocket PTY client               [ticket 0094]
├─ PoC-A4  Zig ↔ Swift FFI                        [ticket 0095]
├─ PoC-A6  Zig + SQLite on iOS                    [ticket 0103]   (storage is central, must be proven on device)
├─ PoC-C1  Android core build                     [ticket 0104]   (continuous build canary; no user-release)
├─ Plue    Sandbox quota enforcement              [ticket 0105]
├─ Plue    Add new feature flags                  [ticket 0112]   (backs every gated ticket's rollout control)
├─ D1      Testing strategy                       [ticket 0097]
├─ D2      Observability                          [ticket 0098]
├─ D4      Migration (gui tree only)              [ticket 0100]

Dependencies that serialize within Stage 0:
├─ D3      Validation checklist                   [ticket 0099]   (LANDS FIRST among D* — every other D ticket's 'Independent validation' section references it)
├─ D0      Dispatch-run semantics decision        [ticket 0108]   (RESOLVED: Option A — implicit via user message; see ios-and-remote-sandboxes-dispatch-run.md)
├─ D5      Rollout                                [ticket 0101]   (references feature-flag owner tickets; best landed after 0107/0110/0111/0112/0113 exist as tickets so cross-refs resolve)

Parallel work with one-directional benefit (not hard blocks):
├─ PoC-B1  Electric Go consumer                   [ticket 0096]   (reference harness)
├─ PoC-A2  Zig Electric client                    [ticket 0093]   (benefits from B1 landing first as reference, but NOT blocked — can proceed against the fake-server test tier)

Architectural-decision PoCs (outcome changes spec; resolve before Stage 1):
├─ PoC-B4  Multi-client PTY attach                [ticket 0102]   (conclusion may add/keep shared PTY out of scope; spec's v1 default stays 'out of scope')

Auth chain (strict dependency — NOT parallel within itself):
├─ Plue    OAuth2 authorize browser flow          [ticket 0106]
└─  └─ Client OAuth2 sign-in UI                   [ticket 0109]   (can develop in parallel against mocked server; integration blocks on 0106)

Plue implementation work for gated features (each gated by a flag from 0112):
├─ Plue    Devtools snapshot surface              [ticket 0107]
├─ Plue    Approvals implementation               [ticket 0110]
├─ Plue    Run shape + route reconciliation       [ticket 0111]

Production-ready iOS client — runs AFTER Stage 0 PoCs are green:
└─ Client  iOS productization                     [ticket 0113]   (Stage 1; listed here so the plan doesn't stop at PoCs)

Stage 1 (needs Stage 0 pieces)
├─ PoC-A5  Terminal integration demo     (needs A1, A3, A4, A6)
├─ PoC-B3  Approval flow                  (reuses B1 shape pattern)
├─ PoC-B5  Run shape + route reconciliation
└─ PoC-B6  Sandbox boot timing

Stage 1.5 (deferred to sibling spec)
└─ Desktop-local engine binary            (was PoC-B2; moved out)

Stage 2 — implementation
Begin shipping production code, one feature ticket at a time, only
once the corresponding PoCs are green and the design docs approved.
Ordering is driven by D4 (migration) — do not improvise here.
```

**Dependency notes (corrected from a previous draft):**
- PoC-A2 (Zig Electric client) does NOT block on PoC-B1; it benefits from B1 as a reference. They can run in parallel.
- PoC-B3 (approvals) does NOT block on PoC-B1; it only needs the Electric auth proxy, which exists independently.
- Desktop-local moved out of this plan entirely. Its own spec covers it.
- Multi-client PTY is Stage 0 because the main spec's user-facing promises depend on the outcome.
- Android canary is Stage 0 because the main spec claims the architecture preserves it.

## Ticketing

Each task above gets a single ticket file. Per-ticket template:

```
# <Task ID>: <Title>

## Context
(1–2 sentences; link to the line in this plan)

## Goal
(what the task must deliver)

## Scope
(what's in, what's out — copied from plan)

## Acceptance criteria
(from plan's "done when")

## Independent validation
(from D3 once written; until then: "see D3")
```

Once a ticket file exists in `.smithers/tickets/`, implementation runs via `ticket-implement` smithers workflow. The workflow's ValidationLoop exercises implement → validate → review; review references D3 for the ticket-specific checklist.

## Open items

- The execution plan currently assumes D3 (validation checklist) is written before Stage 1 PoCs ship. If that's too slow, Stage 1 PoCs can proceed with "tests pass" as the only review criterion and D3 backfills before Stage 3 implementation begins.
- Who owns which stage — solo right now, but if we add collaborators, stages split by group naturally (Group A → client/Swift/Zig engineer; Group B → plue/Go engineer; D* → whoever's writing the doc).
