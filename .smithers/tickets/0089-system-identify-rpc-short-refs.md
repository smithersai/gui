# system.identify RPC and Short Ref Handles

## Problem

As soon as the socket CLI (ticket 0085) has two consumers — an agent script
and a human at the REPL — both immediately need two things:

1. A "where am I?" call that tells them which window/workspace/pane/surface
   they are in. Without it, every script has to guess or require flags.
2. Human-friendly short handles. UUIDs are unreadable in scripts; requiring
   them in every CLI call is painful.

cmux nails both. This ticket extracts them as a first-class primitive so every
other CLI/RPC method can rely on it.

## Proposed Design

### 1. system.identify

JSON-RPC method: `system.identify`.

Request (no params required):

```json
{ "method": "system.identify", "params": {} }
```

Response:

```json
{
  "caller": {
    "window_id": "window:1",
    "workspace_id": "workspace:3",
    "pane_id": "pane:5",
    "surface_id": "surface:12",
    "surface_type": "terminal",
    "surface_uuid": "C9F3...",
    "valid": true
  },
  "focused": {
    "window_id": "window:1",
    "workspace_id": "workspace:3",
    "pane_id": "pane:5",
    "surface_id": "surface:12",
    "surface_type": "terminal"
  }
}
```

When the surface is a browser surface, also include:

```json
"focused": {
  "surface_type": "browser",
  "browser": { "url": "https://...", "title": "...", "loading": false }
}
```

Caller resolution:

- Read `SMITHERS_WINDOW_ID`, `SMITHERS_WORKSPACE_ID`, `SMITHERS_SURFACE_ID` from
  the connecting process's environment (already injected by ticket 0085).
- Validate they still resolve to live surfaces.
- If any do not resolve, set `caller.valid = false` and leave fields null.

### 2. Short Refs

Format: `<kind>:<N>` where `kind ∈ {window, workspace, pane, surface}` and `N`
is a monotonic integer per app launch (already specified in ticket 0083).

- Allocator lives in a single `HandleResolver` service.
- Never reused within a launch.
- Every RPC method accepts refs **or** UUIDs.
- Every RPC response uses refs by default; UUIDs are available via the output
  mode flag.

### 3. ID Format Flag

Every CLI subcommand accepts `--id-format refs | uuids | both`:

- Plain-text default: `refs`.
- `--json` default: `refs`.
- `uuids`: show only UUIDs.
- `both`: show both, typically as `{ "id": "surface:12", "uuid": "..." }`.

### 4. system.capabilities

Companion method that returns the full method list and which of them support
browser surfaces, write operations, or background/async semantics. Lets CLIs
and agents detect support without shipping per-version logic.

```json
{
  "methods": [
    { "name": "system.identify", "readonly": true },
    { "name": "surface.focus",   "readonly": false, "focus_steal": true },
    { "name": "surface.log",     "readonly": false }
  ]
}
```

### 5. Focus-Steal Marking

As part of capabilities, every method is marked `focus_steal: true|false`. Only
methods marked true may change the user's focus. This is enforced at the
dispatcher level to make it mechanical: non-focus methods cannot accidentally
activate a window (this is the cmux socket-focus-steal-audit policy).

## Non-Goals for First Pass

- Remote / SSH relay aware identify (no remote daemon yet).
- Persisting short refs across app relaunch.
- Exposing arbitrary app state beyond the handle graph.

## Files Likely to Change

- `Sources/SocketProtocol.swift` (add methods)
- `Sources/HandleResolver.swift` (ticket 0083)
- `CLI/smithers.swift` (ticket 0085) — `identify`, `capabilities`, `--id-format`
- Tests under `Tests/SmithersGUITests`

## Test Plan

- `system.identify` with no flags returns caller + focused, both populated.
- `system.identify` with caller env pointing at a closed surface returns
  `caller.valid=false` and populated `focused`.
- Browser surface focused → `browser.{url,title,loading}` fields present.
- Short refs accepted in every existing method.
- Output includes refs by default, UUIDs only with `--id-format uuids`.
- Focus-steal policy: non-focus methods do not bring the app to front even when
  it is in the background.
- Short ref allocator is monotonic and never reuses within a launch.

## Acceptance Criteria

- `smithers identify` works with zero flags from any Smithers terminal.
- Every RPC method accepts both refs and UUIDs.
- Default output uses refs; `--id-format` switches in both plain and JSON mode.
- `system.capabilities` enumerates methods and marks focus-steal behavior.
- Focus-steal policy enforced centrally; no ad-hoc focus changes slip through.
