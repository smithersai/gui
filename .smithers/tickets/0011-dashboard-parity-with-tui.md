# Bring Dashboard To TUI Parity

## Problem

The GUI dashboard is a simplified overview with Runs, Workflows, and Approvals.
The TUI dashboard includes more tabs, JJHub data, quick actions, repo header
context, Smithers initialization, sessions, and active-run tab population.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- TUI source of truth: `../tui/internal/ui/views/dashboard.go`.
- GUI source: `DashboardView.swift`.
- GUI dashboard tabs are only Overview, Runs, Workflows, and Approvals.

## Goal

Make the GUI dashboard behavior match the TUI dashboard feature set.

## Proposed Changes

- Add dashboard tabs for Landings, Issues, Workspaces, and Sessions where
  applicable.
- Add quick action menu equivalents: initialize Smithers, run workflow, new
  chat, browse sessions.
- Show JJHub repo name when available.
- Show JJHub at-a-glance counts.
- Add active-run/approval indicators matching TUI semantics.
- Add active-run auto-population or GUI equivalent.
- Wire dashboard navigation actions into the GUI router.

## Acceptance Criteria

- GUI dashboard exposes all TUI dashboard tabs.
- GUI dashboard shows Smithers and JJHub overview data when transports exist.
- Users can initialize Smithers from the dashboard when missing.
- Dashboard navigation actions route to the correct GUI surfaces.

