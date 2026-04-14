# Port Triggers And Crons To GUI

## Problem

The TUI has a `triggers` view for Smithers cron schedules. The GUI has a
`listCrons` client method, but no view calls it and create/toggle/delete are
missing.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- TUI source of truth: `../tui/internal/ui/views/triggers.go`.
- TUI client support: `ListCrons`, `CreateCron`, `ToggleCron`, and
  `DeleteCron` in `../tui/internal/smithers/client.go`.
- GUI `SmithersClient.listCrons()` exists but is unused.
- GUI has no triggers/crons navigation destination.

## Goal

Add GUI parity for cron trigger management.

## Proposed Changes

- Add `TriggersView.swift` and navigation.
- Wire list/create/toggle/delete client methods.
- Show pattern, workflow path, enabled status, next/last run, and error JSON.
- Support refresh and form validation.

## Acceptance Criteria

- GUI lists cron triggers.
- GUI can create a cron trigger.
- GUI can enable/disable a cron trigger.
- GUI can delete a cron trigger.
- Empty, loading, and error states match TUI expectations.

