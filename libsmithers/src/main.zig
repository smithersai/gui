pub const App = @import("App.zig");
pub const apprt = @import("apprt/apprt.zig");
pub const client = @import("client/client.zig");
pub const commands = @import("commands/mod.zig");
pub const ffi = @import("ffi.zig");
pub const models = @import("models/mod.zig");
pub const persistence = @import("persistence/sqlite.zig");
pub const session = @import("session/session.zig");
pub const terminal = @import("terminal/tmux.zig");
pub const workspace = @import("workspace/mod.zig");

comptime {
    _ = apprt.embedded;
}

test {
    @import("std").testing.refAllDecls(@This());
}
