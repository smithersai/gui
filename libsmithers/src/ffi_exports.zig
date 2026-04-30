const ffi = @import("ffi.zig");
const structs = @import("apprt/structs.zig");

pub export fn smithers_string_free(s: structs.String) void {
    ffi.stringFree(s);
}

pub export fn smithers_error_free(e: structs.Error) void {
    ffi.errorFree(e);
}

pub export fn smithers_bytes_free(b: structs.Bytes) void {
    ffi.bytesFree(b);
}
