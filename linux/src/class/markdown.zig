const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

pub const MarkdownBlock = union(enum) {
    heading: struct { level: u8, text: []u8 },
    paragraph: []u8,
    code_block: struct { language: ?[]u8, code: []u8 },
    unordered_list: std.ArrayList([]u8),
    ordered_list: std.ArrayList([]u8),
    blockquote: []u8,
    table: std.ArrayList(std.ArrayList([]u8)),
    image: struct { alt: []u8, source: []u8 },
    horizontal_rule,

    pub fn deinit(self: *MarkdownBlock, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .heading => |h| alloc.free(h.text),
            .paragraph => |text| alloc.free(text),
            .code_block => |code| {
                if (code.language) |language| alloc.free(language);
                alloc.free(code.code);
            },
            .unordered_list, .ordered_list => |*items| {
                for (items.items) |item| alloc.free(item);
                items.deinit(alloc);
            },
            .blockquote => |text| alloc.free(text),
            .table => |*rows| {
                for (rows.items) |*row| {
                    for (row.items) |cell| alloc.free(cell);
                    row.deinit(alloc);
                }
                rows.deinit(alloc);
            },
            .image => |image| {
                alloc.free(image.alt);
                alloc.free(image.source);
            },
            .horizontal_rule => {},
        }
    }
};

pub fn parseBlocks(alloc: std.mem.Allocator, text: []const u8) !std.ArrayList(MarkdownBlock) {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(alloc);
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| try lines.append(alloc, std.mem.trimRight(u8, line, "\r"));

    var blocks = std.ArrayList(MarkdownBlock).empty;
    errdefer {
        for (blocks.items) |*block| block.deinit(alloc);
        blocks.deinit(alloc);
    }

    var index: usize = 0;
    while (index < lines.items.len) {
        const line = lines.items[index];
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            index += 1;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "```")) {
            const language_raw = std.mem.trim(u8, trimmed[3..], &std.ascii.whitespace);
            var writer: std.Io.Writer.Allocating = try .initCapacity(alloc, 256);
            defer writer.deinit();
            index += 1;
            while (index < lines.items.len) : (index += 1) {
                const candidate = std.mem.trim(u8, lines.items[index], &std.ascii.whitespace);
                if (std.mem.startsWith(u8, candidate, "```")) {
                    index += 1;
                    break;
                }
                if (writer.writer.end > 0) try writer.writer.writeByte('\n');
                try writer.writer.writeAll(lines.items[index]);
            }
            try blocks.append(alloc, .{
                .code_block = .{
                    .language = if (language_raw.len > 0) try alloc.dupe(u8, language_raw) else null,
                    .code = try writer.toOwnedSlice(),
                },
            });
            continue;
        }

        if (parseHeading(trimmed)) |heading| {
            try blocks.append(alloc, .{
                .heading = .{
                    .level = heading.level,
                    .text = try alloc.dupe(u8, heading.text),
                },
            });
            index += 1;
            continue;
        }

        if (isHorizontalRule(trimmed)) {
            try blocks.append(alloc, .horizontal_rule);
            index += 1;
            continue;
        }

        if (parseImage(trimmed)) |image| {
            try blocks.append(alloc, .{
                .image = .{
                    .alt = try alloc.dupe(u8, image.alt),
                    .source = try alloc.dupe(u8, image.source),
                },
            });
            index += 1;
            continue;
        }

        if (isTableStart(lines.items, index)) {
            var table = std.ArrayList(std.ArrayList([]u8)).empty;
            errdefer {
                for (table.items) |*row| {
                    for (row.items) |cell| alloc.free(cell);
                    row.deinit(alloc);
                }
                table.deinit(alloc);
            }

            try table.append(alloc, try splitTableRow(alloc, lines.items[index]));
            index += 2; // Skip the header separator.
            while (index < lines.items.len) : (index += 1) {
                const row_line = std.mem.trim(u8, lines.items[index], &std.ascii.whitespace);
                if (row_line.len == 0 or std.mem.indexOfScalar(u8, row_line, '|') == null) break;
                try table.append(alloc, try splitTableRow(alloc, row_line));
            }
            try blocks.append(alloc, .{ .table = table });
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, ">")) {
            var writer: std.Io.Writer.Allocating = try .initCapacity(alloc, 128);
            defer writer.deinit();
            while (index < lines.items.len) : (index += 1) {
                const quote = std.mem.trim(u8, lines.items[index], &std.ascii.whitespace);
                if (!std.mem.startsWith(u8, quote, ">")) break;
                const body = std.mem.trimLeft(u8, quote[1..], &std.ascii.whitespace);
                if (writer.writer.end > 0) try writer.writer.writeByte(' ');
                try writer.writer.writeAll(body);
            }
            try blocks.append(alloc, .{ .blockquote = try writer.toOwnedSlice() });
            continue;
        }

        if (unorderedItem(trimmed)) |item_text| {
            var items = std.ArrayList([]u8).empty;
            errdefer {
                for (items.items) |item| alloc.free(item);
                items.deinit(alloc);
            }
            while (index < lines.items.len) : (index += 1) {
                const item = unorderedItem(std.mem.trim(u8, lines.items[index], &std.ascii.whitespace)) orelse break;
                try items.append(alloc, try alloc.dupe(u8, item));
            }
            _ = item_text;
            try blocks.append(alloc, .{ .unordered_list = items });
            continue;
        }

        if (orderedItem(trimmed)) |item_text| {
            var items = std.ArrayList([]u8).empty;
            errdefer {
                for (items.items) |item| alloc.free(item);
                items.deinit(alloc);
            }
            while (index < lines.items.len) : (index += 1) {
                const item = orderedItem(std.mem.trim(u8, lines.items[index], &std.ascii.whitespace)) orelse break;
                try items.append(alloc, try alloc.dupe(u8, item));
            }
            _ = item_text;
            try blocks.append(alloc, .{ .ordered_list = items });
            continue;
        }

        var paragraph: std.Io.Writer.Allocating = try .initCapacity(alloc, 256);
        defer paragraph.deinit();
        while (index < lines.items.len) : (index += 1) {
            const part = std.mem.trim(u8, lines.items[index], &std.ascii.whitespace);
            if (part.len == 0 or std.mem.startsWith(u8, part, "```") or parseHeading(part) != null or
                isHorizontalRule(part) or std.mem.startsWith(u8, part, ">") or unorderedItem(part) != null or
                orderedItem(part) != null or parseImage(part) != null or isTableStart(lines.items, index))
            {
                break;
            }
            if (paragraph.writer.end > 0) try paragraph.writer.writeByte('\n');
            try paragraph.writer.writeAll(part);
        }
        try blocks.append(alloc, .{ .paragraph = try paragraph.toOwnedSlice() });
    }

    return blocks;
}

pub const MarkdownSurface = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersMarkdownSurface",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        body: *gtk.Box = undefined,
        content: []u8 = &.{},
        blocks: std.ArrayList(MarkdownBlock) = .empty,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, content: []const u8) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{
            .alloc = alloc,
            .content = try alloc.dupe(u8, content),
        };
        try self.build();
        try self.render();
        return self;
    }

    pub fn setMarkdown(self: *Self, content: []const u8) !void {
        const priv = self.private();
        const owned = try priv.alloc.dupe(u8, content);
        priv.alloc.free(priv.content);
        priv.content = owned;
        try self.render();
    }

    fn build(self: *Self) !void {
        const body = gtk.Box.new(.vertical, 10);
        ui.margin(body.as(gtk.Widget), 18);
        self.private().body = body;
        const scroll = ui.scrolled(body.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        self.as(adw.Bin).setChild(scroll.as(gtk.Widget));
    }

    fn render(self: *Self) !void {
        const priv = self.private();
        clearBlocks(priv);
        ui.clearBox(priv.body);
        priv.blocks = try parseBlocks(priv.alloc, priv.content);

        if (priv.blocks.items.len == 0) {
            priv.body.append(ui.dim("No markdown content").as(gtk.Widget));
            return;
        }

        for (priv.blocks.items) |block| {
            priv.body.append((try renderBlock(priv.alloc, block)).as(gtk.Widget));
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            priv.alloc.free(priv.content);
            clearBlocks(priv);
            priv.blocks.deinit(priv.alloc);
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

pub fn renderBlock(alloc: std.mem.Allocator, block: MarkdownBlock) !*gtk.Widget {
    switch (block) {
        .heading => |heading| {
            const z = try alloc.dupeZ(u8, heading.text);
            defer alloc.free(z);
            const label = if (heading.level <= 2) ui.heading(z) else ui.label(z, "heading");
            label.setSelectable(1);
            return label.as(gtk.Widget);
        },
        .paragraph => |text| return (try renderInlineLabel(alloc, text, null)).as(gtk.Widget),
        .code_block => |code| return try renderCodeBlock(alloc, code.language, code.code),
        .unordered_list => |items| return try renderList(alloc, items.items, false),
        .ordered_list => |items| return try renderList(alloc, items.items, true),
        .blockquote => |text| {
            const box = gtk.Box.new(.horizontal, 8);
            box.as(gtk.Widget).addCssClass("blockquote");
            const bar = gtk.Separator.new(.vertical);
            box.append(bar.as(gtk.Widget));
            box.append((try renderInlineLabel(alloc, text, null)).as(gtk.Widget));
            return box.as(gtk.Widget);
        },
        .table => |rows| return try renderTable(alloc, rows.items),
        .image => |image| return try renderImage(alloc, image.alt, image.source),
        .horizontal_rule => return gtk.Separator.new(.horizontal).as(gtk.Widget),
    }
}

pub fn renderInlineLabel(alloc: std.mem.Allocator, text: []const u8, css: ?[:0]const u8) !*gtk.Label {
    const markup = try inlineMarkdownToPango(alloc, text);
    defer alloc.free(markup);
    const label = gtk.Label.new(null);
    label.setXalign(0);
    label.setWrap(1);
    label.setWrapMode(.word_char);
    label.setSelectable(1);
    if (css) |class| label.as(gtk.Widget).addCssClass(class.ptr);
    label.setMarkup(markup.ptr);
    return label;
}

fn renderCodeBlock(alloc: std.mem.Allocator, language: ?[]const u8, code: []const u8) !*gtk.Widget {
    const root = gtk.Box.new(.vertical, 6);
    root.as(gtk.Widget).addCssClass("card");
    ui.margin(root.as(gtk.Widget), 10);

    if (language) |lang| {
        const lang_z = try alloc.dupeZ(u8, lang);
        defer alloc.free(lang_z);
        const lang_label = ui.label(lang_z, "dim-label");
        lang_label.as(gtk.Widget).addCssClass("monospace");
        root.append(lang_label.as(gtk.Widget));
    }

    const z = try alloc.dupeZ(u8, code);
    defer alloc.free(z);
    const label = ui.label(z, null);
    label.as(gtk.Widget).addCssClass("monospace");
    label.setSelectable(1);
    root.append(label.as(gtk.Widget));
    return root.as(gtk.Widget);
}

fn renderList(alloc: std.mem.Allocator, items: []const []u8, ordered: bool) !*gtk.Widget {
    const box = gtk.Box.new(.vertical, 4);
    for (items, 0..) |item, index| {
        const row = gtk.Box.new(.horizontal, 8);
        const marker_text = if (ordered) try std.fmt.allocPrintSentinel(alloc, "{d}.", .{index + 1}, 0) else try alloc.dupeZ(u8, "*");
        defer alloc.free(marker_text);
        const marker = ui.label(marker_text, "dim-label");
        marker.setWidthChars(3);
        row.append(marker.as(gtk.Widget));
        row.append((try renderInlineLabel(alloc, item, null)).as(gtk.Widget));
        box.append(row.as(gtk.Widget));
    }
    return box.as(gtk.Widget);
}

fn renderTable(alloc: std.mem.Allocator, rows: []const std.ArrayList([]u8)) !*gtk.Widget {
    const box = gtk.Box.new(.vertical, 0);
    box.as(gtk.Widget).addCssClass("card");
    for (rows, 0..) |row_items, row_index| {
        const row = gtk.Box.new(.horizontal, 0);
        row.as(gtk.Widget).addCssClass(if (row_index == 0) "heading" else "dim-label");
        for (row_items.items) |cell| {
            const label = try renderInlineLabel(alloc, cell, null);
            label.setWidthChars(14);
            label.setWrap(1);
            ui.margin4(label.as(gtk.Widget), 6, 8, 6, 8);
            row.append(label.as(gtk.Widget));
        }
        box.append(row.as(gtk.Widget));
    }
    return box.as(gtk.Widget);
}

fn renderImage(alloc: std.mem.Allocator, alt: []const u8, source: []const u8) !*gtk.Widget {
    const box = gtk.Box.new(.horizontal, 8);
    box.as(gtk.Widget).addCssClass("card");
    ui.margin(box.as(gtk.Widget), 10);
    const icon = gtk.Image.newFromIconName("image-x-generic-symbolic");
    icon.setPixelSize(28);
    box.append(icon.as(gtk.Widget));

    const text = if (alt.len > 0)
        try std.fmt.allocPrint(alloc, "{s} - {s}", .{ alt, source })
    else
        try alloc.dupe(u8, source);
    defer alloc.free(text);
    box.append((try renderInlineLabel(alloc, text, "dim-label")).as(gtk.Widget));
    return box.as(gtk.Widget);
}

fn clearBlocks(priv: anytype) void {
    for (priv.blocks.items) |*block| block.deinit(priv.alloc);
    priv.blocks.clearRetainingCapacity();
}

fn parseHeading(line: []const u8) ?struct { level: u8, text: []const u8 } {
    var level: usize = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 6 or level >= line.len or line[level] != ' ') return null;
    return .{ .level = @intCast(level), .text = std.mem.trim(u8, line[level + 1 ..], &std.ascii.whitespace) };
}

fn isHorizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const ch = line[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (line) |candidate| if (candidate != ch) return false;
    return true;
}

fn unorderedItem(line: []const u8) ?[]const u8 {
    if (line.len < 2) return null;
    if ((line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') return line[2..];
    return null;
}

fn orderedItem(line: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < line.len and std.ascii.isDigit(line[index])) index += 1;
    if (index == 0 or index + 1 >= line.len) return null;
    if (line[index] != '.' or line[index + 1] != ' ') return null;
    return line[index + 2 ..];
}

fn parseImage(line: []const u8) ?struct { alt: []const u8, source: []const u8 } {
    if (!std.mem.startsWith(u8, line, "![")) return null;
    const close = std.mem.indexOf(u8, line, "](") orelse return null;
    if (line.len == 0 or line[line.len - 1] != ')') return null;
    return .{ .alt = line[2..close], .source = line[close + 2 .. line.len - 1] };
}

fn isTableStart(lines: []const []const u8, index: usize) bool {
    if (index + 1 >= lines.len) return false;
    const header = std.mem.trim(u8, lines[index], &std.ascii.whitespace);
    const separator = std.mem.trim(u8, lines[index + 1], &std.ascii.whitespace);
    if (std.mem.indexOfScalar(u8, header, '|') == null) return false;
    if (std.mem.indexOfScalar(u8, separator, '|') == null) return false;
    return isTableSeparator(separator);
}

fn isTableSeparator(line: []const u8) bool {
    var saw_dash = false;
    for (line) |ch| {
        switch (ch) {
            '|', '-', ':', ' ' => {
                if (ch == '-') saw_dash = true;
            },
            else => return false,
        }
    }
    return saw_dash;
}

fn splitTableRow(alloc: std.mem.Allocator, line: []const u8) !std.ArrayList([]u8) {
    var row = std.ArrayList([]u8).empty;
    errdefer {
        for (row.items) |cell| alloc.free(cell);
        row.deinit(alloc);
    }

    var raw = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (raw.len > 0 and raw[0] == '|') raw = raw[1..];
    if (raw.len > 0 and raw[raw.len - 1] == '|') raw = raw[0 .. raw.len - 1];

    var parts = std.mem.splitScalar(u8, raw, '|');
    while (parts.next()) |part| {
        try row.append(alloc, try alloc.dupe(u8, std.mem.trim(u8, part, &std.ascii.whitespace)));
    }
    return row;
}

pub fn inlineMarkdownToPango(alloc: std.mem.Allocator, markdown: []const u8) ![:0]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, markdown.len + 64);
    defer out.deinit();
    const writer = &out.writer;

    var i: usize = 0;
    while (i < markdown.len) {
        if (markdown[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, markdown, i + 1, '`')) |end| {
                try writer.writeAll("<tt>");
                try appendEscaped(writer, markdown[i + 1 .. end]);
                try writer.writeAll("</tt>");
                i = end + 1;
                continue;
            }
        }

        if (i + 1 < markdown.len and markdown[i] == '*' and markdown[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, markdown, i + 2, "**")) |end| {
                try writer.writeAll("<b>");
                try appendEscaped(writer, markdown[i + 2 .. end]);
                try writer.writeAll("</b>");
                i = end + 2;
                continue;
            }
        }

        if (markdown[i] == '*' and (i + 1 >= markdown.len or markdown[i + 1] != '*')) {
            if (std.mem.indexOfScalarPos(u8, markdown, i + 1, '*')) |end| {
                try writer.writeAll("<i>");
                try appendEscaped(writer, markdown[i + 1 .. end]);
                try writer.writeAll("</i>");
                i = end + 1;
                continue;
            }
        }

        if (markdown[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, markdown, i + 1, ']')) |close_label| {
                if (close_label + 1 < markdown.len and markdown[close_label + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, markdown, close_label + 2, ')')) |close_url| {
                        const label = markdown[i + 1 .. close_label];
                        const url = markdown[close_label + 2 .. close_url];
                        try writer.writeAll("<a href=\"");
                        try appendEscapedAttr(writer, url);
                        try writer.writeAll("\">");
                        try appendEscaped(writer, label);
                        try writer.writeAll("</a>");
                        i = close_url + 1;
                        continue;
                    }
                }
            }
        }

        try appendEscaped(writer, markdown[i .. i + 1]);
        i += 1;
    }

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

fn appendEscapedAttr(writer: *std.Io.Writer, text: []const u8) !void {
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

test "markdown parser recognizes tables and images" {
    var blocks = try parseBlocks(std.testing.allocator,
        \\![Alt](image.png)
        \\
        \\| A | B |
        \\| - | - |
        \\| 1 | 2 |
    );
    defer {
        for (blocks.items) |*block| block.deinit(std.testing.allocator);
        blocks.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), blocks.items.len);
    try std.testing.expect(switch (blocks.items[0]) {
        .image => true,
        else => false,
    });
    try std.testing.expect(switch (blocks.items[1]) {
        .table => true,
        else => false,
    });
}
