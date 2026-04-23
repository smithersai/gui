# Design: testing strategy for iOS + remote sandboxes

## Context

From `.smithers/specs/ios-and-remote-sandboxes-execution.md`, task D1. Design-only. The spec introduces a three-piece architecture (engine / core / platform UI), multiple network surfaces (Electric / WebSocket / HTTP / SSE), a new client-side SQLite cache, and cross-platform targets (macOS, iOS, Linux, Android WIP). No single current test strategy covers this surface.

## Goal

A written testing strategy document at `.smithers/specs/ios-and-remote-sandboxes-testing.md` that prescribes, per component, what kinds of tests exist, what boundary conditions must be covered, and how the Android WIP canary stays honest.

## Scope of the output doc

Each section below is a section of the doc being produced by this ticket.

- **Per-component test layers.** For each of {plue engine routes, plue Electric proxy, guest-agent, `libsmithers-core`, SwiftUI platform UI, GTK UI, Android UI}: which of {unit, integration, e2e, fuzz, benchmark} applies and why. State what runs in CI and what runs on a developer's machine only.
- **Boundary conditions to explicitly exercise.** Non-exhaustive starting list the doc must expand:
  - Electric shape reconnect at byte offset 0, at mid-delta, across token refresh, across schema migration.
  - **WebSocket PTY handshake failures** (per what plue actually enforces): bad `Origin` header rejected (`workspace_terminal.go:84`), missing bearer token rejected. Client surfaces each as a distinct error. *Subprotocol rejection is NOT tested* — `coder/websocket`'s `Accept` only selects an offered subprotocol and does not reject missing/wrong ones; if the test strategy doc wants subprotocol enforcement tested, it must first propose adding that enforcement to plue as a prerequisite.
  - WebSocket PTY: write-during-disconnect, backpressure (slow reader), ping/pong across network pause, resize during active output.
  - SQLite cache eviction during active subscription (does the shape re-populate?).
  - Auth token expiry mid-request on each transport; refresh races.
  - Shape subscription during sandbox suspend/resume.
  - Concurrent writes to the same session from two clients.
  - Approval race: two clients decide simultaneously.
- **iOS device vs simulator coverage matrix.** Explicit list of which tests run on which. Simulator-gated: Swift sanitizers (TSan/ASan), CI e2e. Device-required: signing, real Keychain, background/backgrounding behavior, APNs interaction if added. Build-only on device is acceptable for most PoCs; runtime on device is reserved for auth + backgrounding tests.
- **Local-only vs Freestyle-dependent test matrix.** Split the e2e tests by whether they need a real Freestyle VM (for sandbox boot timing, guest-agent behavior) vs. can mock the sandbox layer (Electric, auth, most routes). Only the former runs gated on a Freestyle API key in CI.
- **Fuzz targets.** Identify at least: WS frame decoder, Electric shape delta parser, JSON control-message parser on WS, guest-agent vsock protocol parser. For each, one paragraph on corpus seeding and failure criteria.
- **Benchmarks.** Name the metrics worth regression-testing (Electric subscribe → first row latency, WS PTY round-trip, SQLite cache read p50/p99 under N shapes). Include thresholds only if we have PoC-B6 data; otherwise mark TBD.
- **Android WIP canary.** CI job that builds `libsmithers-core` for `aarch64-linux-android` and runs the equivalent of PoC-A4. If build breaks, the offending PR is labeled. No runtime tests on device in this pass.
- **E2E orchestration.** How full-stack e2e tests run: docker-compose for plue + Postgres + Electric, a test sandbox, a headless SwiftUI test runner, a headless Zig client. Document the harness expected by every PoC so they all plug into one rig.
- **What we intentionally don't test.** Be explicit: anything out of scope (e.g., libghostty's internal rendering correctness — trust ghostty's own tests).

## Acceptance criteria

- Doc lives at `.smithers/specs/ios-and-remote-sandboxes-testing.md`, structured per sections above.
- Each PoC ticket (0092–0096 and later) has an entry in an appendix table showing which tests it contributes to the overall matrix.
- Cross-linked from the execution plan (`ios-and-remote-sandboxes-execution.md`) and the main spec.
- Reviewed and approved by the spec owner before any Stage 1 PoC begins implementation.

## Independent validation

See D3 (`ticket 0099`). Until D3 lands: reviewer verifies each boundary condition in the spec has a specific test named somewhere, and that "unit vs integration vs e2e" lines are drawn concretely (what runs in each, not hand-wavy).

## Out of scope

- Writing any tests. This ticket produces a doc; actual tests are written inside each PoC and feature ticket.
- CI infrastructure changes beyond naming what jobs need to exist.
