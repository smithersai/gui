# Wire Landings Backend In GUI

## Problem

The GUI has a `LandingsView`, but its backend methods are stubs. Listing returns
an empty array and detail/diff/review/land actions throw `notAvailable`.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI stubs: `SmithersClient.listLandings`, `getLanding`, `landingDiff`, and
  `reviewLanding`.
- TUI source of truth: `../tui/internal/ui/views/landings.go`.
- TUI JJHub client support: `ListLandings`, `ViewLanding`, `CreateLanding`,
  `ReviewLanding`, `LandLanding`, `LandingDiff`, and `LandingChecks` in
  `../tui/internal/jjhub/client.go`.

## Goal

Replace GUI landings stubs with real JJHub-backed behavior.

## Proposed Changes

- Add a GUI JJHub transport or extend `SmithersClient` with JJHub command
  execution.
- Implement landing list, detail, create, review, land, diff, and checks.
- Update `LandingsView.swift` to expose missing create/checks/comment/change
  request behavior where the TUI supports it.
- Use the same command shapes as the TUI JJHub client.

## Acceptance Criteria

- `LandingsView` displays real landings.
- Users can view landing details and diffs.
- Users can approve, request changes/comment, and land where permitted.
- The GUI no longer silently shows empty landings because of stubbed methods.

