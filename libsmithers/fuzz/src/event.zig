const std = @import("std");
const lib = @import("libsmithers");
const fuzz_corpus = @import("fuzz_corpus");

const embedded = lib.apprt.embedded;
const structs = lib.apprt.structs;
const ffi = lib.ffi;

const max_input = 128 * 1024;
const max_events_to_drain = 512;

test "fuzz event stream serialization" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus.corpus });
}

fn fuzzOne(_: void, input: []const u8) !void {
    const bounded = input[0..@min(input.len, max_input)];
    var parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, bounded, .{}) catch return;
    defer parsed.deinit();

    var args = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer args.deinit();
    try args.writer.writeAll("{\"events\":");
    try args.writer.writeAll(bounded);
    try args.writer.writeByte('}');
    const args_z = try std.testing.allocator.dupeZ(u8, args.written());
    defer std.testing.allocator.free(args_z);

    const app = embedded.smithers_app_new(null) orelse return error.AppCreateFailed;
    defer embedded.smithers_app_free(app);
    const client = embedded.smithers_client_new(app) orelse return error.ClientCreateFailed;
    defer embedded.smithers_client_free(client);

    var err: structs.Error = undefined;
    const stream = embedded.smithers_client_stream(client, "streamChat", args_z.ptr, &err) orelse {
        defer ffi.errorFree(err);
        return;
    };
    defer embedded.smithers_event_stream_free(stream);
    defer ffi.errorFree(err);

    var drained: usize = 0;
    while (drained < max_events_to_drain) : (drained += 1) {
        const ev = embedded.smithers_event_stream_next(stream);
        defer ffi.stringFree(ev.payload);
        switch (ev.tag) {
            .json => {
                var payload = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stringSlice(ev.payload), .{});
                defer payload.deinit();
            },
            .end, .none => break,
            .err => {},
        }
    }
}

fn stringSlice(s: structs.String) []const u8 {
    return if (s.ptr) |ptr| ptr[0..s.len] else "";
}
