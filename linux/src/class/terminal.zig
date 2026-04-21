const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

pub const have_vte = false;
pub const dependency_status = "vte-2.91-gtk4 unavailable on this host; using GtkTextView fallback";

const max_scrollback_bytes: usize = 512 * 1024;

pub const TerminalSurface = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersTerminalSurface",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        session: smithers.c.smithers_session_t = null,
        buffer: *gtk.TextBuffer = undefined,
        view: *gtk.TextView = undefined,
        entry: *gtk.Entry = undefined,
        size_label: *gtk.Label = undefined,
        scrollback: std.ArrayList(u8) = .empty,
        rows: usize = 24,
        cols: usize = 80,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, session: smithers.c.smithers_session_t) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .alloc = alloc, .session = session };
        try self.build();
        try self.appendOutput("Terminal backend: GtkTextView fallback\n");
        try self.appendOutput(dependency_status ++ "\n");
        return self;
    }

    pub fn appendOutput(self: *Self, text: []const u8) !void {
        const priv = self.private();
        try priv.scrollback.appendSlice(priv.alloc, text);
        trimScrollback(&priv.scrollback);
        const z = try priv.alloc.dupeZ(u8, priv.scrollback.items);
        defer priv.alloc.free(z);
        priv.buffer.setText(z.ptr, @intCast(priv.scrollback.items.len));
        self.updateSizeEstimate();
    }

    fn build(self: *Self) !void {
        const root = gtk.Box.new(.vertical, 0);

        const toolbar = gtk.Box.new(.horizontal, 6);
        ui.margin4(toolbar.as(gtk.Widget), 6, 8, 6, 8);
        const copy = ui.iconButton("edit-copy-symbolic", "Copy selection (Ctrl+Shift+C)");
        _ = gtk.Button.signals.clicked.connect(copy, *Self, copyClicked, self, .{});
        toolbar.append(copy.as(gtk.Widget));
        const paste = ui.iconButton("edit-paste-symbolic", "Paste (Ctrl+Shift+V)");
        _ = gtk.Button.signals.clicked.connect(paste, *Self, pasteClicked, self, .{});
        toolbar.append(paste.as(gtk.Widget));
        self.private().size_label = ui.dim("80x24");
        self.private().size_label.as(gtk.Widget).setHexpand(1);
        toolbar.append(self.private().size_label.as(gtk.Widget));
        root.append(toolbar.as(gtk.Widget));

        self.private().buffer = gtk.TextBuffer.new(null);
        self.private().view = gtk.TextView.new();
        self.private().view.setBuffer(self.private().buffer);
        self.private().view.setEditable(0);
        self.private().view.setCursorVisible(1);
        self.private().view.setMonospace(1);
        self.private().view.setWrapMode(.char);
        self.private().view.as(gtk.Widget).addCssClass("monospace");

        const controller = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(controller, *Self, keyPressed, self, .{});
        self.private().view.as(gtk.Widget).addController(controller.as(gtk.EventController));

        const scroll = ui.scrolled(self.private().view.as(gtk.Widget));
        scroll.setPolicy(.automatic, .automatic);
        scroll.as(gtk.Widget).setVexpand(1);
        root.append(scroll.as(gtk.Widget));

        const input = gtk.Box.new(.horizontal, 8);
        ui.margin(input.as(gtk.Widget), 8);
        self.private().entry = gtk.Entry.new();
        self.private().entry.setPlaceholderText("Send text to terminal session");
        self.private().entry.as(gtk.Widget).setHexpand(1);
        _ = gtk.Entry.signals.activate.connect(self.private().entry, *Self, entryActivated, self, .{});
        input.append(self.private().entry.as(gtk.Widget));
        const send = ui.iconButton("mail-send-symbolic", "Send");
        _ = gtk.Button.signals.clicked.connect(send, *Self, sendClicked, self, .{});
        input.append(send.as(gtk.Widget));
        root.append(input.as(gtk.Widget));

        self.as(adw.Bin).setChild(root.as(gtk.Widget));
    }

    fn sendInput(self: *Self) void {
        const text = std.mem.span(self.private().entry.as(gtk.Editable).getText());
        if (text.len == 0) return;
        self.sendText(text);
        self.private().entry.as(gtk.Editable).setText("");
    }

    fn sendText(self: *Self, text: []const u8) void {
        if (self.private().session) |session| {
            smithers.c.smithers_session_send_text(session, text.ptr, text.len);
        }
        self.appendOutput(text) catch {};
        self.appendOutput("\n") catch {};
    }

    fn copySelection(self: *Self) void {
        const priv = self.private();
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        if (priv.buffer.getSelectionBounds(&start, &end) == 0) return;
        const ptr = priv.buffer.getText(&start, &end, 1);
        defer glib.free(ptr);
        const display = gdk.Display.getDefault() orelse return;
        display.getClipboard().setText(ptr);
    }

    fn pasteFromClipboard(self: *Self) void {
        const display = gdk.Display.getDefault() orelse return;
        const request = self.private().alloc.create(PasteRequest) catch return;
        request.* = .{ .surface = self.ref() };
        display.getClipboard().readTextAsync(null, clipboardReadText, request);
    }

    fn updateSizeEstimate(self: *Self) void {
        const priv = self.private();
        const widget = priv.view.as(gtk.Widget);
        const width: usize = @intCast(@max(widget.getAllocatedWidth(), 1));
        const height: usize = @intCast(@max(widget.getAllocatedHeight(), 1));
        const cols = @max(@as(usize, 20), width / 8);
        const rows = @max(@as(usize, 4), height / 17);
        if (cols == priv.cols and rows == priv.rows) return;
        priv.cols = cols;
        priv.rows = rows;
        const z = std.fmt.allocPrintSentinel(priv.alloc, "{d}x{d}", .{ cols, rows }, 0) catch return;
        defer priv.alloc.free(z);
        priv.size_label.setText(z.ptr);
        self.reportResize();
    }

    fn reportResize(self: *Self) void {
        if (self.private().session) |session| {
            const msg = std.fmt.allocPrint(self.private().alloc, "\x1b]777;smithers-resize;{d};{d}\x07", .{
                self.private().rows,
                self.private().cols,
            }) catch return;
            defer self.private().alloc.free(msg);
            smithers.c.smithers_session_send_text(session, msg.ptr, msg.len);
        }
    }

    fn sendClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.sendInput();
    }

    fn entryActivated(_: *gtk.Entry, self: *Self) callconv(.c) void {
        self.sendInput();
    }

    fn copyClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.copySelection();
    }

    fn pasteClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.pasteFromClipboard();
    }

    fn keyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        mods: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        if (mods.control_mask and mods.shift_mask and (keyval == gdk.KEY_c or keyval == gdk.KEY_C)) {
            self.copySelection();
            return 1;
        }
        if (mods.control_mask and mods.shift_mask and (keyval == gdk.KEY_v or keyval == gdk.KEY_V)) {
            self.pasteFromClipboard();
            return 1;
        }
        return 0;
    }

    fn clipboardReadText(source: ?*gobject.Object, res: *gio.AsyncResult, userdata: ?*anyopaque) callconv(.c) void {
        const request: *PasteRequest = @ptrCast(@alignCast(userdata orelse return));
        const self = request.surface;
        const alloc = self.private().alloc;
        defer self.unref();
        defer alloc.destroy(request);

        const clipboard = gobject.ext.cast(gdk.Clipboard, source orelse return) orelse return;
        var err: ?*glib.Error = null;
        const cstr_ = clipboard.readTextFinish(res, &err);
        if (err) |e| {
            e.free();
            return;
        }
        const cstr = cstr_ orelse return;
        defer glib.free(cstr);
        self.sendText(std.mem.span(cstr));
    }

    const PasteRequest = struct {
        surface: *Self,
    };

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            priv.scrollback.deinit(priv.alloc);
            priv.buffer.unref();
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

fn trimScrollback(scrollback: *std.ArrayList(u8)) void {
    if (scrollback.items.len <= max_scrollback_bytes) return;
    const extra = scrollback.items.len - max_scrollback_bytes;
    var trim_at = extra;
    while (trim_at < scrollback.items.len and scrollback.items[trim_at] != '\n') : (trim_at += 1) {}
    if (trim_at < scrollback.items.len) trim_at += 1;
    std.mem.copyForwards(u8, scrollback.items[0 .. scrollback.items.len - trim_at], scrollback.items[trim_at..]);
    scrollback.shrinkRetainingCapacity(scrollback.items.len - trim_at);
}
