## Status (audited 2026-04-21)

Done:
- Zig CLI scaffold with arg parsing and subcommand dispatch (`libsmithers/cli/src/main.zig:28`, commands at `libsmithers/cli/src/commands/`: info, cwd, workspace, slash, palette, session, client, persistence, event).
- `session-connect` companion binary speaks to a daemon socket via `--socket` / `--spawn-daemon` (`libsmithers/cli/session-connect.zig:17`), commit `b3f54703` ("feat(cli): add smithers cli frontend").
- DevTools streaming routed through the CLI (commit `105c9616`).
- `SurfaceNotificationStore` exists and tracks per-surface notifications/unread/errored/focus state (`SurfaceNotificationStore.swift:14`).

Remaining:
- No Unix-domain socket server in-app at `~/.cmux/smithers-<uid>.sock` / `$XDG_RUNTIME_DIR/smithers.sock`; no JSON-RPC v2 line protocol handler. No `SocketServer.swift` / `SocketProtocol.swift`.
- No env injection of `SMITHERS_SOCKET_PATH` / `SMITHERS_WINDOW_ID` / `SMITHERS_WORKSPACE_ID` / `SMITHERS_SURFACE_ID` for spawned PTYs (grep finds zero hits in `TerminalView.swift` / session store).
- Missing command surface: `identify`, `capabilities`, `ping`, `notify`, `set-status`, `clear-status`, `set-progress`, `clear-progress`, `log`, `list-log`, `read-screen`, `trigger-flash`, `list-workspaces`/`list-panes`/`list-surfaces`, `send`, `send-key`.
- No agent-hook wrappers (`claude-hook`, `codex-hook`, `cursor-hook`, `gemini-hook`).
- `SurfaceNotificationStore` not extended with `statusByKey`, `progress`, or bounded log ring buffer (grep: no matches for `statusByKey`/`progress`/ring buffer).
- No sidebar rendering of status chips / progress / log.
- No bundled CLI install path (`Contents/Resources/smithers-cli/smithers`) or "Install smithers CLI" Settings action.
- No focus-steal policy implementation, no agent-cli docs at `.smithers/docs/agent-cli.md`.

---

# Add smithers CLI with Socket Control and Env Injection

## Problem

Agents (Claude Code, Codex, etc.) running inside a Smithers terminal surface
cannot currently ask the app "where am I?", push status into the sidebar, or
notify the user when they finish a turn. Today this requires bespoke
observability per child process.

cmux solves this with a `cmux` Swift binary that talks to a Unix socket the app
exposes. Every shell Smithers spawns gets env vars (`SMITHERS_SOCKET_PATH`,
`SMITHERS_SURFACE_ID`, `SMITHERS_WORKSPACE_ID`, `SMITHERS_WINDOW_ID`). The CLI
reads them and talks JSON-RPC over the socket. This is the single most
leveraged piece of cmux's design.

## Proposed Design

### 1. Socket Server in-App

- Unix domain socket at `~/.cmux/smithers-<uid>.sock` or
  `$XDG_RUNTIME_DIR/smithers.sock` when available.
- JSON line-delimited protocol (v2 RPC) with request IDs.
- Socket file permissions default to `0o600`.
- Runs on a background dispatch queue; handlers route to main only when they
  must mutate AppKit/SwiftUI state.

### 2. Env Injection

Every PTY/child process Smithers launches gets:

- `SMITHERS_SOCKET_PATH`
- `SMITHERS_WINDOW_ID`
- `SMITHERS_WORKSPACE_ID`
- `SMITHERS_SURFACE_ID`

These are the short refs (ticket 0083). UUIDs are available via `identify`.

### 3. CLI Binary

A thin Swift executable `smithers` that:

- Reads the env vars to determine default targeting.
- Supports `--window`, `--workspace`, `--surface` to override.
- Speaks JSON-RPC to the socket.
- Pretty-prints for humans; supports `--json` for machines.

### Initial Command Surface

| Command | Description |
|---------|-------------|
| `smithers identify` | Returns focused window/workspace/pane/surface IDs plus caller's surface |
| `smithers capabilities` | Lists supported RPC methods |
| `smithers ping` | Round-trip health check |
| `smithers notify --title T [--body B] [--subtitle S] [--surface ref]` | Pushes a notification to the app + macOS Notification Center |
| `smithers set-status <key> <value> [--surface ref]` | Writes a sidebar status chip |
| `smithers clear-status <key> [--surface ref]` | Clears a status chip |
| `smithers set-progress <pct> [--surface ref]` | Sets progress 0–100 |
| `smithers clear-progress [--surface ref]` | Clears progress |
| `smithers log <text> [--surface ref]` | Appends a line to the surface log store |
| `smithers list-log [--surface ref]` | Reads recent log lines |
| `smithers read-screen [--surface ref]` | Returns visible terminal buffer for a surface |
| `smithers trigger-flash [--surface ref]` | Flashes the pane ring to grab attention |
| `smithers list-workspaces` / `list-panes` / `list-surfaces` | Read-only topology |
| `smithers send <text> [--surface ref]` | Writes text to a terminal surface's PTY |
| `smithers send-key <keychord> [--surface ref]` | Writes a key sequence |

Agent hook convenience wrappers:

- `smithers claude-hook` — reads stdin, dispatches to notify/status
- `smithers codex-hook`
- `smithers cursor-hook`
- `smithers gemini-hook`

### 4. Install Path

- Ship the binary in the app bundle under
  `Contents/Resources/smithers-cli/smithers`.
- A "Install smithers CLI" Settings action symlinks into
  `$HOME/.local/bin/smithers` (fallback `/usr/local/bin/smithers` if writable).

### 5. Agent Integration Docs

Short doc at `.smithers/docs/agent-cli.md` with copy-paste snippets for:

- Claude Code hooks
- Codex `notify`
- Generic shell `command -v smithers && smithers notify ...`

## Surface Interactions

- `SurfaceNotificationStore.swift` already exists; extend it with structured
  `statusByKey`, `progress`, and a bounded log ring buffer (default 500 lines).
- Sidebar surfaces render these compactly with truncation.

## Non-Goals for First Pass

- Browser automation CLI family (`smithers browser …`) — separate ticket.
- Remote / SSH daemon relay — not in scope.
- MCP-style tool exposure over the same socket.
- Password-mode socket auth (covered by ticket 0090).

## Files Likely to Change

- New `CLI/smithers.swift` (Swift Package executable)
- New `Sources/SocketServer.swift` (or in existing module)
- New `Sources/SocketProtocol.swift`
- `SurfaceNotificationStore.swift` (extend with status/progress/log)
- `TerminalView.swift` (env injection)
- `SessionStore.swift` (env injection on terminal tab creation)
- `SidebarView.swift` (render status/progress)
- `Package.swift`
- `project.yml`
- Tests under `Tests/SmithersGUITests`

## Test Plan

- Socket server starts with the app and accepts `ping`.
- `identify` returns the caller's surface when launched from a Smithers PTY.
- `notify` records into `SurfaceNotificationStore` and triggers the macOS
  notification.
- `set-status`/`clear-status` round-trip.
- `set-progress` clamps to 0–100.
- `log` appends bounded to the ring buffer.
- `read-screen` returns the current visible buffer.
- `trigger-flash` fires the ring animation.
- Env vars are injected into child processes in terminal surfaces.
- Commands accept both short refs and UUIDs.
- Socket focus policy: no socket command steals app focus unless it is an
  explicit focus verb (`window.focus`, `workspace.select`, `surface.focus`).

## Acceptance Criteria

- `smithers` is installable from within the app.
- From any Smithers terminal, `smithers identify` works without flags.
- Agents can push notifications, status, progress, and logs to their own
  surface's sidebar.
- Status/progress/log visible in the sidebar per surface.
- Socket server robust to reconnects and honors focus-steal policy.
