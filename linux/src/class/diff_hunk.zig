const std = @import("std");
const gtk = @import("gtk");

const diff_parser = @import("../features/diff_parser.zig");
const ui = @import("../ui.zig");

pub fn hunkWidget(alloc: std.mem.Allocator, hunk: diff_parser.Hunk) !*gtk.Widget {
    const root = gtk.Box.new(.vertical, 0);
    root.append((try headerRow(alloc, hunk.header)).as(gtk.Widget));
    for (hunk.lines.items) |line| {
        root.append((try lineRow(alloc, line)).as(gtk.Widget));
    }
    return root.as(gtk.Widget);
}

fn headerRow(alloc: std.mem.Allocator, header: []const u8) !*gtk.Widget {
    const row = gtk.Box.new(.horizontal, 0);
    row.as(gtk.Widget).addCssClass("diff-hunk");
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

fn lineRow(alloc: std.mem.Allocator, line: diff_parser.Line) !*gtk.Widget {
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

    const text_z = try alloc.dupeZ(u8, line.text);
    defer alloc.free(text_z);
    const text = ui.label(text_z, "monospace");
    text.setWrap(0);
    text.setSelectable(1);
    text.as(gtk.Widget).setHexpand(1);
    row.append(text.as(gtk.Widget));
    return row.as(gtk.Widget);
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

fn kindCss(kind: diff_parser.LineKind) [:0]const u8 {
    return switch (kind) {
        .addition => "diff-add",
        .deletion => "diff-del",
        .context => "diff-context",
    };
}
