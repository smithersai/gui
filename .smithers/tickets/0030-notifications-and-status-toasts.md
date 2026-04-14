# Add Notifications And Status Toasts

## Problem

The TUI has in-terminal notifications/toasts and native notification support.
The GUI does not appear to expose equivalent status/notification behavior for
agent completion, warnings, errors, or background run updates.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- TUI source of truth: `../tui/internal/ui/notification`,
  `../tui/internal/ui/model/notifications.go`, and `components/toast.go`.
- GUI has basic inline error/loading states but no shared notification system.

## Goal

Add a GUI notification/toast system that covers the same important events as the
TUI.

## Proposed Changes

- Add a shared toast/notification model for GUI views.
- Surface errors, warnings, info, completion, approval, and run update events.
- Add dismiss behavior.
- Wire native macOS notifications where appropriate.
- Ensure noisy/non-fatal events stay non-blocking.

## Acceptance Criteria

- GUI shows transient status messages for important events.
- Users can dismiss notifications.
- Background completion/approval events can trigger native notifications where
  appropriate.
- Notification behavior is consistent across views.

