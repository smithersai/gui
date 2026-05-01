const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const browser_surface = @import("browser_surface.zig");
const chat = @import("chat.zig");
const markdown = @import("markdown.zig");
const smithers = @import("../smithers.zig");
const terminal = @import("terminal.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

pub const SurfaceKind = enum {
    terminal,
    chat,
    run,
    workflow,
    dashboard,
    browser,
    markdown,

    pub fn iconName(self: SurfaceKind) [:0]const u8 {
        return switch (self) {
            .terminal => "utilities-terminal-symbolic",
            .chat => "mail-message-new-symbolic",
            .run => "view-list-symbolic",
            .workflow => "media-playlist-shuffle-symbolic",
            .dashboard => "view-grid-symbolic",
            .browser => "web-browser-symbolic",
            .markdown => "text-x-generic-symbolic",
        };
    }

    pub fn defaultTitle(self: SurfaceKind) []const u8 {
        return switch (self) {
            .terminal => "Terminal",
            .chat => "Chat",
            .run => "Run",
            .workflow => "Workflow",
            .dashboard => "Dashboard",
            .browser => "Browser",
            .markdown => "Markdown",
        };
    }

    pub fn fromSessionKind(kind: smithers.c.smithers_session_kind_e) SurfaceKind {
        return switch (kind) {
            smithers.c.SMITHERS_SESSION_KIND_TERMINAL => .terminal,
            smithers.c.SMITHERS_SESSION_KIND_CHAT => .chat,
            smithers.c.SMITHERS_SESSION_KIND_RUN_INSPECT => .run,
            smithers.c.SMITHERS_SESSION_KIND_WORKFLOW => .workflow,
            smithers.c.SMITHERS_SESSION_KIND_DASHBOARD => .dashboard,
            else => .dashboard,
        };
    }
};

pub const SplitAxis = enum {
    horizontal,
    vertical,
};

pub const Surface = struct {
    id: []u8,
    kind: SurfaceKind,
    title: []u8,
    subtitle: []u8,

    pub fn init(
        alloc: std.mem.Allocator,
        id: []const u8,
        kind: SurfaceKind,
        title: ?[]const u8,
        subtitle: ?[]const u8,
    ) !Surface {
        return .{
            .id = try alloc.dupe(u8, id),
            .kind = kind,
            .title = try alloc.dupe(u8, title orelse kind.defaultTitle()),
            .subtitle = try alloc.dupe(u8, subtitle orelse ""),
        };
    }

    pub fn deinit(self: *Surface, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.title);
        alloc.free(self.subtitle);
    }
};

pub const WorkspaceContent = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersWorkspaceContent",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        stack: *gtk.Stack = undefined,
        header: *gtk.Box = undefined,
        surfaces: std.ArrayList(Surface) = .empty,
        focused_index: usize = 0,
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

    pub fn addSurface(self: *Self, surface: Surface, child: ?*gtk.Widget) !void {
        const priv = self.private();
        const index = priv.surfaces.items.len;
        try priv.surfaces.append(priv.alloc, surface);
        const name = try std.fmt.allocPrintSentinel(priv.alloc, "surface-{d}", .{index}, 0);
        defer priv.alloc.free(name);
        const title_z = try priv.alloc.dupeZ(u8, surface.title);
        defer priv.alloc.free(title_z);
        const widget = child orelse try placeholder(priv.alloc, surface);
        _ = priv.stack.addTitled(widget, name.ptr, title_z.ptr);
        try self.rebuildHeader();
        if (index == 0) self.focusSurface(0);
    }

    pub fn addSessionSurface(
        self: *Self,
        id: []const u8,
        kind: smithers.c.smithers_session_kind_e,
        session: smithers.c.smithers_session_t,
    ) !void {
        const surface_kind = SurfaceKind.fromSessionKind(kind);
        var surface = try Surface.init(self.private().alloc, id, surface_kind, null, null);
        errdefer surface.deinit(self.private().alloc);
        const child: ?*gtk.Widget = switch (surface_kind) {
            .terminal => (try terminal.TerminalSurface.new(self.private().alloc, session)).as(gtk.Widget),
            .chat => (try chat.ChatView.new(self.private().alloc)).as(gtk.Widget),
            else => null,
        };
        try self.addSurface(surface, child);
    }

    pub fn updateSurfaceKind(self: *Self, index: usize, kind: smithers.c.smithers_session_kind_e) void {
        const priv = self.private();
        if (index >= priv.surfaces.items.len) return;
        const surface_kind = SurfaceKind.fromSessionKind(kind);
        var surface = &priv.surfaces.items[index];
        surface.kind = surface_kind;
        priv.alloc.free(surface.title);
        surface.title = priv.alloc.dupe(u8, surface_kind.defaultTitle()) catch return;
        self.rebuildHeader() catch {};
    }

    pub fn focusSurface(self: *Self, index: usize) void {
        const priv = self.private();
        if (index >= priv.surfaces.items.len) return;
        priv.focused_index = index;
        const name = std.fmt.allocPrintSentinel(priv.alloc, "surface-{d}", .{index}, 0) catch return;
        defer priv.alloc.free(name);
        priv.stack.setVisibleChildName(name.ptr);
        self.rebuildHeader() catch {};
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 0);
        self.private().header = gtk.Box.new(.horizontal, 4);
        ui.margin4(self.private().header.as(gtk.Widget), 6, 8, 6, 8);
        root.append(self.private().header.as(gtk.Widget));
        self.private().stack = gtk.Stack.new();
        self.private().stack.setTransitionType(.crossfade);
        self.private().stack.as(gtk.Widget).setVexpand(1);
        root.append(self.private().stack.as(gtk.Widget));
        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn rebuildHeader(self: *Self) !void {
        const priv = self.private();
        ui.clearBox(priv.header);
        for (priv.surfaces.items, 0..) |surface, index| {
            const button = gtk.Button.new();
            button.as(gtk.Widget).addCssClass("flat");
            if (index == priv.focused_index) button.as(gtk.Widget).addCssClass("suggested-action");
            ui.setIndex(button.as(gobject.Object), index);
            _ = gtk.Button.signals.clicked.connect(button, *Self, tabClicked, self, .{});

            const row = gtk.Box.new(.horizontal, 6);
            row.append(gtk.Image.newFromIconName(surface.kind.iconName().ptr).as(gtk.Widget));
            const title_z = try priv.alloc.dupeZ(u8, surface.title);
            defer priv.alloc.free(title_z);
            row.append(ui.label(title_z, null).as(gtk.Widget));
            button.setChild(row.as(gtk.Widget));
            priv.header.append(button.as(gtk.Widget));
        }
    }

    fn tabClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        self.focusSurface(ui.getIndex(button.as(gobject.Object)) orelse return);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            for (priv.surfaces.items) |*surface| surface.deinit(priv.alloc);
            priv.surfaces.deinit(priv.alloc);
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

fn placeholder(alloc: std.mem.Allocator, surface: Surface) !*gtk.Widget {
    const box = gtk.Box.new(.vertical, 10);
    ui.margin(box.as(gtk.Widget), 24);
    box.as(gtk.Widget).setValign(.center);
    box.as(gtk.Widget).setHalign(.center);
    box.append(gtk.Image.newFromIconName(surface.kind.iconName().ptr).as(gtk.Widget));
    const title_z = try alloc.dupeZ(u8, surface.title);
    defer alloc.free(title_z);
    box.append(ui.heading(title_z).as(gtk.Widget));
    if (surface.subtitle.len > 0) {
        const sub_z = try alloc.dupeZ(u8, surface.subtitle);
        defer alloc.free(sub_z);
        box.append(ui.dim(sub_z).as(gtk.Widget));
    }
    _ = browser_surface.have_webkit;
    _ = chat.ChatView;
    _ = markdown.MarkdownSurface;
    _ = terminal.have_vte;
    return box.as(gtk.Widget);
}
