# Fix Inspect CLI JSON Shape Mismatch

## Problem

The GUI parses `smithers inspect` output expecting a different JSON structure
than the CLI actually produces. Fields are misnamed or nested differently,
causing inspect results to silently fail or show incomplete data.

Reviews: transport, runs.

## Current State

- `SmithersClient` calls `smithers inspect` and decodes the response into
  Swift model types that do not match the real CLI output schema.
- Affected models live in `SmithersModels.swift`.

## Proposed Changes

- Audit `smithers inspect --json` output against the Swift `Codable` models.
- Fix field names, nesting, and optional/required mismatches.
- Add integration-style tests that decode real CLI sample output.

## Files

- `SmithersClient.swift`
- `SmithersModels.swift`

## Acceptance Criteria

- `smithers inspect` JSON decodes without errors against real CLI output.
- Run detail views display correct data from inspect results.
