# Markdown + Mermaid Viewer Surface with Live File Reload

## Problem

Agents frequently produce plan/notes files (`plan.md`, design docs, mermaid
diagrams) that are easier to review rendered than raw. Today the user has to
open these in another editor. We also want agents to include mermaid diagrams
in plans and have them render in-app.

cmux has a `MarkdownPanel` surface (`Sources/Panels/MarkdownPanel.swift`) with
a DispatchSource file watcher that handles atomic saves (editor write-temp +
rename) and temporary deletion. It does **not** render mermaid — that is our
addition.

## Proposed Design

### 1. MarkdownSurface

A new surface type alongside terminal/browser. Holds:

- Absolute file path.
- Current content (string).
- Watcher state.
- Focus/flash plumbing matching other surfaces.

### 2. File Watcher (port from cmux)

Copy the DispatchSource approach from `vendor/cmux/Sources/Panels/MarkdownPanel.swift`:

- `DispatchSource.makeFileSystemObjectSource` with mask
  `[.write, .delete, .rename, .extend]`.
- On delete/rename: stop the watcher, reload content, schedule bounded retry
  to reattach (up to ~6 attempts at 500ms).
- On extend/write: reload content only.
- Fall back to directory watcher if the file does not exist yet.
- Correctly reopen to the new inode after atomic rename.

### 3. Renderer

Use a `WKWebView` with a locally bundled HTML shell that loads:

- `marked` (markdown → HTML) or `markdown-it`.
- `mermaid.js` for fenced ` ```mermaid ` blocks.
- `highlight.js` for fenced code blocks.
- A small CSS with a light/dark theme driven by `window.matchMedia`.

Render pipeline:

1. Swift receives `content` updates.
2. Swift calls `webView.evaluateJavaScript("window.smithersMarkdown.setContent(...)")`.
3. JS renders via marked, then calls `mermaid.run()` on any rendered `.mermaid`
   blocks.
4. External links open via a `WKNavigationDelegate` that routes through the
   URL intercept table (ticket 0087) — or defaults to external browser.

### 4. Opening a MarkdownSurface

- Command palette: "Open Markdown File…"
- `smithers markdown open <path> [--workspace ref] [--surface ref]` (see ticket
  0085).
- Drop a `.md` file into a workspace.
- Right-click a `.md` file in the file explorer and "Open in markdown viewer".

### 5. File Unavailable State

If the file is gone and retry exhausts, show a "File unavailable" placeholder
with the path and an instruction; watcher keeps polling in the background for
reappearance.

## Non-Goals for First Pass

- Editing markdown inside the surface (we already have `MarkdownEditorView.swift`
  elsewhere; that stays separate).
- Rendering across agents' notes in a single merged view.
- Export to HTML/PDF.
- Mermaid live-edit playground.

## Files Likely to Change

- New `Sources/Panels/MarkdownSurface.swift`
- New `Sources/Panels/MarkdownSurfaceView.swift`
- New `Resources/MarkdownShell/index.html` bundling marked + mermaid
- `WorkspaceSurfaceModels.swift`
- `SidebarView.swift` (icon for markdown surfaces)
- `CommandPaletteModel.swift` (add "Open Markdown File…")
- Tests under `Tests/SmithersGUITests`
- `project.yml` / `Package.swift` for resource bundling

## Test Plan

- Opening a markdown file loads content.
- Editing the file via simple write triggers a re-render within one watcher
  tick.
- Atomic rename save (vim-style `:w`) reattaches the watcher to the new inode.
- Delete then recreate within the retry window reconnects and renders new
  content.
- Deleted-and-stays-deleted shows unavailable state.
- A fenced ` ```mermaid ` block renders a diagram.
- A fenced code block renders with syntax highlighting.
- External links routed through the URL intercept (or default) path.
- Theme follows light/dark system preference.

## Acceptance Criteria

- A new MarkdownSurface renders markdown including mermaid diagrams.
- Content updates live on disk changes.
- File watcher tolerates atomic saves and brief deletion windows.
- Surface integrates with workspace/pane/surface identity from ticket 0083.
- Accessible from the command palette and the agent CLI.
