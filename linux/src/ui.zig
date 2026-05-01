const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

pub fn widget(obj: anytype) *gtk.Widget {
    return obj.as(gtk.Widget);
}

pub fn object(obj: anytype) *gobject.Object {
    return obj.as(gobject.Object);
}

pub fn margin(w: *gtk.Widget, value: c_int) void {
    w.setMarginTop(value);
    w.setMarginBottom(value);
    w.setMarginStart(value);
    w.setMarginEnd(value);
}

pub fn margin4(w: *gtk.Widget, top: c_int, end: c_int, bottom: c_int, start: c_int) void {
    w.setMarginTop(top);
    w.setMarginBottom(bottom);
    w.setMarginStart(start);
    w.setMarginEnd(end);
}

pub fn label(text: [:0]const u8, css: ?[:0]const u8) *gtk.Label {
    const l = gtk.Label.new(text.ptr);
    l.setXalign(0);
    l.setWrap(1);
    l.setWrapMode(.word_char);
    if (css) |class| l.as(gtk.Widget).addCssClass(class.ptr);
    return l;
}

pub fn heading(text: [:0]const u8) *gtk.Label {
    const l = label(text, "title-2");
    l.setWrap(0);
    return l;
}

pub fn dim(text: [:0]const u8) *gtk.Label {
    return label(text, "dim-label");
}

pub fn iconButton(icon_name: [:0]const u8, tooltip: [:0]const u8) *gtk.Button {
    const button = gtk.Button.newFromIconName(icon_name.ptr);
    button.as(gtk.Widget).addCssClass("flat");
    button.as(gtk.Widget).setTooltipText(tooltip.ptr);
    return button;
}

pub fn textButton(text: [:0]const u8, suggested: bool) *gtk.Button {
    const button = gtk.Button.newWithLabel(text.ptr);
    if (suggested) button.as(gtk.Widget).addCssClass("suggested-action");
    return button;
}

pub fn scrolled(child: *gtk.Widget) *gtk.ScrolledWindow {
    const scroll = gtk.ScrolledWindow.new();
    scroll.setPolicy(.never, .automatic);
    scroll.setChild(child);
    return scroll;
}

pub fn clamped(child: *gtk.Widget) *adw.Clamp {
    const clamp = adw.Clamp.new();
    clamp.setChild(child);
    clamp.setMaximumSize(850);
    return clamp;
}

pub fn row(alloc: std.mem.Allocator, icon_name: [:0]const u8, title: []const u8, subtitle: ?[]const u8) !*adw.ActionRow {
    const list_row = adw.ActionRow.new();
    list_row.as(gtk.ListBoxRow).setActivatable(1);

    const title_z = try alloc.dupeZ(u8, title);
    defer alloc.free(title_z);
    list_row.as(adw.PreferencesRow).setTitle(title_z.ptr);

    if (subtitle) |subtitle_text| {
        const subtitle_z = try alloc.dupeZ(u8, subtitle_text);
        defer alloc.free(subtitle_z);
        list_row.setSubtitle(subtitle_z.ptr);
        list_row.setSubtitleLines(2);
    }

    const image = gtk.Image.newFromIconName(icon_name.ptr);
    image.setPixelSize(20);
    image.as(gtk.Widget).setValign(.center);
    list_row.addPrefix(image.as(gtk.Widget));

    return list_row;
}

pub fn clearBox(box: *gtk.Box) void {
    while (box.as(gtk.Widget).getFirstChild()) |child| {
        box.remove(child);
    }
}

pub fn clearList(list: *gtk.ListBox) void {
    list.removeAll();
}

pub fn setIndex(obj: *gobject.Object, index: usize) void {
    obj.setData("smithers-index", @ptrFromInt(index + 1));
}

pub fn getIndex(obj: *gobject.Object) ?usize {
    const ptr = obj.getData("smithers-index") orelse return null;
    const raw = @intFromPtr(ptr);
    if (raw == 0) return null;
    return raw - 1;
}

pub fn markdownLabel(alloc: std.mem.Allocator, markdown: []const u8) !*gtk.Label {
    const markup = try markdownToPango(alloc, markdown);
    defer alloc.free(markup);
    const l = gtk.Label.new(null);
    l.setXalign(0);
    l.setWrap(1);
    l.setWrapMode(.word_char);
    l.setSelectable(1);
    l.setMarkup(markup.ptr);
    return l;
}

pub fn markdownToPango(alloc: std.mem.Allocator, markdown: []const u8) ![:0]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, markdown.len + 64);
    defer out.deinit();
    const writer = &out.writer;

    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var in_code = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) {
            if (in_code) {
                try writer.writeAll("</tt>\n");
            } else {
                try writer.writeAll("<tt>");
            }
            in_code = !in_code;
            continue;
        }
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (!in_code and std.mem.startsWith(u8, trimmed, "# ")) {
            try writer.writeAll("<b>");
            try appendEscaped(writer, trimmed[2..]);
            try writer.writeAll("</b>\n");
        } else if (!in_code and std.mem.startsWith(u8, trimmed, "## ")) {
            try writer.writeAll("<b>");
            try appendEscaped(writer, trimmed[3..]);
            try writer.writeAll("</b>\n");
        } else if (!in_code and std.mem.startsWith(u8, trimmed, "- ")) {
            try writer.writeAll("* ");
            try appendEscaped(writer, trimmed[2..]);
            try writer.writeAll("\n");
        } else {
            try appendEscaped(writer, trimmed);
            try writer.writeAll("\n");
        }
    }

    if (in_code) try writer.writeAll("</tt>");
    return try out.toOwnedSliceSentinel(0);
}

fn appendEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(ch),
        }
    }
}

test "markdown to pango escapes and formats basics" {
    const alloc = std.testing.allocator;
    const out = try markdownToPango(alloc, "# Hi\n- <ok>");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<b>Hi</b>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "&lt;ok&gt;") != null);
}
