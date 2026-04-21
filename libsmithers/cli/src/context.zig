const std = @import("std");
const lib = @import("libsmithers.zig");

pub const CliFailure = error{CliFailure};

pub const Globals = struct {
    json: bool = false,
    verbose: bool = false,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    globals: Globals,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,

    pub fn fail(self: *Context, comptime fmt: []const u8, values: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, values);
        defer self.allocator.free(message);
        try self.writeError(message);
        return error.CliFailure;
    }

    pub fn writeError(self: *Context, message: []const u8) !void {
        if (self.globals.json) {
            try std.json.Stringify.value(.{
                .ok = false,
                .@"error" = message,
            }, .{}, self.stderr);
            try self.stderr.writeByte('\n');
            return;
        }
        try self.stderr.print("error: {s}\n", .{message});
    }

    pub fn writeJson(self: *Context, value: anytype) !void {
        const whitespace: std.json.Stringify.Options = if (self.globals.json)
            .{}
        else
            .{ .whitespace = .indent_2 };
        try std.json.Stringify.value(value, whitespace, self.stdout);
        try self.stdout.writeByte('\n');
    }

    pub fn writeJsonRaw(self: *Context, raw: []const u8) !void {
        if (self.globals.json) {
            try self.stdout.writeAll(raw);
            try self.stdout.writeByte('\n');
            return;
        }

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch {
            try self.stdout.writeAll(raw);
            try self.stdout.writeByte('\n');
            return;
        };
        defer parsed.deinit();
        try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, self.stdout);
        try self.stdout.writeByte('\n');
    }

    pub fn makeApp(self: *Context) !lib.App {
        const app = lib.smithers_app_new(&runtime_config);
        if (app == null) {
            try self.fail("failed to create smithers app", .{});
            unreachable;
        }
        return app;
    }

    pub fn makeClient(self: *Context, app: lib.App) !lib.Client {
        const client = lib.smithers_client_new(app);
        if (client == null) {
            try self.fail("failed to create smithers client", .{});
            unreachable;
        }
        return client;
    }

    pub fn makePalette(self: *Context, app: lib.App) !lib.Palette {
        const palette = lib.smithers_palette_new(app);
        if (palette == null) {
            try self.fail("failed to create smithers palette", .{});
            unreachable;
        }
        return palette;
    }
};

fn wakeup(_: lib.Userdata) callconv(.c) void {}

fn action(_: lib.App, _: lib.ActionTarget, _: lib.Action) callconv(.c) bool {
    return false;
}

fn readClipboard(_: lib.Userdata, _: *lib.String) callconv(.c) bool {
    return false;
}

fn writeClipboard(_: lib.Userdata, _: ?[*:0]const u8) callconv(.c) void {}

fn stateChanged(_: lib.Userdata) callconv(.c) void {}

fn log(_: lib.Userdata, _: i32, _: ?[*:0]const u8) callconv(.c) void {}

pub const runtime_config = lib.RuntimeConfig{
    .wakeup = wakeup,
    .action = action,
    .read_clipboard = readClipboard,
    .write_clipboard = writeClipboard,
    .state_changed = stateChanged,
    .log = log,
};
