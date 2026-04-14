# Port SQL Browser To GUI

## Problem

The TUI includes a Smithers SQL browser with table listing, schema inspection,
and query execution. The GUI defines `SQLResult` but has no SQL browser view or
client methods.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- TUI source of truth: `../tui/internal/ui/views/sql.go`.
- TUI client support: `ListTables`, `GetTableSchema`, and `ExecuteSQL` in
  `../tui/internal/smithers/systems.go` and
  `../tui/internal/smithers/client.go`.
- GUI has no SQL navigation destination or view.

## Goal

Add a native GUI SQL browser for Smithers data inspection.

## Proposed Changes

- Add `SQLBrowserView.swift`.
- Add Smithers client methods for listing tables, loading schema, and executing
  supported SQL.
- Mirror TUI transport behavior: HTTP first, safe SQLite read path where
  available, and clear no-transport messaging.
- Support query editor, results table, schema display, refresh, and error
  rendering.

## Acceptance Criteria

- Users can browse Smithers tables.
- Users can inspect table schema.
- Users can run supported SQL queries and see tabular results.
- Unsupported/mutating queries are blocked or routed consistently with the TUI.

