const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
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
        expanded: tree_state.ExpandedSet = undefined,
        last_state: ?*tree_state.LiveState = null,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{
            .alloc = alloc,
            .expanded = tree_state.ExpandedSet.init(alloc),
        };
        try self.build();
        return self;
    }

    pub fn list(self: *Self) *gtk.ListBox {
        return self.private().list;
    }

    pub fn update(self: *Self, state: *tree_state.LiveState) void {
        self.private().last_state = state;
        self.render(state);
    }

    pub fn focusSelected(self: *Self) void {
        const state = self.private().last_state orelse {
            _ = self.private().list.as(gtk.Widget).grabFocus();
            return;
        };
        if (state.selected_id) |id| {
            self.selectRenderedRow(id);
            return;
        }
        _ = self.private().list.as(gtk.Widget).grabFocus();
    }

    fn render(self: *Self, state: *tree_state.LiveState) void {
        const priv = self.private();
        priv.list.removeAll();
        const root = state.root orelse {
            priv.empty.setText("Waiting for tree data...");
            priv.empty.as(gtk.Widget).setVisible(1);
            return;
        };

        priv.expanded.expandPathTo(root, state.selected_id orelse root.id) catch {};
        priv.expanded.autoExpandRunningPaths(root) catch {};

        var error_index = tree_state.AncestorErrorIndex.init(priv.alloc, root) catch null;
        defer if (error_index) |*idx| idx.deinit();

        const query = std.mem.span(priv.search.as(gtk.Editable).getText());
        var search_index = tree_state.SearchIndex.init(priv.alloc, root, query) catch null;
        defer if (search_index) |*idx| idx.deinit();

        var rows = tree_state.collectVisibleRows(priv.alloc, root, &priv.expanded) catch {
            priv.empty.setText("Tree unavailable.");
            priv.empty.as(gtk.Widget).setVisible(1);
            return;
        };
        defer rows.deinit(priv.alloc);

        const search_active = if (search_index) |idx| idx.active else false;
        for (rows.items.items) |node| {
            const row = self.rowForNode(
                state,
                node,
                state.selected_id,
                if (error_index) |*idx| idx else null,
                if (search_index) |*idx| idx else null,
            ) catch continue;
            priv.list.append(row.as(gtk.Widget));
            if (state.selected_id != null and state.selected_id.? == node.id) {
                priv.list.selectRow(row);
            }
        }

        if (rows.items.items.len == 0) {
            priv.empty.setText("No tree rows");
            priv.empty.as(gtk.Widget).setVisible(1);
        } else if (search_active and search_index != null and !search_index.?.hasMatches()) {
            priv.empty.setText("No matching nodes");
            priv.empty.as(gtk.Widget).setVisible(1);
        } else {
            priv.empty.as(gtk.Widget).setVisible(0);
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

        const expand_all = ui.iconButton("pan-down-symbolic", "Expand all");
        _ = gtk.Button.signals.clicked.connect(expand_all, *Self, expandAllClicked, self, .{});
        search_box.append(expand_all.as(gtk.Widget));

        const collapse_all = ui.iconButton("pan-end-symbolic", "Collapse all");
        _ = gtk.Button.signals.clicked.connect(collapse_all, *Self, collapseAllClicked, self, .{});
        search_box.append(collapse_all.as(gtk.Widget));
        root.append(search_box.as(gtk.Widget));

        self.private().empty = ui.dim("Waiting for tree data...");
        ui.margin(self.private().empty.as(gtk.Widget), 16);
        root.append(self.private().empty.as(gtk.Widget));

        self.private().list = gtk.ListBox.new();
        self.private().list.setSelectionMode(.single);
        self.private().list.setShowSeparators(0);
        self.private().list.as(gtk.Widget).setCanFocus(1);
        self.installShortcuts(self.private().list.as(gtk.Widget));
        const scroll = ui.scrolled(self.private().list.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        root.append(scroll.as(gtk.Widget));

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn installShortcuts(self: *Self, widget: *gtk.Widget) void {
        const controller = gtk.ShortcutController.new();
        controller.setScope(.local);
        self.addShortcut(controller, "Up", shortcutMoveUp);
        self.addShortcut(controller, "Down", shortcutMoveDown);
        self.addShortcut(controller, "Left", shortcutCollapse);
        self.addShortcut(controller, "Right", shortcutExpand);
        self.addShortcut(controller, "Home", shortcutFirst);
        self.addShortcut(controller, "End", shortcutLast);
        self.addShortcut(controller, "Return", shortcutInspector);
        self.addShortcut(controller, "Escape", shortcutClearSearch);
        self.addShortcut(controller, "<Control>f", shortcutFocusSearch);
        self.addShortcut(controller, "<Control>Right", shortcutExpandAll);
        self.addShortcut(controller, "<Control>Left", shortcutCollapseAll);
        widget.addController(controller.as(gtk.EventController));
    }

    fn addShortcut(self: *Self, controller: *gtk.ShortcutController, trigger_text: [:0]const u8, callback: gtk.ShortcutFunc) void {
        const trigger = gtk.ShortcutTrigger.parseString(trigger_text.ptr) orelse return;
        const action = gtk.CallbackAction.new(callback, self, null);
        const shortcut = gtk.Shortcut.new(trigger, action.as(gtk.ShortcutAction));
        controller.addShortcut(shortcut);
    }

    fn rowForNode(
        self: *Self,
        state: *const tree_state.LiveState,
        node: *const tree_state.Node,
        selected_id: ?i64,
        error_index: ?*const tree_state.AncestorErrorIndex,
        search_index: ?*const tree_state.SearchIndex,
    ) !*gtk.ListBoxRow {
        const alloc = self.private().alloc;
        const row = gtk.ListBoxRow.new();
        row.setSelectable(1);
        row.setActivatable(1);
        if (node.id >= 0) row.as(gobject.Object).setData("smithers-live-node-id", @ptrFromInt(@as(usize, @intCast(node.id)) + 1));

        const box = gtk.Box.new(.horizontal, 8);
        ui.margin4(box.as(gtk.Widget), 4, 8, 4, 8);
        box.as(gtk.Widget).setMarginStart(@intCast(8 + node.depth * 16));

        const state_value = node.state();
        if (state_value == .running and node.children.items.len == 0) {
            const spinner = gtk.Spinner.new();
            spinner.start();
            spinner.as(gtk.Widget).setSizeRequest(18, 18);
            box.append(spinner.as(gtk.Widget));
        } else {
            const glyph_z = try alloc.dupeZ(u8, state_value.glyph());
            defer alloc.free(glyph_z);
            const state_label = ui.label(glyph_z, state_value.cssClass());
            state_label.as(gtk.Widget).setSizeRequest(20, -1);
            box.append(state_label.as(gtk.Widget));
        }

        if (node.children.items.len > 0) {
            const expanded = self.private().expanded.contains(node.id);
            const icon = if (expanded) "pan-down-symbolic" else "pan-end-symbolic";
            const toggle = ui.iconButton(icon, if (expanded) "Collapse node" else "Expand node");
            toggle.as(gobject.Object).setData("smithers-live-node-id", @ptrFromInt(@as(usize, @intCast(node.id)) + 1));
            _ = gtk.Button.signals.clicked.connect(toggle, *Self, expandButtonClicked, self, .{});
            box.append(toggle.as(gtk.Widget));
        } else {
            const spacer = gtk.Box.new(.horizontal, 0);
            spacer.as(gtk.Widget).setSizeRequest(28, -1);
            box.append(spacer.as(gtk.Widget));
        }

        const title_box = gtk.Box.new(.vertical, 1);
        title_box.as(gtk.Widget).setHexpand(1);
        const is_match = if (search_index) |idx| idx.isMatch(node.id) else true;
        const title_css: ?[:0]const u8 = if (selected_id != null and selected_id.? == node.id)
            "heading"
        else if (!is_match)
            "dim-label"
        else
            state_value.cssClass();
        const title_text = try std.fmt.allocPrintSentinel(alloc, "<{s}>", .{node.name}, 0);
        defer alloc.free(title_text);
        const title = ui.label(title_text, title_css);
        title.setWrap(0);
        title.setEllipsize(.end);
        title_box.append(title.as(gtk.Widget));

        const summary = try tree_state.keyPropsSummary(alloc, node, 120);
        defer alloc.free(summary);
        const last_log = if (node.task) |task|
            if (node.children.items.len == 0 and state_value == .running) tree_state.lastLogForTask(state, task.node_id) else null
        else
            null;
        if (summary.len > 0 or last_log != null) {
            var line: []u8 = undefined;
            if (last_log) |block| {
                const preview = try tree_state.singleLinePreview(alloc, block.content, 180);
                defer alloc.free(preview);
                line = if (summary.len > 0)
                    try std.fmt.allocPrint(alloc, "{s}  {s}", .{ summary, preview })
                else
                    try alloc.dupe(u8, preview);
            } else {
                line = try alloc.dupe(u8, summary);
            }
            defer alloc.free(line);
            const line_z = try alloc.dupeZ(u8, line);
            defer alloc.free(line_z);
            const subtitle = ui.dim(line_z);
            subtitle.setWrap(0);
            subtitle.setEllipsize(.end);
            title_box.append(subtitle.as(gtk.Widget));
        }
        box.append(title_box.as(gtk.Widget));

        if (error_index) |idx| {
            const failed = idx.count(node.id);
            if (failed > 0) {
                const failed_z = try std.fmt.allocPrintSentinel(alloc, "{d} failed", .{failed}, 0);
                defer alloc.free(failed_z);
                const failed_label = ui.label(failed_z, "error");
                failed_label.as(gtk.Widget).setTooltipText("A descendant node failed");
                box.append(failed_label.as(gtk.Widget));
            }
        }

        if (try tree_state.elapsedText(alloc, node, tree_state.nowMs())) |elapsed| {
            defer alloc.free(elapsed);
            const elapsed_z = try alloc.dupeZ(u8, elapsed);
            defer alloc.free(elapsed_z);
            const timing = ui.dim(elapsed_z);
            timing.as(gtk.Widget).setSizeRequest(48, -1);
            box.append(timing.as(gtk.Widget));
        }

        const badge_z = try alloc.dupeZ(u8, state_value.label());
        defer alloc.free(badge_z);
        const badge = ui.label(badge_z, state_value.cssClass());
        box.append(badge.as(gtk.Widget));

        const tooltip = try self.nodeTooltip(state, node);
        defer alloc.free(tooltip);
        const tooltip_z = try alloc.dupeZ(u8, tooltip);
        defer alloc.free(tooltip_z);
        row.as(gtk.Widget).setTooltipText(tooltip_z.ptr);

        row.setChild(box.as(gtk.Widget));
        return row;
    }

    fn nodeTooltip(self: *Self, state: *const tree_state.LiveState, node: *const tree_state.Node) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.private().alloc);
        defer out.deinit();
        try out.writer.print("<{s}> {s}", .{ node.name, node.state().label() });
        if (node.task) |task| {
            try out.writer.print("\nNode ID: {s}", .{task.node_id});
            if (task.iteration) |iteration| try out.writer.print("\nIteration: {d}", .{iteration});
            if (tree_state.lastLogForTask(state, task.node_id)) |block| {
                const preview = try tree_state.singleLinePreview(self.private().alloc, block.content, 200);
                defer self.private().alloc.free(preview);
                try out.writer.print("\nLast log: {s}", .{preview});
            }
        }
        return try out.toOwnedSlice();
    }

    fn handleKeyboard(self: *Self, action: tree_state.TreeKeyboardAction) !bool {
        const priv = self.private();
        const state = priv.last_state orelse return false;
        const root = state.root orelse return false;
        var rows = try tree_state.collectVisibleRows(priv.alloc, root, &priv.expanded);
        defer rows.deinit(priv.alloc);
        const result = tree_state.handleTreeKeyboard(
            action,
            currentSelectedId(priv.list) orelse state.selected_id,
            rows.items.items,
            &priv.expanded,
            root,
        );

        if (result.expand_change) |change| {
            switch (change) {
                .expand => |id| try priv.expanded.expand(id),
                .collapse => |id| try priv.expanded.collapse(id),
            }
            self.render(state);
        }

        if (result.selected_id) |id| {
            self.selectRenderedRow(id);
        }

        if (result.focus) |focus| switch (focus) {
            .inspector => if (currentSelectedId(priv.list) == null and result.selected_id == null) return false,
            .search => _ = priv.search.as(gtk.Widget).grabFocus(),
            .clear_search => {
                if (std.mem.span(priv.search.as(gtk.Editable).getText()).len > 0) {
                    priv.search.as(gtk.Editable).setText("");
                } else {
                    priv.list.selectRow(null);
                }
            },
        };
        return true;
    }

    fn selectRenderedRow(self: *Self, id: i64) void {
        const list_widget = self.private().list;
        var index: c_int = 0;
        while (list_widget.getRowAtIndex(index)) |row| : (index += 1) {
            if (nodeIdForRow(row) == id) {
                list_widget.selectRow(row);
                _ = row.as(gtk.Widget).grabFocus();
                return;
            }
        }
    }

    fn currentSelectedId(list_widget: *gtk.ListBox) ?i64 {
        return if (list_widget.getSelectedRow()) |row| nodeIdForRow(row) else null;
    }

    fn toggleNode(self: *Self, id: i64) void {
        const priv = self.private();
        priv.expanded.toggle(id) catch {};
        if (priv.last_state) |state| self.render(state);
    }

    fn expandAll(self: *Self) void {
        const priv = self.private();
        const state = priv.last_state orelse return;
        priv.expanded.expandAll(state.root) catch {};
        self.render(state);
    }

    fn collapseAll(self: *Self) void {
        const priv = self.private();
        const state = priv.last_state orelse return;
        priv.expanded.collapseAll();
        if (state.root) |root| {
            if (state.selected_id) |id| priv.expanded.expandPathTo(root, id) catch {};
        }
        self.render(state);
    }

    fn dispose(self: *Self) callconv(.c) void {
        if (!self.private().did_dispose) {
            self.private().did_dispose = true;
            self.private().expanded.deinit();
            self.as(adw.Bin).setChild(null);
        }
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const state = self.private().last_state orelse return;
        self.render(state);
    }

    fn expandButtonClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const ptr = button.as(gobject.Object).getData("smithers-live-node-id") orelse return;
        const raw = @intFromPtr(ptr);
        if (raw == 0) return;
        self.toggleNode(@intCast(raw - 1));
    }

    fn expandAllClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.expandAll();
    }

    fn collapseAllClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.collapseAll();
    }

    fn shortcutMoveUp(_: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        return @intFromBool(self.handleKeyboard(.move_up) catch false);
    }

    fn shortcutMoveDown(_: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        return @intFromBool(self.handleKeyboard(.move_down) catch false);
    }

    fn shortcutCollapse(_: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        return @intFromBool(self.handleKeyboard(.collapse) catch false);
    }

    fn shortcutExpand(_: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        return @intFromBool(self.handleKeyboard(.expand) catch false);
    }

    fn shortcutFirst(_: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        return @intFromBool(self.handleKeyboard(.move_first) catch false);
    }

    fn shortcutLast(_: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        return @intFromBool(self.handleKeyboard(.move_last) catch false);
    }

    fn shortcutInspector(_: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        return @intFromBool(self.handleKeyboard(.focus_inspector) catch false);
    }

    fn shortcutFocusSearch(_: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        return @intFromBool(self.handleKeyboard(.focus_search) catch false);
    }

    fn shortcutClearSearch(_: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        return @intFromBool(self.handleKeyboard(.clear_search) catch false);
    }

    fn shortcutExpandAll(_: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        self.expandAll();
        return 1;
    }

    fn shortcutCollapseAll(_: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data orelse return 0));
        self.collapseAll();
        return 1;
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
