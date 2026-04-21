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

    pub fn optionValue(self: *Parser, arg: []const u8, name: []const u8) !?[]const u8 {
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
};

pub fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
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

test "help flag aliases" {
    try std.testing.expect(isHelp("--help"));
    try std.testing.expect(isHelp("-h"));
    try std.testing.expect(!isHelp("--json"));
}
