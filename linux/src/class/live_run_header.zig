const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const logx = @import("../log.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const tree_state = @import("../features/tree_state.zig");
const HeartbeatView = @import("heartbeat.zig").HeartbeatView;

const log = std.log.scoped(.smithers_gtk_live_run_header);

pub const LiveRunHeader = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersLiveRunHeader",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        status: *gtk.Label = undefined,
        workflow: *gtk.Label = undefined,
        run_id: *gtk.Label = undefined,
        heartbeat: *HeartbeatView = undefined,
        refresh: *gtk.Button = undefined,
        cancel: *gtk.Button = undefined,
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

    pub fn refreshButton(self: *Self) *gtk.Button {
        return self.private().refresh;
    }

    pub fn cancelButton(self: *Self) *gtk.Button {
        return self.private().cancel;
    }

    pub fn update(self: *Self, state: *const tree_state.LiveState) void {
        const priv = self.private();
        const status_z = priv.alloc.dupeZ(u8, state.status.label()) catch |err| {
            logx.catchWarn(log, "status dupeZ", err);
            return;
        };
        defer priv.alloc.free(status_z);
        priv.status.setText(status_z.ptr);
        priv.cancel.as(gtk.Widget).setSensitive(@intFromBool(!state.status.isTerminal()));

        const workflow_z = priv.alloc.dupeZ(u8, state.workflow_name) catch |err| {
            logx.catchWarn(log, "workflow dupeZ", err);
            return;
        };
        defer priv.alloc.free(workflow_z);
        priv.workflow.setText(workflow_z.ptr);

        const run_z = priv.alloc.dupeZ(u8, state.run_id) catch |err| {
            logx.catchWarn(log, "run_id dupeZ", err);
            return;
        };
        defer priv.alloc.free(run_z);
        priv.run_id.setText(run_z.ptr);
        priv.heartbeat.update(state.started_at_ms, state.last_event_ms, state.seq);
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.horizontal, 12);
        ui.margin4(root.as(gtk.Widget), 8, 12, 8, 12);

        self.private().status = ui.label("UNKNOWN", "heading");
        self.private().status.as(gtk.Widget).setSizeRequest(92, -1);
        root.append(self.private().status.as(gtk.Widget));

        const id_box = gtk.Box.new(.vertical, 2);
        id_box.as(gtk.Widget).setHexpand(1);
        self.private().workflow = ui.label("Live Run", "heading");
        self.private().workflow.setWrap(0);
        self.private().workflow.setEllipsize(.end);
        id_box.append(self.private().workflow.as(gtk.Widget));
        self.private().run_id = ui.dim("");
        self.private().run_id.setWrap(0);
        self.private().run_id.setEllipsize(.middle);
        id_box.append(self.private().run_id.as(gtk.Widget));
        root.append(id_box.as(gtk.Widget));

        self.private().heartbeat = try HeartbeatView.new(self.private().alloc);
        root.append(self.private().heartbeat.as(gtk.Widget));

        self.private().refresh = ui.iconButton("view-refresh-symbolic", "Refresh live run");
        root.append(self.private().refresh.as(gtk.Widget));

        self.private().cancel = ui.iconButton("process-stop-symbolic", "Cancel run");
        self.private().cancel.as(gtk.Widget).addCssClass("destructive-action");
        root.append(self.private().cancel.as(gtk.Widget));

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
