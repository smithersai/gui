const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");

const Value = std.json.Value;

pub const JsonValue = union(enum) {
    string: []const u8,
    optional_string: ?[]const u8,
    integer: i64,
    boolean: bool,
    raw: []const u8,
    null,
};

pub const JsonField = struct {
    key: []const u8,
    value: JsonValue,
};

pub const ItemSpec = struct {
    id: []const []const u8,
    title: []const []const u8,
    subtitle: []const []const u8 = &.{},
    status: []const []const u8 = &.{},
    body: []const []const u8 = &.{},
    path: []const []const u8 = &.{},
    number: []const []const u8 = &.{},
    run_id: []const []const u8 = &.{},
    node_id: []const []const u8 = &.{},
    enabled: []const []const u8 = &.{},
    score: []const []const u8 = &.{},
};

pub const Item = struct {
    id: []u8,
    title: []u8,
    subtitle: ?[]u8 = null,
    status: ?[]u8 = null,
    body: ?[]u8 = null,
    path: ?[]u8 = null,
    number: ?i64 = null,
    run_id: ?[]u8 = null,
    node_id: ?[]u8 = null,
    iteration: ?i64 = null,
    enabled: ?bool = null,
    score: ?f64 = null,
    raw_json: ?[]u8 = null,

    pub fn deinit(self: *Item, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.title);
        if (self.subtitle) |v| alloc.free(v);
        if (self.status) |v| alloc.free(v);
        if (self.body) |v| alloc.free(v);
        if (self.path) |v| alloc.free(v);
        if (self.run_id) |v| alloc.free(v);
        if (self.node_id) |v| alloc.free(v);
        if (self.raw_json) |v| alloc.free(v);
    }
};

pub fn clearItems(alloc: std.mem.Allocator, items: *std.ArrayList(Item)) void {
    for (items.items) |*item| item.deinit(alloc);
    items.clearRetainingCapacity();
}

pub fn callJson(
    alloc: std.mem.Allocator,
    client: smithers.c.smithers_client_t,
    method: []const u8,
    fields: []const JsonField,
) ![]u8 {
    const args = try jsonObject(alloc, fields);
    defer alloc.free(args);
    return smithers.callJson(alloc, client, method, args);
}

pub fn jsonObject(alloc: std.mem.Allocator, fields: []const JsonField) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.beginObject();
    for (fields) |field| {
        try jw.objectField(field.key);
        switch (field.value) {
            .string => |value| try jw.write(value),
            .optional_string => |value| if (value) |text| try jw.write(text) else try jw.write(null),
            .integer => |value| try jw.write(value),
            .boolean => |value| try jw.write(value),
            .raw => |raw| {
                var parsed = try std.json.parseFromSlice(Value, alloc, raw, .{});
                defer parsed.deinit();
                try std.json.Stringify.value(parsed.value, .{}, &out.writer);
            },
            .null => try jw.write(null),
        }
    }
    try jw.endObject();
    return out.toOwnedSlice();
}

pub fn parseItems(
    alloc: std.mem.Allocator,
    json: []const u8,
    root_keys: []const []const u8,
    spec: ItemSpec,
) !std.ArrayList(Item) {
    var parsed = try std.json.parseFromSlice(Value, alloc, json, .{});
    defer parsed.deinit();

    var result: std.ArrayList(Item) = .empty;
    errdefer {
        clearItems(alloc, &result);
        result.deinit(alloc);
    }

    if (arrayFromRoot(&parsed.value, root_keys)) |items| {
        for (items, 0..) |*item_value, index| {
            if (try itemFromValue(alloc, item_value, spec, index)) |item| {
                try result.append(alloc, item);
            }
        }
    } else if (object(&parsed.value) != null) {
        if (try itemFromValue(alloc, &parsed.value, spec, 0)) |item| {
            try result.append(alloc, item);
        }
    }

    return result;
}

pub fn parseStringResult(alloc: std.mem.Allocator, json: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(Value, alloc, json, .{}) catch {
        return alloc.dupe(u8, json);
    };
    defer parsed.deinit();
    return try stringFromValue(alloc, &parsed.value);
}

pub fn rawJsonFieldString(alloc: std.mem.Allocator, raw_json: ?[]const u8, keys: []const []const u8) !?[]u8 {
    const raw = raw_json orelse return null;
    var parsed = try std.json.parseFromSlice(Value, alloc, raw, .{});
    defer parsed.deinit();
    const obj = object(&parsed.value) orelse return null;
    return try stringField(alloc, obj, keys);
}

pub fn rawJsonFieldValueString(alloc: std.mem.Allocator, raw_json: ?[]const u8, keys: []const []const u8) !?[]u8 {
    const raw = raw_json orelse return null;
    var parsed = try std.json.parseFromSlice(Value, alloc, raw, .{});
    defer parsed.deinit();
    const obj = object(&parsed.value) orelse return null;
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        var copy = value;
        const text = try stringFromValue(alloc, &copy);
        if (std.mem.trim(u8, text, &std.ascii.whitespace).len == 0) {
            alloc.free(text);
            continue;
        }
        return text;
    }
    return null;
}

pub fn rawJsonFieldJson(alloc: std.mem.Allocator, raw_json: ?[]const u8, keys: []const []const u8) !?[]u8 {
    const raw = raw_json orelse return null;
    var parsed = try std.json.parseFromSlice(Value, alloc, raw, .{});
    defer parsed.deinit();
    const obj = object(&parsed.value) orelse return null;
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        return try jsonValueAlloc(alloc, value);
    }
    return null;
}

pub fn openUrl(alloc: std.mem.Allocator, raw_url: []const u8) !void {
    const trimmed = std.mem.trim(u8, raw_url, &std.ascii.whitespace);
    if (trimmed.len == 0) return error.EmptyUrl;
    const z = try alloc.dupeZ(u8, trimmed);
    defer alloc.free(z);
    var err: ?*glib.Error = null;
    const ok = gio.AppInfo.launchDefaultForUri(z.ptr, null, &err);
    if (err) |e| {
        defer e.free();
        return error.OpenUrlFailed;
    }
    if (ok == 0) return error.OpenUrlFailed;
}

fn itemFromValue(alloc: std.mem.Allocator, value: *Value, spec: ItemSpec, index: usize) !?Item {
    const obj = object(value) orelse return null;

    const id = try stringField(alloc, obj, spec.id) orelse fallback: {
        if (try stringField(alloc, obj, spec.title)) |title_id| break :fallback title_id;
        break :fallback try std.fmt.allocPrint(alloc, "item-{d}", .{index + 1});
    };
    errdefer alloc.free(id);

    const title = try stringField(alloc, obj, spec.title) orelse try alloc.dupe(u8, id);
    errdefer alloc.free(title);

    const subtitle = try stringField(alloc, obj, spec.subtitle);
    errdefer if (subtitle) |v| alloc.free(v);
    const status = try stringField(alloc, obj, spec.status);
    errdefer if (status) |v| alloc.free(v);
    const body = try stringField(alloc, obj, spec.body);
    errdefer if (body) |v| alloc.free(v);
    const path = try stringField(alloc, obj, spec.path);
    errdefer if (path) |v| alloc.free(v);
    const run_id = try stringField(alloc, obj, spec.run_id);
    errdefer if (run_id) |v| alloc.free(v);
    const node_id = try stringField(alloc, obj, spec.node_id);
    errdefer if (node_id) |v| alloc.free(v);
    const raw_json = try jsonValueAlloc(alloc, value.*);
    errdefer alloc.free(raw_json);

    return .{
        .id = id,
        .title = title,
        .subtitle = subtitle,
        .status = status,
        .body = body,
        .path = path,
        .number = intField(obj, spec.number),
        .run_id = run_id,
        .node_id = node_id,
        .iteration = intField(obj, &.{ "iteration", "attempt" }),
        .enabled = boolField(obj, spec.enabled),
        .score = floatField(obj, spec.score),
        .raw_json = raw_json,
    };
}

pub fn arrayFromRoot(root: *Value, keys: []const []const u8) ?[]Value {
    switch (root.*) {
        .array => |array| return array.items,
        .object => |obj| {
            for (keys) |key| {
                if (obj.get(key)) |value| {
                    var value_copy = value;
                    if (arrayFromRoot(&value_copy, keys)) |array| return array;
                }
            }
        },
        else => {},
    }
    return null;
}

pub fn object(value: *Value) ?*std.json.ObjectMap {
    return switch (value.*) {
        .object => |*obj| obj,
        else => null,
    };
}

pub fn stringField(alloc: std.mem.Allocator, obj: *std.json.ObjectMap, keys: []const []const u8) !?[]u8 {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        var copy = value;
        if (try nonEmptyStringFromValue(alloc, &copy)) |text| return text;
    }
    return null;
}

pub fn intField(obj: *std.json.ObjectMap, keys: []const []const u8) ?i64 {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .integer => |i| return i,
            .float => |f| return @intFromFloat(f),
            .number_string, .string => |s| return std.fmt.parseInt(i64, s, 10) catch null,
            else => {},
        }
    }
    return null;
}

pub fn boolField(obj: *std.json.ObjectMap, keys: []const []const u8) ?bool {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .bool => |b| return b,
            .integer => |i| return i != 0,
            .number_string, .string => |s| {
                if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1")) return true;
                if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0")) return false;
            },
            else => {},
        }
    }
    return null;
}

pub fn floatField(obj: *std.json.ObjectMap, keys: []const []const u8) ?f64 {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .integer => |i| return @floatFromInt(i),
            .float => |f| return f,
            .number_string, .string => |s| return std.fmt.parseFloat(f64, s) catch null,
            else => {},
        }
    }
    return null;
}

pub fn stringFromValue(alloc: std.mem.Allocator, value: *Value) anyerror![]u8 {
    if (try nonEmptyStringFromValue(alloc, value)) |text| return text;
    return alloc.dupe(u8, "");
}

fn nonEmptyStringFromValue(alloc: std.mem.Allocator, value: *Value) anyerror!?[]u8 {
    switch (value.*) {
        .null => return null,
        .string => |s| return if (s.len == 0) null else try alloc.dupe(u8, s),
        .number_string => |s| return try alloc.dupe(u8, s),
        .integer => |i| return try std.fmt.allocPrint(alloc, "{d}", .{i}),
        .float => |f| return try std.fmt.allocPrint(alloc, "{d}", .{f}),
        .bool => |b| return try alloc.dupe(u8, if (b) "true" else "false"),
        .array => |array| {
            var joined: std.ArrayList(u8) = .empty;
            defer joined.deinit(alloc);
            for (array.items, 0..) |*entry, index| {
                const text = try stringFromValue(alloc, entry);
                defer alloc.free(text);
                if (text.len == 0) continue;
                if (index > 0 and joined.items.len > 0) try joined.appendSlice(alloc, ", ");
                try joined.appendSlice(alloc, text);
            }
            if (joined.items.len == 0) return null;
            return try joined.toOwnedSlice(alloc);
        },
        .object => |*obj| {
            if (try stringField(alloc, obj, &.{ "name", "login", "username", "fullName", "full_name", "title", "id" })) |text| {
                return text;
            }
            return try jsonValueAlloc(alloc, value.*);
        },
    }
}

pub fn jsonValueAlloc(alloc: std.mem.Allocator, value: Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub fn makeHeader(title: [:0]const u8, subtitle: ?[]const u8) *gtk.Box {
    const header = gtk.Box.new(.horizontal, 10);
    ui.margin4(header.as(gtk.Widget), 10, 16, 10, 16);
    const title_box = gtk.Box.new(.vertical, 2);
    title_box.as(gtk.Widget).setHexpand(1);
    title_box.append(ui.heading(title).as(gtk.Widget));
    if (subtitle) |text| {
        const alloc = std.heap.c_allocator;
        const z = alloc.dupeZ(u8, text) catch null;
        if (z) |owned| {
            defer alloc.free(owned);
            title_box.append(ui.dim(owned).as(gtk.Widget));
        }
    }
    header.append(title_box.as(gtk.Widget));
    return header;
}

pub fn listBox() *gtk.ListBox {
    const list = gtk.ListBox.new();
    list.as(gtk.Widget).addCssClass("boxed-list");
    list.setSelectionMode(.none);
    list.setShowSeparators(1);
    return list;
}

pub fn splitPane(left_width: c_int) struct { root: *gtk.Paned, left: *gtk.Box, right: *gtk.Box } {
    const paned = gtk.Paned.new(.horizontal);
    paned.setPosition(left_width);
    const left = gtk.Box.new(.vertical, 0);
    const right = gtk.Box.new(.vertical, 0);
    paned.setStartChild(left.as(gtk.Widget));
    paned.setEndChild(right.as(gtk.Widget));
    return .{ .root = paned, .left = left, .right = right };
}

pub fn itemRow(alloc: std.mem.Allocator, item: Item, icon_name: [:0]const u8) !*gtk.ListBoxRow {
    const subtitle = subtitle: {
        if (item.subtitle) |s| {
            if (item.status) |status| {
                const text = try std.fmt.allocPrint(alloc, "{s} - {s}", .{ s, status });
                break :subtitle text;
            }
            break :subtitle try alloc.dupe(u8, s);
        }
        if (item.status) |status| break :subtitle try alloc.dupe(u8, status);
        if (item.path) |path| break :subtitle try alloc.dupe(u8, path);
        break :subtitle try alloc.dupe(u8, item.id);
    };
    defer alloc.free(subtitle);
    return ui.row(alloc, icon_name, item.title, subtitle);
}

pub fn statusPage(
    alloc: std.mem.Allocator,
    icon_name: [:0]const u8,
    title: []const u8,
    description: []const u8,
) !*adw.StatusPage {
    const page = adw.StatusPage.new();
    page.setIconName(icon_name.ptr);
    const title_z = try alloc.dupeZ(u8, title);
    defer alloc.free(title_z);
    const description_z = try alloc.dupeZ(u8, description);
    defer alloc.free(description_z);
    page.setTitle(title_z.ptr);
    page.setDescription(description_z.ptr);
    page.as(gtk.Widget).setVexpand(1);
    page.as(gtk.Widget).setHexpand(1);
    return page;
}

pub fn setStatus(
    alloc: std.mem.Allocator,
    box: *gtk.Box,
    icon_name: [:0]const u8,
    title: []const u8,
    description: []const u8,
) void {
    ui.clearBox(box);
    const page = statusPage(alloc, icon_name, title, description) catch return;
    box.append(page.as(gtk.Widget));
}

pub fn appendMetric(
    alloc: std.mem.Allocator,
    parent: *gtk.Box,
    title: []const u8,
    value: usize,
    detail: []const u8,
) !void {
    const card = gtk.Box.new(.vertical, 4);
    card.as(gtk.Widget).setHexpand(1);
    card.as(gtk.Widget).addCssClass("card");
    ui.margin(card.as(gtk.Widget), 12);
    const value_z = try std.fmt.allocPrintSentinel(alloc, "{d}", .{value}, 0);
    defer alloc.free(value_z);
    const title_z = try alloc.dupeZ(u8, title);
    defer alloc.free(title_z);
    const detail_z = try alloc.dupeZ(u8, detail);
    defer alloc.free(detail_z);
    card.append(ui.heading(value_z).as(gtk.Widget));
    card.append(ui.label(title_z, "heading").as(gtk.Widget));
    card.append(ui.dim(detail_z).as(gtk.Widget));
    parent.append(card.as(gtk.Widget));
}

pub fn detailRow(alloc: std.mem.Allocator, parent: *gtk.Box, label: []const u8, value: ?[]const u8) !void {
    const row = gtk.Box.new(.horizontal, 10);
    ui.margin4(row.as(gtk.Widget), 6, 0, 6, 0);
    const label_z = try alloc.dupeZ(u8, label);
    defer alloc.free(label_z);
    const left = ui.dim(label_z);
    left.as(gtk.Widget).setSizeRequest(120, -1);
    row.append(left.as(gtk.Widget));
    const value_z = try alloc.dupeZ(u8, value orelse "-");
    defer alloc.free(value_z);
    const right = ui.label(value_z, null);
    right.setSelectable(1);
    right.as(gtk.Widget).setHexpand(1);
    row.append(right.as(gtk.Widget));
    parent.append(row.as(gtk.Widget));
}

pub fn textView(editable: bool) *gtk.TextView {
    const view = gtk.TextView.new();
    view.setMonospace(1);
    view.setEditable(if (editable) 1 else 0);
    view.setWrapMode(.word_char);
    view.as(gtk.Widget).setVexpand(1);
    view.as(gtk.Widget).setHexpand(1);
    return view;
}

pub fn setTextViewText(alloc: std.mem.Allocator, view: *gtk.TextView, text: []const u8) !void {
    const z = try alloc.dupeZ(u8, text);
    defer alloc.free(z);
    view.getBuffer().setText(z.ptr, @intCast(text.len));
}

pub fn getTextViewText(alloc: std.mem.Allocator, view: *gtk.TextView) ![]u8 {
    const buffer = view.getBuffer();
    var start: gtk.TextIter = undefined;
    var end: gtk.TextIter = undefined;
    buffer.getBounds(&start, &end);
    const ptr = buffer.getText(&start, &end, 1);
    defer glib.free(ptr);
    return alloc.dupe(u8, std.mem.span(ptr));
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

pub fn trimEntryText(entry: *gtk.Entry) []const u8 {
    return std.mem.trim(u8, std.mem.span(entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
}

pub fn addSectionTitle(parent: *gtk.Box, title: [:0]const u8) void {
    const label = ui.heading(title);
    ui.margin4(label.as(gtk.Widget), 12, 0, 2, 0);
    parent.append(label.as(gtk.Widget));
}

pub fn actionBar() *gtk.Box {
    const box = gtk.Box.new(.horizontal, 8);
    box.as(gtk.Widget).setHalign(.start);
    return box;
}

pub fn installShortcut(
    comptime T: type,
    widget: *gtk.Widget,
    accelerator: [:0]const u8,
    target: *T,
    comptime handler: fn (*T) void,
) void {
    const Wrapper = struct {
        fn activate(_: *gtk.Widget, _: ?*glib.Variant, data: ?*anyopaque) callconv(.c) c_int {
            const ptr = data orelse return 0;
            const self: *T = @ptrCast(@alignCast(ptr));
            handler(self);
            return 1;
        }
    };

    const trigger = gtk.ShortcutTrigger.parseString(accelerator.ptr) orelse return;
    const action = gtk.CallbackAction.new(Wrapper.activate, @ptrCast(target), null);
    const shortcut = gtk.Shortcut.new(trigger, action.as(gtk.ShortcutAction));
    const controller = gtk.ShortcutController.new();
    controller.setScope(.local);
    controller.addShortcut(shortcut);
    widget.addController(controller.as(gtk.EventController));
}

pub fn findTextView(widget: *gtk.Widget) ?*gtk.TextView {
    if (gobject.ext.cast(gtk.TextView, widget.as(gobject.Object))) |text_view| return text_view;
    var child = widget.getFirstChild();
    while (child) |current| {
        if (findTextView(current)) |found| return found;
        child = current.getNextSibling();
    }
    return null;
}

pub fn markdownEditorText(alloc: std.mem.Allocator, widget: *gtk.Widget) ![]u8 {
    const text_view = findTextView(widget) orelse return alloc.dupe(u8, "");
    return getTextViewText(alloc, text_view);
}

pub fn appendJsonViewer(alloc: std.mem.Allocator, parent: *gtk.Box, title: [:0]const u8, text: []const u8, height: c_int) !void {
    addSectionTitle(parent, title);
    const view = textView(false);
    try setTextViewText(alloc, view, text);
    const scroll = ui.scrolled(view.as(gtk.Widget));
    scroll.as(gtk.Widget).setSizeRequest(-1, height);
    parent.append(scroll.as(gtk.Widget));
}

pub fn setIndex(obj: *gobject.Object, index: usize) void {
    ui.setIndex(obj, index);
}

pub fn getIndex(obj: *gobject.Object) ?usize {
    return ui.getIndex(obj);
}
