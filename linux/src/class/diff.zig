const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gobject = @import("gobject");
const gtk = @import("gtk");

const diff_hunk = @import("diff_hunk.zig");
const diff_parser = @import("../features/diff_parser.zig");
const logx = @import("../log.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.smithers_gtk_diff);

pub const UnifiedDiffView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersUnifiedDiffView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        body: *gtk.Box = undefined,
        side_button: *gtk.Button = undefined,
        context_label: *gtk.Label = undefined,
        hunk_label: *gtk.Label = undefined,
        diff_text: []u8 = &.{},
        parsed: ?diff_parser.Result = null,
        expanded: bool = true,
        side_by_side: bool = false,
        context_limit: ?usize = null,
        focused_hunk: usize = 0,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, diff_text: []const u8, path: []const u8) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{
            .alloc = alloc,
            .diff_text = try alloc.dupe(u8, diff_text),
        };
        try self.build();
        try self.parseAndRender(path);
        return self;
    }

    pub fn setDiff(self: *Self, diff_text: []const u8, path: []const u8) !void {
        const priv = self.private();
        const owned = try priv.alloc.dupe(u8, diff_text);
        priv.alloc.free(priv.diff_text);
        priv.diff_text = owned;
        try self.parseAndRender(path);
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 0);
        const toolbar = gtk.Box.new(.horizontal, 6);
        ui.margin4(toolbar.as(gtk.Widget), 7, 8, 7, 8);

        const prev = ui.iconButton("go-up-symbolic", "Previous hunk (Alt+P)");
        _ = gtk.Button.signals.clicked.connect(prev, *Self, prevHunkClicked, self, .{});
        toolbar.append(prev.as(gtk.Widget));
        const next = ui.iconButton("go-down-symbolic", "Next hunk (Alt+N)");
        _ = gtk.Button.signals.clicked.connect(next, *Self, nextHunkClicked, self, .{});
        toolbar.append(next.as(gtk.Widget));

        self.private().hunk_label = ui.dim("Hunk 0/0");
        self.private().hunk_label.as(gtk.Widget).setHexpand(1);
        toolbar.append(self.private().hunk_label.as(gtk.Widget));

        self.private().context_label = ui.dim("Context: all");
        toolbar.append(self.private().context_label.as(gtk.Widget));
        const ctx3 = ui.textButton("3", false);
        _ = gtk.Button.signals.clicked.connect(ctx3, *Self, context3Clicked, self, .{});
        toolbar.append(ctx3.as(gtk.Widget));
        const ctx10 = ui.textButton("10", false);
        _ = gtk.Button.signals.clicked.connect(ctx10, *Self, context10Clicked, self, .{});
        toolbar.append(ctx10.as(gtk.Widget));
        const ctx_all = ui.textButton("All", true);
        _ = gtk.Button.signals.clicked.connect(ctx_all, *Self, contextAllClicked, self, .{});
        toolbar.append(ctx_all.as(gtk.Widget));

        self.private().side_button = ui.textButton("Unified", false);
        _ = gtk.Button.signals.clicked.connect(self.private().side_button, *Self, sideBySideClicked, self, .{});
        toolbar.append(self.private().side_button.as(gtk.Widget));
        root.append(toolbar.as(gtk.Widget));

        const body = gtk.Box.new(.vertical, 12);
        ui.margin(body.as(gtk.Widget), 14);
        self.private().body = body;
        const scroll = ui.scrolled(body.as(gtk.Widget));
        scroll.setPolicy(.automatic, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        root.append(scroll.as(gtk.Widget));

        const controller = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(controller, *Self, keyPressed, self, .{});
        root.as(gtk.Widget).addController(controller.as(gtk.EventController));

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn parseAndRender(self: *Self, path: []const u8) !void {
        const priv = self.private();
        if (priv.parsed) |*parsed| parsed.deinit(priv.alloc);
        const t = logx.startTimer();
        priv.parsed = try diff_parser.parse(priv.alloc, priv.diff_text, .{ .path = path, .strict = false });
        logx.endTimerDebug(log, "diff parse", t);
        if (priv.parsed) |parsed| {
            log.debug("diff parsed path={s} hunks={d} additions={d} deletions={d} binary={} partial={}", .{
                parsed.file.path,
                parsed.file.hunks.items.len,
                parsed.file.additions(),
                parsed.file.deletions(),
                parsed.file.is_binary,
                parsed.file.partial_parse,
            });
        }
        priv.focused_hunk = 0;
        try self.render();
    }

    fn render(self: *Self) !void {
        const priv = self.private();
        ui.clearBox(priv.body);
        const parsed = priv.parsed orelse {
            priv.body.append(ui.dim("(no changes)").as(gtk.Widget));
            self.updateToolbar();
            return;
        };
        logx.event(log, "diff_shown", "path={s} hunks={d} side_by_side={} context_limit={?d}", .{
            parsed.file.path,
            parsed.file.hunks.items.len,
            priv.side_by_side,
            priv.context_limit,
        });

        if (parsed.file.hunks.items.len == 0 and !parsed.file.is_binary) {
            priv.body.append(ui.dim("(no changes)").as(gtk.Widget));
            self.updateToolbar();
            return;
        }

        priv.body.append((try fileHeader(priv.alloc, parsed.file)).as(gtk.Widget));
        if (parsed.file.partial_parse) {
            priv.body.append(ui.dim("Partial parse: some hunks could not be rendered.").as(gtk.Widget));
        }
        if (parsed.file.mode_changes.items.len > 0) {
            const mode_box = gtk.Box.new(.vertical, 2);
            for (parsed.file.mode_changes.items) |mode| {
                const z = try priv.alloc.dupeZ(u8, mode);
                defer priv.alloc.free(z);
                mode_box.append(ui.dim(z).as(gtk.Widget));
            }
            priv.body.append(mode_box.as(gtk.Widget));
        }

        if (parsed.file.is_binary) {
            priv.body.append((try binaryRow(priv.alloc, parsed.file.binary_size_bytes)).as(gtk.Widget));
            self.updateToolbar();
            return;
        }

        const syntax_class = syntaxClassForPath(parsed.file.path);
        for (parsed.file.hunks.items, 0..) |hunk, index| {
            priv.body.append((try diff_hunk.hunkWidgetWithOptions(priv.alloc, hunk, .{
                .side_by_side = priv.side_by_side,
                .context_limit = priv.context_limit,
                .focused = index == priv.focused_hunk,
                .syntax_class = syntax_class,
            })).as(gtk.Widget));
        }
        self.updateToolbar();
    }

    fn updateToolbar(self: *Self) void {
        const priv = self.private();
        const total = if (priv.parsed) |parsed| parsed.file.hunks.items.len else 0;
        const hunk_text = std.fmt.allocPrintSentinel(priv.alloc, "Hunk {d}/{d}", .{
            if (total == 0) 0 else priv.focused_hunk + 1,
            total,
        }, 0) catch |err| {
            logx.catchWarn(log, "updateToolbar allocPrintSentinel", err);
            return;
        };
        defer priv.alloc.free(hunk_text);
        priv.hunk_label.setText(hunk_text.ptr);

        priv.side_button.setLabel(if (priv.side_by_side) "Side by side" else "Unified");
        priv.context_label.setText(switch (priv.context_limit orelse 0) {
            3 => "Context: 3",
            10 => "Context: 10",
            else => "Context: all",
        });
    }

    fn focusDelta(self: *Self, delta: isize) void {
        const priv = self.private();
        const parsed = priv.parsed orelse return;
        const total = parsed.file.hunks.items.len;
        if (total == 0) return;
        if (delta < 0) {
            priv.focused_hunk = if (priv.focused_hunk == 0) total - 1 else priv.focused_hunk - 1;
        } else {
            priv.focused_hunk = (priv.focused_hunk + 1) % total;
        }
        logx.event(log, "hunk_focused", "index={d}/{d}", .{ priv.focused_hunk + 1, total });
        self.render() catch |err| logx.catchWarn(log, "focusDelta render", err);
    }

    fn setContext(self: *Self, limit: ?usize) void {
        self.private().context_limit = limit;
        logx.event(log, "diff_context_set", "limit={?d}", .{limit});
        self.render() catch |err| logx.catchWarn(log, "setContext render", err);
    }

    fn sideBySideClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().side_by_side = !self.private().side_by_side;
        logx.event(log, "diff_side_by_side", "enabled={}", .{self.private().side_by_side});
        self.render() catch |err| logx.catchWarn(log, "sideBySideClicked render", err);
    }

    fn nextHunkClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.focusDelta(1);
    }

    fn prevHunkClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.focusDelta(-1);
    }

    fn context3Clicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.setContext(3);
    }

    fn context10Clicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.setContext(10);
    }

    fn contextAllClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.setContext(null);
    }

    fn keyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        mods: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        if (!mods.alt_mask) return 0;
        if (keyval == gdk.KEY_n or keyval == gdk.KEY_N) {
            self.focusDelta(1);
            return 1;
        }
        if (keyval == gdk.KEY_p or keyval == gdk.KEY_P) {
            self.focusDelta(-1);
            return 1;
        }
        return 0;
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            priv.alloc.free(priv.diff_text);
            if (priv.parsed) |*parsed| parsed.deinit(priv.alloc);
            priv.parsed = null;
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

fn fileHeader(alloc: std.mem.Allocator, file: diff_parser.File) !*gtk.Widget {
    const row = gtk.Box.new(.horizontal, 8);
    row.as(gtk.Widget).addCssClass("card");
    ui.margin(row.as(gtk.Widget), 10);

    const badge_z = try alloc.dupeZ(u8, file.status.badge());
    defer alloc.free(badge_z);
    const badge = ui.label(badge_z, "heading");
    badge.setWidthChars(2);
    row.append(badge.as(gtk.Widget));

    const title = if (file.old_path) |old|
        try std.fmt.allocPrintSentinel(alloc, "{s} (from {s})", .{ file.path, old }, 0)
    else
        try alloc.dupeZ(u8, file.path);
    defer alloc.free(title);
    const path = ui.label(title, "monospace");
    path.setWrap(0);
    path.setEllipsize(.middle);
    path.as(gtk.Widget).setHexpand(1);
    row.append(path.as(gtk.Widget));

    if (file.additions() > 0) {
        const add_z = try std.fmt.allocPrintSentinel(alloc, "+{d}", .{file.additions()}, 0);
        defer alloc.free(add_z);
        row.append(ui.label(add_z, "success").as(gtk.Widget));
    }
    if (file.deletions() > 0) {
        const del_z = try std.fmt.allocPrintSentinel(alloc, "-{d}", .{file.deletions()}, 0);
        defer alloc.free(del_z);
        row.append(ui.label(del_z, "error").as(gtk.Widget));
    }
    return row.as(gtk.Widget);
}

fn binaryRow(alloc: std.mem.Allocator, size: ?usize) !*gtk.Widget {
    const text = if (size) |bytes| try std.fmt.allocPrintSentinel(alloc, "Binary file ({d} bytes)", .{bytes}, 0) else try alloc.dupeZ(u8, "Binary file");
    defer alloc.free(text);
    return ui.label(text, "warning").as(gtk.Widget);
}

fn syntaxClassForPath(path: []const u8) [:0]const u8 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".zig")) return "source-zig";
    if (std.ascii.eqlIgnoreCase(ext, ".swift")) return "source-swift";
    if (std.ascii.eqlIgnoreCase(ext, ".ts") or std.ascii.eqlIgnoreCase(ext, ".tsx")) return "source-typescript";
    if (std.ascii.eqlIgnoreCase(ext, ".js") or std.ascii.eqlIgnoreCase(ext, ".jsx")) return "source-javascript";
    if (std.ascii.eqlIgnoreCase(ext, ".json")) return "source-json";
    if (std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".mdx")) return "source-markdown";
    if (std.ascii.eqlIgnoreCase(ext, ".sh")) return "source-shell";
    return "source-plain";
}
