# Add Scores Metrics Parity

## Problem

The GUI scores view lists recent scores and aggregates client-side, but lacks
the TUI's token usage, latency, and cost metrics.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI source: `ScoresView.swift` and `SmithersClient.aggregateScores`.
- TUI source of truth: `../tui/internal/ui/views/scores.go`.
- TUI client support: `GetTokenUsageMetrics`, `GetLatencyMetrics`, and
  `GetCostTracking` in `../tui/internal/smithers/systems.go`.

## Goal

Add the missing metrics surface to the GUI scores view.

## Proposed Changes

- Add GUI models for token metrics, latency metrics, and cost reports.
- Add Smithers client methods matching TUI filters and transport fallback.
- Render summary metrics and any daily/weekly/period breakdowns exposed by the
  TUI.
- Preserve existing recent/aggregate score display.

## Acceptance Criteria

- GUI displays token usage metrics.
- GUI displays latency metrics.
- GUI displays cost tracking metrics.
- Metrics loading errors do not break score listing.
- Values match TUI output for the same Smithers database/server.

