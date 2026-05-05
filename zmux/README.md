# zmux

`zmux` is the tmux-style PTY session package used by SmithersGUI. It is written
in Zig and follows tmux's core architecture: a long-lived server owns the mux
model and PTY child processes, while GUI/client processes attach and detach
through a UNIX-domain socket.

The tmux reference points used for this package are:

- `../tmux/server.c`: server socket creation, long-running server loop, client handling
- `../tmux/client.c`: client connect/start-server retry and start lock pattern
- `../tmux/proc.c`: background server process model
- `../tmux/spawn.c`: server-owned PTY child creation
- `../tmux/tmux.1`: documented client/server attach/detach behavior

## Supported

- UNIX-domain JSON-RPC control socket
- owner-only socket file permissions; newly-created private socket directories
  are tightened to `0700` without chmodding existing parents like `/tmp`
- same-UID peer credential validation on accepted socket clients
- daemon-side startup locking so concurrent starters cannot unlink or steal a
  live daemon socket
- daemon ping and shutdown
- server-owned session, window, pane, layout, client, key binding, alert, and
  respawn state exposed by `mux.snapshot`
- session create, info, list, terminate, resize, input, key, and capture RPCs
  for the current GUI
- window new/select/rename
- pane split/select/rename/respawn
- multiple logical clients attached to the same pane, with client list, switch,
  and detach APIs
- prefix-style key binding and dispatch APIs, plus a first tmux-like command
  parser for `split-window`, `new-window`, and `respawn-pane`
- PTY resize, input send, named key send, and scrollback capture
- tmux-style logical client attachments: the control connection remains open
  for the lifetime of a live attachment, and closing it detaches that client
- server-side pane output capture with bounded replay on reattach
- pane output, activity, bell, exit, and foreground process notifications for
  GUI affordances
- client-side raw mode, SIGWINCH resize forwarding, and termios restoration
- helper binary aliases for existing GUI integration:
  `smithers-session-daemon` and `smithers-session-connect`

## Current Gaps

`zmux` now owns the state that should move out of the GUI, but it is not
command-line compatible with tmux yet. The current command parser is deliberately
small and should be expanded behind the same daemon model as the GUI migrates:
target syntax, options, copy mode, paste buffers, status bars, menus, popups,
hooks, formats, config files, and layout persistence remain incomplete.

GUI clients use logical `client.attach` plus `pane_output` notifications, so
multiple native, GTK, or web frontends can observe the same server-owned pane
without taking exclusive ownership of the PTY fd.

Like tmux, `zmux` keeps sessions alive across client/GUI restarts only while
the daemon process and its PTY child processes remain alive. It does not keep
live processes alive across an operating-system reboot.

## Build And Test

```sh
cd zmux
zig build
zig build test
```

Artifacts:

- `zig-out/bin/zmuxd`
- `zig-out/bin/zmux-connect`
- `zig-out/bin/smithers-session-daemon`
- `zig-out/bin/smithers-session-connect`

Protocol version is reported by `daemon.ping` from `src/protocol.zig`.
