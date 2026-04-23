const std = @import("std");
const logx = @import("../log.zig");
const EventStream = @import("../session/event_stream.zig");
const snapshot = @import("Snapshot.zig");

const log = std.log.scoped(.smithers_core_snapshot_stream);

pub const Ctx = struct {
    allocator: std.mem.Allocator,
    stream: *EventStream,
    run_id: []u8,
    db_path: []u8,
    poll_ms: u64,
    from_seq: ?i64,
};

pub fn start(
    allocator: std.mem.Allocator,
    stream: *EventStream,
    run_id: []const u8,
    db_path: []const u8,
    from_seq: ?i64,
) !void {
    const ctx = try allocator.create(Ctx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .stream = stream.retain(),
        .run_id = try allocator.dupe(u8, run_id),
        .db_path = try allocator.dupe(u8, db_path),
        .poll_ms = resolvePollMs(),
        .from_seq = from_seq,
    };
    errdefer {
        allocator.free(ctx.run_id);
        allocator.free(ctx.db_path);
        ctx.stream.release();
    }

    const thread = try std.Thread.spawn(.{}, loop, .{ctx});
    stream.attachProducer(thread, @ptrCast(ctx), cleanup);
    logx.event(log, "snapshot_stream_open", "run_id={s} poll_ms={d} from_seq={?d}", .{ ctx.run_id, ctx.poll_ms, ctx.from_seq });
}

fn cleanup(raw: *anyopaque) void {
    const ctx: *Ctx = @ptrCast(@alignCast(raw));
    logx.event(log, "snapshot_stream_close", "run_id={s}", .{ctx.run_id});
    ctx.stream.release();
    ctx.allocator.free(ctx.run_id);
    ctx.allocator.free(ctx.db_path);
    ctx.allocator.destroy(ctx);
}

fn resolvePollMs() u64 {
    if (std.posix.getenv("SMITHERS_DEVTOOLS_POLL_MS")) |raw| {
        if (std.fmt.parseInt(u64, raw, 10) catch null) |v| {
            if (v >= 1) return v;
        }
    }
    return 250;
}

fn loop(ctx: *Ctx) void {
    var last_emitted: i64 = -1;
    // Push initial snapshot (best-effort — run may not exist yet).
    if (snapshot.buildSnapshotEventJson(ctx.allocator, ctx.db_path, ctx.run_id, null)) |json| {
        defer ctx.allocator.free(json);
        pushAndTrack(ctx, json, &last_emitted);
    } else |err| logx.catchDebug(log, "buildSnapshotEventJson(initial)", err);

    while (!ctx.stream.stopRequested()) {
        sleepSlices(ctx);
        if (ctx.stream.stopRequested()) break;

        const latest = snapshot.latestFrameNo(ctx.allocator, ctx.db_path, ctx.run_id) catch |err| {
            logx.catchDebug(log, "latestFrameNo", err);
            continue;
        };
        if (latest) |max| {
            if (max > last_emitted) {
                if (snapshot.buildSnapshotEventJson(ctx.allocator, ctx.db_path, ctx.run_id, null)) |json| {
                    defer ctx.allocator.free(json);
                    pushAndTrack(ctx, json, &last_emitted);
                } else |err| logx.catchWarn(log, "buildSnapshotEventJson", err);
            }
        }
    }
}

fn pushAndTrack(ctx: *Ctx, json: []const u8, last_emitted: *i64) void {
    // Extract frameNo from payload and update tracker.
    if (extractFrameNo(json)) |fn_val| {
        if (fn_val <= last_emitted.*) return;
        last_emitted.* = fn_val;
    }
    ctx.stream.pushJson(json) catch |err| {
        logx.catchErr(log, "stream.pushJson(snapshot)", err);
        log.warn("backpressure drop: snapshot run_id={s} frame={?d}", .{ ctx.run_id, extractFrameNo(json) });
        return;
    };
    log.debug("event sent type=snapshot run_id={s} frame={?d}", .{ ctx.run_id, extractFrameNo(json) });
}

fn extractFrameNo(json: []const u8) ?i64 {
    const key = "\"frameNo\":";
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    var i = idx + key.len;
    while (i < json.len and (json[i] == ' ')) : (i += 1) {}
    const num_start = i;
    if (num_start < json.len and (json[num_start] == '-' or json[num_start] == '+')) i += 1;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
    if (i == num_start) return null;
    return std.fmt.parseInt(i64, json[num_start..i], 10) catch null;
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
