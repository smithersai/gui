# Live Run Inspector — Diff Tab

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §2.2 "Diff".

Renders the unified git/jj diff of files a task changed.

## Scope

### 1. `DiffTab` view

Input: selected node.

On mount: call `smithers.getNodeDiff(runId, nodeId, iteration)`.

### 2. Diff renderer

- Top: file list with per-file add/mod/del badges + total line counts.
  Clicking a file scrolls to its section.
- Body: per-file collapsible sections (default: first 3 files expanded,
  rest collapsed).
- Hunks:
  - Red background for `-` lines, green for `+` lines.
  - Context lines muted.
  - Line numbers shown on the left (old | new).
- Binary files: icon + "Binary file, N bytes"; no preview.
- Deleted files: show red "File deleted" header + the old content as
  context (if `diff` contains it).
- Added files: show green "New file" header + the content as `+` lines.

### 3. Empty / loading / error

- Loading spinner.
- Empty: *"No file changes."*
- RPC error: banner + retry.

### 4. Large diffs

If `patches.length > 50` or total diff size > 1MB, render the file list
normally but collapse every file by default and show a warning at the top.
Avoid rendering all hunks at once.

## Files (expected)

- `DiffTab.swift` (new)
- `DiffFileView.swift` (new)
- `DiffHunkView.swift` (new)
- `UnifiedDiffParser.swift` (new — parse unified diff into hunks)
- `SmithersClient.swift` — add `getNodeDiff` method.
- `Tests/SmithersGUITests/UnifiedDiffParserTests.swift` (new)
- `Tests/SmithersGUITests/DiffTabTests.swift` (new)

## Acceptance

- Single-file modification renders correct hunks with line numbers.
- Binary file renders as icon + size.
- Added / deleted files render with correct headers.
- Empty patches array shows the empty message.
- 100-file diff: file list renders; files collapsed by default.

## Blocked by

- smithers/0011 (getNodeDiff RPC).
- gui/0076 (inspector shell).
