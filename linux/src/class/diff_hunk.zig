const std = @import("std");
const gtk = @import("gtk");

const diff_parser = @import("../features/diff_parser.zig");
const ui = @import("../ui.zig");

pub const RenderOptions = struct {
    side_by_side: bool = false,
    context_limit: ?usize = null,
    focused: bool = false,
    syntax_class: [:0]const u8 = "source-plain",
};

pub fn hunkWidget(alloc: std.mem.Allocator, hunk: diff_parser.Hunk) !*gtk.Widget {
    return hunkWidgetWithOptions(alloc, hunk, .{});
}

pub fn hunkWidgetWithOptions(alloc: std.mem.Allocator, hunk: diff_parser.Hunk, options: RenderOptions) !*gtk.Widget {
    const root = gtk.Box.new(.vertical, 0);
    root.append((try headerRow(alloc, hunk.header, options.focused)).as(gtk.Widget));
    for (hunk.lines.items, 0..) |line, index| {
        if (!shouldShowLine(hunk, index, options.context_limit)) continue;
        root.append((if (options.side_by_side)
            try sideBySideLineRow(alloc, line, options.syntax_class)
        else
            try lineRow(alloc, line, options.syntax_class)).as(gtk.Widget));
    }
    return root.as(gtk.Widget);
}

fn headerRow(alloc: std.mem.Allocator, header: []const u8, focused: bool) !*gtk.Widget {
    const row = gtk.Box.new(.horizontal, 0);
    row.as(gtk.Widget).addCssClass("diff-hunk");
    if (focused) row.as(gtk.Widget).addCssClass("accent");
    ui.margin4(row.as(gtk.Widget), 2, 8, 2, 8);
    const gutter = ui.label("...", "dim-label");
    gutter.setWidthChars(9);
    row.append(gutter.as(gtk.Widget));
    const header_z = try alloc.dupeZ(u8, header);
    defer alloc.free(header_z);
    const label = ui.label(header_z, "monospace");
    label.setWrap(0);
    label.setSelectable(1);
    row.append(label.as(gtk.Widget));
    return row.as(gtk.Widget);
}

fn lineRow(alloc: std.mem.Allocator, line: diff_parser.Line, syntax_class: [:0]const u8) !*gtk.Widget {
    const row = gtk.Box.new(.horizontal, 0);
    row.as(gtk.Widget).addCssClass(kindCss(line.kind));
    ui.margin4(row.as(gtk.Widget), 1, 8, 1, 8);

    row.append((try numberLabel(alloc, line.old_line_number)).as(gtk.Widget));
    row.append((try numberLabel(alloc, line.new_line_number)).as(gtk.Widget));

    const prefix_z = try alloc.dupeZ(u8, switch (line.kind) {
        .addition => "+",
        .deletion => "-",
        .context => " ",
    });
    defer alloc.free(prefix_z);
    const prefix = ui.label(prefix_z, "monospace");
    prefix.setWidthChars(2);
    row.append(prefix.as(gtk.Widget));

    const text = try sourceLabel(alloc, line.text, syntax_class);
    text.as(gtk.Widget).setHexpand(1);
    row.append(text.as(gtk.Widget));
    return row.as(gtk.Widget);
}

fn sideBySideLineRow(alloc: std.mem.Allocator, line: diff_parser.Line, syntax_class: [:0]const u8) !*gtk.Widget {
    const row = gtk.Box.new(.horizontal, 0);
    row.as(gtk.Widget).addCssClass(kindCss(line.kind));
    ui.margin4(row.as(gtk.Widget), 1, 8, 1, 8);

    const left_text = if (line.kind == .addition) "" else line.text;
    const right_text = if (line.kind == .deletion) "" else line.text;

    row.append((try numberLabel(alloc, line.old_line_number)).as(gtk.Widget));
    const left = try sourceLabel(alloc, left_text, syntax_class);
    left.setWidthChars(48);
    left.as(gtk.Widget).setHexpand(1);
    row.append(left.as(gtk.Widget));

    row.append((try numberLabel(alloc, line.new_line_number)).as(gtk.Widget));
    const right = try sourceLabel(alloc, right_text, syntax_class);
    right.setWidthChars(48);
    right.as(gtk.Widget).setHexpand(1);
    row.append(right.as(gtk.Widget));
    return row.as(gtk.Widget);
}

fn sourceLabel(alloc: std.mem.Allocator, text: []const u8, syntax_class: [:0]const u8) !*gtk.Label {
    const text_z = try alloc.dupeZ(u8, text);
    defer alloc.free(text_z);
    const label = ui.label(text_z, "monospace");
    label.as(gtk.Widget).addCssClass(syntax_class.ptr);
    label.setWrap(0);
    label.setSelectable(1);
    return label;
}

fn numberLabel(alloc: std.mem.Allocator, value: ?usize) !*gtk.Label {
    const z = if (value) |number| try std.fmt.allocPrintSentinel(alloc, "{d}", .{number}, 0) else try alloc.dupeZ(u8, "");
    defer alloc.free(z);
    const label = ui.label(z, "dim-label");
    label.as(gtk.Widget).addCssClass("monospace");
    label.setWidthChars(5);
    label.setXalign(1);
    return label;
}

fn shouldShowLine(hunk: diff_parser.Hunk, index: usize, context_limit: ?usize) bool {
    const limit = context_limit orelse return true;
    if (index >= hunk.lines.items.len) return false;
    if (hunk.lines.items[index].kind != .context) return true;

    var distance: usize = 0;
    var left = index;
    while (left > 0 and distance <= limit) {
        left -= 1;
        distance += 1;
        if (hunk.lines.items[left].kind != .context) return true;
    }

    distance = 0;
    var right = index + 1;
    while (right < hunk.lines.items.len and distance < limit) : (right += 1) {
        distance += 1;
        if (hunk.lines.items[right].kind != .context) return true;
    }
    return false;
}

fn kindCss(kind: diff_parser.LineKind) [:0]const u8 {
    return switch (kind) {
        .addition => "diff-add",
        .deletion => "diff-del",
        .context => "diff-context",
    };
}
