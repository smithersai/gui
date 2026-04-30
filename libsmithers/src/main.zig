pub const core = @import("core/core.zig");
pub const ffi = @import("ffi.zig");
pub const obs = @import("obs.zig");

comptime {
    // Shared string/error/bytes frees.
    _ = @import("ffi_exports.zig");
    // Core runtime exports.
    _ = @import("core/ffi.zig");
    // Observability runtime exports.
    _ = @import("obs_ffi.zig");
}

test {
    @import("std").testing.refAllDecls(@This());
}
