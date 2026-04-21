const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const tree_state = @import("../features/tree_state.zig");

pub const FrameScrubber = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersLiveRunFrameScrubber",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        label: *gtk.Label = undefined,
        banner: *gtk.Label = undefined,
        scale: *gtk.Scale = undefined,
        rewind: *gtk.Button = undefined,
        live: *gtk.Button = undefined,
        suppress_change: bool = false,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .alloc = alloc };
        try self.build();
        return self;
    }

    pub fn scale(self: *Self) *gtk.Scale {
        return self.private().scale;
    }

    pub fn rewindButton(self: *Self) *gtk.Button {
        return self.private().rewind;
    }

    pub fn liveButton(self: *Self) *gtk.Button {
        return self.private().live;
    }

    pub fn currentFrame(self: *Self) i64 {
        return @intFromFloat(self.private().scale.as(gtk.Range).getValue());
    }

    pub fn update(self: *Self, state: *const tree_state.LiveState) void {
        const priv = self.private();
        const max_frame = @max(state.latest_frame_no, 1);
        priv.suppress_change = true;
        priv.scale.as(gtk.Range).setRange(0, @floatFromInt(max_frame));
        priv.scale.as(gtk.Range).setValue(@floatFromInt(state.displayed_frame_no));
        priv.suppress_change = false;

        const label = std.fmt.allocPrintZ(priv.alloc, "frame {d} / {d}", .{ state.displayed_frame_no, state.latest_frame_no }) catch return;
        defer priv.alloc.free(label);
        priv.label.setText(label.ptr);

        const historical = state.historicalFrameNo();
        priv.rewind.as(gtk.Widget).setVisible(@intFromBool(historical != null and !state.status.isTerminal()));
        priv.live.as(gtk.Widget).setVisible(@intFromBool(historical != null));
        if (historical) |frame| {
            const running = state.runningLeafCount();
            const banner = std.fmt.allocPrintZ(
                priv.alloc,
                "Viewing historical frame {d}. {d} task{s} running at this frame.",
                .{ frame, running, if (running == 1) "" else "s" },
            ) catch return;
            defer priv.alloc.free(banner);
            priv.banner.setText(banner.ptr);
            priv.banner.as(gtk.Widget).setVisible(1);
        } else {
            priv.banner.as(gtk.Widget).setVisible(0);
        }
    }

    pub fn isSuppressingChange(self: *Self) bool {
        return self.private().suppress_change;
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 6);
        ui.margin4(root.as(gtk.Widget), 8, 12, 8, 12);

        const top = gtk.Box.new(.horizontal, 8);
        self.private().label = ui.label("frame 0 / 0", "monospace");
        self.private().label.as(gtk.Widget).setHexpand(1);
        top.append(self.private().label.as(gtk.Widget));

        self.private().live = ui.textButton("Return to live", false);
        top.append(self.private().live.as(gtk.Widget));
        self.private().rewind = ui.textButton("Rewind", false);
        self.private().rewind.as(gtk.Widget).addCssClass("destructive-action");
        top.append(self.private().rewind.as(gtk.Widget));
        root.append(top.as(gtk.Widget));

        self.private().scale = gtk.Scale.newWithRange(.horizontal, 0, 1, 1);
        self.private().scale.setDrawValue(0);
        self.private().scale.as(gtk.Widget).setHexpand(1);
        root.append(self.private().scale.as(gtk.Widget));

        self.private().banner = ui.dim("");
        self.private().banner.as(gtk.Widget).setVisible(0);
        root.append(self.private().banner.as(gtk.Widget));

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        if (!self.private().did_dispose) {
            self.private().did_dispose = true;
            self.as(adw.Bin).setChild(null);
        }
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
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
