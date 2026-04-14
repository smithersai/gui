# Fix Approve And Deny CLI Shape

## Problem

The GUI calls Smithers approval commands with an argument shape that disagrees
with the TUI and current Smithers CLI. Per instruction, the TUI/Smithers shape
is correct and the GUI is wrong.

## Current State

- GUI uses `approve --run <runId> <nodeId>` and `deny --run <runId> <nodeId>`
  in `SmithersClient.swift`.
- TUI uses `approve <runId> --node <nodeId>` and
  `deny <runId> --node <nodeId>` in `../tui/internal/smithers/runs.go`.
- Smithers CLI implementation expects the run ID as the positional argument and
  the node via `--node`.

## Goal

Correct the GUI approval command construction and keep it aligned with the TUI.

## Proposed Changes

- Change GUI approval args to `["approve", runId, "--node", nodeId]`.
- Change GUI denial args to `["deny", runId, "--node", nodeId]`.
- Include `--iteration`, `--note`, or reason/note options using the CLI shape
  supported by Smithers.
- Add focused tests or a small command-builder seam so the argument shape
  cannot regress.

## Acceptance Criteria

- Approve from GUI succeeds against the same Smithers CLI the TUI uses.
- Deny from GUI succeeds against the same Smithers CLI the TUI uses.
- Multiple pending approvals still pass a node ID explicitly.
- Tests or verification cover the constructed command arguments.

