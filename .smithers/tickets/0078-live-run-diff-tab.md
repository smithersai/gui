# Live Run Inspector — Diff Tab

> Quality bar: spec §9.

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §2.2 "Diff".

Unified git/jj diff of files a task changed.

## Scope

### `DiffTab`

Input: selected node.

On mount: `smithers.getNodeDiff(runId, nodeId, iteration)`.

### Renderer

- File list at top: per-file add/mod/del badges + line counts. Click a
  file → scroll to section.
- Body: per-file collapsible sections (default: first 3 files expanded,
  rest collapsed when total files > 3).
- Hunks: red `-`, green `+`, muted context.
- Line numbers on the left (old | new).
- Binary files: icon + size; no preview.
- Deleted files: red "File deleted" header + old content as context.
- Added files: green "New file" header + content as `+`.

### Large diff handling

- Patches > 50 files OR total bytes > 1 MB → all files collapsed by
  default + warning at top ("Large diff — expand files individually").
- File with > 2000 lines → render first 1000 + "Expand remaining N
  lines" button.
- Total diff > 50 MB (server-side `DiffTooLarge`) → show error + hint.

### Empty / loading / error

- Loading spinner.
- Empty patches → "No file changes."
- `DevToolsClientError` → banner + retry.

## Files (expected)

- `DiffTab.swift` (new)
- `DiffFileView.swift` (new)
- `DiffHunkView.swift` (new)
- `UnifiedDiffParser.swift` (new)
- `SmithersClient.swift` (add `getNodeDiff`)
- `Tests/SmithersGUITests/UnifiedDiffParserTests.swift`
- `Tests/SmithersGUITests/DiffFileViewTests.swift`
- `Tests/SmithersGUITests/DiffTabTests.swift`
- `Tests/SmithersGUIUITests/DiffTabE2ETests.swift`

## Testing & Validation

### Unit tests — UnifiedDiffParser

Parametric over fixtures:

- Empty diff string → zero hunks.
- Single hunk with no context → parses correctly.
- Multiple hunks in same file → correct line numbers.
- File with only additions → all hunks `+`.
- File with only deletions → all hunks `-`.
- Rename header (`rename from / rename to`) → correct old/new paths.
- Mode change header → recorded.
- Hunk header with no end count (`@@ -12 +12 @@`) → count defaults to 1.
- Hunk with "\ No newline at end of file" → handled, not treated as content.
- Non-ASCII content in hunks → preserved.
- Very long single line (8,000 chars) → not corrupted.
- Patch with CRLF line endings → normalized to LF.
- Malformed header → throws `DiffParseError` with line number.

### Unit tests — DiffFileView

- Added / modified / deleted / renamed badges correct.
- Line counts calculated correctly.
- Binary file → "Binary" badge, no hunks.
- > 2000 line file → pagination toggle.
- Collapse / expand toggle persists per-file.

### Unit tests — DiffTab

- Loading state → spinner.
- Empty patches → empty message.
- Normal diff → rendered.
- Large diff (50+ files) → warning + all collapsed.
- Error → retry button works.
- Refresh on iteration change (inspector selects a new iteration).
- In-flight RPC cancelled on tab switch.

### Input-boundary tests

| Case                                | Expected                          |
|-------------------------------------|-----------------------------------|
| Zero patches                         | "No file changes."               |
| 1 file, 1 hunk, 1 line               | renders                          |
| 100 files, each 10 hunks             | file list + collapsed by default |
| File with 10,000 lines changed       | pagination at 1,000 lines        |
| File with 1 line 8,000 chars wide    | horizontal scroll, no wrap       |
| Binary file                          | icon + size                      |
| Added-then-deleted (net empty)       | empty                            |
| Non-UTF8 filename                    | rendered with unicode normalization; no crash |
| CRLF line endings                    | rendered as LF                   |
| Rename with small edit               | rename header + small hunk       |
| `DiffTooLarge` from server           | error + hint                     |
| `DiffTooLarge` with partial truncation marker | visible "truncated at N MB" marker |

### Integration / UI tests

- Task changes 3 files → diff renders correctly.
- Click a file in list → smooth scroll to its section.
- Collapse a file → hunks hidden.
- Copy a hunk → pasteboard check.
- 100-file fixture → list performant, collapsed, expanding one works.

### Accessibility

- File list is a landmark; each file has a role.
- Keyboard nav through hunks (next hunk / previous hunk).
- Line numbers announce ("line 42 added").
- Contrast on `+` / `-` / context backgrounds passes WCAG AA in both
  themes (including color-blind safe — test with deuteranopia-simulated
  palette).

### Performance

- 10-file diff: render < 200ms.
- 100-file diff (collapsed): render < 500ms.
- Expanding a 2000-line file: < 500ms.
- Scroll-to-file: smooth, no jank.

## Observability

- `debug` on RPC: duration, byte count, file count.
- `warn` on `DiffTooLarge`.
- `warn` on parser error with line number (no patch content).
- Signposts around parse and render.

## Error handling

- Parse errors on specific hunks → skip that hunk, mark file as "partial
  parse", log warn. Other files still render.
- Every typed `DevToolsClientError` maps to a user-facing message + hint.

## Acceptance

- [ ] Every parser fixture passes.
- [ ] Every boundary case handled.
- [ ] UI tests pass.
- [ ] Accessibility tests pass (VoiceOver, keyboard, contrast in both
      themes and color-blind palettes).
- [ ] Performance budgets met.
- [ ] Manual verification against real task diffs.
- [ ] Diff content never logged above `debug`.

## Blocked by

- smithers/0011
- gui/0076
