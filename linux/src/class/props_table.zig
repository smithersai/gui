const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const logx = @import("../log.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const tree_state = @import("../features/tree_state.zig");

const log = std.log.scoped(.smithers_gtk_props_table);

pub const PropsTable = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersLivePropsTable",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        search: *gtk.SearchEntry = undefined,
        scroll: *gtk.ScrolledWindow = undefined,
        list: *gtk.ListBox = undefined,
        empty: *gtk.Label = undefined,
        expanded: std.AutoHashMap(usize, void) = undefined,
        last_node: ?*const tree_state.Node = null,
        scroll_value: f64 = 0,
        suppress_scroll: bool = false,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{
            .alloc = alloc,
            .expanded = .init(alloc),
        };
        try self.build();
        return self;
    }

    pub fn update(self: *Self, node: ?*const tree_state.Node) void {
        if (self.private().last_node != node) self.private().expanded.clearRetainingCapacity();
        self.private().last_node = node;
        self.render();
    }

    fn render(self: *Self) void {
        const priv = self.private();
        priv.list.removeAll();

        const target = priv.last_node orelse {
            priv.empty.setText("Select a node to inspect props.");
            priv.empty.as(gtk.Widget).setVisible(1);
            return;
        };

        if (target.props.items.len == 0) {
            priv.empty.setText("No props");
            priv.empty.as(gtk.Widget).setVisible(1);
            return;
        }

        const query = std.mem.span(priv.search.as(gtk.Editable).getText());
        const t = logx.startTimer();
        var rendered: usize = 0;
        for (target.props.items, 0..) |prop, index| {
            if (!(tree_state.propMatchesSearch(prop, query, priv.alloc) catch |err| blk: {
                logx.catchDebug(log, "propMatchesSearch", err);
                break :blk false;
            })) continue;
            const row = self.propRow(prop, index) catch |err| {
                logx.catchWarn(log, "propRow", err);
                continue;
            };
            priv.list.append(row.as(gtk.Widget));
            rendered += 1;
        }
        logx.endTimerDebug(log, "props_table render", t);
        log.debug("props rendered total={d} shown={d}", .{ target.props.items.len, rendered });

        if (rendered == 0) {
            priv.empty.setText("No props match search");
            priv.empty.as(gtk.Widget).setVisible(1);
        } else {
            priv.empty.as(gtk.Widget).setVisible(0);
        }
        self.restoreScroll();
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 8);

        self.private().search = gtk.SearchEntry.new();
        self.private().search.setPlaceholderText("Search props");
        _ = gtk.SearchEntry.signals.search_changed.connect(self.private().search, *Self, searchChanged, self, .{});
        ui.margin4(self.private().search.as(gtk.Widget), 6, 8, 0, 8);
        root.append(self.private().search.as(gtk.Widget));

        self.private().empty = ui.dim("No props");
        root.append(self.private().empty.as(gtk.Widget));

        self.private().list = gtk.ListBox.new();
        self.private().list.setSelectionMode(.none);
        self.private().list.as(gtk.Widget).addCssClass("boxed-list");
        self.private().scroll = ui.scrolled(self.private().list.as(gtk.Widget));
        self.private().scroll.as(gtk.Widget).setVexpand(1);
        _ = gtk.Adjustment.signals.value_changed.connect(self.private().scroll.getVadjustment(), *Self, scrollChanged, self, .{});
        root.append(self.private().scroll.as(gtk.Widget));

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn propRow(self: *Self, prop: tree_state.Prop, index: usize) !*gtk.ListBoxRow {
        const alloc = self.private().alloc;
        const row = gtk.ListBoxRow.new();
        row.setSelectable(0);
        row.setActivatable(0);

        const box = gtk.Box.new(.horizontal, 8);
        ui.margin4(box.as(gtk.Widget), 6, 8, 6, 8);

        const nested = isNested(prop.rendered);
        if (nested) {
            const expanded = self.private().expanded.contains(index);
            const toggle = ui.iconButton(if (expanded) "pan-down-symbolic" else "pan-end-symbolic", if (expanded) "Collapse value" else "Expand value");
            ui.setIndex(toggle.as(gobject.Object), index);
            _ = gtk.Button.signals.clicked.connect(toggle, *Self, toggleClicked, self, .{});
            box.append(toggle.as(gtk.Widget));
        }

        const key_z = try alloc.dupeZ(u8, prop.key);
        defer alloc.free(key_z);
        const key = ui.label(key_z, "monospace");
        key.as(gtk.Widget).setSizeRequest(120, -1);
        key.setWrap(0);
        key.setEllipsize(.end);
        box.append(key.as(gtk.Widget));

        const shown = if (nested and !self.private().expanded.contains(index))
            try tree_state.singleLinePreview(alloc, prop.rendered, 160)
        else
            try alloc.dupe(u8, prop.rendered);
        defer alloc.free(shown);
        const value_z = try alloc.dupeZ(u8, shown);
        defer alloc.free(value_z);
        const value = ui.label(value_z, null);
        value.as(gtk.Widget).setHexpand(1);
        value.setSelectable(1);
        value.setWrap(1);
        value.setWrapMode(.word_char);
        box.append(value.as(gtk.Widget));

        const copy = ui.iconButton("edit-copy-symbolic", "Copy value");
        ui.setIndex(copy.as(gobject.Object), index);
        _ = gtk.Button.signals.clicked.connect(copy, *Self, copyClicked, self, .{});
        box.append(copy.as(gtk.Widget));

        row.setChild(box.as(gtk.Widget));
        return row;
    }

    fn isNested(value: []const u8) bool {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        return trimmed.len > 1 and (trimmed[0] == '{' or trimmed[0] == '[');
    }

    fn toggleClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const index = ui.getIndex(button.as(gobject.Object)) orelse return;
        const node = self.private().last_node orelse return;
        if (index >= node.props.items.len) return;
        if (self.private().expanded.contains(index)) {
            _ = self.private().expanded.remove(index);
        } else {
            self.private().expanded.put(index, {}) catch {};
        }
        self.render();
    }

    fn copyClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const index = ui.getIndex(button.as(gobject.Object)) orelse return;
        const node = self.private().last_node orelse return;
        if (index >= node.props.items.len) return;
        const raw = tree_state.rawPropValue(self.private().alloc, node.props.items[index]) catch return;
        defer self.private().alloc.free(raw);
        const z = self.private().alloc.dupeZ(u8, raw) catch return;
        defer self.private().alloc.free(z);
        self.as(gtk.Widget).getClipboard().setText(z.ptr);
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        self.render();
    }

    fn restoreScroll(self: *Self) void {
        const priv = self.private();
        const adj = priv.scroll.getVadjustment();
        var max = adj.getUpper() - adj.getPageSize();
        if (max < 0) max = 0;
        const value = if (priv.scroll_value > max) max else priv.scroll_value;
        priv.suppress_scroll = true;
        adj.setValue(value);
        priv.suppress_scroll = false;
    }

    fn scrollChanged(_: *gtk.Adjustment, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.suppress_scroll) return;
        priv.scroll_value = priv.scroll.getVadjustment().getValue();
    }

    fn dispose(self: *Self) callconv(.c) void {
        if (!self.private().did_dispose) {
            self.private().did_dispose = true;
            self.private().expanded.deinit();
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
