# Fix Memory List CLI Shape and Workflow Scoping

## Problem

`SmithersClient.listMemories` builds invalid CLI arguments and does not scope
memory queries to the active workflow/namespace.

Reviews: memory, transport.

## Current State

- The CLI arguments do not match `smithers memory list` expected shape.
- Namespace/workflow scoping is absent; all memories are returned unfiltered.

## Proposed Changes

- Fix argument construction to match `smithers memory list` CLI shape.
- Add `--namespace` or `--workflow` flag forwarding when a scope is active.
- Update the memory list view to pass the active scope.

## Files

- `SmithersClient.swift`
- `SmithersModels.swift`
- Memory-related views

## Acceptance Criteria

- `memory list` produces valid CLI arguments.
- Memories can be scoped to the active workflow/namespace.
- Decoded results match the real CLI JSON output.
