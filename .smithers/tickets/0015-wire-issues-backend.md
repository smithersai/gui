# Wire Issues Backend In GUI

## Problem

The GUI has an `IssuesView`, but its backend methods are stubs. Listing returns
an empty array and get/create/close throw `notAvailable`.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI stubs: `SmithersClient.listIssues`, `getIssue`, `createIssue`, and
  `closeIssue`.
- TUI source of truth: `../tui/internal/ui/views/issues.go`.
- TUI JJHub client support: `ListIssues`, `ViewIssue`, `CreateIssue`, and
  `CloseIssue` in `../tui/internal/jjhub/client.go`.

## Goal

Replace GUI issues stubs with real JJHub-backed issue behavior.

## Proposed Changes

- Implement JJHub issue list/detail/create/close in the GUI client.
- Preserve state filtering semantics.
- Show labels, assignees, body, number, state, and comment count.
- Ensure close/create actions refresh the view consistently.

## Acceptance Criteria

- `IssuesView` displays real issues.
- Users can create issues.
- Users can close open issues.
- Detail metadata matches what the TUI shows.

