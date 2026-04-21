const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;

const log = std.log.scoped(.smithers_gtk_session);

pub const SessionWidget = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersSession",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        app: *Application = undefined,
        session: smithers.c.smithers_session_t = null,
        stream: smithers.c.smithers_event_stream_t = null,
        kind: smithers.c.smithers_session_kind_e = smithers.c.SMITHERS_SESSION_KIND_DASHBOARD,
        body: *gtk.Box = undefined,
        input: ?*gtk.Entry = null,

        pub var offset: c_int = 0;
    };

    pub fn new(
        app: *Application,
        kind: smithers.c.smithers_session_kind_e,
        workspace_path: ?[]const u8,
        target_id: ?[]const u8,
    ) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();

        const alloc = app.allocator();
        const workspace_z = if (workspace_path) |path| try alloc.dupeZ(u8, path) else null;
        defer if (workspace_z) |path| alloc.free(path);
        const target_z = if (target_id) |target| try alloc.dupeZ(u8, target) else null;
        defer if (target_z) |target| alloc.free(target);

        var opts = std.mem.zeroes(smithers.c.smithers_session_options_s);
        opts.kind = kind;
        opts.workspace_path = if (workspace_z) |path| path.ptr else null;
        opts.target_id = if (target_z) |target| target.ptr else null;
        opts.userdata = self;

        const priv = self.private();
        priv.* = .{
            .app = app,
            .kind = kind,
            .session = smithers.c.smithers_session_new(app.core(), opts),
        };
        if (priv.session == null) return error.SessionCreateFailed;
        priv.stream = smithers.c.smithers_session_events(priv.session);

        try self.build();
        return self;
    }

    pub fn title(self: *Self, alloc: std.mem.Allocator) ![]u8 {
        const priv = self.private();
        if (priv.session) |session| {
            const value = smithers.sessionTitle(alloc, session) catch null;
            if (value) |title_text| {
                if (title_text.len > 0) return title_text;
                alloc.free(title_text);
            }
        }
        return alloc.dupe(u8, self.kindLabel());
    }

    pub fn titleZ(self: *Self, alloc: std.mem.Allocator) ![:0]u8 {
        const owned = try self.title(alloc);
        defer alloc.free(owned);
        return try alloc.dupeZ(u8, owned);
    }

    pub fn kindLabel(self: *Self) [:0]const u8 {
        return switch (self.private().kind) {
            smithers.c.SMITHERS_SESSION_KIND_TERMINAL => "Terminal",
            smithers.c.SMITHERS_SESSION_KIND_CHAT => "Chat",
            smithers.c.SMITHERS_SESSION_KIND_RUN_INSPECT => "Run Inspector",
            smithers.c.SMITHERS_SESSION_KIND_WORKFLOW => "Workflow",
            smithers.c.SMITHERS_SESSION_KIND_MEMORY => "Memory",
            smithers.c.SMITHERS_SESSION_KIND_DASHBOARD => "Dashboard",
            else => "Session",
        };
    }

    pub fn iconName(self: *Self) [:0]const u8 {
        return switch (self.private().kind) {
            smithers.c.SMITHERS_SESSION_KIND_TERMINAL => "utilities-terminal-symbolic",
            smithers.c.SMITHERS_SESSION_KIND_CHAT => "mail-message-new-symbolic",
            smithers.c.SMITHERS_SESSION_KIND_RUN_INSPECT => "view-list-symbolic",
            smithers.c.SMITHERS_SESSION_KIND_WORKFLOW => "media-playlist-shuffle-symbolic",
            smithers.c.SMITHERS_SESSION_KIND_MEMORY => "document-open-recent-symbolic",
            smithers.c.SMITHERS_SESSION_KIND_DASHBOARD => "view-grid-symbolic",
            else => "tab-new-symbolic",
        };
    }

    pub fn drainEvents(self: *Self) !void {
        const priv = self.private();
        const stream = priv.stream orelse return;
        while (true) {
            const ev = smithers.c.smithers_event_stream_next(stream);
            switch (ev.tag) {
                smithers.c.SMITHERS_EVENT_NONE => {
                    smithers.c.smithers_event_free(ev);
                    return;
                },
                smithers.c.SMITHERS_EVENT_END => {
                    smithers.c.smithers_event_free(ev);
                    smithers.c.smithers_event_stream_free(stream);
                    priv.stream = null;
                    return;
                },
                smithers.c.SMITHERS_EVENT_ERROR => {
                    const payload = try eventPayload(self.allocator(), ev);
                    defer self.allocator().free(payload);
                    try self.appendMarkdown(payload);
                },
                smithers.c.SMITHERS_EVENT_JSON => {
                    const payload = try eventPayload(self.allocator(), ev);
                    defer self.allocator().free(payload);
                    try self.appendEvent(payload);
                },
                else => {
                    smithers.c.smithers_event_free(ev);
                    return;
                },
            }
        }
    }

    fn allocator(self: *Self) std.mem.Allocator {
        return self.private().app.allocator();
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 0);
        const scroller_box = gtk.Box.new(.vertical, 12);
        ui.margin(scroller_box.as(gtk.Widget), 24);
        self.private().body = scroller_box;
        const scroll = ui.scrolled(scroller_box.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        root.append(scroll.as(gtk.Widget));

        try self.appendMarkdown(switch (self.private().kind) {
            smithers.c.SMITHERS_SESSION_KIND_TERMINAL =>
            \\# Terminal
            \\PTY rendering is reserved for the next Linux milestone. Commands and terminal text still flow through the libsmithers session ABI.
            ,
            smithers.c.SMITHERS_SESSION_KIND_CHAT =>
            \\# Chat
            \\Markdown chat blocks render here. Send a message to append a local block and forward it through smithers_session_send_text.
            ,
            smithers.c.SMITHERS_SESSION_KIND_RUN_INSPECT =>
            \\# Run Inspector
            \\Open a run from the Runs view for the read-only inspector, or bind this tab to a target run when libsmithers exposes one.
            ,
            smithers.c.SMITHERS_SESSION_KIND_WORKFLOW =>
            \\# Workflow
            \\Use the Workflows view to launch definitions. Workflow sessions are ready for richer graph/source tooling.
            ,
            smithers.c.SMITHERS_SESSION_KIND_MEMORY =>
            \\# Memory
            \\Memory browsing is stubbed in the GTK MVP.
            ,
            else =>
            \\# Dashboard
            \\The Dashboard view is available from the sidebar.
            ,
        });

        if (self.private().kind == smithers.c.SMITHERS_SESSION_KIND_CHAT or
            self.private().kind == smithers.c.SMITHERS_SESSION_KIND_TERMINAL)
        {
            const input_row = gtk.Box.new(.horizontal, 8);
            ui.margin(input_row.as(gtk.Widget), 12);
            const entry = gtk.Entry.new();
            entry.setPlaceholderText(if (self.private().kind == smithers.c.SMITHERS_SESSION_KIND_CHAT) "Message" else "Send text");
            entry.as(gtk.Widget).setHexpand(1);
            self.private().input = entry;
            input_row.append(entry.as(gtk.Widget));
            const send = ui.iconButton("mail-send-symbolic", "Send");
            _ = gtk.Button.signals.clicked.connect(send, *Self, sendClicked, self, .{});
            input_row.append(send.as(gtk.Widget));
            root.append(input_row.as(gtk.Widget));
        }

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn appendEvent(self: *Self, payload: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator(), payload, .{}) catch {
            return self.appendMarkdown(payload);
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |*obj| obj,
            else => return self.appendMarkdown(payload),
        };
        const text = stringFromObject(obj, &.{ "markdown", "content", "text", "message" }) orelse payload;
        try self.appendMarkdown(text);
    }

    fn appendMarkdown(self: *Self, markdown: []const u8) !void {
        const label = try ui.markdownLabel(self.allocator(), markdown);
        self.private().body.append(label.as(gtk.Widget));
    }

    fn eventPayload(alloc: std.mem.Allocator, ev: smithers.c.smithers_event_s) ![]u8 {
        defer smithers.c.smithers_event_free(ev);
        if (ev.payload.len == 0) return alloc.dupe(u8, "");
        return try alloc.dupe(u8, @as([*]const u8, @ptrCast(ev.payload.ptr))[0..ev.payload.len]);
    }

    fn stringFromObject(obj: *const std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
        for (keys) |key| {
            const value = obj.get(key) orelse continue;
            switch (value) {
                .string => |text| return text,
                else => {},
            }
        }
        return null;
    }

    fn sendClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const entry = self.private().input orelse return;
        const text = std.mem.span(entry.as(gtk.Editable).getText());
        if (text.len == 0) return;
        if (self.private().session) |session| {
            smithers.c.smithers_session_send_text(session, text.ptr, text.len);
        }
        self.appendMarkdown(text) catch |err| log.warn("failed to append sent text: {}", .{err});
        entry.as(gtk.Editable).setText("");
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.stream) |stream| {
            smithers.c.smithers_event_stream_free(stream);
            priv.stream = null;
        }
        if (priv.session) |session| {
            smithers.c.smithers_session_free(session);
            priv.session = null;
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
