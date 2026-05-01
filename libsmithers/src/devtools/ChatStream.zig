const std = @import("std");
const logx = @import("../log.zig");
const EventStream = @import("../session/event_stream.zig");
const chat_output = @import("ChatOutput.zig");

const log = std.log.scoped(.smithers_core_chat_stream);

pub const Ctx = struct {
    allocator: std.mem.Allocator,
    stream: *EventStream,
    run_id: []u8,
    db_path: []u8,
    poll_ms: u64,
};

pub fn start(
    allocator: std.mem.Allocator,
    stream: *EventStream,
    run_id: []const u8,
    db_path: []const u8,
) !void {
    const ctx = try allocator.create(Ctx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .stream = stream.retain(),
        .run_id = try allocator.dupe(u8, run_id),
        .db_path = try allocator.dupe(u8, db_path),
        .poll_ms = resolvePollMs(),
    };
    errdefer {
        allocator.free(ctx.run_id);
        allocator.free(ctx.db_path);
        ctx.stream.release();
    }

    const thread = try std.Thread.spawn(.{}, loop, .{ctx});
    stream.attachProducer(thread, @ptrCast(ctx), cleanup);
    logx.event(log, "chat_stream_open", "run_id={s} poll_ms={d}", .{ ctx.run_id, ctx.poll_ms });
}

fn cleanup(raw: *anyopaque) void {
    const ctx: *Ctx = @ptrCast(@alignCast(raw));
    logx.event(log, "chat_stream_close", "run_id={s}", .{ctx.run_id});
    ctx.stream.release();
    ctx.allocator.free(ctx.run_id);
    ctx.allocator.free(ctx.db_path);
    ctx.allocator.destroy(ctx);
}

fn resolvePollMs() u64 {
    if (std.posix.getenv("SMITHERS_CHAT_POLL_MS")) |raw| {
        if (std.fmt.parseInt(u64, raw, 10) catch null) |v| {
            if (v >= 1) return v;
        }
    }
    if (std.posix.getenv("SMITHERS_DEVTOOLS_POLL_MS")) |raw| {
        if (std.fmt.parseInt(u64, raw, 10) catch null) |v| {
            if (v >= 1) return v;
        }
    }
    return 500;
}

fn loop(ctx: *Ctx) void {
    var emitted = std.StringHashMap(void).init(ctx.allocator);
    defer {
        var it = emitted.keyIterator();
        while (it.next()) |k| ctx.allocator.free(k.*);
        emitted.deinit();
    }

    // Initial emission: push all current blocks.
    pushNewBlocks(ctx, &emitted) catch |err| logx.catchWarn(log, "pushNewBlocks(initial)", err);

    while (!ctx.stream.stopRequested()) {
        sleepSlices(ctx);
        if (ctx.stream.stopRequested()) break;
        pushNewBlocks(ctx, &emitted) catch |err| logx.catchWarn(log, "pushNewBlocks", err);
    }
}

fn pushNewBlocks(ctx: *Ctx, emitted: *std.StringHashMap(void)) !void {
    const blocks = chat_output.loadBlocks(ctx.allocator, ctx.db_path, ctx.run_id, -1) catch |err| {
        logx.catchWarn(log, "loadBlocks", err);
        return;
    };
    defer chat_output.freeBlocks(ctx.allocator, blocks);

    for (blocks) |b| {
        if (emitted.contains(b.stable_id)) continue;
        const json = try blockToJson(ctx.allocator, b);
        defer ctx.allocator.free(json);
        ctx.stream.pushJson(json) catch |err| {
            logx.catchErr(log, "stream.pushJson(chat_block)", err);
            log.warn("backpressure drop: chat block stable_id={s}", .{b.stable_id});
            continue;
        };
        log.debug("event sent type=chat_block stable_id={s} role={s}", .{ b.stable_id, b.role });
        const key_copy = try ctx.allocator.dupe(u8, b.stable_id);
        try emitted.put(key_copy, {});
    }
}

fn blockToJson(allocator: std.mem.Allocator, b: chat_output.Block) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try chat_output.writeBlockJson(&out.writer, b);
    return try allocator.dupe(u8, out.written());
}

fn sleepSlices(ctx: *Ctx) void {
    const total_ms = ctx.poll_ms;
    var slept: u64 = 0;
    const slice: u64 = if (total_ms < 50) total_ms else 50;
    while (slept < total_ms) : (slept += slice) {
        if (ctx.stream.stopRequested()) return;
        std.Thread.sleep(slice * std.time.ns_per_ms);
    }
}
