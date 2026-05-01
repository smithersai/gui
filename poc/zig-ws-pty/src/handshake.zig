//! HTTP/1.1 Upgrade: websocket handshake — client side only.
//!
//! We write our own rather than lean on std.http because:
//!   1. std.http.Client in Zig 0.15 does not expose the raw socket after
//!      upgrade (connection-reuse logic assumes HTTP semantics continue).
//!   2. We need exact control over `Origin`, `Authorization`, and
//!      `Sec-WebSocket-Protocol` headers — plue checks Origin and we want
//!      the handshake byte-exact for debugging.
//!   3. It is ~100 lines of code to do correctly.

const std = @import("std");
const Err = @import("errors.zig").Error;

pub const ws_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Request = struct {
    host: []const u8,
    /// Full path + query, e.g. "/api/repos/a/b/workspace/sessions/sid/terminal".
    path: []const u8,
    origin: []const u8,
    /// Bearer token (without "Bearer " prefix).
    bearer: ?[]const u8 = null,
    /// Sec-WebSocket-Protocol value, e.g. "terminal".
    subprotocol: ?[]const u8 = null,
    /// 16 random bytes, base64-encoded by the caller.
    key_b64: []const u8,
};

/// Render the HTTP/1.1 upgrade request. Caller owns the returned slice.
pub fn writeRequest(allocator: std.mem.Allocator, req: Request) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.print(allocator, "GET {s} HTTP/1.1\r\n", .{req.path});
    try buf.print(allocator, "Host: {s}\r\n", .{req.host});
    try buf.appendSlice(allocator, "Upgrade: websocket\r\n");
    try buf.appendSlice(allocator, "Connection: Upgrade\r\n");
    try buf.print(allocator, "Sec-WebSocket-Key: {s}\r\n", .{req.key_b64});
    try buf.appendSlice(allocator, "Sec-WebSocket-Version: 13\r\n");
    try buf.print(allocator, "Origin: {s}\r\n", .{req.origin});
    if (req.subprotocol) |sp| {
        try buf.print(allocator, "Sec-WebSocket-Protocol: {s}\r\n", .{sp});
    }
    if (req.bearer) |tok| {
        try buf.print(allocator, "Authorization: Bearer {s}\r\n", .{tok});
    }
    try buf.appendSlice(allocator, "\r\n");
    return buf.toOwnedSlice(allocator);
}

pub const Response = struct {
    status: u16,
    /// Slice into caller-owned buffer. Do not free separately.
    sec_accept: ?[]const u8,
    subprotocol: ?[]const u8,
    /// Bytes consumed from `buf` for the handshake response (everything up to
    /// and including the "\r\n\r\n" terminator). Anything after is the first
    /// WS frame data.
    bytes_consumed: usize,
};

/// Parse an HTTP response. Returns Err.ShortRead if terminator not yet seen.
pub fn parseResponse(buf: []const u8) Err!Response {
    const terminator = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return Err.ShortRead;
    const end = terminator + 4;

    var lines = std.mem.splitSequence(u8, buf[0..terminator], "\r\n");
    const status_line = lines.next() orelse return Err.HandshakeMalformed;

    // "HTTP/1.1 101 Switching Protocols"
    var sp = std.mem.splitScalar(u8, status_line, ' ');
    _ = sp.next() orelse return Err.HandshakeMalformed; // HTTP/1.1
    const code_str = sp.next() orelse return Err.HandshakeMalformed;
    const status = std.fmt.parseInt(u16, code_str, 10) catch return Err.HandshakeMalformed;

    var sec_accept: ?[]const u8 = null;
    var subprotocol: ?[]const u8 = null;
    var seen_upgrade_websocket = false;
    var seen_connection_upgrade = false;

    while (lines.next()) |raw| {
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
        const name = std.mem.trim(u8, raw[0..colon], " \t");
        const value = std.mem.trim(u8, raw[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
            sec_accept = value;
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol")) {
            subprotocol = value;
        } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            if (std.ascii.eqlIgnoreCase(value, "websocket")) seen_upgrade_websocket = true;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            // Connection: Upgrade (case-insensitive, possibly with other tokens).
            var toks = std.mem.splitScalar(u8, value, ',');
            while (toks.next()) |t| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, t, " \t"), "upgrade")) {
                    seen_connection_upgrade = true;
                    break;
                }
            }
        }
    }

    // Validate status. Map plue-specific statuses to distinct errors.
    if (status != 101) {
        return switch (status) {
            401 => Err.HandshakeUnauthorized,
            403 => Err.HandshakeOriginRejected,
            else => Err.HandshakeBadStatus,
        };
    }
    if (!seen_upgrade_websocket or !seen_connection_upgrade) return Err.HandshakeMissingUpgrade;
    if (sec_accept == null) return Err.HandshakeMissingUpgrade;

    return .{
        .status = status,
        .sec_accept = sec_accept,
        .subprotocol = subprotocol,
        .bytes_consumed = end,
    };
}

/// Compute expected Sec-WebSocket-Accept for a client-sent Sec-WebSocket-Key.
/// Out must be >= 28 bytes (base64 of 20-byte SHA1 = 28 chars).
pub fn computeAccept(client_key_b64: []const u8, out: []u8) []const u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(client_key_b64);
    sha.update(ws_magic);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    const Enc = std.base64.standard.Encoder;
    const len = Enc.calcSize(digest.len);
    std.debug.assert(out.len >= len);
    return Enc.encode(out[0..len], &digest);
}

pub fn validateAccept(client_key_b64: []const u8, received: []const u8) bool {
    var buf: [32]u8 = undefined;
    const expected = computeAccept(client_key_b64, &buf);
    return std.mem.eql(u8, expected, received);
}

/// Generate 16 random bytes, base64-encode into out (must be >= 24 bytes).
pub fn generateKey(random: std.Random, out: []u8) []const u8 {
    var raw: [16]u8 = undefined;
    random.bytes(&raw);
    const Enc = std.base64.standard.Encoder;
    const len = Enc.calcSize(raw.len);
    std.debug.assert(out.len >= len);
    return Enc.encode(out[0..len], &raw);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "computeAccept: RFC 6455 example" {
    // Canonical example from RFC 6455 §1.3.
    var buf: [32]u8 = undefined;
    const got = computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &buf);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", got);
}

test "parseResponse: short read" {
    try testing.expectError(Err.ShortRead, parseResponse("HTTP/1.1 101"));
    try testing.expectError(Err.ShortRead, parseResponse("HTTP/1.1 101 OK\r\n"));
}

test "parseResponse: 101 success" {
    const raw =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
        "Sec-WebSocket-Protocol: terminal\r\n" ++
        "\r\n";
    const r = try parseResponse(raw);
    try testing.expectEqual(@as(u16, 101), r.status);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", r.sec_accept.?);
    try testing.expectEqualStrings("terminal", r.subprotocol.?);
    try testing.expectEqual(raw.len, r.bytes_consumed);
}

test "parseResponse: 403 -> HandshakeOriginRejected" {
    const raw =
        "HTTP/1.1 403 Forbidden\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";
    try testing.expectError(Err.HandshakeOriginRejected, parseResponse(raw));
}

test "parseResponse: 401 -> HandshakeUnauthorized" {
    const raw =
        "HTTP/1.1 401 Unauthorized\r\n" ++
        "\r\n";
    try testing.expectError(Err.HandshakeUnauthorized, parseResponse(raw));
}

test "parseResponse: 500 -> HandshakeBadStatus (generic)" {
    const raw =
        "HTTP/1.1 500 Internal Server Error\r\n" ++
        "\r\n";
    try testing.expectError(Err.HandshakeBadStatus, parseResponse(raw));
}

test "parseResponse: 101 without upgrade headers -> missing" {
    const raw =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "\r\n";
    try testing.expectError(Err.HandshakeMissingUpgrade, parseResponse(raw));
}

test "parseResponse: Connection header with multiple tokens" {
    const raw =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: keep-alive, Upgrade\r\n" ++
        "Sec-WebSocket-Accept: aaaa\r\n" ++
        "\r\n";
    const r = try parseResponse(raw);
    try testing.expectEqualStrings("aaaa", r.sec_accept.?);
}

test "validateAccept: rejects wrong accept" {
    try testing.expect(!validateAccept("dGhlIHNhbXBsZSBub25jZQ==", "wrong"));
    try testing.expect(validateAccept("dGhlIHNhbXBsZSBub25jZQ==", "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="));
}

test "parseResponse: body-remainder bytes tracked" {
    const raw =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: x\r\n" ++
        "\r\n" ++
        // first WS frame bytes that the caller will consume later
        "\x82\x05hello";
    const r = try parseResponse(raw);
    try testing.expectEqual(@as(u16, 101), r.status);
    // bytes_consumed marks end of "\r\n\r\n".
    try testing.expect(r.bytes_consumed < raw.len);
    try testing.expectEqualStrings("\x82\x05hello", raw[r.bytes_consumed..]);
}
