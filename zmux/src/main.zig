//! Feature-minimal tmux-style PTY session server for SmithersGUI.
//!
//! `zmux` deliberately implements only the GUI-facing contract: a durable
//! local daemon owns PTY child processes, GUI/client processes attach and
//! detach over a UNIX socket, and server-owned PTYs keep running with
//! bounded scrollback capture for replay on reattach.

pub const buffer = @import("buffer.zig");
pub const daemon = @import("daemon.zig");
pub const foreground = @import("foreground.zig");
pub const mux = @import("mux.zig");
pub const native = @import("native.zig");
pub const protocol = @import("protocol.zig");
pub const pty = @import("pty.zig");
pub const server = @import("server.zig");

pub const NativeSession = native.NativeSession;
pub const NativeSessionOptions = native.NativeSessionOptions;
pub const Server = server.Server;
pub const SessionManager = mux.Manager;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
