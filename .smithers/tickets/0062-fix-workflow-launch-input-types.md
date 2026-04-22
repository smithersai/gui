## Status (audited 2026-04-21)

Done:
- Typed JSON serialization for workflow inputs at launch time: booleans, numbers, and array/object (parsed from JSON) are coerced before send. See `QuickLaunchConfirmSheet.swift:209` (`resolvedInputs`) and `QuickLaunchConfirmSheet.swift:219` (`coerce(text:type:)`).
- `WorkflowLaunchField` carries `type` metadata used by the coercion (`SmithersModels.swift` launch fields decoded alongside `WorkflowDAG`).

Remaining:
- Launch form still renders every input as a plain `TextField` regardless of declared type (`QuickLaunchConfirmSheet.swift:138`). Acceptance criterion "rendered with type-appropriate controls" (Toggle for bool, numeric stepper/number field for number, JSON/array editor) is not implemented.
- No tests cover `coerce` or the launch-field UI path; add unit coverage once typed controls land.
- Audit any other workflow launch entry points (e.g. `WorkflowsView.swift`) to ensure they route through the same typed path rather than a legacy string-only form.

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
