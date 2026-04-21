const std = @import("std");
const main = @import("smithers_cli");

test "golden: global flags before command" {
    const inv = try main.parseInvocation(&.{ "--json", "--verbose", "palette", "query", "run", "--mode", "commands" });
    try std.testing.expect(inv.globals.json);
    try std.testing.expect(inv.globals.verbose);
    try std.testing.expectEqual(main.Command.palette, inv.command.?);
    try std.testing.expectEqual(@as(usize, 4), inv.rest.len);
    try std.testing.expectEqualStrings("query", inv.rest[0]);
    try std.testing.expectEqualStrings("commands", inv.rest[3]);
}

test "golden: nested command positional path" {
    const inv = try main.parseInvocation(&.{ "cwd", "resolve", "/tmp/project" });
    try std.testing.expectEqual(main.Command.cwd, inv.command.?);
    try std.testing.expectEqualStrings("resolve", inv.rest[0]);
    try std.testing.expectEqualStrings("/tmp/project", inv.rest[1]);
}

test "golden: version short-circuits without command" {
    const inv = try main.parseInvocation(&.{"--version"});
    try std.testing.expect(inv.version);
    try std.testing.expect(inv.command == null);
}

test "golden: unknown command is rejected" {
    try std.testing.expectError(error.UnknownCommand, main.parseInvocation(&.{"unknown"}));
}
