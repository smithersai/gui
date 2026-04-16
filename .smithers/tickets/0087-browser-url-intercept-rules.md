# URL Intercept Rules for Browser Surface Routing

## Problem

When a link is opened (clicked in browser pane, cmd-clicked in terminal, opened
by an agent, or routed from a markdown surface), the user currently has no
control over whether it opens in the in-app browser surface or in the OS
default browser. Users want per-URL rules:

- Internal/dev URLs (`localhost:*`, `*.internal`, `127.0.0.1:*`) → in-app
  browser surface.
- External URLs (`*.slack.com`, `linear.app`, `github.com/orgs/*`) → OS default
  browser.
- Default catch-all configurable.

cmux has the machinery (WKNavigationDelegate hooks) but does not ship the rule
table. We build that here.

## Proposed Design

### 1. Config Schema

Rules live in `smithers.json` (global + per-repo, see ticket 0088) under a
`browser` block:

```json
{
  "browser": {
    "intercept": [
      { "pattern": "localhost:*",        "target": "in-app" },
      { "pattern": "127.0.0.1:*",        "target": "in-app" },
      { "pattern": "*.local",            "target": "in-app" },
      { "pattern": "*.internal",         "target": "in-app" },
      { "pattern": "github.com/*/pull/*", "target": "in-app" },
      { "pattern": "*",                  "target": "default-browser" }
    ]
  }
}
```

- Patterns are glob-style against the full URL or host+path.
- `target` is one of: `in-app`, `default-browser`, `ask`.
- First matching rule wins.
- Missing config falls back to `default-browser` for everything.

### 2. Entry Points that Must Respect the Table

All of these call a single `URLRouter.route(url:, source:)`:

1. `WKNavigationDelegate.webView(_:decidePolicyFor:)` inside
   `Sources/Panels/BrowserSurfaceView.swift` and any `CmuxWebView`-style
   subclass.
2. Terminal hyperlink click (cmd-click) paths in `TerminalView.swift`.
3. Markdown surface link clicks (ticket 0086).
4. Any `openURL:` call the app makes itself.
5. Notification body click handlers when they contain URLs.

### 3. URLRouter

```swift
enum URLIntercept { case inApp, defaultBrowser, ask }

struct URLRouter {
    static func decide(for url: URL) -> URLIntercept
    static func route(url: URL, source: URLSource, in workspace: WorkspaceID?)
}
```

- `decide` consults the rule table.
- `route`:
  - `.inApp`: open as a surface in the current workspace. Reuse an existing
    browser surface in the same workspace if one exists; otherwise split or
    open a new browser surface.
  - `.defaultBrowser`: `NSWorkspace.shared.open(url)`.
  - `.ask`: present a small confirmation popover with both options, remember
    choice per-host if the user checks "Remember".

### 4. Glob Matching

Support cmux-style globs:

- `*` matches a segment, `**` matches any.
- `?` matches a single char.
- Host-only patterns (`github.com`) match any URL on that host.
- Optional port wildcards (`localhost:*`).

### 5. UI

- Settings → Browser → Intercept Rules table with add/edit/reorder/delete.
- Inline "Open externally" / "Open in app" per-link context menu override.
- Status line shows "Rule: <pattern> → <target>" on hover.

## Non-Goals for First Pass

- Request interception/mocking (that is a full agent-browser parity story).
- Per-workspace rule scoping (first pass is global).
- Proxy/authentication routing.

## Files Likely to Change

- New `Sources/BrowserRouting/URLRouter.swift`
- New `Sources/BrowserRouting/URLInterceptRule.swift`
- `BrowserSurfaceView.swift`
- `TerminalView.swift` (cmd-click path)
- Markdown surface from ticket 0086
- Settings view
- Tests under `Tests/SmithersGUITests`

## Test Plan

- Glob matcher: exact host, wildcard host, `localhost:*`, path prefix, full
  wildcard.
- First-match-wins ordering.
- `WKNavigationDelegate` policy honors the decision for main-frame
  navigations and new-window requests.
- Terminal cmd-click routes through the router.
- Reuse-existing-browser-surface-in-workspace behavior when one is present.
- `ask` mode remembers per-host choice when the user opts in.
- Falling back to `default-browser` when no config is present.

## Acceptance Criteria

- Users can define URL intercept rules in `smithers.json`.
- All URL-opening paths consult a single router.
- `localhost:*` and intranet URLs stay in-app by default when configured.
- External URLs open in the OS default browser.
- Settings UI allows editing rules without editing JSON by hand.
