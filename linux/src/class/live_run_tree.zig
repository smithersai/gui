const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const tree_state = @import("../features/tree_state.zig");

pub const LiveRunTree = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersLiveRunTree",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        search: *gtk.SearchEntry = undefined,
        list: *gtk.ListBox = undefined,
        empty: *gtk.Label = undefined,
        last_state: ?*const tree_state.LiveState = null,
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

    pub fn list(self: *Self) *gtk.ListBox {
        return self.private().list;
    }

    pub fn update(self: *Self, state: *const tree_state.LiveState) void {
        self.private().last_state = state;
        self.render(state);
    }

    fn render(self: *Self, state: *const tree_state.LiveState) void {
        const priv = self.private();
        priv.list.removeAll();
        const root = state.root orelse {
            priv.empty.setText("Waiting for tree data...");
            priv.empty.as(gtk.Widget).setVisible(1);
            return;
        };

        priv.empty.as(gtk.Widget).setVisible(0);
        var error_index = tree_state.AncestorErrorIndex.init(priv.alloc, root) catch null;
        defer if (error_index) |*idx| idx.deinit();

        const query = std.mem.span(priv.search.as(gtk.Editable).getText());
        var search_index = tree_state.SearchIndex.init(priv.alloc, root, query) catch null;
        defer if (search_index) |*idx| idx.deinit();

        const shown = appendNode(
            priv.alloc,
            priv.list,
            root,
            state.selected_id,
            if (error_index) |*idx| idx else null,
            if (search_index) |*idx| idx else null,
        ) catch 0;
        if (shown == 0) {
            priv.empty.setText("No matching nodes");
            priv.empty.as(gtk.Widget).setVisible(1);
        }
    }

    pub fn nodeIdForRow(row: *gtk.ListBoxRow) ?i64 {
        const ptr = row.as(gobject.Object).getData("smithers-live-node-id") orelse return null;
        const raw = @intFromPtr(ptr);
        if (raw == 0) return null;
        return @intCast(raw - 1);
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 0);

        const search_box = gtk.Box.new(.horizontal, 6);
        ui.margin4(search_box.as(gtk.Widget), 8, 8, 8, 8);
        const icon = gtk.Image.newFromIconName("system-search-symbolic");
        search_box.append(icon.as(gtk.Widget));
        self.private().search = gtk.SearchEntry.new();
        self.private().search.setPlaceholderText("Search tree");
        self.private().search.setSearchDelay(90);
        _ = gtk.SearchEntry.signals.search_changed.connect(self.private().search, *Self, searchChanged, self, .{});
        self.private().search.as(gtk.Widget).setHexpand(1);
        search_box.append(self.private().search.as(gtk.Widget));
        root.append(search_box.as(gtk.Widget));

        self.private().empty = ui.dim("Waiting for tree data...");
        ui.margin(self.private().empty.as(gtk.Widget), 16);
        root.append(self.private().empty.as(gtk.Widget));

        self.private().list = gtk.ListBox.new();
        self.private().list.setSelectionMode(.single);
        self.private().list.setShowSeparators(0);
        const scroll = ui.scrolled(self.private().list.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        root.append(scroll.as(gtk.Widget));

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn appendNode(
        alloc: std.mem.Allocator,
        list_widget: *gtk.ListBox,
        node: *const tree_state.Node,
        selected_id: ?i64,
        error_index: ?*const tree_state.AncestorErrorIndex,
        search_index: ?*const tree_state.SearchIndex,
    ) !usize {
        var shown: usize = 0;
        if (search_index == null or search_index.?.isMatch(node.id)) {
            const row = try rowForNode(alloc, node, selected_id, error_index);
            list_widget.append(row.as(gtk.Widget));
            if (selected_id != null and selected_id.? == node.id) list_widget.selectRow(row);
            shown += 1;
        }
        for (node.children.items) |child| shown += try appendNode(alloc, list_widget, child, selected_id, error_index, search_index);
        return shown;
    }

    fn rowForNode(
        alloc: std.mem.Allocator,
        node: *const tree_state.Node,
        selected_id: ?i64,
        error_index: ?*const tree_state.AncestorErrorIndex,
    ) !*gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.setSelectable(1);
        row.setActivatable(1);
        if (node.id >= 0) row.as(gobject.Object).setData("smithers-live-node-id", @ptrFromInt(@as(usize, @intCast(node.id)) + 1));

        const box = gtk.Box.new(.horizontal, 8);
        ui.margin4(box.as(gtk.Widget), 4, 8, 4, 8);
        box.as(gtk.Widget).setMarginStart(@intCast(8 + node.depth * 16));

        const state = node.state();
        const glyph = switch (state) {
            .running => ">",
            .finished => "ok",
            .failed => "x",
            .blocked, .waiting_approval => "!",
            .cancelled => "-",
            .pending => "o",
            .unknown => "?",
        };
        const glyph_z = try alloc.dupeZ(u8, glyph);
        defer alloc.free(glyph_z);
        const state_label = ui.label(glyph_z, "monospace");
        state_label.as(gtk.Widget).setSizeRequest(20, -1);
        box.append(state_label.as(gtk.Widget));

        const title_box = gtk.Box.new(.vertical, 1);
        title_box.as(gtk.Widget).setHexpand(1);
        const title_text = try std.fmt.allocPrintZ(alloc, "<{s}>", .{node.name});
        defer alloc.free(title_text);
        const title = ui.label(title_text, if (selected_id != null and selected_id.? == node.id) "heading" else null);
        title.setWrap(0);
        title.setEllipsize(.end);
        title_box.append(title.as(gtk.Widget));

        const summary = try tree_state.keyPropsSummary(alloc, node, 120);
        defer alloc.free(summary);
        if (summary.len > 0) {
            const summary_z = try alloc.dupeZ(u8, summary);
            defer alloc.free(summary_z);
            const subtitle = ui.dim(summary_z);
            subtitle.setWrap(0);
            subtitle.setEllipsize(.end);
            title_box.append(subtitle.as(gtk.Widget));
        }
        box.append(title_box.as(gtk.Widget));

        if (error_index) |idx| {
            const failed = idx.count(node.id);
            if (failed > 0) {
                const failed_z = try std.fmt.allocPrintZ(alloc, "{d} failed", .{failed});
                defer alloc.free(failed_z);
                const failed_label = ui.label(failed_z, null);
                box.append(failed_label.as(gtk.Widget));
            }
        }

        const badge_z = try alloc.dupeZ(u8, state.label());
        defer alloc.free(badge_z);
        const badge = ui.dim(badge_z);
        box.append(badge.as(gtk.Widget));

        row.setChild(box.as(gtk.Widget));
        return row;
    }

    fn dispose(self: *Self) callconv(.c) void {
        if (!self.private().did_dispose) {
            self.private().did_dispose = true;
            self.as(adw.Bin).setChild(null);
        }
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const state = self.private().last_state orelse return;
        self.render(state);
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
