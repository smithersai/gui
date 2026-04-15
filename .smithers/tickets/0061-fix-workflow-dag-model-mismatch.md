# Fix Workflow DAG Model Mismatch

## Problem

The workflow DAG model in the GUI does not match the structure returned by
`smithers workflow graph`, causing graph rendering to fail or show incorrect
edges.

Review: workflows.

## Current State

- Field names or edge representations differ between CLI output and Swift
  model.

## Proposed Changes

- Audit `smithers workflow graph --json` output and align the Swift DAG model.
- Fix edge/node field mappings.

## Files

- `SmithersModels.swift`
- Workflow graph view files

## Acceptance Criteria

- Workflow DAG decodes correctly from real CLI output.
- Graph renders with correct nodes and edges.
