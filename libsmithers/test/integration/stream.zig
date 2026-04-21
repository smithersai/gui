const std = @import("std");
const lib = @import("libsmithers");
const h = @import("helpers.zig");

const EventStream = eventStreamType();

fn eventStreamType() type {
    const stream_fn = @typeInfo(@TypeOf(lib.client.stream)).@"fn";
    const optional_ptr = @typeInfo(stream_fn.return_type.?).optional.child;
    return @typeInfo(optional_ptr).pointer.child;
}

test "client stream drains json events then end and frees after end" {
    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);
    const client = h.embedded.smithers_client_new(app).?;
    defer h.embedded.smithers_client_free(client);

    var err: h.structs.Error = undefined;
    const stream = h.embedded.smithers_client_stream(
        client,
        "streamChat",
        "{\"events\":[{\"token\":\"a\"},{\"token\":\"b\"},{\"done\":true}]}",
        &err,
    ).?;
    defer h.embedded.smithers_error_free(err);
    try h.expectSuccess(err);

    var seen: usize = 0;
    while (seen < 3) : (seen += 1) {
        const ev = h.embedded.smithers_event_stream_next(stream);
        defer h.embedded.smithers_event_free(ev);
        try std.testing.expectEqual(h.structs.EventTag.json, ev.tag);
        try h.expectJsonValid(h.stringSlice(ev.payload));
    }

    const end = h.embedded.smithers_event_stream_next(stream);
    defer h.embedded.smithers_event_free(end);
    try std.testing.expectEqual(h.structs.EventTag.end, end.tag);
    try std.testing.expectEqualStrings("", h.stringSlice(end.payload));

    h.embedded.smithers_event_stream_free(stream);
}

test "event stream reports mid-stream error then end" {
    var stream = try EventStream.create(std.testing.allocator);
    try stream.pushJson("{\"token\":\"before-error\"}");
    try stream.pushError("{\"message\":\"daemon disconnected\",\"retryable\":false}");
    stream.close();
    defer stream.destroy();

    const first = stream.next();
    defer h.ffi.stringFree(first.payload);
    try std.testing.expectEqual(h.structs.EventTag.json, first.tag);
    try h.expectJsonValid(h.stringSlice(first.payload));

    const second = stream.next();
    defer h.ffi.stringFree(second.payload);
    try std.testing.expectEqual(h.structs.EventTag.err, second.tag);
    var parsed_error = try h.expectJsonObject(h.stringSlice(second.payload));
    defer parsed_error.deinit();
    try std.testing.expectEqualStrings("daemon disconnected", parsed_error.value.object.get("message").?.string);

    const end = stream.next();
    defer h.ffi.stringFree(end.payload);
    try std.testing.expectEqual(h.structs.EventTag.end, end.tag);
}
