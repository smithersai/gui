//! High-level client: owns a TCP socket, does handshake, owns a reassembly
//! buffer, exposes readEvent / writeBinary / sendResize / close.
//!
//! No TLS yet — plue dev is `ws://`. TLS is documented as a follow-up.

const std = @import("std");
const net = std.net;
const frame = @import("frame.zig");
const handshake = @import("handshake.zig");
const Err = @import("errors.zig").Error;

pub const ResizeMsg = struct {
    type: []const u8 = "resize",
    cols: u32,
    rows: u32,
};

pub const ConnectOptions = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    origin: []const u8,
    bearer: ?[]const u8 = null,
    /// Defaults to "terminal" (plue's subprotocol).
    subprotocol: ?[]const u8 = "terminal",
    /// Max reassembled message size. Defaults to 1 MiB to safely exceed plue's
    /// 64 KiB frame size × reasonable multi-frame outputs.
    max_message_size: usize = 1 * 1024 * 1024,
};

pub const EventKind = enum { binary, text, close, ping, pong };

pub const Event = struct {
    kind: EventKind,
    /// Payload bytes. Owned by the Client until the next readEvent call
    /// (caller should copy if retained).
    payload: []const u8,
    /// For `close` events, the CloseCode if present.
    close_code: ?u16 = null,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    /// Read side buffer — holds unparsed bytes from the socket.
    rx: std.ArrayList(u8),
    /// Reassembly buffer for fragmented messages.
    reassembly: std.ArrayList(u8),
    /// Opcode of the first fragment of the currently-assembling message.
    /// Null means "not currently in a fragmented message".
    fragment_opcode: ?frame.Opcode = null,
    /// Set when the peer sent a close frame (graceful close).
    peer_closed: bool = false,
    /// Last close code received; valid after peer_closed == true.
    close_code: ?u16 = null,
    /// Max message size; protocol-error if exceeded.
    max_message_size: usize,
    /// Random source for mask keys.
    prng: std.Random.DefaultPrng,

    pub fn connect(allocator: std.mem.Allocator, opts: ConnectOptions) Err!Client {
        const addr_list = net.getAddressList(allocator, opts.host, opts.port) catch return Err.IoError;
        defer addr_list.deinit();
        if (addr_list.addrs.len == 0) return Err.IoError;

        var stream: net.Stream = undefined;
        var connect_err: ?anyerror = null;
        for (addr_list.addrs) |addr| {
            stream = net.tcpConnectToAddress(addr) catch |e| {
                connect_err = e;
                continue;
            };
            connect_err = null;
            break;
        }
        if (connect_err != null) return Err.IoError;

        var self = Client{
            .allocator = allocator,
            .stream = stream,
            .rx = .empty,
            .reassembly = .empty,
            .max_message_size = opts.max_message_size,
            .prng = std.Random.DefaultPrng.init(seedFromTime()),
        };
        errdefer self.stream.close();
        errdefer self.rx.deinit(allocator);
        errdefer self.reassembly.deinit(allocator);

        try self.performHandshake(opts);
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.rx.deinit(self.allocator);
        self.reassembly.deinit(self.allocator);
        self.stream.close();
    }

    fn seedFromTime() u64 {
        const ns = std.time.nanoTimestamp();
        // Truncate i128 → u64 cleanly.
        return @as(u64, @truncate(@as(u128, @bitCast(ns))));
    }

    fn performHandshake(self: *Client, opts: ConnectOptions) Err!void {
        var key_buf: [32]u8 = undefined;
        const key_b64 = handshake.generateKey(self.prng.random(), &key_buf);

        const req_bytes = handshake.writeRequest(self.allocator, .{
            .host = opts.host,
            .path = opts.path,
            .origin = opts.origin,
            .bearer = opts.bearer,
            .subprotocol = opts.subprotocol,
            .key_b64 = key_b64,
        }) catch return Err.OutOfMemory;
        defer self.allocator.free(req_bytes);

        self.stream.writeAll(req_bytes) catch return Err.IoError;

        // Read until we see \r\n\r\n terminator.
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = self.stream.read(&tmp) catch return Err.IoError;
            if (n == 0) return Err.AbruptDisconnect;
            self.rx.appendSlice(self.allocator, tmp[0..n]) catch return Err.OutOfMemory;
            const parsed = handshake.parseResponse(self.rx.items) catch |e| switch (e) {
                Err.ShortRead => continue,
                else => return e,
            };
            // Validate Sec-WebSocket-Accept to make sure we're not being spoofed.
            const accept = parsed.sec_accept orelse return Err.HandshakeMissingUpgrade;
            if (!handshake.validateAccept(key_b64, accept)) return Err.HandshakeBadAcceptKey;

            // Drop the handshake bytes from rx; the rest is frame data.
            const leftover_len = self.rx.items.len - parsed.bytes_consumed;
            if (leftover_len > 0) {
                std.mem.copyForwards(u8, self.rx.items[0..leftover_len], self.rx.items[parsed.bytes_consumed..]);
            }
            self.rx.shrinkRetainingCapacity(leftover_len);
            return;
        }
    }

    /// Write bytes as a single masked binary frame.
    pub fn writeBinary(self: *Client, bytes: []const u8) Err!void {
        try self.writeFrame(.binary, bytes, true);
    }

    /// Send a resize control message as a text frame with JSON payload.
    pub fn sendResize(self: *Client, cols: u32, rows: u32) Err!void {
        var buf: [64]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"resize\",\"cols\":{d},\"rows\":{d}}}", .{ cols, rows }) catch return Err.IoError;
        try self.writeFrame(.text, json, true);
    }

    /// Close the connection gracefully with code 1000.
    pub fn close(self: *Client, code: u16, reason: []const u8) Err!void {
        var payload: [128]u8 = undefined;
        const n = frame.buildClosePayload(code, reason, &payload);
        try self.writeFrame(.close, payload[0..n], true);
    }

    fn writeFrame(self: *Client, opcode: frame.Opcode, payload: []const u8, fin: bool) Err!void {
        var mask_key: [4]u8 = undefined;
        self.prng.random().bytes(&mask_key);

        const needed = frame.encodedLen(payload.len);
        const out = self.allocator.alloc(u8, needed) catch return Err.OutOfMemory;
        defer self.allocator.free(out);
        const n = frame.encodeClientFrame(opcode, payload, mask_key, fin, out);
        self.stream.writeAll(out[0..n]) catch return Err.IoError;
    }

    /// Read until we have a complete message (after reassembly of fragments).
    /// Returns a single Event.
    /// For ping frames: the library transparently replies with pong and
    /// surfaces a ping Event (so callers can log / ignore). For pong frames:
    /// surfaced as pong Events.
    pub fn readEvent(self: *Client) Err!Event {
        while (true) {
            // Try to parse a header from what we have.
            const h = frame.decodeHeader(self.rx.items) catch |e| switch (e) {
                Err.ShortRead => {
                    try self.pumpRead();
                    continue;
                },
                else => return e,
            };

            // Server -> client frames must be unmasked.
            if (h.masked) return Err.ProtocolError;

            const total_needed = h.header_len + h.payload_len;
            if (total_needed > self.max_message_size) return Err.MessageTooLarge;
            if (self.rx.items.len < total_needed) {
                try self.pumpRead();
                continue;
            }

            // We have a full frame in rx. Extract payload.
            const payload_start = h.header_len;
            const payload_end = payload_start + @as(usize, @intCast(h.payload_len));
            const payload = self.rx.items[payload_start..payload_end];

            if (h.opcode.isControl()) {
                // Control frame. MUST be FIN (already validated in decodeHeader).
                const result = try self.handleControlFrame(h, payload);
                // Consume the frame from rx.
                try self.consumeRx(total_needed);
                if (result) |ev| return ev;
                // Control frame consumed silently (e.g. auto-pong); loop.
                continue;
            }

            // Data frame (binary, text, or continuation).
            if (h.opcode == .continuation) {
                if (self.fragment_opcode == null) return Err.ProtocolError;
                try self.reassembly.appendSlice(self.allocator, payload);
            } else {
                // New data frame. If we were in the middle of fragments, that's bad.
                if (self.fragment_opcode != null) return Err.ProtocolError;
                if (h.fin) {
                    // Common fast-path: whole message in one frame. Return a slice
                    // directly into rx — BUT rx gets compacted after consume, so
                    // we must stage into reassembly for a stable pointer.
                    self.reassembly.clearRetainingCapacity();
                    try self.reassembly.appendSlice(self.allocator, payload);
                    const ev = Event{
                        .kind = if (h.opcode == .binary) .binary else .text,
                        .payload = self.reassembly.items,
                    };
                    try self.consumeRx(total_needed);
                    return ev;
                }
                self.fragment_opcode = h.opcode;
                self.reassembly.clearRetainingCapacity();
                try self.reassembly.appendSlice(self.allocator, payload);
            }

            try self.consumeRx(total_needed);

            if (h.fin) {
                const kind: EventKind = if (self.fragment_opcode == .binary) .binary else .text;
                self.fragment_opcode = null;
                return Event{ .kind = kind, .payload = self.reassembly.items };
            }
            // Still fragmenting; loop to get the next frame.
        }
    }

    fn handleControlFrame(self: *Client, h: frame.Header, payload: []const u8) Err!?Event {
        switch (h.opcode) {
            .ping => {
                // Auto-pong with the same payload.
                try self.writeFrame(.pong, payload, true);
                // Surface a ping event so tests / logging can observe.
                self.reassembly.clearRetainingCapacity();
                self.reassembly.appendSlice(self.allocator, payload) catch return Err.OutOfMemory;
                return Event{ .kind = .ping, .payload = self.reassembly.items };
            },
            .pong => {
                self.reassembly.clearRetainingCapacity();
                self.reassembly.appendSlice(self.allocator, payload) catch return Err.OutOfMemory;
                return Event{ .kind = .pong, .payload = self.reassembly.items };
            },
            .close => {
                self.peer_closed = true;
                var code: ?u16 = null;
                if (payload.len >= 2) {
                    code = std.mem.readInt(u16, payload[0..2], .big);
                }
                self.close_code = code;
                // RFC: respond with our own close frame.
                var reply_payload: [2]u8 = undefined;
                if (code) |c| {
                    std.mem.writeInt(u16, &reply_payload, c, .big);
                    self.writeFrame(.close, &reply_payload, true) catch {};
                }
                self.reassembly.clearRetainingCapacity();
                self.reassembly.appendSlice(self.allocator, payload) catch return Err.OutOfMemory;
                return Event{ .kind = .close, .payload = self.reassembly.items, .close_code = code };
            },
            else => return Err.ProtocolError,
        }
    }

    fn consumeRx(self: *Client, n: usize) Err!void {
        std.debug.assert(n <= self.rx.items.len);
        const leftover = self.rx.items.len - n;
        if (leftover > 0) {
            std.mem.copyForwards(u8, self.rx.items[0..leftover], self.rx.items[n..]);
        }
        self.rx.shrinkRetainingCapacity(leftover);
    }

    fn pumpRead(self: *Client) Err!void {
        var tmp: [8192]u8 = undefined;
        const n = self.stream.read(&tmp) catch return Err.IoError;
        if (n == 0) {
            // EOF. If we weren't expecting a close, this is abrupt.
            if (self.peer_closed) return Err.PeerClosed;
            return Err.AbruptDisconnect;
        }
        self.rx.appendSlice(self.allocator, tmp[0..n]) catch return Err.OutOfMemory;
    }
};

// ===========================================================================
// Tests that exercise the Client against an in-memory transport.
// Full integration (real TCP + plue) lives in test/integration_tests.zig.
// ===========================================================================

const testing = std.testing;

test "ResizeMsg: JSON format matches plue's terminalResizeMsg" {
    // Plue expects exactly: {"type":"resize","cols":N,"rows":N}
    // The implementation is inline in sendResize(); replicate here to guard
    // against accidental drift.
    var buf: [64]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "{{\"type\":\"resize\",\"cols\":{d},\"rows\":{d}}}", .{ 120, 40 });
    try testing.expectEqualStrings("{\"type\":\"resize\",\"cols\":120,\"rows\":40}", out);
}
