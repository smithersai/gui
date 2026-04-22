# Remove tmux Dependency with Native PTY Session Daemon

## Status (audited 2026-04-21)

**PARTIAL.** Phase 1 (native backend) is substantially implemented; Phase 3 (tmux removal) is not done; Phase 2 (migration tool) is not done.

### Done
- Native session daemon in Zig implemented:
  - `libsmithers/src/session/daemon.zig:1` — entrypoint with `--socket`/`--idle-seconds` args, PID file, socket path fallback.
  - `libsmithers/src/session/server.zig:345` — dispatches `daemon.ping`, `session.create`, `session.attach`, `session.detach`, `session.terminate`, `session.list`, `session.resize`, `session.capture`, `session.send`, `session.sendKey` (all methods from the ticket table).
  - `libsmithers/src/session/session.zig`, `pty.zig`, `buffer.zig`, `protocol.zig`, `fd_passing.zig`, `native.zig`, `event_stream.zig`, `foreground.zig` — all present.
- CLI connector: `libsmithers/cli/session-connect.zig:1` (384 lines).
- Swift integration: `macos/Sources/Smithers/Smithers.SessionController.swift:1` (495 lines) with `ensureDaemon`/`createSession`/`attach`/`detach`/`terminate`/`capture`/`send`/`resize`.
- `TerminalBackend.native` case added and new surfaces default to `.native` in several constructors (`WorkspaceSurfaceModels.swift:214`, `Models.swift:326`, `Models.swift:393`).
- `WorkspaceSurface.sessionId` wired; native teardown path in `Models.swift:733`.
- Integration tests: `libsmithers/test/integration/session_daemon.zig`; unit tests: `Tests/SmithersGUITests/SessionControllerTests.swift`.

### Remaining
- tmux source still present: `libsmithers/src/terminal/tmux.zig` (not deleted per Phase 3).
- `TmuxController` still present and used: `Models.swift:193`; tmux code path is still reachable (`Models.swift:342,360,424,627,728,879,947`).
- `WorkspaceSurface.tmuxSocketName` / `tmuxSessionName` fields still exist (`WorkspaceSurfaceModels.swift`… actually `Models.swift:63,64,151,152,174,175,335,403`). Ticket says replace with `sessionId`; today both coexist.
- Default backend inconsistency: `Models.swift:61` still defaults `backend = .tmux`, while `WorkspaceSurfaceModels.swift:214` defaults `.native` — ticket wants new surfaces on `.native`.
- Phase 2 migration tool for orphaned tmux sessions: not implemented.
- No evidence of `smithers capture --session <id>` / `smithers send --session <id>` CLI surface replacing `tmuxCapturePane` / `tmuxSendText` (acceptance criteria).
- `TmuxControllerTests.swift` still present (`Tests/SmithersGUITests/TmuxControllerTests.swift`).
- `ghostty_surface_attach_pty` / fd-attachment strategy vs. command-wrapper: command-wrapper path (`session-connect.zig`) exists, but no confirmation it is wired as the default for new terminal surfaces in `TerminalView.swift`.

## Problem

Terminal surfaces currently use tmux as a session multiplexer to provide:
1. **Session persistence** — shells survive app crashes/restarts
2. **Output capture** — `tmuxCapturePane()` reads scrollback
3. **Process lifecycle** — tmux server owns the shell, not the GUI

This introduces an external dependency, spawns extra processes per session, and
requires tmux to be installed. We already have:
- A libsmithers/Swift separation with FFI
- A socket server architecture (tickets 0085, 0090)
- libghostty with `ghostty_surface_read_text()` for buffer access

We can replace tmux with a native PTY session daemon in libsmithers that owns
shells and allows the GUI to reconnect after crashes.

## Architecture Overview

```
┌─────────────────────────┐
│     Swift GUI App       │
│  ┌───────────────────┐  │
│  │  TerminalView     │  │     Unix Socket
│  │  (ghostty render) │◄─┼──────────────────┐
│  └───────────────────┘  │                  │
│  ┌───────────────────┐  │                  │
│  │  libsmithers.a    │  │                  │
│  │  (linked in-proc) │  │                  │
│  └───────────────────┘  │                  │
└─────────────────────────┘                  │
                                             │
┌────────────────────────────────────────────▼─┐
│              smithers-session-daemon          │
│  ┌─────────────────────────────────────────┐ │
│  │  SessionServer (Zig)                    │ │
│  │  - Owns PTY file descriptors            │ │
│  │  - Spawns/manages shell processes       │ │
│  │  - Maintains scrollback ring buffers    │ │
│  │  - Accepts socket connections from GUI  │ │
│  │  - Forwards PTY I/O to connected client │ │
│  └─────────────────────────────────────────┘ │
│                      │                        │
│         ┌────────────┼────────────┐          │
│         ▼            ▼            ▼          │
│     ┌──────┐    ┌──────┐    ┌──────┐        │
│     │ PTY  │    │ PTY  │    │ PTY  │        │
│     │ bash │    │ zsh  │    │ fish │        │
│     └──────┘    └──────┘    └──────┘        │
└──────────────────────────────────────────────┘
```

## Proposed Design

### 1. Session Daemon (`smithers-session-daemon`)

A standalone Zig executable that:

- Runs as a background daemon, launched on-demand by the GUI
- Listens on `$XDG_RUNTIME_DIR/smithers-sessions.sock` or
  `~/.smithers/sessions.sock`
- Manages a pool of PTY sessions identified by stable session IDs
- Persists session metadata to `~/.smithers/sessions.db` (SQLite)
- Survives GUI crashes; GUI reconnects on restart

#### Daemon Lifecycle

1. GUI checks if daemon is running via socket ping
2. If not, GUI spawns daemon as detached subprocess
3. Daemon writes PID to `~/.smithers/session-daemon.pid`
4. Daemon exits after configurable idle timeout (default: 1 hour with no
   sessions)

#### Session State Machine

```
CREATING → RUNNING → DETACHED → TERMINATED
              │          ▲
              └──────────┘
           (client disconnects)
```

- **CREATING**: PTY allocated, shell spawning
- **RUNNING**: Client attached, I/O flowing
- **DETACHED**: Client disconnected, shell still alive, output buffered
- **TERMINATED**: Shell exited, session can be removed

### 2. Wire Protocol (JSON-RPC over Unix Socket)

Request format:
```json
{"id": 1, "method": "session.create", "params": {...}}
```

Response format:
```json
{"id": 1, "result": {...}}
{"id": 1, "error": {"code": -1, "message": "..."}}
```

#### Methods

| Method | Description |
|--------|-------------|
| `daemon.ping` | Health check, returns version |
| `daemon.shutdown` | Graceful shutdown (terminates all sessions) |
| `session.create` | Create new session with shell/cwd/env |
| `session.attach` | Attach to existing session, receive PTY fd |
| `session.detach` | Detach from session (keeps shell running) |
| `session.terminate` | Kill session and shell |
| `session.list` | List all sessions with state |
| `session.info` | Get session metadata (pid, cwd, title, state) |
| `session.resize` | Send TIOCSWINSZ to PTY |
| `session.capture` | Read scrollback buffer (last N lines) |
| `session.send` | Write bytes to PTY stdin |
| `session.sendKey` | Send key sequence to PTY |

#### File Descriptor Passing

For `session.attach`, the daemon sends the PTY master fd to the client via
`SCM_RIGHTS` ancillary data. The client (ghostty) then does direct I/O on the
fd. This avoids proxying all terminal data through the socket.

```zig
// Daemon side: send fd
const cmsg = std.os.linux.cmsghdr(...);
cmsg.cmsg_type = std.os.linux.SCM_RIGHTS;

// Client side: receive fd
const fd = recvmsg(...);
ghostty_surface_attach_fd(surface, fd);
```

### 3. Scrollback Buffer Management

Each session maintains an in-memory ring buffer:

- Default size: 10MB (matches ghostty default)
- Configurable per-session or globally
- Persisted to disk on clean shutdown for crash recovery (optional phase 2)

The `session.capture` method returns text from this buffer, replacing
`tmuxCapturePane()`.

### 4. libghostty Integration

Currently ghostty spawns shells directly. We need to:

1. **Add fd attachment mode**: New API `ghostty_surface_attach_pty(surface, fd)`
   that uses an existing PTY fd instead of spawning
2. **Or use existing command mechanism**: Pass a "cat" command that just
   connects stdin/stdout to the daemon's forwarded stream

Option 1 is cleaner. This requires either:
- Upstream ghostty change (preferred)
- Local patch in our ghostty submodule

### 5. Swift Integration Layer

Replace `TmuxController` with `SessionController`:

```swift
enum SessionController {
    /// Ensure daemon is running, spawn if needed
    static func ensureDaemon() async throws

    /// Create a new session, returns session ID
    static func createSession(
        workingDirectory: String?,
        command: String?,
        environment: [String: String]?
    ) async throws -> SessionID

    /// Attach to session, returns PTY file descriptor
    static func attach(sessionId: SessionID) async throws -> FileDescriptor

    /// Detach from session (keeps shell running)
    static func detach(sessionId: SessionID) async throws

    /// Terminate session
    static func terminate(sessionId: SessionID) async throws

    /// Capture scrollback
    static func capture(sessionId: SessionID, lines: Int) async throws -> String

    /// Send text to session
    static func send(sessionId: SessionID, text: String, enter: Bool) async throws

    /// Resize session PTY
    static func resize(sessionId: SessionID, cols: UInt16, rows: UInt16) async throws
}
```

### 6. WorkspaceSurface Changes

Update `TerminalBackend` enum:

```swift
enum TerminalBackend: String, Codable {
    case native   // New: smithers-session-daemon
    case ghostty  // Direct ghostty spawn (no persistence)
    case tmux     // Legacy (deprecated, remove after migration)
}
```

Update `WorkspaceSurface`:

```swift
struct WorkspaceSurface {
    // Replace tmux fields:
    // - var tmuxSocketName: String?   // REMOVE
    // - var tmuxSessionName: String?  // REMOVE

    // Add native session field:
    var sessionId: SessionID?  // For .native backend
}
```

### 7. Migration Path

#### Phase 1: Add Native Backend (This Ticket)
- Implement session daemon in Zig
- Add SessionController Swift wrapper
- Add ghostty fd attachment (or use command wrapper)
- Default new surfaces to `.native`
- Keep `.tmux` for existing surfaces

#### Phase 2: Migration Tool
- On app launch, detect orphaned tmux sessions
- Offer to migrate them to native sessions (spawn new shell in same cwd)
- Or terminate them cleanly

#### Phase 3: Remove tmux Code
- Delete `libsmithers/src/terminal/tmux.zig`
- Delete `Smithers.Terminal.swift` tmux wrappers
- Remove tmux detection code
- Update documentation

## Implementation Details

### Daemon Source Location

```
libsmithers/
├── src/
│   └── session/
│       ├── daemon.zig        # Main daemon entry point
│       ├── server.zig        # Socket server, RPC dispatch
│       ├── session.zig       # Session state machine
│       ├── pty.zig           # PTY allocation/management
│       ├── buffer.zig        # Ring buffer for scrollback
│       ├── protocol.zig      # JSON-RPC message types
│       └── fd_passing.zig    # SCM_RIGHTS helpers
├── build.zig                 # Add daemon executable target
└── include/
    └── smithers.h            # Add session FFI functions
```

### Daemon Build Target

```zig
// build.zig addition
const daemon = b.addExecutable(.{
    .name = "smithers-session-daemon",
    .root_source_file = b.path("src/session/daemon.zig"),
    .target = target,
    .optimize = optimize,
});
b.installArtifact(daemon);
```

### Socket Path Resolution

```zig
fn socketPath(allocator: Allocator) ![]u8 {
    // Prefer XDG_RUNTIME_DIR (per-user, tmpfs, auto-cleaned)
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |xdg| {
        return std.fs.path.join(allocator, &.{xdg, "smithers-sessions.sock"});
    }
    // Fallback to ~/.smithers/
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return std.fs.path.join(allocator, &.{home, ".smithers", "sessions.sock"});
}
```

### Ghostty fd Attachment

If upstream doesn't accept fd attachment, use a command wrapper:

```swift
// Instead of spawning shell directly, spawn a connector
let command = "smithers-session-connect \(sessionId)"
let surface = ghostty_surface_new(app, &config)
// config.command = command
```

The `smithers-session-connect` binary:
1. Connects to daemon socket
2. Calls `session.attach`
3. Receives PTY fd
4. Proxies stdin/stdout to PTY fd
5. Exits when session terminates

This adds one process per terminal but avoids patching ghostty.

## Files to Change

### New Files
- `libsmithers/src/session/daemon.zig`
- `libsmithers/src/session/server.zig`
- `libsmithers/src/session/session.zig`
- `libsmithers/src/session/pty.zig`
- `libsmithers/src/session/buffer.zig`
- `libsmithers/src/session/protocol.zig`
- `libsmithers/src/session/fd_passing.zig`
- `libsmithers/cli/session-connect.zig` (if using wrapper approach)
- `macos/Sources/Smithers/Smithers.Session.swift`

### Modified Files
- `libsmithers/build.zig` — add daemon executable
- `libsmithers/include/smithers.h` — add session FFI
- `WorkspaceSurfaceModels.swift` — replace tmux fields with sessionId
- `WorkspaceContentView.swift` — use SessionController instead of TmuxController
- `TerminalView.swift` — support fd attachment or command wrapper
- `Models.swift` — replace TmuxController with SessionController

### Deprecated/Removed (Phase 3)
- `libsmithers/src/terminal/tmux.zig`
- `macos/Sources/Smithers/Smithers.Terminal.swift` (tmux parts)

## Test Plan

### Unit Tests
- `session.zig`: State machine transitions
- `buffer.zig`: Ring buffer wraparound, capacity limits
- `protocol.zig`: JSON-RPC parsing/serialization
- `fd_passing.zig`: SCM_RIGHTS send/receive

### Integration Tests
- Daemon starts on first session create
- Session persists after client disconnect
- Client reconnects to detached session
- Scrollback capture returns correct content
- Resize propagates to PTY
- Session terminates when shell exits
- Daemon exits after idle timeout
- Multiple concurrent sessions
- GUI crash recovery (sessions survive, reconnect works)

### Migration Tests
- New surfaces default to `.native` backend
- Existing `.tmux` surfaces continue working
- Mixed workspace with both backends

### Performance Tests
- PTY I/O latency (should be <1ms overhead vs direct)
- Memory usage per session (target: <15MB including scrollback)
- Daemon startup time (<100ms)

## Acceptance Criteria

- [ ] New terminal surfaces use native session daemon by default
- [ ] Sessions persist across app restart (daemon keeps shells alive)
- [ ] `smithers capture --session <id>` returns scrollback (replaces tmuxCapturePane)
- [ ] `smithers send --session <id> "command"` works (replaces tmuxSendText)
- [ ] GUI shows session state (attached/detached) in sidebar
- [ ] Daemon auto-starts when first session is created
- [ ] Daemon auto-exits after configurable idle period
- [ ] No tmux process spawned for new sessions
- [ ] Performance: no perceptible latency increase vs tmux

## Non-Goals for Phase 1

- Remote session support (SSH relay)
- Session sharing between users
- Encrypted session storage
- Session recording/replay
- Integration with system session management (systemd user sessions)

## Future Considerations

- **Session groups**: Multiple sessions that start/stop together
- **Session templates**: Predefined shell configurations
- **Session export**: Dump full session history to file
- **Cross-machine sync**: Session state replication (very future)

## Dependencies

- Ticket 0085 (socket server) — shares socket infrastructure patterns
- Ticket 0090 (socket auth) — daemon should support same auth modes
- Ticket 0083 (surface vocabulary) — session IDs follow same patterns

## Risks

1. **Ghostty fd attachment**: May require upstream changes or local fork
   - Mitigation: Command wrapper approach works without ghostty changes

2. **fd passing complexity**: SCM_RIGHTS is platform-specific
   - Mitigation: macOS and Linux both support it; abstract in fd_passing.zig

3. **Daemon reliability**: Daemon crash loses all sessions
   - Mitigation: Watchdog/auto-restart, session state persistence to disk

4. **Migration disruption**: Users with many tmux sessions
   - Mitigation: Keep tmux backend functional during transition, provide
     migration tool
