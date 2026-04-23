const std = @import("std");
const logx = @import("../log.zig");

const log = std.log.scoped(.smithers_gtk_diff_parser);

pub const Operation = enum {
    add,
    modify,
    delete,
    rename,
    unknown,
};

pub const FileStatus = enum {
    added,
    modified,
    deleted,
    renamed,
    unknown,

    pub fn badge(self: FileStatus) []const u8 {
        return switch (self) {
            .added => "A",
            .modified => "M",
            .deleted => "D",
            .renamed => "R",
            .unknown => "?",
        };
    }
};

pub const LineKind = enum {
    context,
    addition,
    deletion,
};

pub const Warning = struct {
    line: usize,
    header: []u8,

    pub fn deinit(self: *Warning, alloc: std.mem.Allocator) void {
        alloc.free(self.header);
    }
};

pub const Line = struct {
    kind: LineKind,
    text: []u8,
    old_line_number: ?usize,
    new_line_number: ?usize,

    pub fn deinit(self: *Line, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
    }
};

pub const Hunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    header: []u8,
    lines: std.ArrayList(Line) = .empty,

    pub fn deinit(self: *Hunk, alloc: std.mem.Allocator) void {
        alloc.free(self.header);
        for (self.lines.items) |*line| line.deinit(alloc);
        self.lines.deinit(alloc);
    }
};

pub const File = struct {
    path: []u8,
    old_path: ?[]u8 = null,
    status: FileStatus,
    mode_changes: std.ArrayList([]u8) = .empty,
    is_binary: bool = false,
    binary_size_bytes: ?usize = null,
    hunks: std.ArrayList(Hunk) = .empty,
    partial_parse: bool = false,

    pub fn deinit(self: *File, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        if (self.old_path) |path| alloc.free(path);
        for (self.mode_changes.items) |line| alloc.free(line);
        self.mode_changes.deinit(alloc);
        for (self.hunks.items) |*hunk| hunk.deinit(alloc);
        self.hunks.deinit(alloc);
    }

    pub fn additions(self: File) usize {
        var count: usize = 0;
        for (self.hunks.items) |hunk| {
            for (hunk.lines.items) |line| {
                if (line.kind == .addition) count += 1;
            }
        }
        return count;
    }

    pub fn deletions(self: File) usize {
        var count: usize = 0;
        for (self.hunks.items) |hunk| {
            for (hunk.lines.items) |line| {
                if (line.kind == .deletion) count += 1;
            }
        }
        return count;
    }

    pub fn renderedLineCount(self: File) usize {
        var count: usize = 0;
        for (self.hunks.items) |hunk| count += hunk.lines.items.len;
        return count;
    }
};

pub const Result = struct {
    file: File,
    warnings: std.ArrayList(Warning) = .empty,

    pub fn deinit(self: *Result, alloc: std.mem.Allocator) void {
        self.file.deinit(alloc);
        for (self.warnings.items) |*warning| warning.deinit(alloc);
        self.warnings.deinit(alloc);
    }
};

pub const FileList = struct {
    files: std.ArrayList(File) = .empty,

    pub fn deinit(self: *FileList, alloc: std.mem.Allocator) void {
        for (self.files.items) |*file| file.deinit(alloc);
        self.files.deinit(alloc);
    }
};

pub const Options = struct {
    path: []const u8 = "unknown",
    operation: Operation = .modify,
    old_path: ?[]const u8 = null,
    is_binary: bool = false,
    binary_size_bytes: ?usize = null,
    strict: bool = true,
};

pub fn parseFiles(alloc: std.mem.Allocator, diff: []const u8, options: Options) !FileList {
    log.debug("parseFiles start bytes={d}", .{diff.len});
    const t = logx.startTimer();
    var starts = std.ArrayList(usize).empty;
    defer starts.deinit(alloc);
    try starts.append(alloc, 0);

    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, diff, search_from, "\ndiff --git ")) |pos| {
        try starts.append(alloc, pos + 1);
        search_from = pos + 1;
    }

    var list = FileList{};
    errdefer list.deinit(alloc);

    for (starts.items, 0..) |start, index| {
        const end = if (index + 1 < starts.items.len) starts.items[index + 1] else diff.len;
        const chunk = std.mem.trim(u8, diff[start..end], &std.ascii.whitespace);
        if (chunk.len == 0) continue;
        var chunk_options = options;
        if (pathFromDiffGit(chunk)) |path| chunk_options.path = path;
        var parsed = try parse(alloc, chunk, chunk_options);
        errdefer parsed.file.deinit(alloc);
        try list.files.append(alloc, parsed.file);
        for (parsed.warnings.items) |*warning| warning.deinit(alloc);
        parsed.warnings.deinit(alloc);
    }

    log.debug("parseFiles done files={d}", .{list.files.items.len});
    logx.endTimerDebug(log, "parseFiles", t);
    return list;
}

const HunkMeta = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    header: []u8,
};

const ParsedHeader = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
};

pub fn parse(alloc: std.mem.Allocator, diff: []const u8, options: Options) !Result {
    log.debug("parse start path={s} bytes={d} strict={}", .{ options.path, diff.len, options.strict });
    const t = logx.startTimer();
    const normalized = try normalizeLineEndings(alloc, diff);
    defer alloc.free(normalized);

    var result = Result{
        .file = .{
            .path = try alloc.dupe(u8, options.path),
            .old_path = if (options.old_path) |old| try alloc.dupe(u8, old) else null,
            .status = statusFromOperation(options.operation),
            .is_binary = options.is_binary,
            .binary_size_bytes = options.binary_size_bytes,
        },
    };
    errdefer result.deinit(alloc);

    var rename_from: ?[]const u8 = options.old_path;
    var rename_to: ?[]const u8 = null;
    var inferred_old_path: ?[]const u8 = options.old_path;
    var inferred_new_path: []const u8 = options.path;

    var current_meta: ?HunkMeta = null;
    var current_lines: std.ArrayList(Line) = .empty;
    errdefer {
        if (current_meta) |*meta| alloc.free(meta.header);
        for (current_lines.items) |*line| line.deinit(alloc);
        current_lines.deinit(alloc);
    }

    var old_line: usize = 0;
    var new_line: usize = 0;

    var line_iter = std.mem.splitScalar(u8, normalized, '\n');
    var line_number: usize = 0;
    while (line_iter.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trimRight(u8, raw_line, "\r");

        if (std.mem.startsWith(u8, line, "diff --git ") or
            std.mem.startsWith(u8, line, "index ") or
            std.mem.startsWith(u8, line, "similarity index "))
        {
            continue;
        }

        if (std.mem.startsWith(u8, line, "rename from ")) {
            rename_from = line["rename from ".len..];
            result.file.status = .renamed;
            continue;
        }
        if (std.mem.startsWith(u8, line, "rename to ")) {
            rename_to = line["rename to ".len..];
            inferred_new_path = rename_to.?;
            result.file.status = .renamed;
            continue;
        }

        if (std.mem.startsWith(u8, line, "old mode ") or
            std.mem.startsWith(u8, line, "new mode "))
        {
            try result.file.mode_changes.append(alloc, try alloc.dupe(u8, line));
            continue;
        }

        if (std.mem.startsWith(u8, line, "new file mode ")) {
            result.file.status = .added;
            continue;
        }
        if (std.mem.startsWith(u8, line, "deleted file mode ")) {
            result.file.status = .deleted;
            continue;
        }

        if (std.mem.startsWith(u8, line, "--- ")) {
            const parsed = parsePathHeader(line, "--- ");
            if (std.mem.eql(u8, parsed, "/dev/null")) {
                result.file.status = .added;
                inferred_old_path = null;
            } else {
                inferred_old_path = parsed;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "+++ ")) {
            const parsed = parsePathHeader(line, "+++ ");
            if (std.mem.eql(u8, parsed, "/dev/null")) {
                result.file.status = .deleted;
            } else {
                inferred_new_path = parsed;
            }
            continue;
        }

        if (std.mem.eql(u8, line, "GIT binary patch") or std.mem.startsWith(u8, line, "Binary files ")) {
            result.file.is_binary = true;
            continue;
        }

        if (std.mem.startsWith(u8, line, "\\ No newline at end of file")) continue;

        if (std.mem.startsWith(u8, line, "@@")) {
            try flushHunk(alloc, &result.file.hunks, &current_meta, &current_lines);
            const parsed = parseHunkHeader(line) orelse {
                if (options.strict) return error.MalformedHunkHeader;
                try result.warnings.append(alloc, .{
                    .line = line_number,
                    .header = try alloc.dupe(u8, line),
                });
                continue;
            };
            current_meta = .{
                .old_start = parsed.old_start,
                .old_count = parsed.old_count,
                .new_start = parsed.new_start,
                .new_count = parsed.new_count,
                .header = try alloc.dupe(u8, line),
            };
            old_line = parsed.old_start;
            new_line = parsed.new_start;
            continue;
        }

        if (current_meta == null) continue;

        if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) {
            try current_lines.append(alloc, .{
                .kind = .addition,
                .text = try alloc.dupe(u8, line[1..]),
                .old_line_number = null,
                .new_line_number = new_line,
            });
            new_line += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) {
            try current_lines.append(alloc, .{
                .kind = .deletion,
                .text = try alloc.dupe(u8, line[1..]),
                .old_line_number = old_line,
                .new_line_number = null,
            });
            old_line += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, " ")) {
            try current_lines.append(alloc, .{
                .kind = .context,
                .text = try alloc.dupe(u8, line[1..]),
                .old_line_number = old_line,
                .new_line_number = new_line,
            });
            old_line += 1;
            new_line += 1;
            continue;
        }

        if (line.len == 0) continue;

        try current_lines.append(alloc, .{
            .kind = .context,
            .text = try alloc.dupe(u8, line),
            .old_line_number = old_line,
            .new_line_number = new_line,
        });
        old_line += 1;
        new_line += 1;
    }

    try flushHunk(alloc, &result.file.hunks, &current_meta, &current_lines);

    alloc.free(result.file.path);
    result.file.path = try alloc.dupe(u8, rename_to orelse inferred_new_path);
    if (result.file.old_path) |old| alloc.free(old);
    result.file.old_path = if (rename_from orelse inferred_old_path) |old| try alloc.dupe(u8, old) else null;
    result.file.partial_parse = result.warnings.items.len > 0;
    log.debug("parse done path={s} hunks={d} lines={d} warnings={d}", .{
        result.file.path,
        result.file.hunks.items.len,
        result.file.renderedLineCount(),
        result.warnings.items.len,
    });
    logx.endTimerDebug(log, "parse", t);
    return result;
}

fn flushHunk(
    alloc: std.mem.Allocator,
    hunks: *std.ArrayList(Hunk),
    current_meta: *?HunkMeta,
    current_lines: *std.ArrayList(Line),
) !void {
    const meta = current_meta.* orelse return;
    try hunks.append(alloc, .{
        .old_start = meta.old_start,
        .old_count = meta.old_count,
        .new_start = meta.new_start,
        .new_count = meta.new_count,
        .header = meta.header,
        .lines = current_lines.*,
    });
    current_meta.* = null;
    current_lines.* = .empty;
}

fn normalizeLineEndings(alloc: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, value.len);
    defer out.deinit();
    const writer = &out.writer;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] == '\r') {
            try writer.writeByte('\n');
            if (i + 1 < value.len and value[i + 1] == '\n') i += 1;
        } else {
            try writer.writeByte(value[i]);
        }
    }
    return try out.toOwnedSlice();
}

fn statusFromOperation(operation: Operation) FileStatus {
    return switch (operation) {
        .add => .added,
        .modify => .modified,
        .delete => .deleted,
        .rename => .renamed,
        .unknown => .unknown,
    };
}

fn parsePathHeader(line: []const u8, prefix: []const u8) []const u8 {
    var raw = line[prefix.len..];
    if (std.mem.startsWith(u8, raw, "a/") or std.mem.startsWith(u8, raw, "b/")) raw = raw[2..];
    return raw;
}

fn pathFromDiffGit(chunk: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, chunk, '\n');
    const first = lines.next() orelse return null;
    if (!std.mem.startsWith(u8, first, "diff --git ")) return null;
    if (std.mem.lastIndexOf(u8, first, " b/")) |b_index| return first[b_index + 3 ..];
    return null;
}

fn parseHunkHeader(line: []const u8) ?ParsedHeader {
    if (!std.mem.startsWith(u8, line, "@@ -")) return null;
    var index: usize = 4;
    const old_start = parsePositive(line, &index) orelse return null;
    const old_count = if (consume(line, &index, ',')) parsePositive(line, &index) orelse return null else 1;
    if (!consume(line, &index, ' ')) return null;
    if (!consume(line, &index, '+')) return null;
    const new_start = parsePositive(line, &index) orelse return null;
    const new_count = if (consume(line, &index, ',')) parsePositive(line, &index) orelse return null else 1;
    if (!consume(line, &index, ' ')) return null;
    if (index + 2 > line.len or !std.mem.eql(u8, line[index .. index + 2], "@@")) return null;
    return .{
        .old_start = old_start,
        .old_count = old_count,
        .new_start = new_start,
        .new_count = new_count,
    };
}

fn parsePositive(line: []const u8, index: *usize) ?usize {
    const start = index.*;
    while (index.* < line.len and std.ascii.isDigit(line[index.*])) index.* += 1;
    if (index.* == start) return null;
    return std.fmt.parseInt(usize, line[start..index.*], 10) catch null;
}

fn consume(line: []const u8, index: *usize, ch: u8) bool {
    if (index.* >= line.len or line[index.*] != ch) return false;
    index.* += 1;
    return true;
}

test "empty diff string produces no hunks" {
    var parsed = try parse(std.testing.allocator, "", .{ .path = "empty.txt" });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), parsed.file.hunks.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.file.renderedLineCount());
}

test "multiple hunks count additions and deletions" {
    var parsed = try parse(std.testing.allocator,
        \\@@ -1,2 +1,2 @@
        \\-a
        \\+b
        \\@@ -10,2 +10,3 @@
        \\ x
        \\+y
        \\ z
    , .{ .path = "multi.txt" });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), parsed.file.hunks.items.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.file.additions());
    try std.testing.expectEqual(@as(usize, 1), parsed.file.deletions());
}

test "headers infer status and paths" {
    var parsed = try parse(std.testing.allocator,
        \\diff --git a/old-name.txt b/new-name.txt
        \\rename from old-name.txt
        \\rename to new-name.txt
        \\old mode 100644
        \\new mode 100755
        \\@@ -1 +1 @@
        \\-hello
        \\+hello world
    , .{ .path = "new-name.txt", .operation = .rename, .old_path = "old-name.txt" });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(FileStatus.renamed, parsed.file.status);
    try std.testing.expectEqualStrings("old-name.txt", parsed.file.old_path.?);
    try std.testing.expectEqualStrings("new-name.txt", parsed.file.path);
    try std.testing.expectEqual(@as(usize, 2), parsed.file.mode_changes.items.len);
}

test "parseFiles splits multi-file unified diff" {
    var files = try parseFiles(std.testing.allocator,
        \\diff --git a/a.txt b/a.txt
        \\--- a/a.txt
        \\+++ b/a.txt
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\diff --git a/b.txt b/b.txt
        \\--- a/b.txt
        \\+++ b/b.txt
        \\@@ -1 +1 @@
        \\-c
        \\+d
    , .{ .path = "unknown", .strict = false });
    defer files.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), files.files.items.len);
    try std.testing.expectEqualStrings("a.txt", files.files.items[0].path);
    try std.testing.expectEqualStrings("b.txt", files.files.items[1].path);
}

test "crlf and no-newline markers are normalized" {
    var parsed = try parse(std.testing.allocator, "@@ -1,1 +1,1 @@\r\n-old\r\n\\ No newline at end of file\r\n+new\r\n", .{ .path = "crlf.txt" });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), parsed.file.hunks.items.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.file.hunks.items[0].lines.items.len);
    try std.testing.expectEqualStrings("new", parsed.file.hunks.items[0].lines.items[1].text);
}

test "malformed header can warn instead of fail" {
    try std.testing.expectError(error.MalformedHunkHeader, parse(std.testing.allocator,
        \\@@ malformed header @@
        \\+line
    , .{ .path = "bad.txt" }));

    var parsed = try parse(std.testing.allocator,
        \\@@ malformed header @@
        \\+line
    , .{ .path = "bad.txt", .strict = false });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.file.partial_parse);
    try std.testing.expectEqual(@as(usize, 1), parsed.warnings.items[0].line);
}
