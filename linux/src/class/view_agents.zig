const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const models = @import("../models.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;

pub const AgentsView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersAgentsView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        body: *gtk.Box = undefined,
        agents: std.ArrayList(models.Agent) = .empty,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(window: *MainWindow) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .window = window };
        try self.build();
        return self;
    }

    pub fn refresh(self: *Self) void {
        self.refreshImpl() catch |err| {
            vh.setStatus(self.allocator(), self.private().body, "dialog-error-symbolic", "Agents unavailable", @errorName(err));
        };
    }

    fn allocator(self: *Self) std.mem.Allocator {
        return self.private().window.allocator();
    }

    fn build(self: *Self) !void {
        const root = self.as(gtk.Box);
        root.as(gtk.Orientable).setOrientation(.vertical);
        const header = vh.makeHeader("Agents", null);
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh agents");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));
        self.private().body = gtk.Box.new(.vertical, 12);
        ui.margin(self.private().body.as(gtk.Widget), 20);
        const scroll = ui.scrolled(self.private().body.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        root.append(scroll.as(gtk.Widget));
        vh.setStatus(self.allocator(), self.private().body, "system-users-symbolic", "No agents loaded", "Refresh to detect local agent binaries.");
    }

    fn refreshImpl(self: *Self) !void {
        const alloc = self.allocator();
        const json = try smithers.callJson(alloc, self.private().window.app().client(), "listAgents", "{}");
        defer alloc.free(json);
        const parsed = try models.parseAgents(alloc, json);
        models.clearList(models.Agent, alloc, &self.private().agents);
        self.private().agents = parsed;
        try self.render();
    }

    fn render(self: *Self) !void {
        const alloc = self.allocator();
        const body = self.private().body;
        ui.clearBox(body);
        if (self.private().agents.items.len == 0) {
            vh.setStatus(alloc, body, "system-users-symbolic", "No agents found", "Install Codex, Claude Code, or another supported agent.");
            return;
        }
        body.append(ui.heading("Available Agents").as(gtk.Widget));
        for (self.private().agents.items) |agent| {
            const card = gtk.Box.new(.vertical, 6);
            card.as(gtk.Widget).addCssClass("card");
            ui.margin(card.as(gtk.Widget), 12);
            const title = try std.fmt.allocPrintSentinel(alloc, "{s} - {s}", .{ agent.name, if (agent.usable) "Detected" else "Unavailable" }, 0);
            defer alloc.free(title);
            card.append(ui.heading(title).as(gtk.Widget));
            try vh.detailRow(alloc, card, "Status", agent.status);
            try vh.detailRow(alloc, card, "Version", agent.version);
            body.append(card.as(gtk.Widget));
        }
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            models.clearList(models.Agent, self.allocator(), &priv.agents);
            priv.agents.deinit(self.allocator());
            ui.clearBox(self.as(gtk.Box));
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
