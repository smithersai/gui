const std = @import("std");
const build_options = @import("build_options");

test "binary --help" {
    const result = try run(&.{"--help"});
    defer result.deinit();
    try result.expectExit(0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Usage: smithers-cli") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Commands:") != null);
}

test "binary info" {
    const result = try run(&.{"info"});
    defer result.deinit();
    try result.expectExit(0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "version:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "platform:") != null);
}

test "binary cwd resolve" {
    const result = try run(&.{ "cwd", "resolve" });
    defer result.deinit();
    try result.expectExit(0);
    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    try std.testing.expect(trimmed.len > 0);
    try std.testing.expect(trimmed[0] == '/');
}

test "binary slash parse" {
    const result = try run(&.{ "slash", "parse", "/build foo" });
    defer result.deinit();
    try result.expectExit(0);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.stdout, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

const RunResult = struct {
    allocator: std.mem.Allocator,
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: RunResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    fn expectExit(self: RunResult, expected: u8) !void {
        const actual = switch (self.term) {
            .Exited => |code| code,
            else => 255,
        };
        try std.testing.expectEqual(expected, actual);
        if (actual != expected) {
            std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ self.stdout, self.stderr });
        }
    }
};

fn run(args: []const []const u8) !RunResult {
    const allocator = std.testing.allocator;
    var argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = build_options.exe_path;
    for (args, 0..) |arg, i| argv[i + 1] = arg;

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    });
    return .{
        .allocator = allocator,
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}
