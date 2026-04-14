# Wire Search Backend In GUI

## Problem

The GUI has a `SearchView`, but `searchCode`, `searchIssues`, and
`searchRepos` return empty arrays. The TUI search view is JJHub-backed.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI stubs: `SmithersClient.searchCode`, `searchIssues`, and `searchRepos`.
- TUI source of truth: `../tui/internal/ui/views/search.go`.
- TUI JJHub client support: `SearchCode`, `SearchIssues`, and
  `SearchRepositories` in `../tui/internal/jjhub/client.go`.

## Goal

Wire GUI search to JJHub search APIs/CLI behavior.

## Proposed Changes

- Implement repository, issue, and code search client methods.
- Preserve issue state filtering.
- Render code snippets with file path and line numbers.
- Render result counts and empty/error states accurately.

## Acceptance Criteria

- GUI search returns real code, issue, and repo results.
- Issue state filters are honored.
- Code results show snippets and line numbers.
- Empty results mean no matches, not an unimplemented backend.

