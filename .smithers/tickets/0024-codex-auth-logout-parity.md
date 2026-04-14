# Add Codex Auth And Logout Parity

## Problem

The TUI has onboarding and OAuth/API-key auth flows. The GUI has a `/logout`
slash command placeholder and no equivalent auth management surface.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI placeholder: `ChatView.swift` appends "Codex logout is not wired into
  this GUI yet."
- TUI auth dialogs live under `../tui/internal/ui/dialog/`.
- TUI also has onboarding behavior in `../tui/internal/ui/model/onboarding.go`.

## Goal

Add GUI auth management parity for Codex providers.

## Proposed Changes

- Add GUI login/onboarding flows for supported providers.
- Add logout behavior for current provider/session.
- Surface auth errors and missing provider states.
- Replace `/logout` placeholder with real behavior.

## Acceptance Criteria

- GUI can guide users through missing provider credentials.
- GUI can log out where the TUI supports logout.
- Auth state changes are reflected in chat readiness.
- Placeholder status text is removed.

