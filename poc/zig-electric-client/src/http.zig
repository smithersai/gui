//! Minimal HTTP/1.1 client for Electric shape responses.
//!
//! We don't use std.http for two reasons:
//!   1. We need full visibility into Electric's custom response headers
//!      (`electric-handle`, `electric-offset`, `electric-cursor`,
//!      `electric-schema`). std.http exposes these via an iterator but the
//!      API is awkward for our needs.
//!   2. This matches the style of poc/zig-ws-pty: ~120 LoC of hand-rolled
//!      HTTP, fully auditable.
//!
//! Scope: GET-only, chunked + Content-Length bodies, long-poll-friendly
//! (connection kept open by the server via `?live=true`), HTTP only (no
//! TLS — documented in README).

const std = @import("std");
const Err = @import("errors.zig").Error;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Response = struct {
    status: u16,
    headers: []Header,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        for (self.headers) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.allocator.free(self.headers);
    }

    pub fn header(self: Response, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

pub const Request = struct {
    host: []const u8,
    port: u16,
    path_and_query: []const u8,
    bearer: ?[]const u8 = null,
    /// Server-assigned shape handle from a previous response. When present,
    /// we send it as the `electric-handle` header. Electric uses this to tie
    /// a long-poll to the existing shape (required for deltas).
    handle: ?[]const u8 = null,
};

pub fn renderRequest(allocator: std.mem.Allocator, r: Request) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.print(allocator, "GET {s} HTTP/1.1\r\n", .{r.path_and_query});
    try buf.print(allocator, "Host: {s}\r\n", .{r.host});
    try buf.appendSlice(allocator, "Accept: application/json\r\n");
    try buf.appendSlice(allocator, "Connection: close\r\n");
    if (r.bearer) |t| try buf.print(allocator, "Authorization: Bearer {s}\r\n", .{t});
    if (r.handle) |h| try buf.print(allocator, "electric-handle: {s}\r\n", .{h});
    try buf.appendSlice(allocator, "\r\n");
    return buf.toOwnedSlice(allocator);
}

/// Issue a GET and read the entire response into memory. For long-polls
/// we pass `?live=true` in the query string and rely on the server
/// timeout (typically 20s) to release the connection.
pub fn fetch(allocator: std.mem.Allocator, req: Request) Err!Response {
    const rendered = renderRequest(allocator, req) catch return Err.OutOfMemory;
    defer allocator.free(rendered);

    var stream = std.net.tcpConnectToHost(allocator, req.host, req.port) catch return Err.IoError;
    defer stream.close();

    _ = stream.writeAll(rendered) catch return Err.IoError;

    // Slurp the entire response. Electric shape responses are bounded —
    // the server closes the connection once it emits the batch or once
    // its long-poll timeout elapses.
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    var scratch: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&scratch) catch return Err.IoError;
        if (n == 0) break;
        raw.appendSlice(allocator, scratch[0..n]) catch return Err.OutOfMemory;
    }

    return parseResponse(allocator, raw.items);
}

/// Parse a byte buffer into a Response. Exposed for fake-server tests.
pub fn parseResponse(allocator: std.mem.Allocator, buf: []const u8) Err!Response {
    const header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return Err.HttpMalformed;
    const head = buf[0..header_end];
    const after_headers = buf[header_end + 4 ..];

    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return Err.HttpMalformed;
    // "HTTP/1.1 200 OK"
    var sp = std.mem.splitScalar(u8, status_line, ' ');
    _ = sp.next() orelse return Err.HttpMalformed;
    const code_str = sp.next() orelse return Err.HttpMalformed;
    const status = std.fmt.parseInt(u16, code_str, 10) catch return Err.HttpMalformed;

    var headers: std.ArrayList(Header) = .empty;
    errdefer {
        for (headers.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        headers.deinit(allocator);
    }

    var content_length: ?usize = null;
    var chunked = false;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return Err.HttpMalformed;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return Err.HttpMalformed;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.ascii.eqlIgnoreCase(value, "chunked")) {
            chunked = true;
        }
        const n_copy = allocator.dupe(u8, name) catch return Err.OutOfMemory;
        errdefer allocator.free(n_copy);
        const v_copy = allocator.dupe(u8, value) catch return Err.OutOfMemory;
        errdefer allocator.free(v_copy);
        headers.append(allocator, .{ .name = n_copy, .value = v_copy }) catch return Err.OutOfMemory;
    }

    // --- Decode body ---
    var body: []u8 = &.{};
    if (chunked) {
        body = decodeChunked(allocator, after_headers) catch |e| switch (e) {
            error.OutOfMemory => return Err.OutOfMemory,
            else => return Err.HttpMalformed,
        };
    } else if (content_length) |clen| {
        if (after_headers.len < clen) return Err.ShortRead;
        body = allocator.dupe(u8, after_headers[0..clen]) catch return Err.OutOfMemory;
    } else {
        // Connection: close — body is everything up to EOF.
        body = allocator.dupe(u8, after_headers) catch return Err.OutOfMemory;
    }

    return Response{
        .status = status,
        .headers = headers.toOwnedSlice(allocator) catch return Err.OutOfMemory,
        .body = body,
        .allocator = allocator,
    };
}

/// Decode RFC 7230 chunked transfer encoding. We only handle unextended
/// chunks; Electric doesn't emit extensions or trailers in the shape API.
fn decodeChunked(allocator: std.mem.Allocator, buf: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pos: usize = 0;
    while (pos < buf.len) {
        const line_end = std.mem.indexOfPos(u8, buf, pos, "\r\n") orelse return error.Truncated;
        const size_line = buf[pos..line_end];
        // Strip possible ";ext" after the hex count.
        const semi = std.mem.indexOfScalar(u8, size_line, ';');
        const hex = if (semi) |s| size_line[0..s] else size_line;
        const chunk_size = try std.fmt.parseInt(usize, hex, 16);
        pos = line_end + 2;
        if (chunk_size == 0) break;
        if (pos + chunk_size + 2 > buf.len) return error.Truncated;
        try out.appendSlice(allocator, buf[pos .. pos + chunk_size]);
        pos += chunk_size;
        if (!std.mem.eql(u8, buf[pos .. pos + 2], "\r\n")) return error.Truncated;
        pos += 2;
    }
    return out.toOwnedSlice(allocator);
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "renderRequest: bearer + handle" {
    const s = try renderRequest(testing.allocator, .{
        .host = "api.example.com",
        .port = 4000,
        .path_and_query = "/v1/shape?table=poc_items&offset=-1",
        .bearer = "jjhub_aaaa",
        .handle = "h-123",
    });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "GET /v1/shape?table=poc_items&offset=-1 HTTP/1.1") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Host: api.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, s, "Authorization: Bearer jjhub_aaaa") != null);
    try testing.expect(std.mem.indexOf(u8, s, "electric-handle: h-123") != null);
}

test "parseResponse: 200 with content-length" {
    const raw =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 2\r\n" ++
        "electric-handle: abc\r\n" ++
        "electric-offset: 42_0\r\n" ++
        "\r\n" ++
        "[]";
    var r = try parseResponse(testing.allocator, raw);
    defer r.deinit();
    try testing.expectEqual(@as(u16, 200), r.status);
    try testing.expectEqualStrings("[]", r.body);
    try testing.expectEqualStrings("abc", r.header("electric-handle").?);
    try testing.expectEqualStrings("42_0", r.header("ELECTRIC-OFFSET").?);
}

test "parseResponse: chunked body reassembles" {
    // Two chunks ("hel", "lo") then terminator.
    const raw =
        "HTTP/1.1 200 OK\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "3\r\nhel\r\n" ++
        "2\r\nlo\r\n" ++
        "0\r\n\r\n";
    var r = try parseResponse(testing.allocator, raw);
    defer r.deinit();
    try testing.expectEqualStrings("hello", r.body);
}

test "parseResponse: short body -> ShortRead" {
    const raw =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: 100\r\n" ++
        "\r\n" ++
        "abc";
    const res = parseResponse(testing.allocator, raw);
    try testing.expectError(Err.ShortRead, res);
}

test "parseResponse: 401 unauthorized" {
    const raw =
        "HTTP/1.1 401 Unauthorized\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n";
    var r = try parseResponse(testing.allocator, raw);
    defer r.deinit();
    try testing.expectEqual(@as(u16, 401), r.status);
}

test "parseResponse: 403 forbidden carries body" {
    const raw =
        "HTTP/1.1 403 Forbidden\r\n" ++
        "Content-Length: 22\r\n" ++
        "\r\n" ++
        "{\"error\":\"denied\"}    ";
    var r = try parseResponse(testing.allocator, raw);
    defer r.deinit();
    try testing.expectEqual(@as(u16, 403), r.status);
    try testing.expectEqual(@as(usize, 22), r.body.len);
}

test "parseResponse: malformed status line" {
    const raw = "not http\r\n\r\n";
    const res = parseResponse(testing.allocator, raw);
    try testing.expectError(Err.HttpMalformed, res);
}

test "parseResponse: missing header terminator" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n";
    const res = parseResponse(testing.allocator, raw);
    try testing.expectError(Err.HttpMalformed, res);
}

test "parseResponse: connection-close body runs to EOF" {
    const raw =
        "HTTP/1.1 200 OK\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "payload-bytes";
    var r = try parseResponse(testing.allocator, raw);
    defer r.deinit();
    try testing.expectEqualStrings("payload-bytes", r.body);
}
