# Fix Timeline/Fork/Replay/Diff CLI Shape Mismatch

## Problem

The GUI builds incorrect argument shapes for `smithers timeline`,
`smithers fork`, `smithers replay`, and `smithers diff` commands. Flag names,
positional arguments, and JSON output schemas do not match the real CLI.

Reviews: transport, ui_build_theme.

## Current State

- Multiple timeline-related commands use wrong flag names or argument order.
- JSON decoding fails or returns partial data.

## Proposed Changes

- Audit each command against the real CLI `--help` / source.
- Fix argument construction in `SmithersClient`.
- Fix model decoding to match actual JSON output.

## Files

- `SmithersClient.swift`
- `SmithersModels.swift`

## Acceptance Criteria

- Timeline, fork, replay, and diff commands produce valid CLI invocations.
- JSON responses decode correctly into Swift models.
