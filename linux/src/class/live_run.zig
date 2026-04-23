const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const logx = @import("../log.zig");
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
                        const payload = eventPayload(self.allocator, ev) catch |err| {
                            logx.catchWarn(log, "live run event payload (json)", err);
                            continue;
                        };
                        log.debug("event received kind=json bytes={d}", .{payload.len});
                        self.post(.json, payload) catch |err| logx.catchWarn(log, "live run post json", err);
                    },
                    smithers.c.SMITHERS_EVENT_ERROR => {
                        drained = true;
                        const payload = eventPayload(self.allocator, ev) catch |err| {
                            logx.catchWarn(log, "live run event payload (err)", err);
                            continue;
                        };
                        log.debug("event received kind=err bytes={d}", .{payload.len});
                        self.post(.err, payload) catch |err| logx.catchWarn(log, "live run post err", err);
                    },
                    smithers.c.SMITHERS_EVENT_END => {
                        smithers.c.smithers_event_free(ev);
                        log.info("event stream ended", .{});
                        const payload = self.allocator.dupe(u8, "") catch |err| {
                            logx.catchErr(log, "live run end payload dupe", err);
                            return;
                        };
                        self.post(.end, payload) catch |err| logx.catchWarn(log, "live run post end", err);
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
        pending.owner.handleSubscriptionEvent(pending.kind, pending.payload) catch |err|
            logx.catchWarn(log, "live run event handling", err);
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
        rewind_dialog: ?*adw.AlertDialog = null,
        rewind_reason: ?*gtk.Entry = null,
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
        logx.event(log, "stream_open", "run_id={s} owns_session={}", .{ run_id, owns_session });
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
        self.installShortcuts(root.as(gtk.Widget));

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
        _ = gtk.ListBox.signals.row_selected.connect(self.private().tree.list(), *Self, treeRowSelected, self, .{});
        _ = gtk.ListBox.signals.row_activated.connect(self.private().tree.list(), *Self, treeRowActivated, self, .{});
        panes.setStartChild(self.private().tree.as(gtk.Widget));

        self.private().inspector = try NodeInspector.new(alloc);
        panes.setEndChild(self.private().inspector.as(gtk.Widget));
        root.append(panes.as(gtk.Widget));

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn installShortcuts(self: *Self, widget: *gtk.Widget) void {
        const controller = gtk.ShortcutController.new();
        controller.setScope(.managed);
        self.addShortcut(controller, "<Control>j", shortcutJumpToNode);
        widget.addController(controller.as(gtk.EventController));
    }

    fn addShortcut(self: *Self, controller: *gtk.ShortcutController, trigger_text: [:0]const u8, callback: gtk.ShortcutFunc) void {
        const trigger = gtk.ShortcutTrigger.parseString(trigger_text.ptr) orelse return;
        const action = gtk.CallbackAction.new(callback, self, null);
        const shortcut = gtk.Shortcut.new(trigger, action.as(gtk.ShortcutAction));
        controller.addShortcut(shortcut);
    }

    fn restartSubscription(self: *Self) !void {
        const priv = self.private();
        const run_id: []const u8 = if (priv.state) |*state| state.run_id else "?";
        if (priv.subscription) |sub| {
            sub.stop();
            priv.subscription = null;
            logx.event(log, "stream_close", "run_id={s} reason=restart", .{run_id});
        }
        const stream = smithers.c.smithers_session_events(priv.session);
        if (stream == null) return error.EventStreamCreateFailed;
        errdefer smithers.c.smithers_event_stream_free(stream);
        priv.subscription = try SessionSubscription.create(priv.app.allocator(), stream, self);
        logx.event(log, "stream_open", "run_id={s} reason=restart", .{run_id});
    }

    fn handleSubscriptionEvent(self: *Self, kind: SessionSubscription.PendingKind, payload: []const u8) !void {
        const priv = self.private();
        const state = if (priv.state) |*state| state else return;
        const prev_status = state.status;
        const prev_frame = state.latest_frame_no;
        switch (kind) {
            .json => try state.applyPayload(payload),
            .err => try state.applyError(payload),
            .end => try state.applyError("Event stream ended."),
        }
        if (state.status != prev_status) {
            logx.event(log, "run_status", "run_id={s} from={s} to={s}", .{ state.run_id, prev_status.label(), state.status.label() });
        }
        if (state.latest_frame_no != prev_frame) {
            log.debug("frame advanced run_id={s} frame={d} seq={d}", .{ state.run_id, state.latest_frame_no, state.seq });
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
            priv.banner.setText("Historical - read only. The tree is showing a past frame while live events continue in the background.");
            priv.banner.as(gtk.Widget).setVisible(1);
            priv.tree.as(gtk.Widget).addCssClass("warning");
        } else {
            priv.banner.as(gtk.Widget).setVisible(0);
            priv.tree.as(gtk.Widget).removeCssClass("warning");
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
        if (priv.state) |*state| state.returnToLive() catch |err|
            logx.catchWarn(log, "returnToLive (refresh)", err);
        const run_id: []const u8 = if (priv.state) |*state| state.run_id else "?";
        logx.event(log, "refresh_clicked", "run_id={s}", .{run_id});
        self.sendCommand("{\"command\":\"refresh\"}");
        self.restartSubscription() catch |err|
            logx.catchWarn(log, "live run resubscribe", err);
        self.refreshAll();
    }

    fn cancelClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const run_id: []const u8 = if (priv.state) |*state| state.run_id else "?";
        logx.event(log, "cancel_clicked", "run_id={s}", .{run_id});
        self.sendCommand("{\"command\":\"cancel\"}");
    }

    fn returnLiveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.state) |*state| {
            logx.event(log, "return_to_live", "run_id={s}", .{state.run_id});
            state.returnToLive() catch |err| logx.catchWarn(log, "returnToLive", err);
        }
        self.refreshAll();
    }

    fn rewindClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const state = if (priv.state) |*state| state else return;
        const frame = state.historicalFrameNo() orelse return;
        priv.pending_rewind_frame = frame;
        const body = std.fmt.allocPrintSentinel(
            priv.app.allocator(),
            "Rewind this run to frame {d}? This cannot be undone. Provide a reason to continue.",
            .{frame},
            0,
        ) catch return;
        defer priv.app.allocator().free(body);

        const dialog = adw.AlertDialog.new("Confirm Rewind", body.ptr);
        const reason = gtk.Entry.new();
        reason.setPlaceholderText("Reason for rewind");
        reason.as(gtk.Widget).setHexpand(1);
        _ = gtk.Editable.signals.changed.connect(reason.as(gtk.Editable), *Self, rewindReasonChanged, self, .{});
        dialog.setExtraChild(reason.as(gtk.Widget));
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("rewind", "Rewind");
        dialog.setCloseResponse("cancel");
        dialog.setDefaultResponse("cancel");
        dialog.setResponseAppearance("rewind", .destructive);
        dialog.setResponseEnabled("rewind", 0);
        priv.rewind_dialog = dialog;
        priv.rewind_reason = reason;
        _ = adw.AlertDialog.signals.response.connect(dialog, *Self, rewindDialogResponse, self, .{});
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
    }

    fn rewindDialogResponse(_: *adw.AlertDialog, response: [*:0]u8, self: *Self) callconv(.c) void {
        const priv = self.private();
        defer {
            priv.rewind_dialog = null;
            priv.rewind_reason = null;
        }
        if (std.mem.orderZ(u8, response, "rewind") != .eq) return;
        const frame = priv.pending_rewind_frame orelse return;
        priv.pending_rewind_frame = null;
        const entry = priv.rewind_reason orelse return;
        const reason = std.mem.trim(u8, std.mem.span(entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        if (reason.len == 0) {
            priv.banner.setText("Rewind reason is required.");
            priv.banner.as(gtk.Widget).setVisible(1);
            log.warn("rewind rejected: empty reason (frame={d})", .{frame});
            return;
        }
        const run_id: []const u8 = if (priv.state) |*state| state.run_id else "?";
        logx.event(log, "rewind_requested", "run_id={s} frame={d} reason_len={d}", .{ run_id, frame, reason.len });
        self.sendRewindCommand(frame, reason);
        priv.banner.setText("Rewind requested.");
        priv.banner.as(gtk.Widget).setVisible(1);
        if (priv.state) |*state| state.returnToLive() catch |err|
            logx.catchWarn(log, "returnToLive (rewind)", err);
        self.refreshAll();
    }

    fn rewindReasonChanged(_: *gtk.Editable, self: *Self) callconv(.c) void {
        const priv = self.private();
        const dialog = priv.rewind_dialog orelse return;
        const entry = priv.rewind_reason orelse return;
        const reason = std.mem.trim(u8, std.mem.span(entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        dialog.setResponseEnabled("rewind", @intFromBool(reason.len > 0));
    }

    fn sendRewindCommand(self: *Self, frame: i64, reason: []const u8) void {
        const alloc = self.private().app.allocator();
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        out.writer.print("{{\"command\":\"rewind\",\"frameNo\":{d},\"confirm\":true,\"reason\":", .{frame}) catch return;
        appendJsonString(&out.writer, reason) catch return;
        out.writer.writeAll("}") catch return;
        self.sendCommand(out.written());
    }

    fn appendJsonString(writer: *std.Io.Writer, text: []const u8) !void {
        try writer.writeByte('"');
        for (text) |ch| {
            switch (ch) {
                '\\' => try writer.writeAll("\\\\"),
                '"' => try writer.writeAll("\\\""),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0...8, 11...12, 14...0x1f => try writer.print("\\u{x:0>4}", .{ch}),
                else => try writer.writeByte(ch),
            }
        }
        try writer.writeByte('"');
    }

    fn scrubberChanged(_: *gtk.Range, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.scrubber.isSuppressingChange()) return;
        const frame = priv.scrubber.currentFrame();
        if (priv.state) |*state| {
            state.scrubTo(frame) catch |err| {
                logx.catchWarn(log, "scrubTo", err);
                return;
            };
            logx.event(log, "frame_jump", "run_id={s} frame={d}", .{ state.run_id, frame });
            self.sendCommandFmt("{{\"command\":\"scrub\",\"frameNo\":{d}}}", .{frame});
        }
        self.refreshAll();
    }

    fn treeRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const id = LiveRunTree.nodeIdForRow(row) orelse return;
        const priv = self.private();
        if (priv.state) |*state| {
            logx.event(log, "node_activate", "run_id={s} node_id={d}", .{ state.run_id, id });
            state.select(id);
        }
        self.refreshAll();
    }

    fn treeRowSelected(_: *gtk.ListBox, row: ?*gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const priv = self.private();
        const state = if (priv.state) |*state| state else return;
        const selected = if (row) |r| LiveRunTree.nodeIdForRow(r) else null;
        if (state.selected_id == null and selected == null) return;
        if (state.selected_id != null and selected != null and state.selected_id.? == selected.?) return;
        if (selected) |id| {
            log.debug("node_select run_id={s} node_id={d}", .{ state.run_id, id });
        } else {
            log.debug("node_select run_id={s} cleared", .{state.run_id});
        }
        state.select(selected);
        self.refreshAll();
    }

    fn shortcutJumpToNode(_: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        self.private().tree.focusSelected();
        return 1;
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            const run_id: []const u8 = if (priv.state) |*state| state.run_id else "?";
            logx.event(log, "stream_close", "run_id={s} reason=dispose", .{run_id});
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
