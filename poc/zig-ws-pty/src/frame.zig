//! RFC 6455 frame encode/decode, pure (no I/O, no transport).
//!
//! Only the client side matters: client frames are always masked, server frames
//! must be unmasked. We keep enough opcode awareness to dispatch binary / text /
//! ping / pong / close without leaking them as "protocol errors" to callers.

const std = @import("std");
const Err = @import("errors.zig").Error;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    // 0x3..0x7 reserved non-control
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(self: Opcode) bool {
        return (@intFromEnum(self) & 0x8) != 0;
    }
};

pub const Header = struct {
    fin: bool,
    rsv1: bool = false,
    rsv2: bool = false,
    rsv3: bool = false,
    opcode: Opcode,
    masked: bool,
    payload_len: u64,
    /// When `masked`, these 4 bytes unmask the payload.
    mask_key: [4]u8 = .{ 0, 0, 0, 0 },
    /// Number of bytes consumed from the input buffer for this header.
    header_len: usize,
};

/// Decode a header from `buf`. Returns `Err.ShortRead` if more bytes are needed.
pub fn decodeHeader(buf: []const u8) Err!Header {
    if (buf.len < 2) return Err.ShortRead;
    const b0 = buf[0];
    const b1 = buf[1];
    const fin = (b0 & 0x80) != 0;
    const rsv1 = (b0 & 0x40) != 0;
    const rsv2 = (b0 & 0x20) != 0;
    const rsv3 = (b0 & 0x10) != 0;
    // We don't negotiate any extensions; any RSV bit = protocol error.
    if (rsv1 or rsv2 or rsv3) return Err.ProtocolError;

    const raw_op: u4 = @truncate(b0 & 0x0F);
    const opcode: Opcode = @enumFromInt(raw_op);
    // Reject reserved non-control (0x3..0x7) and reserved control (0xB..0xF).
    switch (raw_op) {
        0x0, 0x1, 0x2, 0x8, 0x9, 0xA => {},
        else => return Err.ProtocolError,
    }

    const masked = (b1 & 0x80) != 0;
    const len7: u7 = @truncate(b1 & 0x7F);

    var cursor: usize = 2;
    var payload_len: u64 = undefined;
    if (len7 < 126) {
        payload_len = len7;
    } else if (len7 == 126) {
        if (buf.len < cursor + 2) return Err.ShortRead;
        payload_len = std.mem.readInt(u16, buf[cursor..][0..2], .big);
        cursor += 2;
    } else { // 127
        if (buf.len < cursor + 8) return Err.ShortRead;
        const v = std.mem.readInt(u64, buf[cursor..][0..8], .big);
        // RFC 6455: the most significant bit MUST be 0.
        if (v & 0x8000_0000_0000_0000 != 0) return Err.ProtocolError;
        payload_len = v;
        cursor += 8;
    }

    // Control frames must have payload <= 125 and must be FIN.
    if (opcode.isControl()) {
        if (payload_len > 125) return Err.ProtocolError;
        if (!fin) return Err.ProtocolError;
    }

    var header = Header{
        .fin = fin,
        .rsv1 = rsv1,
        .rsv2 = rsv2,
        .rsv3 = rsv3,
        .opcode = opcode,
        .masked = masked,
        .payload_len = payload_len,
        .header_len = cursor,
    };

    if (masked) {
        if (buf.len < cursor + 4) return Err.ShortRead;
        @memcpy(&header.mask_key, buf[cursor .. cursor + 4]);
        cursor += 4;
        header.header_len = cursor;
    }

    return header;
}

/// Unmask payload in place using the 4-byte mask key.
pub fn unmask(mask_key: [4]u8, payload: []u8) void {
    for (payload, 0..) |*b, i| {
        b.* ^= mask_key[i & 0x3];
    }
}

/// Encode a client frame. `out` must be at least `encodedLen(payload.len)` bytes.
/// `mask_key` is xored over the payload on wire (RFC requires random per frame);
/// caller passes the key — tests use a fixed key, production uses `std.crypto.random`.
/// Returns the number of bytes written.
pub fn encodeClientFrame(
    opcode: Opcode,
    payload: []const u8,
    mask_key: [4]u8,
    fin: bool,
    out: []u8,
) usize {
    std.debug.assert(out.len >= encodedLen(payload.len));

    var cursor: usize = 0;
    var b0: u8 = @intFromEnum(opcode);
    if (fin) b0 |= 0x80;
    out[cursor] = b0;
    cursor += 1;

    // Always masked for client-to-server frames.
    var b1: u8 = 0x80;
    if (payload.len < 126) {
        b1 |= @as(u8, @intCast(payload.len));
        out[cursor] = b1;
        cursor += 1;
    } else if (payload.len <= std.math.maxInt(u16)) {
        b1 |= 126;
        out[cursor] = b1;
        cursor += 1;
        std.mem.writeInt(u16, out[cursor..][0..2], @as(u16, @intCast(payload.len)), .big);
        cursor += 2;
    } else {
        b1 |= 127;
        out[cursor] = b1;
        cursor += 1;
        std.mem.writeInt(u64, out[cursor..][0..8], @as(u64, payload.len), .big);
        cursor += 8;
    }

    @memcpy(out[cursor .. cursor + 4], &mask_key);
    cursor += 4;

    // Masked copy of payload.
    for (payload, 0..) |b, i| {
        out[cursor + i] = b ^ mask_key[i & 0x3];
    }
    cursor += payload.len;
    return cursor;
}

pub fn encodedLen(payload_len: usize) usize {
    const len_field: usize = if (payload_len < 126) 0 else if (payload_len <= std.math.maxInt(u16)) 2 else 8;
    // 2 (b0+b1) + extended len + 4 (mask) + payload
    return 2 + len_field + 4 + payload_len;
}

/// Build a Close frame payload: 2-byte BE code + optional UTF-8 reason.
/// Returns the number of bytes written to `out`.
pub fn buildClosePayload(code: u16, reason: []const u8, out: []u8) usize {
    std.debug.assert(out.len >= 2 + reason.len);
    std.mem.writeInt(u16, out[0..2], code, .big);
    @memcpy(out[2 .. 2 + reason.len], reason);
    return 2 + reason.len;
}

// ===========================================================================
// Tests (run by root.zig pulling us in).
// ===========================================================================

const testing = std.testing;

test "decodeHeader: short read" {
    try testing.expectError(Err.ShortRead, decodeHeader(""));
    try testing.expectError(Err.ShortRead, decodeHeader(&[_]u8{0x82}));
}

test "decodeHeader: unmasked server binary small" {
    // FIN=1, opcode=binary, mask=0, len=5
    const buf = [_]u8{ 0x82, 0x05, 'h', 'e', 'l', 'l', 'o' };
    const h = try decodeHeader(&buf);
    try testing.expect(h.fin);
    try testing.expectEqual(Opcode.binary, h.opcode);
    try testing.expect(!h.masked);
    try testing.expectEqual(@as(u64, 5), h.payload_len);
    try testing.expectEqual(@as(usize, 2), h.header_len);
}

test "decodeHeader: extended 16-bit length" {
    var buf: [4]u8 = .{ 0x81, 0x7E, 0x01, 0x00 }; // FIN+text, len=256
    const h = try decodeHeader(&buf);
    try testing.expectEqual(@as(u64, 256), h.payload_len);
    try testing.expectEqual(@as(usize, 4), h.header_len);
}

test "decodeHeader: extended 64-bit length" {
    // FIN + binary, len marker=127, payload_len=70000
    var buf: [10]u8 = .{ 0x82, 0x7F, 0, 0, 0, 0, 0, 0x01, 0x11, 0x70 };
    const h = try decodeHeader(&buf);
    try testing.expectEqual(@as(u64, 70000), h.payload_len);
    try testing.expectEqual(@as(usize, 10), h.header_len);
}

test "decodeHeader: 64-bit msb set is protocol error" {
    const buf: [10]u8 = .{ 0x82, 0x7F, 0x80, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(Err.ProtocolError, decodeHeader(&buf));
}

test "decodeHeader: rsv bits -> protocol error" {
    const buf = [_]u8{ 0xC2, 0x05 }; // FIN + RSV1 + binary
    try testing.expectError(Err.ProtocolError, decodeHeader(&buf));
}

test "decodeHeader: reserved opcode -> protocol error" {
    const buf = [_]u8{ 0x83, 0x00 }; // opcode 0x3 reserved
    try testing.expectError(Err.ProtocolError, decodeHeader(&buf));
}

test "decodeHeader: non-fin control frame is protocol error" {
    const buf = [_]u8{ 0x08, 0x00 }; // close, fin=0
    try testing.expectError(Err.ProtocolError, decodeHeader(&buf));
}

test "decodeHeader: oversized control frame is protocol error" {
    const buf = [_]u8{ 0x89, 0x7E, 0x00, 0x7E }; // ping, len=126 (>125)
    try testing.expectError(Err.ProtocolError, decodeHeader(&buf));
}

test "decodeHeader: masked frame includes mask key" {
    const buf = [_]u8{ 0x82, 0x85, 0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 5 };
    const h = try decodeHeader(&buf);
    try testing.expect(h.masked);
    try testing.expectEqual(@as(usize, 6), h.header_len);
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, &h.mask_key);
}

test "unmask: round-trip" {
    const key: [4]u8 = .{ 0x01, 0x02, 0x03, 0x04 };
    var payload = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const original = payload;
    unmask(key, &payload);
    // Un-unmask restores original (mask is xor, self-inverse).
    unmask(key, &payload);
    try testing.expectEqualSlices(u8, &original, &payload);
}

test "encodeClientFrame: small binary round-trip via decode" {
    var out: [64]u8 = undefined;
    const key: [4]u8 = .{ 0xAA, 0xBB, 0xCC, 0xDD };
    const payload = "hello";
    const n = encodeClientFrame(.binary, payload, key, true, &out);
    try testing.expectEqual(@as(usize, 2 + 4 + 5), n);

    const h = try decodeHeader(out[0..n]);
    try testing.expect(h.fin);
    try testing.expectEqual(Opcode.binary, h.opcode);
    try testing.expect(h.masked);
    try testing.expectEqual(@as(u64, 5), h.payload_len);

    // Unmask the on-wire payload → should match original.
    const buf = out[h.header_len..n];
    unmask(h.mask_key, buf);
    try testing.expectEqualStrings(payload, buf);
}

test "encodeClientFrame: extended 16-bit length path" {
    const payload = [_]u8{0} ** 300;
    var out: [512]u8 = undefined;
    const key: [4]u8 = .{ 1, 2, 3, 4 };
    const n = encodeClientFrame(.binary, &payload, key, true, &out);
    // 2 (b0+b1) + 2 (ext len) + 4 (mask) + 300 payload = 308
    try testing.expectEqual(@as(usize, 308), n);
    const h = try decodeHeader(out[0..n]);
    try testing.expectEqual(@as(u64, 300), h.payload_len);
}

test "fragmented frames: continuation opcodes allowed, fin clears across frames" {
    // Fragment 1: text, fin=0, payload "hel"
    const f1 = [_]u8{ 0x01, 0x03, 'h', 'e', 'l' };
    // Fragment 2: continuation, fin=0, payload "lo "
    const f2 = [_]u8{ 0x00, 0x03, 'l', 'o', ' ' };
    // Fragment 3: continuation, fin=1, payload "world"
    const f3 = [_]u8{ 0x80, 0x05, 'w', 'o', 'r', 'l', 'd' };

    const h1 = try decodeHeader(&f1);
    try testing.expect(!h1.fin);
    try testing.expectEqual(Opcode.text, h1.opcode);
    const h2 = try decodeHeader(&f2);
    try testing.expect(!h2.fin);
    try testing.expectEqual(Opcode.continuation, h2.opcode);
    const h3 = try decodeHeader(&f3);
    try testing.expect(h3.fin);
    try testing.expectEqual(Opcode.continuation, h3.opcode);
}

test "buildClosePayload: normal closure + reason" {
    var buf: [32]u8 = undefined;
    const n = buildClosePayload(1000, "bye", &buf);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqual(@as(u16, 1000), std.mem.readInt(u16, buf[0..2], .big));
    try testing.expectEqualStrings("bye", buf[2..5]);
}

test "close frame decode: opcode + payload" {
    // Server close: FIN+close, unmasked, 2-byte code 1000 ("Normal Closure")
    const buf = [_]u8{ 0x88, 0x02, 0x03, 0xE8 };
    const h = try decodeHeader(&buf);
    try testing.expectEqual(Opcode.close, h.opcode);
    try testing.expect(h.fin);
    try testing.expectEqual(@as(u64, 2), h.payload_len);
    const code = std.mem.readInt(u16, buf[h.header_len .. h.header_len + 2][0..2], .big);
    try testing.expectEqual(@as(u16, 1000), code);
}

test "ping/pong: roundtrip" {
    // Server ping with 4-byte payload.
    const ping = [_]u8{ 0x89, 0x04, 'p', 'i', 'n', 'g' };
    const h = try decodeHeader(&ping);
    try testing.expectEqual(Opcode.ping, h.opcode);
    try testing.expect(h.opcode.isControl());

    // Client must reply with pong echoing payload.
    var out: [32]u8 = undefined;
    const key: [4]u8 = .{ 9, 9, 9, 9 };
    const n = encodeClientFrame(.pong, "ping", key, true, &out);
    const h2 = try decodeHeader(out[0..n]);
    try testing.expectEqual(Opcode.pong, h2.opcode);
    try testing.expect(h2.masked);
}
