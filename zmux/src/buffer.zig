const std = @import("std");

const Allocator = std.mem.Allocator;

pub const default_capacity = 10 * 1024 * 1024;

pub const ScrollbackBuffer = struct {
    allocator: Allocator,
    data: []u8,
    start: usize = 0,
    len: usize = 0,

    pub fn init(allocator: Allocator, capacity_bytes: usize) !ScrollbackBuffer {
        const cap = @max(capacity_bytes, 1);
        return .{
            .allocator = allocator,
            .data = try allocator.alloc(u8, cap),
        };
    }

    pub fn deinit(self: *ScrollbackBuffer) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    pub fn capacity(self: *const ScrollbackBuffer) usize {
        return self.data.len;
    }

    pub fn append(self: *ScrollbackBuffer, bytes: []const u8) void {
        if (bytes.len == 0) return;

        if (bytes.len >= self.data.len) {
            const tail = bytes[bytes.len - self.data.len ..];
            @memcpy(self.data, tail);
            self.start = 0;
            self.len = self.data.len;
            return;
        }

        const overflow = if (self.len + bytes.len > self.data.len)
            self.len + bytes.len - self.data.len
        else
            0;
        if (overflow > 0) {
            self.start = (self.start + overflow) % self.data.len;
            self.len -= overflow;
        }

        var write_at = (self.start + self.len) % self.data.len;
        var remaining = bytes;
        while (remaining.len > 0) {
            const chunk_len = @min(remaining.len, self.data.len - write_at);
            @memcpy(self.data[write_at .. write_at + chunk_len], remaining[0..chunk_len]);
            remaining = remaining[chunk_len..];
            write_at = (write_at + chunk_len) % self.data.len;
        }
        self.len += bytes.len;
    }

    pub fn snapshot(self: *const ScrollbackBuffer, allocator: Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.len);
        if (self.len == 0) return out;

        const first_len = @min(self.len, self.data.len - self.start);
        @memcpy(out[0..first_len], self.data[self.start .. self.start + first_len]);
        if (first_len < self.len) {
            @memcpy(out[first_len..], self.data[0 .. self.len - first_len]);
        }
        return out;
    }

    pub fn captureLastLines(self: *const ScrollbackBuffer, allocator: Allocator, max_lines: usize) ![]u8 {
        if (max_lines == 0 or self.len == 0) return allocator.dupe(u8, "");

        const snap = try self.snapshot(allocator);
        defer allocator.free(snap);

        var scan_end = snap.len;
        if (scan_end > 0 and snap[scan_end - 1] == '\n') scan_end -= 1;

        var start: usize = 0;
        var seen: usize = 0;
        var i = scan_end;
        while (i > 0) {
            i -= 1;
            if (snap[i] == '\n') {
                seen += 1;
                if (seen == max_lines) {
                    start = i + 1;
                    break;
                }
            }
        }

        return allocator.dupe(u8, snap[start..]);
    }
};

test "scrollback keeps newest bytes after wrap" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 8);
    defer buffer.deinit();

    buffer.append("hello");
    buffer.append(" world");

    const snap = try buffer.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("lo world", snap);
}

test "scrollback captures last lines" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 128);
    defer buffer.deinit();

    buffer.append("one\ntwo\nthree\nfour\n");

    const capture = try buffer.captureLastLines(std.testing.allocator, 2);
    defer std.testing.allocator.free(capture);
    try std.testing.expectEqualStrings("three\nfour\n", capture);
}
