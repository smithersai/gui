# Plue: add new feature flags for iOS + remote sandbox rollout

## Context

Ticket 0101 (rollout plan) enumerates five new global feature flags the rollout will use: `remote_sandbox_enabled`, `electric_client_enabled`, `approvals_flow_enabled`, `devtools_snapshot_enabled`, `run_shape_enabled`. Plue's feature-flag surface today is a fixed list in `internal/config/config.go:53` exposed via `GET /api/feature-flags` (`internal/routes/flags.go`). None of these five flags exist. This ticket adds them.

Without this ticket, 0101 references flags that don't resolve to anything, and every implementation ticket that gates its new behavior (0093, 0096, 0107, 0110, 0111) has nothing to read from.

## Problem

Adding a handful of global booleans is mechanical but the absence of this work was a real gap. Leaving it implicit would result in either the implementation tickets each silently adding their own flag in uncoordinated ways, or ship-time scrambling when it turns out no flag exists.

## Goal

Five new global env-backed feature flags, added to plue's existing flag machinery, exposed via `/api/feature-flags`, with documentation for each describing what it gates.

## Scope

- **In scope**
  - Add five bool entries to `FeatureFlagsConfig` in `plue/internal/config/config.go`:
    - `RemoteSandboxEnabled` (env: `PLUE_REMOTE_SANDBOX_ENABLED`)
    - `ElectricClientEnabled` (env: `PLUE_ELECTRIC_CLIENT_ENABLED`)
    - `ApprovalsFlowEnabled` (env: `PLUE_APPROVALS_FLOW_ENABLED`)
    - `DevtoolsSnapshotEnabled` (env: `PLUE_DEVTOOLS_SNAPSHOT_ENABLED`)
    - `RunShapeEnabled` (env: `PLUE_RUN_SHAPE_ENABLED`)
  - Wire each into the `/api/feature-flags` response in `internal/routes/flags.go`.
  - Defaults: all five default to `false` for safety. Internal dev env overrides to `true`.
  - Each flag has a one-line comment describing exactly what behavior is gated.
  - Tests: `flags.go` test verifies each new flag appears in the response and reflects env overrides correctly.
- **Out of scope**
  - Implementing the gated behavior — each gated feature is its own ticket. Owner mapping (must match 0101 rollout plan):
    - `RemoteSandboxEnabled` → umbrella for iOS + desktop-remote client work: 0109 + 0113 (umbrella) + 0120–0126.
    - `ElectricClientEnabled` → production Electric surfaces: 0114 (agent_sessions), 0115 (agent_messages), 0116 (workspaces), 0117 (workspace_sessions), 0118 (agent_parts). NOT the PoCs 0093/0096 — those prove the machinery but aren't production surfaces.
    - `ApprovalsFlowEnabled` → 0110 (plue approvals implementation).
    - `DevtoolsSnapshotEnabled` → 0107 (plue devtools snapshot surface).
    - `RunShapeEnabled` → 0111 (plue run shape + route reconciliation).
  - Per-user or per-cohort scoping — explicitly not in scope per rollout plan's Option (a) choice; if that changes, a follow-up ticket adds cohort scoping.
  - Kill-switch tooling beyond "flip env var and restart."

## References

- `plue/internal/config/config.go:53` — existing `FeatureFlagsConfig` struct.
- `plue/internal/routes/flags.go` — the `/api/feature-flags` response assembler.

## Acceptance criteria

- Five new fields in `FeatureFlagsConfig`, all default `false`.
- Each exposed in `/api/feature-flags`.
- Each has an env-var override documented.
- Tests cover presence + env override.
- Every flag is cross-referenced to its owner ticket so future readers can trace the dependency.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies all five flags appear in the GET response (not just a subset), env overrides actually flip values (tests don't silently use defaults), and naming matches what 0101 rollout plan references (any rename must update 0101 in a drive-by edit).

## Risks / unknowns

- Scope creep into per-user gating — resist. If the rollout decides to want it, that's a separate ticket on top of this one.
