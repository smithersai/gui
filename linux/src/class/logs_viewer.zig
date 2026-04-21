const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const tree_state = @import("../features/tree_state.zig");

pub const LogsViewer = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersLiveLogsViewer",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        header: *gtk.Label = undefined,
        level: *gtk.ComboBoxText = undefined,
        search: *gtk.SearchEntry = undefined,
        follow: *gtk.CheckButton = undefined,
        scroll: *gtk.ScrolledWindow = undefined,
        text: *gtk.TextView = undefined,
        buffer: *gtk.TextBuffer = undefined,
        last_state: ?*const tree_state.LiveState = null,
        last_node: ?*const tree_state.Node = null,
        suppress_scroll: bool = false,
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

    pub fn update(self: *Self, state: *const tree_state.LiveState, node: ?*const tree_state.Node) void {
        self.private().last_state = state;
        self.private().last_node = node;
        self.render();
    }

    fn render(self: *Self) void {
        const priv = self.private();
        const state = priv.last_state orelse {
            priv.buffer.setText("Select a run.", -1);
            return;
        };
        const node = priv.last_node;
        const node_id = if (node) |n| if (n.task) |task| task.node_id else null else null;
        const filter = self.levelFilter();
        const query = std.mem.span(priv.search.as(gtk.Editable).getText());
        var out: std.Io.Writer.Allocating = .init(priv.alloc);
        defer out.deinit();

        var rendered: usize = 0;
        for (state.logs.items) |block| {
            if (!(tree_state.logMatches(block, node_id, filter, query, priv.alloc) catch false)) continue;
            if (block.timestamp_ms) |ts| {
                out.writer.print("[{d}] ", .{ts}) catch {};
            }
            out.writer.print("{s}: {s}\n\n", .{ tree_state.logBlockLevel(block).label(), block.content }) catch {};
            rendered += 1;
        }

        const header_text = std.fmt.allocPrintSentinel(
            priv.alloc,
            "{d} log block{s}",
            .{ rendered, if (rendered == 1) "" else "s" },
            0,
        ) catch return;
        defer priv.alloc.free(header_text);
        priv.header.setText(header_text.ptr);

        const written = out.written();
        if (written.len == 0) {
            priv.buffer.setText("No transcript yet.", -1);
        } else {
            const z = priv.alloc.dupeZ(u8, written) catch return;
            defer priv.alloc.free(z);
            priv.buffer.setText(z.ptr, @intCast(written.len));
        }

        if (priv.follow.getActive() != 0) {
            priv.suppress_scroll = true;
            const adj = priv.scroll.getVadjustment();
            adj.setValue(adj.getUpper());
            priv.suppress_scroll = false;
        }
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 8);
        const controls = gtk.Box.new(.horizontal, 8);
        ui.margin4(controls.as(gtk.Widget), 6, 8, 0, 8);

        self.private().follow = gtk.CheckButton.newWithLabel("Follow");
        self.private().follow.setActive(1);
        _ = gtk.CheckButton.signals.toggled.connect(self.private().follow, *Self, followToggled, self, .{});
        controls.append(self.private().follow.as(gtk.Widget));

        self.private().level = gtk.ComboBoxText.new();
        self.private().level.append("all", "all");
        self.private().level.append("trace", "trace");
        self.private().level.append("debug", "debug");
        self.private().level.append("info", "info");
        self.private().level.append("warn", "warn");
        self.private().level.append("error", "error");
        _ = self.private().level.as(gtk.ComboBox).setActiveId("all");
        _ = gtk.ComboBox.signals.changed.connect(self.private().level.as(gtk.ComboBox), *Self, levelChanged, self, .{});
        controls.append(self.private().level.as(gtk.Widget));

        self.private().search = gtk.SearchEntry.new();
        self.private().search.setPlaceholderText("Search logs");
        self.private().search.as(gtk.Widget).setHexpand(1);
        _ = gtk.SearchEntry.signals.search_changed.connect(self.private().search, *Self, searchChanged, self, .{});
        controls.append(self.private().search.as(gtk.Widget));

        self.private().header = ui.dim("0 log blocks");
        controls.append(self.private().header.as(gtk.Widget));
        root.append(controls.as(gtk.Widget));

        self.private().buffer = gtk.TextBuffer.new(null);
        self.private().text = gtk.TextView.newWithBuffer(self.private().buffer);
        self.private().text.setEditable(0);
        self.private().text.setMonospace(1);
        self.private().text.setWrapMode(.word_char);
        self.private().scroll = ui.scrolled(self.private().text.as(gtk.Widget));
        self.private().scroll.as(gtk.Widget).setVexpand(1);
        _ = gtk.Adjustment.signals.value_changed.connect(self.private().scroll.getVadjustment(), *Self, scrollChanged, self, .{});
        root.append(self.private().scroll.as(gtk.Widget));

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn levelFilter(self: *Self) ?tree_state.LogLevel {
        const active = self.private().level.as(gtk.ComboBox).getActiveId() orelse return null;
        const id = std.mem.span(active);
        if (std.mem.eql(u8, id, "all")) return null;
        return tree_state.LogLevel.parse(id);
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        self.render();
    }

    fn levelChanged(_: *gtk.ComboBox, self: *Self) callconv(.c) void {
        self.render();
    }

    fn followToggled(_: *gtk.CheckButton, self: *Self) callconv(.c) void {
        self.render();
    }

    fn scrollChanged(_: *gtk.Adjustment, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.suppress_scroll) return;
        const adj = priv.scroll.getVadjustment();
        const distance = adj.getUpper() - adj.getPageSize() - adj.getValue();
        priv.follow.setActive(@intFromBool(distance <= 8));
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
