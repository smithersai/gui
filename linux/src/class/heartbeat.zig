const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const tree_state = @import("../features/tree_state.zig");

pub const HeartbeatView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersLiveHeartbeat",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        elapsed: *gtk.Label = undefined,
        engine: *gtk.Label = undefined,
        ui_dot: *gtk.Label = undefined,
        started_at_ms: ?i64 = null,
        last_event_ms: ?i64 = null,
        last_seq: i64 = 0,
        pulse_until_ms: i64 = 0,
        tick_source: c_uint = 0,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .alloc = alloc };
        try self.build();
        self.private().tick_source = glib.timeoutAdd(1000, tick, self);
        return self;
    }

    pub fn update(self: *Self, started_at_ms: ?i64, last_event_ms: ?i64, seq: i64) void {
        const priv = self.private();
        if (last_event_ms != null and priv.last_event_ms != null and last_event_ms.? != priv.last_event_ms.?) {
            priv.pulse_until_ms = tree_state.nowMs() + 350;
        } else if (last_event_ms != null and priv.last_event_ms == null) {
            priv.pulse_until_ms = tree_state.nowMs() + 350;
        }
        priv.started_at_ms = started_at_ms;
        priv.last_event_ms = last_event_ms;
        priv.last_seq = seq;
        self.refreshLabels();
    }

    fn refreshLabels(self: *Self) void {
        const priv = self.private();
        const now = tree_state.nowMs();
        if (priv.started_at_ms) |started| {
            const elapsed_seconds = @divFloor(@max(now - started, 0), 1000);
            const text = tree_state.formatElapsed(priv.alloc, elapsed_seconds) catch return;
            defer priv.alloc.free(text);
            const z = priv.alloc.dupeZ(u8, text) catch return;
            defer priv.alloc.free(z);
            priv.elapsed.setText(z.ptr);
        } else {
            priv.elapsed.setText("--:--");
        }

        const state = tree_state.heartbeatColor(now, priv.last_event_ms, 1000);
        const pulsing = now < priv.pulse_until_ms;
        const label = switch (state) {
            .running => if (pulsing) "engine live *" else "engine live",
            .blocked => "engine stale",
            else => "engine offline",
        };
        const tooltip = if (priv.last_event_ms) |last|
            std.fmt.allocPrintSentinel(priv.alloc, "Last event ms: {d}\nSeq: {d}", .{ last, priv.last_seq }, 0) catch return
        else
            std.fmt.allocPrintSentinel(priv.alloc, "Last event: none\nSeq: {d}", .{priv.last_seq}, 0) catch return;
        defer priv.alloc.free(tooltip);
        priv.engine.setText(label);
        priv.engine.as(gtk.Widget).setTooltipText(tooltip.ptr);
        priv.ui_dot.setText(if (@mod(@divFloor(now, 1000), 2) == 0) "ui *" else "ui");
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.horizontal, 8);
        self.private().elapsed = ui.label("--:--", "monospace");
        root.append(self.private().elapsed.as(gtk.Widget));
        self.private().engine = ui.dim("engine offline");
        root.append(self.private().engine.as(gtk.Widget));
        self.private().ui_dot = ui.dim("ui");
        root.append(self.private().ui_dot.as(gtk.Widget));
        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        if (!self.private().did_dispose) {
            self.private().did_dispose = true;
            if (self.private().tick_source != 0) {
                _ = glib.Source.remove(self.private().tick_source);
                self.private().tick_source = 0;
            }
            self.as(adw.Bin).setChild(null);
        }
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn tick(userdata: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return 0));
        if (self.private().did_dispose) return 0;
        self.refreshLabels();
        return 1;
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
    };
};
