# Plue: run-inspection tree + tasks shape slice

## Context

Ticket 0124 (C-DATA) wired the remote data plane but left
`RunInspection` (the tree + tasks data the RunInspectView renders) on
the legacy CLI path with a `TODO(0126)` that 0126 didn't address.
Current state: opening a run's inspect view in remote mode shows
nothing because there's no shape and the CLI fallback doesn't work
remotely.

## Goal

Define the production Electric shape(s) that carry run inspection data
and wire the client through the SmithersStore.

## Scope

- Identify the underlying tables: probably `workflow_run_steps` +
  `workflow_run_artifacts` + `workflow_run_logs` or similar.
- Add shapes scoped by `repository_id IN (...) AND run_id IN (...)`.
  Opening a run's inspect view opens these shapes; LRU-evict on close.
- Update `SmithersStore.RunsStore` to consume the new shapes and feed
  `RunInspectView`.

## Acceptance criteria

- `RunInspectView` renders from SmithersStore in remote mode.
- iOS e2e scenario: dispatch a run, open the inspect view, see at
  least the step list populated.

## Dependencies

- 0111 (run shape) already exists for the run metadata; this extends.
- 0140 (real transport) for end-to-end verification.
