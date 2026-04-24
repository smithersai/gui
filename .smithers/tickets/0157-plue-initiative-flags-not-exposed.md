# plue: ios-remote-sandboxes feature flags missing from `/api/feature-flags`

## Context

Surfaced while attempting to run the full iOS e2e suite after the 10-agent
codex batch. The harness gates on `PLUE_REMOTE_SANDBOX_ENABLED=1` and
verifies via `GET /api/feature-flags`. The live response is:

```json
{"flags":{"client_error_reporting":true,"client_metrics":true,
"integrations":false,"landing_queue":false,"readout_dashboard":false,
"repo_snapshots":false,"secrets_manager":false,"session_replay":false,
"tool_policies":false,"tool_skills":false,"web_editor":false}}
```

None of the initiative's documented flags are exposed:
- `remote_sandbox_enabled` (kill switch, ticket 0112)
- `electric_client_enabled` (ticket 0112)
- `approvals_flow_enabled` (ticket 0112)
- `devtools_snapshot_enabled` (tickets 0112 + 0107)
- `run_shape_enabled` (tickets 0112 + 0111)

Ticket 0112 marked "Merged" but the flags were never wired into the
feature-flags handler.

## Plan

- Find the feature-flags handler in `plue/internal/routes/flags.go`.
- Add the five flags with documented defaults from the tickets.
- If plue has a DB-backed `feature_flags` table, seed rows; otherwise
  hardcode defaults matching the ticket specs.

## Acceptance criteria

- `GET /api/feature-flags` returns all five flags.
- `ios/scripts/run-e2e.sh`'s flag gate passes without needing
  `PLUE_REMOTE_SANDBOX_ENABLED=0` override.
- `SmithersiOSE2EFeatureFlagsTests.swift` scenarios stop XCTSkipping on
  "flag not exposed".
