# Fix Prompts Preview Uses Saved File Not Editor Buffer

## Problem

The prompt preview panel reads from the saved file on disk rather than the
current editor buffer. Unsaved edits are not reflected in the preview.

Review: prompts.

## Current State

- Preview loads the file path, ignoring the in-memory editor text.

## Proposed Changes

- Pass the editor buffer contents to the preview renderer instead of the
  file path.
- Update preview on each edit (debounced).

## Files

- Prompts view files
- Preview/render logic

## Acceptance Criteria

- Preview reflects unsaved editor changes in real time.
- Saving is not required to see preview updates.
