# Fix CWD Home Fallback Missing for SmithersClient

## Problem

`SmithersClient` does not fall back to the user's home directory when no
explicit CWD is set. This can cause CLI commands to run in an unexpected
directory or fail.

Review: platform.

## Current State

- CWD is taken from the workspace but has no fallback when unset.

## Proposed Changes

- Default CWD to `FileManager.default.homeDirectoryForCurrentUser` when no
  workspace directory is configured.
- Log a warning when falling back.

## Files

- `SmithersClient.swift`

## Acceptance Criteria

- CLI commands execute in the home directory when no workspace CWD is set.
- No crash or undefined behavior when CWD is nil.
