# Fix Workflow Launch Input Type Handling

## Problem

The workflow launch UI does not handle all input types correctly. Non-string
inputs (booleans, numbers, arrays) are sent as strings or ignored.

Review: workflows.

## Current State

- All workflow inputs are treated as strings in the launch form.

## Proposed Changes

- Parse workflow input schemas to determine types.
- Render appropriate input controls (toggles, number fields, etc.).
- Serialize inputs with correct JSON types when launching.

## Files

- Workflow launch view files
- `SmithersClient.swift`

## Acceptance Criteria

- Workflow inputs are rendered with type-appropriate controls.
- Non-string inputs are serialized with correct JSON types.
