# iOS end-to-end test harness

## Context

User directive: iOS functionality must be verifiable **automatically**
in a simulator, without human assistance. Ships the XCUITest harness
that drives the full iOS app against a real-but-local plue stack in
both CI and developer-local workflows.

## Goal

A CI-able XCUITest target and driver script that:
1. Starts plue via `make docker-up` (relies on follow-up ticket 0142
   having fixed the bun.lock drift).
2. Seeds deterministic fixture data (user, OAuth token, repo,
   workspace).
3. Launches SmithersiOS in the simulator with env-gated auth bypass
   (`PLUE_E2E_MODE=1` + `SMITHERS_E2E_BEARER=<token>`).
4. Runs XCUITest scenarios.
5. Tears down cleanly. Returns non-zero on any failure.

## Scope

- `ios/Tests/SmithersiOSE2ETests/` — XCUITest scenarios.
- `ios/scripts/run-e2e.sh` — the driver.
- `ios/scripts/seed-e2e-data.sh` — deterministic fixture seed.
- `.github/workflows/ios-e2e.yml` — CI job.
- `Shared/Sources/SmithersE2ESupport/` (or narrow additions to
  SmithersAuth) — env-gated auth bypass and base-URL override.

Scenario coverage v1:
1. Cold launch → sign-in screen.
2. Test-token launch → workspace switcher, seeded workspace visible.
3. Open workspace → chat shell renders.
4. Sign out → returns to sign-in, cache wiped.

Follow-up coverage:
- Terminal PTY e2e (after 0140 promotes real WS PTY transport).
- Approvals fan-out (two simulators, one decides).
- Reconnect resilience.

## Acceptance criteria

- `./ios/scripts/run-e2e.sh` returns 0 locally after `make docker-up`.
- CI workflow green on push to main.
- Every test asserts SOMETHING that would fail if the backend path
  broke — no placeholders.
- xcresult bundles uploaded as artifacts on failure.

## Dependencies

- 0142 (docker-up fix) must land first.
- 0140 (real transport) is NOT required for v1 scenarios (launch +
  auth path); it IS required before terminal e2e scenario.
