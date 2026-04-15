# Fix ChatBlock Fallback IDs Non-Deterministic

## Problem

When a `ChatBlock` lacks a server-provided ID, the fallback uses `UUID()`,
producing a new ID on every decode or copy. This breaks SwiftUI diffing,
causes unnecessary re-renders, and can lose scroll position.

Review: models.

## Current State

- `ChatBlock` assigns `UUID()` as a default ID in its initializer or decoder.

## Proposed Changes

- Generate deterministic fallback IDs from content hash (e.g., role + index
  + a content prefix).
- Ensure IDs are stable across re-decodes of the same data.

## Files

- `SmithersModels.swift`

## Acceptance Criteria

- ChatBlock IDs are stable for identical content across decodes.
- SwiftUI list diffing does not produce spurious animations or re-renders.
