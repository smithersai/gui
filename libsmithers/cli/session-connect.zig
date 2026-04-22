const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;

const fd_passing = @import("fd_passing");

const buffer_size: usize = 32 * 1024;
// Attach payload now carries a base64-encoded scrollback replay so the
// client can restore prior terminal state (tmux-style). Size the buffer
// to fit ~256 KiB of raw scrollback plus base64 overhead and JSON wrapping.
const attach_payload_max: usize = 512 * 1024;

var g_saved_termios: ?posix.termios = null;
var g_saved_termios_fd: posix.fd_t = 0;
var g_winch_flag = std.atomic.Value(bool).init(false);
var g_socket_path_for_signals: ?[]const u8 = null;
var g_session_id_for_signals: ?[]const u8 = null;

pub fn main() !void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dbg.allocator();
    defer _ = dbg.deinit();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var session_id: ?[]const u8 = null;
    var explicit_socket_path: ?[]const u8 = null;
    var spawn_daemon = false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--socket")) {
            i += 1;
            if (i >= argv.len) return fail("missing value for --socket", .{});
            explicit_socket_path = argv[i];
        } else if (std.mem.eql(u8, a, "--spawn-daemon")) {
            spawn_daemon = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try printUsage();
            return;
        } else if (a.len > 0 and a[0] == '-') {
            return fail("unknown flag: {s}", .{a});
        } else if (session_id == null) {
            session_id = a;
        } else {
            return fail("unexpected argument: {s}", .{a});
        }
    }

    const sid = session_id orelse return fail("session_id is required", .{});

    const path = if (explicit_socket_path) |value|
        try allocator.dupe(u8, value)
    else
        try resolveSocketPath(allocator);
    defer allocator.free(path);

    const socket_fd = try connectWithRetry(allocator, path, spawn_daemon);
    defer posix.close(socket_fd);

    // Send attach request.
    const attach_req = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.attach\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
        .{sid},
    );
    defer allocator.free(attach_req);
    try writeAll(socket_fd, attach_req);

    const received = try fd_passing.recvFd(allocator, socket_fd, attach_payload_max);
    defer received.deinit(allocator);
    const pty_fd = received.fd;
    errdefer posix.close(pty_fd);

    if (findJsonField(received.payload, "\"error\"")) |_| {
        try stderrWrite(received.payload);
        posix.close(pty_fd);
        std.process.exit(1);
    }

    const stdin_fd: posix.fd_t = 0;
    const stdout_fd: posix.fd_t = 1;

    const stdin_is_tty = posix.isatty(stdin_fd);
    if (stdin_is_tty) try enterRawMode(stdin_fd);
    defer restoreTermios();

    // Install signal handlers.
    g_socket_path_for_signals = path;
    g_session_id_for_signals = sid;
    installSigwinchHandler();
    installExitRestoreHandlers();

    // Replay any prior scrollback the daemon captured while we were
    // detached. This is what makes reattach feel tmux-like: the previously
    // rendered Claude Code / shell output is redrawn instead of disappearing.
    replayScrollbackFromAttach(allocator, received.payload, stdout_fd) catch {};

    // Send an initial resize from our terminal's current size, if known.
    sendResize(allocator, path, sid, stdout_fd) catch {};

    runLoop(stdin_fd, stdout_fd, pty_fd, socket_fd, allocator, path, sid) catch |err| {
        restoreTermios();
        var ebuf: [256]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&ebuf);
        ew.interface.print("session-connect: {s}\n", .{@errorName(err)}) catch {};
        ew.interface.flush() catch {};
        std.process.exit(1);
    };

    posix.close(pty_fd);
}

fn runLoop(
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,
    pty_fd: posix.fd_t,
    socket_fd: posix.fd_t,
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    session_id: []const u8,
) !void {
    _ = socket_fd;
    var buf: [buffer_size]u8 = undefined;

    while (true) {
        if (g_winch_flag.swap(false, .seq_cst)) {
            sendResize(allocator, socket_path, session_id, stdout_fd) catch {};
        }

        var fds = [_]posix.pollfd{
            .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = pty_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = try posix.poll(&fds, 1000);
        if (ready == 0) continue;

        if ((fds[1].revents & posix.POLL.IN) != 0) {
            const n = posix.read(pty_fd, &buf) catch |err| switch (err) {
                error.InputOutput => return, // EIO on master after child exits
                error.WouldBlock => 0,
                else => return err,
            };
            if (n == 0) return; // EOF
            try writeAllFd(stdout_fd, buf[0..n]);
        }

        if ((fds[1].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return;

        if ((fds[0].revents & posix.POLL.IN) != 0) {
            const n = posix.read(stdin_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
            if (n == 0) {
                // stdin closed: shut down write side of PTY, keep draining output.
                // Simpler: exit.
                return;
            }
            try writeAllFd(pty_fd, buf[0..n]);
        }

        if ((fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return;
    }
}

fn connectWithRetry(allocator: std.mem.Allocator, path: []const u8, spawn_daemon: bool) !posix.fd_t {
    if (tryConnect(path)) |fd| return fd else |err| switch (err) {
        error.ConnectionRefused, error.FileNotFound => {
            if (!spawn_daemon) return err;
        },
        else => return err,
    }

    try spawnDaemonDetached(allocator, path);

    const deadline_ms = std.time.milliTimestamp() + 2000;
    while (std.time.milliTimestamp() < deadline_ms) {
        if (tryConnect(path)) |fd| return fd else |err| switch (err) {
            error.ConnectionRefused, error.FileNotFound => {
                std.Thread.sleep(50 * std.time.ns_per_ms);
            },
            else => return err,
        }
    }
    return error.DaemonUnavailable;
}

fn tryConnect(path: []const u8) !posix.fd_t {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    const address = std.net.Address.initUnix(path) catch return error.FileNotFound;
    try posix.connect(fd, &address.any, address.getOsSockLen());
    return fd;
}

fn spawnDaemonDetached(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    // Locate the daemon binary by looking next to our own executable.
    const self_path = std.fs.selfExePathAlloc(allocator) catch |err| return err;
    defer allocator.free(self_path);
    const dir = std.fs.path.dirname(self_path) orelse ".";
    const daemon_path = try std.fs.path.join(allocator, &.{ dir, "smithers-session-daemon" });
    defer allocator.free(daemon_path);

    const pid = try posix.fork();
    if (pid != 0) return;

    // Child: detach and exec.
    _ = std.c.setsid();
    // Redirect stdio to /dev/null.
    const devnull = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch std.c._exit(127);
    _ = std.c.dup2(devnull, 0);
    _ = std.c.dup2(devnull, 1);
    _ = std.c.dup2(devnull, 2);
    if (devnull > 2) posix.close(devnull);

    const daemon_z = allocator.dupeZ(u8, daemon_path) catch std.c._exit(127);
    const socket_flag_z = allocator.dupeZ(u8, "--socket") catch std.c._exit(127);
    const path_z = allocator.dupeZ(u8, socket_path) catch std.c._exit(127);
    const argv = [_:null]?[*:0]const u8{ daemon_z.ptr, socket_flag_z.ptr, path_z.ptr };
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    posix.execvpeZ(daemon_z.ptr, &argv, envp) catch {};
    std.c._exit(127);
}

fn enterRawMode(fd: posix.fd_t) !void {
    const current = posix.tcgetattr(fd) catch |err| switch (err) {
        error.NotATerminal => return,
        else => return err,
    };
    g_saved_termios = current;
    g_saved_termios_fd = fd;

    var raw = current;
    // Input: disable CR/NL translation, parity, strip, XON/XOFF.
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    // Output: disable post-processing (we forward bytes verbatim).
    raw.oflag.OPOST = false;
    // Local: disable echo, canonical mode, signal generation, extended input.
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    try posix.tcsetattr(fd, .FLUSH, raw);
}

fn restoreTermios() void {
    if (g_saved_termios) |saved| {
        posix.tcsetattr(g_saved_termios_fd, .FLUSH, saved) catch {};
        g_saved_termios = null;
    }
}

fn winchHandler(_: c_int) callconv(.c) void {
    g_winch_flag.store(true, .seq_cst);
}

fn exitRestoreHandler(sig: c_int) callconv(.c) void {
    restoreTermios();
    // Reset to default and re-raise so the default action takes effect.
    var dfl: posix.Sigaction = undefined;
    @memset(std.mem.asBytes(&dfl), 0);
    dfl.handler = .{ .handler = null };
    dfl.mask = std.mem.zeroes(posix.sigset_t);
    dfl.flags = 0;
    posix.sigaction(@intCast(sig), &dfl, null);
    _ = std.c.raise(sig);
}

fn installSigwinchHandler() void {
    var act: posix.Sigaction = undefined;
    @memset(std.mem.asBytes(&act), 0);
    act.handler = .{ .handler = winchHandler };
    act.mask = std.mem.zeroes(posix.sigset_t);
    act.flags = 0;
    posix.sigaction(std.c.SIG.WINCH, &act, null);
}

fn installExitRestoreHandlers() void {
    // HUP/PIPE/QUIT: restore termios before default action takes us down.
    // We deliberately do NOT handle INT/TERM — the PTY's own signals reach
    // the child through pty_fd in raw mode.
    var act: posix.Sigaction = undefined;
    @memset(std.mem.asBytes(&act), 0);
    act.handler = .{ .handler = exitRestoreHandler };
    act.mask = std.mem.zeroes(posix.sigset_t);
    act.flags = 0;
    posix.sigaction(std.c.SIG.HUP, &act, null);
    posix.sigaction(std.c.SIG.PIPE, &act, null);
    posix.sigaction(std.c.SIG.QUIT, &act, null);
}

fn sendResize(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    session_id: []const u8,
    tty_fd: posix.fd_t,
) !void {
    var wsz: posix.winsize = undefined;
    const req = tiocgwinsz();
    if (std.c.ioctl(tty_fd, @as(c_int, @bitCast(@as(u32, @truncate(req)))), &wsz) != 0) return;
    if (wsz.col == 0 or wsz.row == 0) return;

    const fd = tryConnect(socket_path) catch return;
    defer posix.close(fd);

    const msg = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.resize\",\"params\":{{\"sessionId\":\"{s}\",\"cols\":{d},\"rows\":{d}}}}}\n",
        .{ session_id, wsz.col, wsz.row },
    );
    defer allocator.free(msg);
    writeAll(fd, msg) catch {};
    // Drain response (best-effort; we don't care about the body).
    var drain: [256]u8 = undefined;
    _ = posix.read(fd, &drain) catch {};
}

// Mirrors daemon.zig::socketPath. Keep in sync.
fn resolveSocketPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |xdg| {
        if (xdg.len > 0) return std.fs.path.join(allocator, &.{ xdg, "smithers-sessions.sock" });
    }
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return std.fs.path.join(allocator, &.{ home, ".smithers", "sessions.sock" });
}

fn tiocgwinsz() usize {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => 0x40087468,
        else => 0x5413, // TIOCGWINSZ on Linux
    };
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = posix.write(fd, bytes[offset..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.WriteZero;
        offset += n;
    }
}

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) !void {
    return writeAll(fd, bytes);
}

fn findJsonField(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

/// Pull the `replayBase64` field out of the attach response JSON, decode
/// it, and write the raw bytes to `out_fd` so the terminal redraws the
/// prior session state.
fn replayScrollbackFromAttach(
    allocator: std.mem.Allocator,
    payload: []const u8,
    out_fd: posix.fd_t,
) !void {
    const marker = "\"replayBase64\":\"";
    const start = std.mem.indexOf(u8, payload, marker) orelse return;
    const value_start = start + marker.len;
    if (value_start >= payload.len) return;
    const value_end = std.mem.indexOfScalarPos(u8, payload, value_start, '"') orelse return;
    const encoded = payload[value_start..value_end];
    if (encoded.len == 0) return;

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(encoded) catch return;
    if (decoded_len == 0) return;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    decoder.decode(decoded, encoded) catch return;
    try writeAllFd(out_fd, decoded);
}

fn stderrWrite(bytes: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn fail(comptime fmt: []const u8, args: anytype) error{InvalidArguments} {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print("session-connect: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
    return error.InvalidArguments;
}

fn printUsage() !void {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try w.interface.writeAll(
        \\Usage: smithers-session-connect <session_id> [--socket PATH] [--spawn-daemon]
        \\
    );
    try w.interface.flush();
}

test "tiocgwinsz encodes the platform ioctl" {
    const req = tiocgwinsz();
    try std.testing.expect(req != 0);
}
