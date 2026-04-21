const std = @import("std");

pub const Parser = struct {
    args: []const []const u8,
    index: usize = 0,

    pub fn init(args: []const []const u8) Parser {
        return .{ .args = args };
    }

    pub fn next(self: *Parser) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        const value = self.args[self.index];
        self.index += 1;
        return value;
    }

    pub fn remaining(self: *const Parser) []const []const u8 {
        return self.args[self.index..];
    }

    pub fn nextNonGlobal(self: *Parser) ?[]const u8 {
        while (self.next()) |arg| {
            if (isGlobalFlag(arg)) continue;
            return arg;
        }
        return null;
    }

    pub fn optionValue(self: *Parser, arg: []const u8, name: []const u8) !?[]const u8 {
        return self.optionValueAny(arg, name, null);
    }

    pub fn optionValueAny(self: *Parser, arg: []const u8, long_name: []const u8, short_name: ?u8) !?[]const u8 {
        if (try self.optionValueLong(arg, long_name)) |value| return value;
        if (short_name) |short| {
            if (try self.optionValueShort(arg, short)) |value| return value;
        }
        return null;
    }

    fn optionValueLong(self: *Parser, arg: []const u8, name: []const u8) !?[]const u8 {
        if (!std.mem.startsWith(u8, arg, "--")) return null;
        const body = arg[2..];
        if (std.mem.eql(u8, body, name)) {
            return self.next() orelse error.MissingOptionValue;
        }
        if (body.len > name.len and
            std.mem.eql(u8, body[0..name.len], name) and
            body[name.len] == '=')
        {
            return body[name.len + 1 ..];
        }
        return null;
    }

    fn optionValueShort(self: *Parser, arg: []const u8, short_name: u8) !?[]const u8 {
        if (arg.len < 2 or arg[0] != '-' or arg[1] == '-') return null;
        if (arg[1] != short_name) return null;
        if (arg.len == 2) return self.next() orelse error.MissingOptionValue;
        if (arg.len > 3 and arg[2] == '=') return arg[3..];
        return null;
    }
};

pub fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub fn containsHelp(args: []const []const u8) bool {
    for (args) |arg| {
        if (isHelp(arg)) return true;
    }
    return false;
}

pub fn isGlobalFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--verbose");
}

pub fn isLongFlag(arg: []const u8, name: []const u8) bool {
    return std.mem.startsWith(u8, arg, "--") and std.mem.eql(u8, arg[2..], name);
}

pub fn rejectUnexpected(ctx: anytype, arg: []const u8) !void {
    if (std.mem.startsWith(u8, arg, "-")) {
        return ctx.fail("unknown option: {s}", .{arg});
    }
    return ctx.fail("unexpected argument: {s}", .{arg});
}

test "option value supports split and equals forms" {
    var split = Parser.init(&.{ "--mode", "commands" });
    try std.testing.expectEqualStrings("commands", (try split.optionValue(split.next().?, "mode")).?);

    var equals = Parser.init(&.{"--mode=files"});
    try std.testing.expectEqualStrings("files", (try equals.optionValue(equals.next().?, "mode")).?);
}

test "option value supports short split and equals forms" {
    var split = Parser.init(&.{ "-m", "commands" });
    try std.testing.expectEqualStrings("commands", (try split.optionValueAny(split.next().?, "mode", 'm')).?);

    var equals = Parser.init(&.{"-m=files"});
    try std.testing.expectEqualStrings("files", (try equals.optionValueAny(equals.next().?, "mode", 'm')).?);
}

test "help flag aliases" {
    try std.testing.expect(isHelp("--help"));
    try std.testing.expect(isHelp("-h"));
    try std.testing.expect(!isHelp("--json"));
}

test "next non-global skips global flags" {
    var parser = Parser.init(&.{ "--json", "--verbose", "resolve" });
    try std.testing.expectEqualStrings("resolve", parser.nextNonGlobal().?);
    try std.testing.expect(parser.nextNonGlobal() == null);
}
