const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const LiveRunHeader = @import("live_run_header.zig").LiveRunHeader;
const LiveRunTree = @import("live_run_tree.zig").LiveRunTree;
const FrameScrubber = @import("live_run_frame_scrubber.zig").FrameScrubber;
const NodeInspector = @import("node_inspector.zig").NodeInspector;
const tree_state = @import("../features/tree_state.zig");

const log = std.log.scoped(.smithers_gtk_live_run);

pub const SessionSubscription = struct {
    allocator: std.mem.Allocator,
    stream: smithers.c.smithers_event_stream_t,
    owner: *LiveRunView,
    stop_requested: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub const PendingKind = enum { json, err, end };

    const PendingEvent = struct {
        allocator: std.mem.Allocator,
        owner: *LiveRunView,
        kind: PendingKind,
        payload: []u8,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        stream: smithers.c.smithers_event_stream_t,
        owner: *LiveRunView,
    ) !*SessionSubscription {
        const self = try allocator.create(SessionSubscription);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .stream = stream,
            .owner = owner.ref(),
        };
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
        return self;
    }

    pub fn stop(self: *SessionSubscription) void {
        self.stop_requested.store(true, .seq_cst);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.stream) |stream| {
            smithers.c.smithers_event_stream_free(stream);
            self.stream = null;
        }
        self.owner.unref();
        self.allocator.destroy(self);
    }

    fn worker(self: *SessionSubscription) void {
        while (!self.stop_requested.load(.seq_cst)) {
            var drained = false;
            while (!self.stop_requested.load(.seq_cst)) {
                const ev = smithers.c.smithers_event_stream_next(self.stream);
                switch (ev.tag) {
                    smithers.c.SMITHERS_EVENT_NONE => {
                        smithers.c.smithers_event_free(ev);
                        break;
                    },
                    smithers.c.SMITHERS_EVENT_JSON => {
                        drained = true;
                        self.post(.json, eventPayload(self.allocator, ev) catch continue) catch {};
                    },
                    smithers.c.SMITHERS_EVENT_ERROR => {
                        drained = true;
                        self.post(.err, eventPayload(self.allocator, ev) catch continue) catch {};
                    },
                    smithers.c.SMITHERS_EVENT_END => {
                        smithers.c.smithers_event_free(ev);
                        self.post(.end, self.allocator.dupe(u8, "") catch return) catch {};
                        return;
                    },
                    else => {
                        smithers.c.smithers_event_free(ev);
                        break;
                    },
                }
            }
            if (!drained) std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }

    fn post(self: *SessionSubscription, kind: PendingKind, payload: []u8) !void {
        errdefer self.allocator.free(payload);
        const pending = try self.allocator.create(PendingEvent);
        pending.* = .{
            .allocator = self.allocator,
            .owner = self.owner.ref(),
            .kind = kind,
            .payload = payload,
        };
        _ = glib.idleAddFull(glib.PRIORITY_DEFAULT, deliverPending, pending, destroyPending);
    }

    fn deliverPending(userdata: ?*anyopaque) callconv(.c) c_int {
        const pending: *PendingEvent = @ptrCast(@alignCast(userdata orelse return 0));
        pending.owner.handleSubscriptionEvent(pending.kind, pending.payload) catch |err| {
            log.warn("live run event handling failed: {}", .{err});
        };
        return 0;
    }

    fn destroyPending(userdata: ?*anyopaque) callconv(.c) void {
        const pending: *PendingEvent = @ptrCast(@alignCast(userdata orelse return));
        pending.allocator.free(pending.payload);
        pending.owner.unref();
        pending.allocator.destroy(pending);
    }

    fn eventPayload(alloc: std.mem.Allocator, ev: smithers.c.smithers_event_s) ![]u8 {
        defer smithers.c.smithers_event_free(ev);
        if (ev.payload.ptr == null or ev.payload.len == 0) return alloc.dupe(u8, "");
        return try alloc.dupe(u8, @as([*]const u8, @ptrCast(ev.payload.ptr))[0..ev.payload.len]);
    }
};

pub const LiveRunView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersLiveRunView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        app: *Application = undefined,
        session: smithers.c.smithers_session_t = null,
        owns_session: bool = false,
        subscription: ?*SessionSubscription = null,
        state: ?tree_state.LiveState = null,
        header: *LiveRunHeader = undefined,
        scrubber: *FrameScrubber = undefined,
        tree: *LiveRunTree = undefined,
        inspector: *NodeInspector = undefined,
        banner: *gtk.Label = undefined,
        pending_rewind_frame: ?i64 = null,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(
        app: *Application,
        workspace_path: ?[]const u8,
        run_id: []const u8,
    ) !*Self {
        const alloc = app.allocator();
        const workspace_z = if (workspace_path) |path| try alloc.dupeZ(u8, path) else null;
        defer if (workspace_z) |path| alloc.free(path);
        const run_z = try alloc.dupeZ(u8, run_id);
        defer alloc.free(run_z);

        var opts = std.mem.zeroes(smithers.c.smithers_session_options_s);
        opts.kind = smithers.c.SMITHERS_SESSION_KIND_RUN_INSPECT;
        opts.workspace_path = if (workspace_z) |path| path.ptr else null;
        opts.target_id = run_z.ptr;

        const session = smithers.c.smithers_session_new(app.core(), opts);
        if (session == null) return error.SessionCreateFailed;
        errdefer smithers.c.smithers_session_free(session);

        const stream = smithers.c.smithers_session_events(session);
        if (stream == null) return error.EventStreamCreateFailed;
        errdefer smithers.c.smithers_event_stream_free(stream);

        return try Self.newForSession(app, session, true, stream, run_id);
    }

    pub fn newForSession(
        app: *Application,
        session: smithers.c.smithers_session_t,
        owns_session: bool,
        stream: smithers.c.smithers_event_stream_t,
        run_id: []const u8,
    ) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();

        const alloc = app.allocator();
        const priv = self.private();
        priv.* = .{
            .app = app,
            .session = session,
            .owns_session = owns_session,
            .state = try tree_state.LiveState.init(alloc, run_id),
        };
        errdefer if (priv.state) |*state| state.deinit();

        try self.build();
        priv.subscription = try SessionSubscription.create(alloc, stream, self);
        self.refreshAll();
        return self;
    }

    pub fn handle(self: *Self) smithers.c.smithers_session_t {
        return self.private().session;
    }

    pub fn title(self: *Self, alloc: std.mem.Allocator) ![]u8 {
        const priv = self.private();
        if (priv.state) |*state| {
            return try std.fmt.allocPrint(alloc, "Run {s}", .{state.run_id});
        }
        return alloc.dupe(u8, "Live Run");
    }

    fn build(self: *Self) !void {
        const alloc = self.private().app.allocator();
        const root = gtk.Box.new(.vertical, 0);

        self.private().header = try LiveRunHeader.new(alloc);
        _ = gtk.Button.signals.clicked.connect(self.private().header.refreshButton(), *Self, refreshClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.private().header.cancelButton(), *Self, cancelClicked, self, .{});
        root.append(self.private().header.as(gtk.Widget));

        self.private().scrubber = try FrameScrubber.new(alloc);
        _ = gtk.Range.signals.value_changed.connect(self.private().scrubber.scale().as(gtk.Range), *Self, scrubberChanged, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.private().scrubber.rewindButton(), *Self, rewindClicked, self, .{});
        _ = gtk.Button.signals.clicked.connect(self.private().scrubber.liveButton(), *Self, returnLiveClicked, self, .{});
        root.append(self.private().scrubber.as(gtk.Widget));

        self.private().banner = ui.dim("");
        self.private().banner.as(gtk.Widget).setVisible(0);
        ui.margin4(self.private().banner.as(gtk.Widget), 6, 12, 6, 12);
        root.append(self.private().banner.as(gtk.Widget));

        const panes = gtk.Paned.new(.horizontal);
        panes.as(gtk.Widget).setVexpand(1);
        self.private().tree = try LiveRunTree.new(alloc);
        _ = gtk.ListBox.signals.row_activated.connect(self.private().tree.list(), *Self, treeRowActivated, self, .{});
        panes.setStartChild(self.private().tree.as(gtk.Widget));

        self.private().inspector = try NodeInspector.new(alloc);
        panes.setEndChild(self.private().inspector.as(gtk.Widget));
        root.append(panes.as(gtk.Widget));

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn restartSubscription(self: *Self) !void {
        const priv = self.private();
        if (priv.subscription) |sub| {
            sub.stop();
            priv.subscription = null;
        }
        const stream = smithers.c.smithers_session_events(priv.session);
        if (stream == null) return error.EventStreamCreateFailed;
        errdefer smithers.c.smithers_event_stream_free(stream);
        priv.subscription = try SessionSubscription.create(priv.app.allocator(), stream, self);
    }

    fn handleSubscriptionEvent(self: *Self, kind: SessionSubscription.PendingKind, payload: []const u8) !void {
        const priv = self.private();
        const state = if (priv.state) |*state| state else return;
        switch (kind) {
            .json => try state.applyPayload(payload),
            .err => try state.applyError(payload),
            .end => try state.applyError("Event stream ended."),
        }
        state.selectFirstIfNeeded();
        self.refreshAll();
    }

    fn refreshAll(self: *Self) void {
        const priv = self.private();
        const state = if (priv.state) |*state| state else return;
        priv.header.update(state);
        priv.scrubber.update(state);
        priv.tree.update(state);
        priv.inspector.update(state);

        if (state.stream_error) |err| {
            const z = priv.app.allocator().dupeZ(u8, err) catch return;
            defer priv.app.allocator().free(z);
            priv.banner.setText(z.ptr);
            priv.banner.as(gtk.Widget).setVisible(1);
        } else if (state.isHistorical()) {
            priv.banner.setText("Historical frame active. Live events continue in the background.");
            priv.banner.as(gtk.Widget).setVisible(1);
        } else {
            priv.banner.as(gtk.Widget).setVisible(0);
        }
    }

    fn sendCommand(self: *Self, text: []const u8) void {
        const session = self.private().session orelse return;
        smithers.c.smithers_session_send_text(session, text.ptr, text.len);
    }

    fn sendCommandFmt(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const alloc = self.private().app.allocator();
        const text = std.fmt.allocPrint(alloc, fmt, args) catch return;
        defer alloc.free(text);
        self.sendCommand(text);
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.state) |*state| state.returnToLive() catch {};
        self.sendCommand("{\"command\":\"refresh\"}");
        self.restartSubscription() catch |err| log.warn("live run resubscribe failed: {}", .{err});
        self.refreshAll();
    }

    fn cancelClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.sendCommand("{\"command\":\"cancel\"}");
    }

    fn returnLiveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.state) |*state| state.returnToLive() catch {};
        self.refreshAll();
    }

    fn rewindClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const state = if (priv.state) |*state| state else return;
        const frame = state.historicalFrameNo() orelse return;
        priv.pending_rewind_frame = frame;
        const body = std.fmt.allocPrintZ(priv.app.allocator(), "Rewind this run to frame {d}? This cannot be undone.", .{frame}) catch return;
        defer priv.app.allocator().free(body);

        const dialog = adw.AlertDialog.new("Confirm Rewind", body.ptr);
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("rewind", "Rewind");
        dialog.setCloseResponse("cancel");
        dialog.setDefaultResponse("cancel");
        dialog.setResponseAppearance("rewind", .destructive);
        _ = adw.AlertDialog.signals.response.connect(dialog, *Self, rewindDialogResponse, self, .{});
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
    }

    fn rewindDialogResponse(_: *adw.AlertDialog, response: [*:0]u8, self: *Self) callconv(.c) void {
        if (std.mem.orderZ(u8, response, "rewind") != .eq) return;
        const priv = self.private();
        const frame = priv.pending_rewind_frame orelse return;
        priv.pending_rewind_frame = null;
        self.sendCommandFmt("{{\"command\":\"rewind\",\"frameNo\":{d},\"confirm\":true}}", .{frame});
        if (priv.state) |*state| state.returnToLive() catch {};
        self.refreshAll();
    }

    fn scrubberChanged(_: *gtk.Range, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.scrubber.isSuppressingChange()) return;
        const frame = priv.scrubber.currentFrame();
        if (priv.state) |*state| {
            state.scrubTo(frame) catch return;
            self.sendCommandFmt("{{\"command\":\"scrub\",\"frameNo\":{d}}}", .{frame});
        }
        self.refreshAll();
    }

    fn treeRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const id = LiveRunTree.nodeIdForRow(row) orelse return;
        const priv = self.private();
        if (priv.state) |*state| state.select(id);
        self.refreshAll();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            if (priv.subscription) |sub| {
                sub.stop();
                priv.subscription = null;
            }
            if (priv.state) |*state| {
                state.deinit();
                priv.state = null;
            }
            if (priv.owns_session and priv.session != null) {
                smithers.c.smithers_session_free(priv.session);
                priv.session = null;
            }
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
