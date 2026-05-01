# iOS And Remote Sandboxes — Testing Strategy

Companion to `ios-and-remote-sandboxes.md` and `ios-and-remote-sandboxes-execution.md`. Produced by ticket [0097](../tickets/0097-design-testing-strategy.md). Design-only. Consumed by every PoC ticket in this initiative (0092, 0093, 0094, 0095, 0096, 0102, 0103, 0104) and every implementation ticket that follows.

This doc says *what* gets tested and *how those tests are organized*. It does not write tests — each PoC and feature ticket writes its own. The validation doc (`ios-and-remote-sandboxes-validation.md`) names the per-ticket expected artifacts; this doc is the orthogonal axis: what testing layers apply to what component, what boundary conditions everyone must exercise, and where the CI pipelines draw the line.

"Tests pass" is the baseline. This doc is how we make sure the tests that exist actually prove the claims the spec makes.

## 1. Per-component test layers

Each component gets a primary set of test layers with explicit CI vs. dev-local split. The layers used:

- **unit** — in-process, no IPC, no network, hermetic.
- **integration** — real process boundary or real network, but one service at a time mocked where cheap.
- **e2e** — full stack (plue + Postgres + Electric + sandbox) with a real client driving the wire.
- **fuzz** — structured-input fuzzing with a corpus, run in CI on a bounded time budget and on-demand locally with no cap.
- **benchmark** — named metrics with regression-tracked thresholds; run nightly, not per-PR.

### 1.1 plue engine routes (Go, `plue/internal/routes/`, `plue/cmd/guest-agent/`)

| Layer | Applies | What runs in CI | What runs dev-local only |
|---|---|---|---|
| unit | yes | every `*_test.go` under `internal/routes/`, `internal/services/`, `internal/electric/`, `internal/sandbox/` | — |
| integration | yes | route tests that spin up an httptest server + real Postgres via testcontainers; WS terminal tests against a test guest-agent running in a local VM fixture | `make test-guest-agent-vsock` requires `/dev/vhost-vsock`, so it's a Linux-only dev-local run |
| e2e | yes | docker-compose-driven tests (see §8) against the reference harness; gated on the freestyle matrix (see §4) | tests requiring `JJHUB_FREESTYLE_API_KEY` run in the `make e2e-freestyle` job, which is CI-optional and dev-local default |
| fuzz | yes | `go test -fuzz` for: WS control-message JSON parser, Electric `where`-clause parser in `internal/electric/auth.go`, guest-agent vsock frame decoder | extended-corpus runs (>10 min) dev-local |
| benchmark | yes | `go test -bench` nightly for route P50/P99 latency; Electric shape subscribe → first row | — |

- **Route tests cover the full matrix** (same as the validation doc's §2.3): auth missing → 401, wrong scope → 403, wrong repo → 403, correct → 2xx, idempotent repeat → documented, malformed body → 400. This is a test-writing contract, not a layer.
- **Electric auth proxy** (`plue/internal/electric/`) specifically gets route-level tests that were missing before PoC-B1 (ticket 0096): good-bearer accepted, bad-bearer rejected, wrong-repo `where` rejected, upstream 502 handled.

### 1.2 plue Electric proxy (`plue/internal/electric/`, `plue/cmd/electric-proxy/`)

Already covered under §1.1 but called out here because it's currently un-tested and PoC-B1 is where coverage lands. The proxy is:

- a pure auth-gated HTTP reverse proxy;
- stateless except for the `where`-clause parser.

| Layer | Applies | Notes |
|---|---|---|
| unit | yes | parser for `repository_id IN (...)`, per-row-type ACL checks (`user_id = authed.User.ID` for `workspaces`, `workspace_sessions` per §2.3 of validation doc). |
| integration | yes | real upstream Electric, real Postgres, shape subscribe → first row → live delta. |
| e2e | yes | part of the §8 harness. |
| fuzz | yes | `where`-clause parser gets its own fuzz target (see §5). |
| benchmark | yes | subscribe → first row P50/P99 (see §6). |

### 1.3 guest-agent (`plue/cmd/guest-agent/`, `plue/internal/sandbox/guest/`)

| Layer | Applies | Notes |
|---|---|---|
| unit | yes | method-handler tests in `internal/sandbox/guest/*_test.go` with a fake vsock conn. |
| integration | yes | real vsock conn inside a Firecracker test VM (Linux CI runners only). Tests `Exec`, `WriteFile`, `ReadFile`, and — if 0107 or 0110 have landed — `MethodWriteDevtoolsSnapshot` / `MethodEmitApprovalRequest` / `MethodHello` (protocol version handshake, ticket 0131). |
| e2e | yes | folded into the §8 harness when a real sandbox is used. |
| fuzz | yes | vsock frame decoder + JSON-RPC request parser (see §5). |
| benchmark | no | not a hot path in v1. |

### 1.4 `libsmithers-core` (Zig, `libsmithers/src/`)

| Layer | Applies | Notes |
|---|---|---|
| unit | yes | `zig build test`. Covers: Electric shape client state machine (subscribe, resume, unsubscribe), WS PTY frame encode/decode, HTTP+JSON write-request encoder, SSE `Last-Event-ID` resume, SQLite wrapper open/read/write, bounded-cache LRU at shape-subscription level. |
| integration | yes | real plue stack via docker-compose. Covers: Electric subscribe end-to-end, WS PTY round-trip, HTTP write + shape echo, auth refresh on 401, cross-transport token refresh race. |
| e2e | yes | §8 harness. |
| fuzz | yes | WS frame decoder, Electric shape delta parser, JSON control-message parser — all three are Zig fuzz targets (see §5). |
| benchmark | yes | SQLite cache read P50/P99 under N shapes (see §6). |

- **Sanitizers:** Zig's `-fsanitize-thread` and `-fsanitize-address` pass on Linux CI; macOS-host Zig TSan has known gaps so we don't rely on it.
- **CI vs. dev-local:** all unit tests run in CI; integration tests gated on docker-compose availability run in CI; the e2e matrix's Freestyle-dependent slice is dev-local default (see §4).

### 1.5 SwiftUI platform UI (`macos/Sources/Smithers/`, future `ios/`)

| Layer | Applies | CI | Dev-local |
|---|---|---|---|
| unit | yes | XCTest against view-models and state stores (no UIKit/AppKit dependency). Runs on Linux CI via `swift test` where possible and on the macOS CI runner where SwiftUI types are needed. | — |
| integration | yes | XCTest against the FFI boundary with a real `libsmithers-core` build (simulator). Covers: subscribe + callback on main thread, tick-based counter (0095 pattern), token-injection surface. | — |
| e2e | yes | XCUITest (iOS simulator) and XCUITest (macOS) driving the sign-in + connect + list workspaces flow against a docker-compose plue + a Freestyle mock. | full device-run e2e (real Freestyle, signed build) is dev-local via `make ios-e2e-device`. |
| fuzz | no | there's no parseable input at the SwiftUI surface. All parsing sits behind the FFI. | — |
| benchmark | yes | SwiftUI re-render latency after FFI update (0095 bounded-time test) — run on simulator CI. | — |

- **Device vs. simulator:** see §3 for the matrix.
- **Sanitizers** (TSan, ASan) on Swift are simulator-only; device builds use release configs without sanitizers.

### 1.6 GTK UI — current desktop shell (`linux/`)

Today's GTK UI continues to exist while the iOS/core migration lands (per ticket 0100). It is not a target of *new* tests in this initiative, but regressions must not land.

| Layer | Applies | Notes |
|---|---|---|
| unit | yes | existing Zig + GTK unit tests continue to run in CI unchanged. |
| integration | yes | existing GTK integration tests (if any) keep running; no new ones added by this initiative. |
| e2e | no | no GTK-specific e2e added for remote sandboxes — remote-sandbox support on Linux desktop lands only when it naturally falls out of the libsmithers-core migration. |
| fuzz | no | — |
| benchmark | no | — |

### 1.7 Android WIP canary (`poc/android-core/`, from 0104)

**Build-only canary. No runtime-on-device in CI.**

| Layer | Applies | Notes |
|---|---|---|
| unit | yes (Kotlin side only) | minimal JNI wrapper tests against the counter FFI. |
| integration | no | full Android integration is out of scope until a user-facing release is planned. |
| e2e | no | — |
| fuzz | no | — |
| benchmark | no | — |
| **build canary** | **yes** | **CI job that builds `libsmithers-core` for `aarch64-linux-android` via the NDK and assembles the Gradle project. Failure blocks the PR.** See §7 for the job spec. |

## 2. Boundary conditions to explicitly exercise

Every boundary below must have at least one test somewhere in the matrix. "Somewhere" means a specific ticket owns it — cited per-row. The validation doc's per-ticket table is the authoritative artifact list; this section is the claim that each condition is covered.

### 2.1 Electric shape reconnect

| Condition | Owning test | Layer |
|---|---|---|
| Reconnect at byte offset 0 (empty state) | 0093 unit (fake server) + 0093 integration | unit + integration |
| Reconnect mid-delta (server closes mid-chunk) | 0093 unit; fake server cuts TCP mid-body | unit |
| Reconnect across token refresh (401 mid-stream → refresh → resume) | 0120 client-integration; plue 0096 integration asserts the proxy handles retry | integration |
| Reconnect across schema migration (plue migration bumps table during active shape) | plue e2e in 0111 / 0114–0118 — one of these owns a "shape resilience across migration" test | integration |

### 2.2 WebSocket PTY handshake failures

| Condition | Test expectation |
|---|---|
| **Bad `Origin`** (rejected by plue per `plue/internal/routes/workspace_terminal.go:84`) | **Negative test in 0094 and in 0120's WS client integration.** Client surfaces this as a distinct `origin_rejected` error per 0098's taxonomy. |
| **Missing bearer token** (rejected by plue middleware) | Negative test in 0094. Client surfaces as `auth_missing`. |
| **Subprotocol rejection — NOT TESTED.** `github.com/coder/websocket` only *selects* an offered subprotocol; it does not reject missing or wrong subprotocols (see `coder/websocket/accept.go:141`). The client sends `Sec-WebSocket-Protocol: terminal` as a correctness practice (ticket 0094 scope), but there is no handshake failure to assert. | **Explicit call-out:** if a future ticket wants subprotocol enforcement, it must first land an enforcement change in plue's `workspace_terminal.go`. Until then, no test. Any reviewer who sees "subprotocol rejection test" in a PR can reject the PR by pointing at this line. |

### 2.3 WebSocket PTY runtime edge cases

| Condition | Owning test | Notes |
|---|---|---|
| Write during disconnect (client writes after TCP close, before detection) | 0094 unit + 0120 integration | write returns error; no crash; no silent drop. |
| Backpressure (slow reader) | 0094 unit with a fixed-size outgoing buffer; integration with a slow consumer | client must apply flow control, not unboundedly buffer. |
| Ping/pong across network pause | 0094 unit on frame decode; integration with a simulated pause | the ping/pong path is not a wall-clock integration test (30s waits ban per 0099 §2.1). |
| Resize during active output | 0094 integration: running `yes` then sending a resize, assert no corruption in stream, `cols`/`rows` actually take effect | — |

### 2.4 SQLite cache

| Condition | Owning test | Notes |
|---|---|---|
| Eviction during active subscription (bounded cache hits the shape-count cap while a shape is live) | 0120 integration | pinned shapes (current workspace, pending approvals) are never evicted. Evicting an *active* non-pinned shape must cause a re-snapshot, not a silent data loss. |
| WAL file creation in iOS sandbox | 0103 on-device smoke | journal + WAL must land in the app Documents directory without permission error. |
| Cache survives app backgrounding | iOS 0113 device-run e2e | see §3.  |

### 2.5 Auth token lifecycle

| Condition | Owning test |
|---|---|
| Access-token expiry mid-request on each transport (HTTP write, Electric shape long-poll, WS PTY) | 0120 integration — simulates expiry by injecting a short-TTL token; asserts refresh-once-and-retry per spec Auth section. |
| Refresh race (two concurrent requests hit 401, both try to refresh) | 0120 unit on the refresh coordinator; exactly one refresh call is issued. |
| Refresh-token revoked (refresh itself returns 401) | 0120 integration; core emits `auth_expired` event per 0098 taxonomy; platform drops to sign-in. |
| Refresh across app resume (iOS) | 0113 device-run e2e: background → resume → first request triggers refresh-if-needed. |

### 2.6 Sandbox suspend/resume

| Condition | Owning test |
|---|---|
| Shape subscription survives sandbox suspend (no user action) | 0105 integration (plue-side) + 0120 client integration: subscribe, plue suspends the sandbox (sets status), resume, assert client still delivered any deltas that happened across the suspend window. |
| Shape subscription during resume (client was connected during suspend, resume completes) | same ticket; explicit no-gap assertion. |

### 2.7 Concurrent writes to same session

| Condition | Owning test |
|---|---|
| Two clients post to `agent_sessions/{id}/messages` at the same time | 0115 plue integration: two goroutines post messages; all messages land, ordering is deterministic-by-server-clock, `sequence` is monotonic. |
| Two clients dispatching a run (once 0108 picks explicit vs. implicit) | 0111 integration once 0108 decides. If implicit-via-message: the two-client concurrent-message test already covers it. If explicit route: a dedicated test of that route's idempotency / race semantics. |

### 2.8 Approval race

| Condition | Owning test |
|---|---|
| Two clients decide the same approval simultaneously (both POST `/approvals/{id}/decide`) | 0110 integration: first write wins; second write returns a structured `approval_already_decided` error per 0098 taxonomy; both clients observe the final decided state via the Electric shape fan-out. |

## 3. iOS device-vs-simulator coverage matrix

The rule: **simulator for most things, device for the things simulator literally cannot test.**

| Capability | Simulator | Device | Notes |
|---|---|---|---|
| Zig ↔ Swift FFI correctness (0095) | yes | build-only | Simulator runs the XCTest; device must build but doesn't have to run the same test. |
| TSan / ASan (Swift & Zig) | yes | no | Swift sanitizers are simulator-gated. Device release builds are un-sanitized. |
| CI e2e (SwiftUI → FFI → plue) | yes | no | Simulator is the CI runner; device e2e is dev-local. |
| Code signing | no | yes | Can't test signing on simulator. Device-run validates provisioning profiles, entitlements (0125). |
| Real Keychain | partial | yes | Simulator Keychain exists but is not the real one; device-run validates accessibility classes, biometric gates if added. |
| Background / foreground transitions | partial | yes | Simulator can simulate background but not system-level jetsam; device-run is load-bearing for "session survives 30s backgrounded." |
| APNs | no | yes | Only if push is added; not in v1. Listed for completeness. |
| libghostty rendering correctness (0092) | yes | build-only | Cell-buffer state asserted on simulator per 0092; device build is proof the slice links. |
| SQLite on real Apple filesystem (0103) | yes | **yes, smoke** | Device run is load-bearing for 0103 — real file system, real WAL behavior. Developer-local run is acceptable per 0103 scope. |
| WS PTY + Electric integration on real networking stack | yes | build-only | Radio stack, cellular NAT, etc. are future concerns; not in v1 test scope. |
| On-device sanitizer coverage | — | no | Out of scope per 0095 README. |

**Summary:** build-only on device is acceptable for 0092, 0094, 0095, 0113, 0120. Runtime-on-device is required for 0103 (SQLite smoke), 0109/0125 (signing + Keychain + OAuth callback), and the iOS e2e slice for backgrounding in 0113.

## 4. Local-only vs Freestyle-dependent e2e matrix

Tests split by whether they need a real Freestyle VM (sandbox boot, guest-agent over vsock, real PTY bytes from a real shell in a real VM) vs. can use a local test harness.

### 4.1 Local-only (no Freestyle API key needed)

Runs in every PR's CI pipeline. Uses docker-compose for plue + Postgres + Electric; uses a mock sandbox (local Docker container with a PTY shell exposed over the same protocol) for anything needing a guest.

- All §2.1, §2.2, §2.3, §2.4, §2.5 tests.
- §2.7 concurrent-write tests.
- §2.8 approval-race test.
- All `libsmithers-core` unit + integration tests.
- All plue route tests (route matrix per §1.1).
- Electric subscribe → first row benchmark (synthetic data, not sandbox-bound).

### 4.2 Freestyle-dependent

Gated on `JJHUB_FREESTYLE_API_KEY` being set. Run via `make e2e-freestyle` target. In CI, run in a nightly job + on explicit PR label (`e2e-freestyle`). Not blocking on every PR because they are slow and cost money.

- Real sandbox boot / suspend / resume timing (0108 / PoC-B6).
- §2.6 sandbox suspend/resume shape survival against a real sandbox.
- End-to-end iOS e2e against a real Freestyle VM (0113 device matrix).
- Guest-agent vsock integration tests that require `/dev/vhost-vsock` on a Linux runner with a Firecracker kernel (a narrow subset; most vsock tests run with a mocked vsock conn locally).
- Approval flow on a real sandbox (0110), where the approval event originates from a real guest-agent inside a Freestyle VM.

**Contract for Freestyle-dependent tests:**
- They must be skippable (`t.Skip` if env var missing; `--skip-freestyle` flag in harness).
- They must clean up after themselves: every sandbox created has a deferred delete.
- They must budget under 10 minutes per job (PoC-B6 measures, so thresholds here are data-backed not guessed).

## 5. Fuzz targets

Four targets, one paragraph each. All fuzzing runs in a bounded-time PR job (60 seconds per target); deeper runs (hours) are nightly and on-demand-dev-local.

### 5.1 WS frame decoder (`libsmithers-core`, Zig)

The RFC-6455 frame decoder in the Zig WS client. Corpus seeding: a handful of hand-crafted frames covering every opcode, fragmented messages, masked vs. unmasked, close codes, ping/pong with data, maximum-size payloads. Failure criteria: any input that panics, hangs >50ms per frame, over-allocates (decoder must bound memory by frame-size header), or produces output that differs from a reference decoder (we use `github.com/coder/websocket` in a differential harness). The fuzzer must not accept malformed frames silently — on invalid input the decoder returns a structured error, never partial bytes.

### 5.2 Electric shape delta parser (`libsmithers-core`, Zig)

The parser that reads ElectricSQL's NDJSON-over-HTTP delta stream and translates it into row insert/update/delete events. Corpus seeding: recordings captured from real PoC-B1 runs against plue + upstream Electric, plus hand-crafted adversarial cases (truncated JSON, invalid UTF-8, unexpected `op` values, `lsn` rollback, shape-handle token mismatch, duplicate row ids within a batch). Failure criteria: panic, wrong row count, reordering within a batch (Electric guarantees per-row ordering), silently-accepted schema mismatch, or over-allocation.

### 5.3 JSON control-message parser (`libsmithers-core` + plue-side, both)

The text-frame JSON messages on the WS terminal channel (today: `{type:"resize",cols,rows}`; may grow). Corpus seeding: every known message shape plus a set of malformed variations (wrong types, missing fields, extra fields, nested objects where scalars expected, numeric overflow for `cols`/`rows`). Failure criteria: both sides (Zig parser + Go parser in `plue/internal/routes/workspace_terminal.go`) must agree on which inputs are valid and must both reject the same malformed inputs. Differential fuzzing — if the two disagree, one is wrong.

### 5.4 guest-agent vsock protocol parser (`plue/internal/sandbox/guest/`, Go)

The JSON-RPC-style request/response parser over vsock. Corpus seeding: every `Method*` request + response known, plus malformed: wrong `method` string, missing `id`, `id` of wrong type, oversized `payload`, truncated framing. Failure criteria: panic, memory blow-up (parser must reject oversized payloads before allocating), silent method-dispatch to a wrong handler, or skip-on-malformed (malformed requests must return a structured error response, not be ignored).

## 6. Benchmarks

Named metrics. Thresholds **TBD until PoC-B6 (ticket 0102 — *correction:* PoC-B6 is sandbox-boot timing, tracked separately under Stage 1)** produces real numbers. Benchmarks run nightly, not per-PR; regression (>20% slower than 7-day trailing median) posts a warning, not a block.

| Metric | Unit | Where measured | Threshold |
|---|---|---|---|
| Electric subscribe → first row latency | ms (P50, P99) | `libsmithers-core` integration against docker-compose plue stack with N=1000 rows preloaded | TBD — baseline captured on first nightly run after 0093 lands. |
| WS PTY round-trip (stdin → stdout echo) | ms (P50, P99) | `libsmithers-core` integration against a local PTY shell behind plue | TBD — baseline after 0094 lands. |
| SQLite cache read latency under N shapes | ms (P50, P99) at N ∈ {1, 10, 25, 50} | `libsmithers-core` integration against a preloaded bounded cache | TBD — baseline after 0103 lands; must not regress as new shapes get added in 0114–0118. |
| Sandbox cold-boot time | ms (P50, P95, P99) | plue + Freestyle; 0102's (PoC-B6's) output | **TBD until PoC-B6 data**, which then feeds back into the spec's "8s slow-boot escape hatch" threshold. |
| Sandbox warm-resume time | ms (P50, P95, P99) | same | TBD per PoC-B6. |
| Sandbox snapshot-restore time | ms (P50, P95, P99) | same | TBD per PoC-B6. |

"TBD" is the only kind of unfilled value this doc permits, and it's explicitly allowed by the ticket (0097 Scope) for benchmark thresholds until PoC-B6 lands.

## 7. Android WIP canary

Per the spec's non-goals, Android is build-only in this pass. The canary is one CI job:

- **Job name:** `android-canary` (added to `.github/workflows/ci.yml` or equivalent).
- **Runs on:** every PR to `main`, plus `main` itself post-merge. No `paths:` filter — a change to anything that breaks `aarch64-linux-android` must fail the job, not be quietly excluded.
- **Steps:**
  1. Check out gui repo including submodules.
  2. Install pinned NDK version (documented in `poc/android-core/README.md`, pinned in `.android-ndk-version`).
  3. Install pinned Zig version (from `.zig-version`).
  4. `zig build -Dtarget=aarch64-linux-android` produces `libsmithers-core.so`.
  5. `./gradlew -p poc/android-core assembleDebug` produces the APK.
  6. Record `.so` size + APK size in the job summary.
- **Failure criteria:**
  - Zig build failure → fail.
  - Gradle build failure → fail.
  - `.so` size grows >20% vs. previous `main` → warning, not block.
- **No runtime-on-device or runtime-on-emulator in CI.** 0104's emulator test runs dev-local only; it's not load-bearing for PR blocking.

If a PR intentionally breaks Android (e.g. takes a dependency on a platform-specific API), the owning ticket's Scope must name the decision, and 0104's canary job must be updated in the same PR. A silently-disabled canary is a rejection at review time.

## 8. E2E orchestration

One harness. Every PoC plugs into it. No PoC invents its own docker-compose incantation.

### 8.1 The harness

Layout (lives under `test-harness/` at the gui repo root; plue has a symmetric `plue/test-harness/`):

```
test-harness/
  docker-compose.yml           # plue + Postgres + Electric + mock sandbox
  docker-compose.freestyle.yml # overlay: real Freestyle API (requires JJHUB_FREESTYLE_API_KEY)
  fixtures/                    # seed data (users, repos, tokens)
  clients/
    headless-swift/            # XCUITest runner for simulator (macOS only)
    headless-zig/              # libsmithers-core-driven Zig client for cross-platform e2e
  scripts/
    up.sh                      # bring stack up with seed data
    down.sh                    # tear down
    mint-token.sh              # produce a bearer token for the seed user
```

### 8.2 Stack composition

`docker-compose.yml` starts:

- **Postgres** (pinned to plue's production Postgres version).
- **Electric** (the upstream `electric:3000` service, pinned version).
- **plue** (the Go server under test — built from local source via a Dockerfile that mounts the `plue/` submodule).
- **mock-sandbox** (a lightweight container that speaks the guest-agent vsock protocol over a local Unix socket the test harness bridges to; used whenever a test doesn't need real Freestyle).
- **electric-proxy** (plue's `cmd/electric-proxy/` as its own container).

Overlay `docker-compose.freestyle.yml` replaces `mock-sandbox` with a real Freestyle API consumer (key in env). Used only by Freestyle-dependent tests (§4.2).

### 8.3 Test-sandbox harness

For any test that needs a "sandbox" but doesn't need a real Freestyle VM:

- **mock-sandbox** exposes the guest-agent protocol faithfully enough that plue's routes can't tell the difference.
- Starts in <1s (local container), so unit + integration budgets aren't blown.
- Supports fault injection: delay, disconnect, slow-write, method-dispatch errors. Tests opt in via env vars (`MOCK_SANDBOX_DELAY_MS`, `MOCK_SANDBOX_DROP_AFTER_N_BYTES`, etc.).
- Does NOT attempt to simulate real PTY programs — a test that needs `bash` runs `bash` in the mock-sandbox container; a test that needs deterministic bytes uses a canned byte-stream replay.

### 8.4 Headless SwiftUI test runner

- XCUITest target lives under `poc/libghostty-ios/` + future `ios/`. Runs on the macOS CI runner against iPhone simulator.
- Binds to the same docker-compose harness (reachable at `host.docker.internal` from simulator, with a `host.docker.internal`-style mapping for macOS simulator networking).
- Produces JUnit XML so CI can parse results.

### 8.5 Headless Zig client

- `test-harness/clients/headless-zig/` is a tiny Zig binary that drives `libsmithers-core` from the command line — connects, subscribes, issues writes, prints deltas.
- Used by integration tests that need a non-SwiftUI client (CI runners other than macOS, most plue-side e2e scenarios).
- Shares auth + transport code with the production `libsmithers-core`; not a separate re-implementation.

### 8.6 PoC plug-in contract

Every PoC's integration/e2e tests that use the harness:

- Start the stack via `test-harness/scripts/up.sh`.
- Obtain a token via `test-harness/scripts/mint-token.sh`.
- Exercise the PoC's own surface.
- Tear down via `test-harness/scripts/down.sh`.
- If a PoC needs a new fixture or overlay, it adds it under `test-harness/fixtures/` (not its own private copy).

PoCs that deviate (their own docker-compose, their own seed script) are a rejection at review — one harness is a hard invariant.

## 9. What we intentionally DON'T test

Be explicit. If it's not here and it's not in §§1–8, the default is "we probably should test it" and reviewers should push back.

- **libghostty internal rendering correctness.** Trust ghostty's own tests. We assert terminal cell-buffer state in 0092, not Metal pixel output. We do not port ghostty's renderer test suite.
- **Upstream ElectricSQL protocol conformance.** We trust `@electric-sql/client` (TypeScript reference) and the upstream `electric:3000` service to define and honor the protocol. We test our implementation against their reference; we don't re-prove Electric to ourselves.
- **SQLite's own correctness.** Trust Apple's / system SQLite. We test our wrapper, not SQLite internals.
- **Auth0 / WorkOS OAuth flows.** We test our PKCE client (0109), not Auth0's server. Their flow correctness is their product.
- **Freestyle VM internals.** We test our interaction with their API (0102 / PoC-B6). We do not test their boot sequences beyond measuring them.
- **Xcode code-signing internals.** We test that 0125 produces a signed build; we don't test the signing algorithm.
- **macOS AppKit / SwiftUI internal behavior.** We test our code against the platform contracts Apple documents; platform bugs are platform bugs.
- **GTK internals.** Same — GTK's own behavior is out of scope; we test our adapter.
- **Android runtime behavior.** Build-canary only. We do not prove the Android app runs correctly because we don't ship it to users in this pass.
- **Network transport below HTTP/2 + WebSocket.** We assume TCP + TLS work. We don't test kernel networking stacks.
- **JJHub's billing, quota UI beyond what we consume, or admin console.** Out of scope for this initiative.
- **Multi-client shared-PTY attach** beyond the PoC (0102). The PoC may conclude "don't ship in v1"; if so, we don't test what we don't ship.
- **Desktop-local engine binary.** Lives in a separate spec; its tests live there.
- **Web / wasm client.** Explicitly not a target in this pass (per main spec §Goals).

## 10. Per-PoC appendix table

For each PoC ticket, which tests it contributes to the matrix above. Keep this lean — the validation doc's §3 table is the authoritative artifact list; this is the mapping of PoC → matrix coverage.

| PoC ticket | Contributes tests for | Which §§ it closes |
|---|---|---|
| 0092 (libghostty iOS) | Canned PTY replay → cell-buffer assertion on simulator; device-slice build proof. | §1.5 iOS SwiftUI integration; §3 device-vs-simulator row for libghostty. |
| 0093 (Zig Electric client) | Subscribe / delta / reconnect / unsubscribe unit against fake server; integration against plue + Postgres + Electric; wrong-repo `where` rejection; reconnect at offset 0, mid-delta. | §1.4 core unit + integration; §2.1 Electric reconnect rows (offset 0, mid-delta); §5.2 fuzz target seeded from its recordings; §6 subscribe → first row benchmark. |
| 0094 (Zig WS PTY) | Frame encode/decode unit (fragmented, close, ping/pong); integration with real plue + mock-sandbox asserting `echo hello`; bad-Origin negative; missing-bearer negative; no subprotocol-rejection test (explicit). | §1.4 core unit + integration; §2.2 bad-Origin + missing-bearer; §2.3 write-during-disconnect, backpressure, resize-during-output; §5.1 WS frame decoder fuzz. |
| 0095 (Zig ↔ Swift FFI) | FFI tick, subscribe/unsubscribe lifecycle, main-thread marshaling, TSan + ASan + leak-checker clean on simulator. | §1.4 core unit; §1.5 SwiftUI integration at the FFI boundary; §3 sanitizer rows. |
| 0096 (Electric Go consumer) | Go consumer against plue auth proxy; auth accept/reject; wrong-repo `where`; upstream 502; delta fan-out integration. | §1.1 plue engine routes under electric; §1.2 plue Electric proxy unit + integration; provides reference harness that 0093 and 0110 study. |
| 0102 (multi-client PTY attach) | Two-client attach proof; write-policy test; detach-without-killing-peer test. **Note:** if the PoC concludes "defer v1," §2.3 multi-client tests stay out of scope and we don't pretend they're covered. | §2.7 adjacent (concurrent writes semantics for PTY specifically, if adopted); otherwise flagged in §9 as "not tested because not shipped." |
| 0103 (Zig + SQLite iOS) | Open/write/read/close on simulator; on-device smoke run; size-overhead measurement. | §1.4 core SQLite unit; §2.4 WAL in iOS sandbox; §3 device row for SQLite; §6 cache-read-latency baseline. |
| 0104 (Android core canary) | Android build on every PR; emulator-run of FFI counter (dev-local); NDK + Zig target configured; JNI bindings; `.so` size recorded. | §1.7 Android canary; §7 CI job spec. |

## 11. Self-check

Applying the validation doc's universal checks to this doc:

1. **Reference integrity.** All cited paths exist in the current tree: `plue/internal/routes/workspace_terminal.go`, `plue/internal/electric/auth.go`, `plue/cmd/guest-agent/`, `plue/internal/sandbox/guest/`, `coder/websocket` upstream, `libsmithers/src/persistence/sqlite.zig`, `poc/android-core/` (0104 landing), `.zig-version`, etc. Line references mirror ticket citations and are grep-verifiable.
2. **Scope match.** Every bullet in 0097's Scope has a corresponding section: per-component layers (§1), boundary conditions (§2), iOS device-vs-simulator (§3), local-only vs Freestyle (§4), fuzz (§5), benchmarks (§6), Android canary (§7), e2e orchestration (§8), intentional non-tests (§9), per-PoC appendix (§10).
3. **RPC / wire format.** None introduced; doc-only.
4. **Error taxonomy.** References existing / future 0098 taxonomy entries (`auth_expired`, `origin_rejected`, `approval_already_decided`). A follow-up note for 0098 if any of those aren't yet declared there.
5. **Metric presence.** References benchmark metrics named in §6; thresholds TBD per PoC-B6 per explicit 0097 Scope allowance.
6. **Mock discipline.** §8.3 explicitly names where mocking is correct (mock-sandbox for integration without Freestyle) and §4 names where it must not be used (PoC-B6 sandbox-timing measurements).
7. **Commit / PR hygiene.** Enforced by commit step.
8. **Feature flag gate.** N/A — doc-only.
9. **Cross-link coherence.** Links out to `ios-and-remote-sandboxes.md`, `ios-and-remote-sandboxes-execution.md`, `ios-and-remote-sandboxes-validation.md`, `ios-and-remote-sandboxes-observability.md` (0098, in flight), plus every referenced ticket (0092–0096, 0102–0104, 0107, 0108, 0109, 0110, 0111, 0113, 0114–0118, 0120, 0125, 0131). No tombstoned-ticket references.
10. **No forbidden assumption.** Desktop-local excluded per §9 and flagged as sibling-spec.
