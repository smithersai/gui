const std = @import("std");
const zbench = @import("zbench");

pub const capi = @import("capi.zig");

pub const default_config = zbench.Config{
    .max_iterations = 512,
    .time_budget_ns = 200_000_000,
    .track_allocations = true,
};

pub fn withLimits(max_iterations: u32, time_budget_ns: u64) zbench.Config {
    var config = default_config;
    config.max_iterations = max_iterations;
    config.time_budget_ns = time_budget_ns;
    return config;
}

pub const CaseMeta = struct {
    name: []const u8,
    group: []const u8,
    narrative: []const u8,
    units_per_run: f64 = 1.0,
    unit: []const u8 = "ops",
    cliff_ns: ?u64 = null,
};

pub const Cleanup = struct {
    ptr: *anyopaque,
    func: *const fn (*anyopaque) void,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    metas: std.ArrayList(CaseMeta) = .empty,
    cleanups: std.ArrayList(Cleanup) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        var i = self.cleanups.items.len;
        while (i > 0) {
            i -= 1;
            const cleanup = self.cleanups.items[i];
            cleanup.func(cleanup.ptr);
        }
        self.cleanups.deinit(self.allocator);
        self.metas.deinit(self.allocator);
    }

    pub fn addSimple(
        self: *Registry,
        bench: *zbench.Benchmark,
        meta: CaseMeta,
        func: zbench.BenchFunc,
        config: zbench.Config,
    ) !void {
        try bench.add(meta.name, func, .{
            .iterations = config.iterations,
            .max_iterations = config.max_iterations,
            .time_budget_ns = config.time_budget_ns,
            .hooks = config.hooks,
            .track_allocations = config.track_allocations,
            .use_shuffling_allocator = config.use_shuffling_allocator,
        });
        try self.metas.append(self.allocator, meta);
    }

    pub fn addCleanup(self: *Registry, ptr: *anyopaque, func: *const fn (*anyopaque) void) !void {
        try self.cleanups.append(self.allocator, .{ .ptr = ptr, .func = func });
    }

    pub fn metaFor(self: *const Registry, name: []const u8) ?CaseMeta {
        for (self.metas.items) |meta| {
            if (std.mem.eql(u8, meta.name, name)) return meta;
        }
        return null;
    }
};

pub fn freshArena(allocator: std.mem.Allocator) std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(allocator);
}

pub fn consumeBytes(bytes: []const u8) void {
    std.mem.doNotOptimizeAway(bytes.len);
    if (bytes.len > 0) std.mem.doNotOptimizeAway(bytes[0]);
}

pub fn dupeZ(allocator: std.mem.Allocator, bytes: []const u8) [:0]u8 {
    return allocator.dupeZ(u8, bytes) catch @panic("out of memory");
}
