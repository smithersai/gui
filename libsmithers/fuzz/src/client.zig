const std = @import("std");
const lib = @import("libsmithers");
const fuzz_corpus = @import("fuzz_corpus");

const embedded = lib.apprt.embedded;
const structs = lib.apprt.structs;
const ffi = lib.ffi;

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const max_method = 512;
const max_args = 64 * 1024;

test "fuzz client call" {
    _ = setenv("PATH", "/nonexistent", 1);
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus.corpus });
}

fn fuzzOne(_: void, input: []const u8) !void {
    const split = splitMethodArgs(input);
    const method = split.method[0..@min(split.method.len, max_method)];
    const args = split.args[0..@min(split.args.len, max_args)];

    const method_z = try std.testing.allocator.dupeZ(u8, method);
    defer std.testing.allocator.free(method_z);
    const args_z = try std.testing.allocator.dupeZ(u8, args);
    defer std.testing.allocator.free(args_z);

    const app = embedded.smithers_app_new(null) orelse return error.AppCreateFailed;
    defer embedded.smithers_app_free(app);
    const client = embedded.smithers_client_new(app) orelse return error.ClientCreateFailed;
    defer embedded.smithers_client_free(client);

    var err: structs.Error = undefined;
    const result = embedded.smithers_client_call(client, method_z.ptr, args_z.ptr, &err);
    defer ffi.stringFree(result);
    defer ffi.errorFree(err);

    _ = stringSlice(result);
}

fn splitMethodArgs(input: []const u8) struct { method: []const u8, args: []const u8 } {
    if (std.mem.indexOfScalar(u8, input, '\n')) |idx| {
        return .{ .method = input[0..idx], .args = input[idx + 1 ..] };
    }
    return .{ .method = input, .args = "" };
}

fn stringSlice(s: structs.String) []const u8 {
    return if (s.ptr) |ptr| ptr[0..s.len] else "";
}
