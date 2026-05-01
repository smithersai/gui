//! Unit tests: frame encode/decode, handshake parsing, and error mapping.
//! All run under the Zig test allocator — any leak fails the test.

const std = @import("std");
const ws = @import("ws_pty");
const testing = std.testing;

// Re-export module tests so `zig build unit` picks them up transitively.
test {
    _ = ws;
    _ = ws.frame;
    _ = ws.handshake;
    _ = ws.client;
}

// ---- Extra coverage layered on top of the submodule tests ----

test "handshake: generate key + full request round-trip via writeRequest" {
    var prng = std.Random.DefaultPrng.init(42);
    var key_buf: [32]u8 = undefined;
    const key = ws.handshake.generateKey(prng.random(), &key_buf);
    try testing.expectEqual(@as(usize, 24), key.len);

    const bytes = try ws.handshake.writeRequest(testing.allocator, .{
        .host = "api.plue.local:4000",
        .path = "/api/repos/a/b/workspace/sessions/sid/terminal",
        .origin = "http://api.plue.local:4000",
        .bearer = "jjhub_deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
        .subprotocol = "terminal",
        .key_b64 = key,
    });
    defer testing.allocator.free(bytes);

    try testing.expect(std.mem.startsWith(u8, bytes, "GET /api/repos/a/b/workspace/sessions/sid/terminal HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, bytes, "Host: api.plue.local:4000\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Upgrade: websocket\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Connection: Upgrade\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Sec-WebSocket-Version: 13\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Origin: http://api.plue.local:4000\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Sec-WebSocket-Protocol: terminal\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Authorization: Bearer jjhub_") != null);
    try testing.expect(std.mem.endsWith(u8, bytes, "\r\n\r\n"));
}

test "bad-origin handshake response surfaces as distinct error" {
    const raw =
        "HTTP/1.1 403 Forbidden\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n" ++
        "{\"error\":\"origin not allowed\"}";
    const err = ws.handshake.parseResponse(raw);
    try testing.expectError(ws.Error.HandshakeOriginRejected, err);
}

test "frame reassembly semantics: 3-fragment message by encoding and decoding headers" {
    // Simulate a server sending a text message in 3 fragments. We drive just
    // the decoder; the client reassembly logic is exercised in integration.
    const f1 = [_]u8{ 0x01, 0x03, 'h', 'e', 'l' };
    const f2 = [_]u8{ 0x00, 0x03, 'l', 'o', ' ' };
    const f3 = [_]u8{ 0x80, 0x05, 'w', 'o', 'r', 'l', 'd' };

    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(testing.allocator);
    try all.appendSlice(testing.allocator, &f1);
    try all.appendSlice(testing.allocator, &f2);
    try all.appendSlice(testing.allocator, &f3);

    var cursor: usize = 0;
    var reassembled: std.ArrayList(u8) = .empty;
    defer reassembled.deinit(testing.allocator);
    var last_opcode: ?ws.frame.Opcode = null;
    while (cursor < all.items.len) {
        const h = try ws.frame.decodeHeader(all.items[cursor..]);
        const payload_start = cursor + h.header_len;
        const payload_end = payload_start + @as(usize, @intCast(h.payload_len));
        try reassembled.appendSlice(testing.allocator, all.items[payload_start..payload_end]);
        if (h.opcode != .continuation) last_opcode = h.opcode;
        cursor = payload_end;
        if (h.fin) break;
    }
    try testing.expectEqualStrings("hello world", reassembled.items);
    try testing.expectEqual(ws.frame.Opcode.text, last_opcode.?);
}

test "frame boundary: long message spanning multiple frames reassembles correctly" {
    // Construct a 3 KiB message split into 4 frames of 768, 768, 768, 768 bytes
    // (last FIN). Decode headers + payloads one-by-one and check byte-identity.
    const total = 3072;
    const chunk = 768;
    const src = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(src);
    for (src, 0..) |*b, i| b.* = @as(u8, @intCast(i & 0xFF));

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(testing.allocator);
    var idx: usize = 0;
    while (idx < total) : (idx += chunk) {
        const end = @min(idx + chunk, total);
        const is_first = idx == 0;
        const is_last = end == total;
        // Unmasked server frames: b0 = fin?|0x00|op, b1 = ext len
        var b0: u8 = 0;
        if (is_last) b0 |= 0x80; // FIN
        b0 |= if (is_first) @intFromEnum(ws.frame.Opcode.binary) else @intFromEnum(ws.frame.Opcode.continuation);
        try wire.append(testing.allocator, b0);
        // chunk = 768 > 125 so use 16-bit extended length.
        const len = end - idx;
        try wire.append(testing.allocator, 126);
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, @as(u16, @intCast(len)), .big);
        try wire.appendSlice(testing.allocator, &buf);
        try wire.appendSlice(testing.allocator, src[idx..end]);
    }

    // Now decode + reassemble.
    var cursor: usize = 0;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    while (cursor < wire.items.len) {
        const h = try ws.frame.decodeHeader(wire.items[cursor..]);
        const payload_start = cursor + h.header_len;
        const payload_end = payload_start + @as(usize, @intCast(h.payload_len));
        try got.appendSlice(testing.allocator, wire.items[payload_start..payload_end]);
        cursor = payload_end;
        if (h.fin) break;
    }
    try testing.expectEqualSlices(u8, src, got.items);
}

test "close code mapping: 1000 Normal, 1001 Going Away" {
    var buf: [8]u8 = undefined;
    _ = ws.frame.buildClosePayload(1000, "", &buf);
    try testing.expectEqual(@as(u16, 1000), std.mem.readInt(u16, buf[0..2], .big));
    _ = ws.frame.buildClosePayload(1001, "", &buf);
    try testing.expectEqual(@as(u16, 1001), std.mem.readInt(u16, buf[0..2], .big));
}
