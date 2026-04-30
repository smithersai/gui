# 0195 Beta Happy Path E2E Trace

Audit date: 2026-04-30

## Summary

Leadership needs one reliable end-to-end trace that answers whether the product works for a real tester: sign in, choose workspace, chat/dispatch, observe run, approve, inspect output, use terminal if enabled, sign out, and verify local data is gone. Existing unit tests are broad, but this product trace is the readiness gate.

## Parallel Ownership

Primary owner writes:

- `ios/Tests/SmithersiOSE2ETests/*HappyPath*`
- `macos/Tests/SmithersMacOSE2ETests/*HappyPath*` if macOS remote mode is included
- `ios/scripts/run-e2e.sh`
- `macos/scripts/run-e2e.sh`
- `ios/scripts/seed-e2e-data.sh`
- docs under `docs/` or `.smithers/specs/`

Avoid app production code except to add missing accessibility identifiers discovered during test writing. If identifiers are needed, coordinate with the feature owner for that view.

## Requirements

- Define the beta happy path in a checked-in trace document.
- Make the E2E harness seed only the minimum data required.
- Prefer production discovery flows over hardcoded `PLUE_E2E_*` IDs wherever previous tickets have removed the need.
- Assert user-visible states, not just launch/no-crash.
- At the end, sign out and verify user-scoped UI/cache no longer shows stale workspace/session data.

## Acceptance Criteria

- [ ] A checked-in trace document lists each user step and backend assertion.
- [ ] iOS E2E covers sign-in/restored auth bypass, workspace open, agent message send, run discovery, approval decision, run output/log visibility, and sign-out wipe.
- [ ] Terminal is included if ticket 0188 has shipped; otherwise the trace explicitly asserts terminal is gated with clear copy.
- [ ] E2E failure artifacts are uploaded by CI or documented locally.
- [ ] The test can run against the local Plue stack with one command.

## Verification

```sh
./ios/scripts/run-e2e.sh
./macos/scripts/run-e2e.sh
```

## Related

- `.smithers/tickets/0175-happy-path-traceability.md`
- `.smithers/tickets/0181-user-testing-readiness-roadmap.md`
