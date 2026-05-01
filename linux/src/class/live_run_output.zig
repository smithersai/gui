const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const tree_state = @import("../features/tree_state.zig");

pub const LiveRunOutput = extern struct {
    const Self = @This();
    const page_size: usize = 12 * 1024;

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersLiveRunOutput",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        title: *gtk.Label = undefined,
        page_label: *gtk.Label = undefined,
        prev: *gtk.Button = undefined,
        next: *gtk.Button = undefined,
        latest: *gtk.Button = undefined,
        download: *gtk.Button = undefined,
        scroll: *gtk.ScrolledWindow = undefined,
        text: *gtk.TextView = undefined,
        buffer: *gtk.TextBuffer = undefined,
        rendered: ?[]u8 = null,
        current_page: usize = 0,
        scroll_value: f64 = 0,
        suppress_scroll: bool = false,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, title_text: [:0]const u8) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .alloc = alloc };
        try self.build(title_text);
        return self;
    }

    pub fn updateOutput(self: *Self, node: ?*const tree_state.Node) void {
        self.updateProp(node, "output", "Task has not produced output yet.");
    }

    pub fn updateDiff(self: *Self, node: ?*const tree_state.Node) void {
        self.updateProp(node, "diff", "No diff for this node.");
    }

    fn updateProp(self: *Self, node: ?*const tree_state.Node, key: []const u8, fallback: []const u8) void {
        const priv = self.private();
        const value = if (node) |target| target.stringProp(key) orelse fallback else "Select a task node.";
        const changed = priv.rendered == null or !std.mem.eql(u8, priv.rendered.?, value);
        if (changed) {
            if (priv.rendered) |old| priv.alloc.free(old);
            priv.rendered = priv.alloc.dupe(u8, value) catch return;
            priv.current_page = 0;
        }
        self.render();
    }

    fn render(self: *Self) void {
        const priv = self.private();
        const rendered = priv.rendered orelse "";
        const page = tree_state.pageFor(rendered.len, priv.current_page, page_size);
        priv.current_page = page.index;
        const body = rendered[page.start..page.end];

        var out: std.Io.Writer.Allocating = .init(priv.alloc);
        defer out.deinit();
        if (tree_state.looksLikeJson(rendered)) {
            out.writer.writeAll("json\n\n") catch {};
        } else if (tree_state.looksLikeMarkdown(rendered)) {
            out.writer.writeAll("markdown\n\n") catch {};
        }
        out.writer.writeAll(body) catch {};
        if (page.end < rendered.len) out.writer.writeAll("\n\n[page truncated]") catch {};

        const written = out.written();
        const z = priv.alloc.dupeZ(u8, written) catch return;
        defer priv.alloc.free(z);
        priv.buffer.setText(z.ptr, @intCast(written.len));

        const label = std.fmt.allocPrintSentinel(
            priv.alloc,
            "page {d}/{d}  {d} bytes",
            .{ page.index + 1, page.count, rendered.len },
            0,
        ) catch return;
        defer priv.alloc.free(label);
        priv.page_label.setText(label.ptr);
        priv.prev.as(gtk.Widget).setSensitive(@intFromBool(page.index > 0));
        priv.next.as(gtk.Widget).setSensitive(@intFromBool(page.index + 1 < page.count));
        self.restoreScroll();
    }

    fn build(self: *Self, title_text: [:0]const u8) !void {
        const root = gtk.Box.new(.vertical, 8);
        const header = gtk.Box.new(.horizontal, 8);
        self.private().title = ui.dim(title_text);
        header.append(self.private().title.as(gtk.Widget));
        self.private().page_label = ui.dim("page 1/1");
        self.private().page_label.as(gtk.Widget).setHexpand(1);
        header.append(self.private().page_label.as(gtk.Widget));

        self.private().prev = ui.iconButton("go-previous-symbolic", "Previous output page");
        _ = gtk.Button.signals.clicked.connect(self.private().prev, *Self, prevClicked, self, .{});
        header.append(self.private().prev.as(gtk.Widget));

        self.private().next = ui.iconButton("go-next-symbolic", "Next output page");
        _ = gtk.Button.signals.clicked.connect(self.private().next, *Self, nextClicked, self, .{});
        header.append(self.private().next.as(gtk.Widget));

        self.private().latest = ui.iconButton("go-bottom-symbolic", "Scroll to latest");
        _ = gtk.Button.signals.clicked.connect(self.private().latest, *Self, latestClicked, self, .{});
        header.append(self.private().latest.as(gtk.Widget));

        self.private().download = ui.iconButton("document-save-symbolic", "Copy full output");
        _ = gtk.Button.signals.clicked.connect(self.private().download, *Self, downloadClicked, self, .{});
        header.append(self.private().download.as(gtk.Widget));

        ui.margin4(header.as(gtk.Widget), 6, 8, 0, 8);
        root.append(header.as(gtk.Widget));

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

    fn movePage(self: *Self, delta: isize) void {
        const priv = self.private();
        const rendered = priv.rendered orelse "";
        const page = tree_state.pageFor(rendered.len, priv.current_page, page_size);
        if (delta < 0 and page.index > 0) {
            priv.current_page = page.index - 1;
        } else if (delta > 0 and page.index + 1 < page.count) {
            priv.current_page = page.index + 1;
        }
        self.render();
    }

    fn prevClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.movePage(-1);
    }

    fn nextClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.movePage(1);
    }

    fn latestClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const adj = self.private().scroll.getVadjustment();
        adj.setValue(adj.getUpper());
        self.private().scroll_value = adj.getValue();
    }

    fn downloadClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const rendered = self.private().rendered orelse return;
        const z = self.private().alloc.dupeZ(u8, rendered) catch return;
        defer self.private().alloc.free(z);
        self.as(gtk.Widget).getClipboard().setText(z.ptr);
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
            if (self.private().rendered) |text| {
                self.private().alloc.free(text);
                self.private().rendered = null;
            }
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
