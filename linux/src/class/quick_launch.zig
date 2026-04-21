const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

const Mode = enum { command, workflow };
const FieldKind = enum { string, number, enumeration, boolean, json };

const LaunchField = struct {
    key: []u8,
    name: []u8,
    kind: FieldKind = .string,
    required: bool = false,
    default_value: ?[]u8 = null,
    options: std.ArrayList([]u8) = .empty,

    fn deinit(self: *LaunchField, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        alloc.free(self.name);
        if (self.default_value) |value| alloc.free(value);
        for (self.options.items) |option| alloc.free(option);
        self.options.deinit(alloc);
    }
};

const FieldInput = struct {
    field: LaunchField,
    entry: ?*gtk.Entry = null,
    check: ?*gtk.CheckButton = null,

    fn deinit(self: *FieldInput, alloc: std.mem.Allocator) void {
        self.field.deinit(alloc);
    }
};

pub const QuickLaunchConfirmSheet = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersQuickLaunchConfirmSheet",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        dialog: *adw.Dialog = undefined,
        command_label: ?*gtk.Label = null,
        fields_box: ?*gtk.Box = null,
        error_label: ?*gtk.Label = null,
        client: smithers.c.smithers_client_t = null,
        mode: Mode = .command,
        workflow_name: ?[]u8 = null,
        workflow_path: ?[]u8 = null,
        command: ?[]u8 = null,
        inputs: std.ArrayList(FieldInput) = .empty,
        last_values: std.StringHashMap([]u8) = undefined,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(alloc: std.mem.Allocator, command: []const u8) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{
            .alloc = alloc,
            .command = try alloc.dupe(u8, command),
            .last_values = std.StringHashMap([]u8).init(alloc),
        };
        try self.build();
        return self;
    }

    pub fn newWorkflow(
        alloc: std.mem.Allocator,
        client: smithers.c.smithers_client_t,
        workflow_name: []const u8,
        workflow_path: []const u8,
        fields_json: []const u8,
        initial_inputs_json: []const u8,
    ) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{
            .alloc = alloc,
            .client = client,
            .mode = .workflow,
            .workflow_name = try alloc.dupe(u8, workflow_name),
            .workflow_path = try alloc.dupe(u8, workflow_path),
            .inputs = try parseFields(alloc, fields_json, initial_inputs_json),
            .last_values = std.StringHashMap([]u8).init(alloc),
        };
        try self.build();
        return self;
    }

    pub fn present(self: *Self, parent: ?*gtk.Widget) void {
        self.private().dialog.present(parent);
    }

    pub fn close(self: *Self) void {
        _ = self.private().dialog.close();
    }

    fn build(self: *Self) !void {
        const priv = self.private();
        priv.dialog = adw.Dialog.new();
        priv.dialog.setTitle("Quick Launch");
        priv.dialog.setContentWidth(560);

        const root = gtk.Box.new(.vertical, 14);
        ui.margin(root.as(gtk.Widget), 18);

        switch (priv.mode) {
            .command => try self.buildCommand(root),
            .workflow => try self.buildWorkflow(root),
        }

        const buttons = gtk.Box.new(.horizontal, 8);
        buttons.as(gtk.Widget).setHalign(.end);
        const cancel = ui.textButton("Cancel", false);
        _ = gtk.Button.signals.clicked.connect(cancel, *Self, cancelClicked, self, .{});
        buttons.append(cancel.as(gtk.Widget));
        const launch_button = ui.textButton("Launch", true);
        _ = gtk.Button.signals.clicked.connect(launch_button, *Self, launchClicked, self, .{});
        buttons.append(launch_button.as(gtk.Widget));
        root.append(buttons.as(gtk.Widget));

        priv.dialog.setChild(root.as(gtk.Widget));
    }

    fn buildCommand(self: *Self, root: *gtk.Box) !void {
        const priv = self.private();
        root.append(ui.heading("Run command?").as(gtk.Widget));
        root.append(ui.dim("Review the command before it is sent to Smithers.").as(gtk.Widget));

        const command_z = try priv.alloc.dupeZ(u8, priv.command orelse "");
        defer priv.alloc.free(command_z);
        const label = ui.label(command_z, "monospace");
        label.setSelectable(1);
        label.as(gtk.Widget).addCssClass("card");
        ui.margin(label.as(gtk.Widget), 10);
        priv.command_label = label;
        root.append(label.as(gtk.Widget));
    }

    fn buildWorkflow(self: *Self, root: *gtk.Box) !void {
        const priv = self.private();
        const title = try std.fmt.allocPrintSentinel(priv.alloc, "Launch {s}", .{priv.workflow_name orelse "Workflow"}, 0);
        defer priv.alloc.free(title);
        root.append(ui.heading(title).as(gtk.Widget));
        const path_z = try priv.alloc.dupeZ(u8, priv.workflow_path orelse "");
        defer priv.alloc.free(path_z);
        root.append(ui.dim(path_z).as(gtk.Widget));

        const fields_box = gtk.Box.new(.vertical, 10);
        priv.fields_box = fields_box;
        if (priv.inputs.items.len == 0) {
            fields_box.append(ui.dim("This workflow takes no inputs.").as(gtk.Widget));
        } else {
            for (priv.inputs.items) |*input| try self.addField(fields_box, input);
        }
        root.append(fields_box.as(gtk.Widget));

        priv.error_label = ui.label("", "error");
        priv.error_label.?.as(gtk.Widget).setVisible(0);
        root.append(priv.error_label.?.as(gtk.Widget));
    }

    fn addField(self: *Self, parent: *gtk.Box, input: *FieldInput) !void {
        const priv = self.private();
        const row = gtk.Box.new(.vertical, 4);
        const header = try std.fmt.allocPrintSentinel(priv.alloc, "{s}{s} ({s})", .{
            input.field.name,
            if (input.field.required) " required" else "",
            @tagName(input.field.kind),
        }, 0);
        defer priv.alloc.free(header);
        row.append(ui.label(header, "heading").as(gtk.Widget));

        switch (input.field.kind) {
            .boolean => {
                const check = gtk.CheckButton.newWithLabel("Enabled");
                const initial = input.field.default_value orelse "false";
                check.setActive(if (parseBool(initial) orelse false) 1 else 0);
                input.check = check;
                row.append(check.as(gtk.Widget));
            },
            else => {
                const entry = gtk.Entry.new();
                const placeholder = try placeholderForField(priv.alloc, input.field);
                defer priv.alloc.free(placeholder);
                entry.setPlaceholderText(placeholder.ptr);
                if (input.field.default_value) |value| {
                    const z = try priv.alloc.dupeZ(u8, value);
                    defer priv.alloc.free(z);
                    entry.as(gtk.Editable).setText(z.ptr);
                }
                input.entry = entry;
                row.append(entry.as(gtk.Widget));
            },
        }
        parent.append(row.as(gtk.Widget));
    }

    fn launch(self: *Self) void {
        const priv = self.private();
        if (priv.mode == .command) {
            self.close();
            return;
        }
        const inputs = self.validatedInputs() catch |err| {
            self.setError(@errorName(err));
            return;
        };
        defer priv.alloc.free(inputs);
        const json = smithers.callJson(priv.alloc, priv.client, "runWorkflow", inputs) catch |err| {
            self.setError(@errorName(err));
            return;
        };
        defer priv.alloc.free(json);
        self.close();
    }

    fn validatedInputs(self: *Self) ![]u8 {
        const priv = self.private();
        var out: std.Io.Writer.Allocating = try .initCapacity(priv.alloc, 512);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("workflowPath");
        try jw.write(priv.workflow_path orelse "");
        try jw.objectField("inputs");
        try jw.beginObject();

        for (priv.inputs.items) |input| {
            const raw = try self.inputText(input);
            defer priv.alloc.free(raw);
            const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (trimmed.len == 0) {
                if (input.field.required) return error.RequiredFieldMissing;
                continue;
            }
            try validateValue(input.field, trimmed);
            try jw.objectField(input.field.key);
            switch (input.field.kind) {
                .number => try jw.write(try std.fmt.parseFloat(f64, trimmed)),
                .boolean => try jw.write(parseBool(trimmed) orelse return error.InvalidBoolean),
                .json => {
                    var parsed = std.json.parseFromSlice(std.json.Value, priv.alloc, trimmed, .{}) catch return error.InvalidJson;
                    defer parsed.deinit();
                    try jw.write(parsed.value);
                },
                else => try jw.write(trimmed),
            }
            try rememberValue(priv, input.field.key, trimmed);
        }
        try jw.endObject();
        try jw.endObject();
        return try out.toOwnedSlice();
    }

    fn inputText(self: *Self, input: FieldInput) ![]u8 {
        const priv = self.private();
        if (input.check) |check| return try priv.alloc.dupe(u8, if (check.getActive() != 0) "true" else "false");
        if (input.entry) |entry| return try priv.alloc.dupe(u8, std.mem.span(entry.as(gtk.Editable).getText()));
        return try priv.alloc.dupe(u8, "");
    }

    fn setError(self: *Self, message: []const u8) void {
        const label = self.private().error_label orelse return;
        const z = self.private().alloc.dupeZ(u8, message) catch return;
        defer self.private().alloc.free(z);
        label.setText(z.ptr);
        label.as(gtk.Widget).setVisible(1);
    }

    fn cancelClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.close();
    }

    fn launchClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.launch();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            priv.dialog.setChild(null);
            priv.dialog.forceClose();
            priv.dialog.unref();
            if (priv.command) |value| priv.alloc.free(value);
            if (priv.workflow_name) |value| priv.alloc.free(value);
            if (priv.workflow_path) |value| priv.alloc.free(value);
            for (priv.inputs.items) |*input| input.deinit(priv.alloc);
            priv.inputs.deinit(priv.alloc);
            var iter = priv.last_values.iterator();
            while (iter.next()) |entry| priv.alloc.free(entry.value_ptr.*);
            priv.last_values.deinit();
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

fn rememberValue(priv: anytype, key: []const u8, value: []const u8) !void {
    const owned = try priv.alloc.dupe(u8, value);
    const result = try priv.last_values.getOrPut(key);
    if (result.found_existing) priv.alloc.free(result.value_ptr.*);
    result.value_ptr.* = owned;
}

fn validateValue(field: LaunchField, value: []const u8) !void {
    switch (field.kind) {
        .number => _ = std.fmt.parseFloat(f64, value) catch return error.InvalidNumber,
        .boolean => if (parseBool(value) == null) return error.InvalidBoolean,
        .enumeration => {
            if (field.options.items.len == 0) return;
            for (field.options.items) |option| if (std.mem.eql(u8, option, value)) return;
            return error.InvalidEnumValue;
        },
        .json => {
            var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, value, .{}) catch return error.InvalidJson;
            parsed.deinit();
        },
        .string => {},
    }
}

fn parseBool(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "yes") or std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "no") or std.mem.eql(u8, value, "0")) return false;
    return null;
}

fn placeholderForField(alloc: std.mem.Allocator, field: LaunchField) ![:0]u8 {
    if (field.options.items.len > 0) {
        var out: std.Io.Writer.Allocating = try .initCapacity(alloc, 64);
        defer out.deinit();
        try out.writer.writeAll("one of: ");
        for (field.options.items, 0..) |option, index| {
            if (index > 0) try out.writer.writeAll(", ");
            try out.writer.writeAll(option);
        }
        return try out.toOwnedSliceSentinel(0);
    }
    return switch (field.kind) {
        .number => try alloc.dupeZ(u8, "number"),
        .enumeration => try alloc.dupeZ(u8, "value"),
        .boolean => try alloc.dupeZ(u8, "true or false"),
        .json => try alloc.dupeZ(u8, "{\"key\":\"value\"}"),
        .string => try alloc.dupeZ(u8, "text"),
    };
}

fn parseFields(alloc: std.mem.Allocator, fields_json: []const u8, initial_inputs_json: []const u8) !std.ArrayList(FieldInput) {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, fields_json, .{});
    defer parsed.deinit();
    var initial = std.json.parseFromSlice(std.json.Value, alloc, initial_inputs_json, .{}) catch null;
    defer if (initial) |*value| value.deinit();

    var result = std.ArrayList(FieldInput).empty;
    errdefer {
        for (result.items) |*input| input.deinit(alloc);
        result.deinit(alloc);
    }

    const items = arrayFromRoot(&parsed.value) orelse return result;
    for (items) |*item| {
        const obj = object(item) orelse continue;
        const key = try stringField(alloc, obj, &.{ "key", "name", "id" }) orelse continue;
        errdefer alloc.free(key);
        const name = try stringField(alloc, obj, &.{ "name", "label", "key" }) orelse try alloc.dupe(u8, key);
        errdefer alloc.free(name);
        var field = LaunchField{
            .key = key,
            .name = name,
            .kind = parseKind(stringFieldBorrowed(obj, &.{"type"})),
            .required = boolField(obj, &.{"required"}) orelse false,
            .default_value = try stringField(alloc, obj, &.{ "defaultValue", "default", "value" }),
        };
        errdefer field.deinit(alloc);
        if (initial) |*initial_value| {
            if (object(&initial_value.value)) |initial_obj| {
                if (initial_obj.get(field.key)) |value| {
                    if (field.default_value) |old| alloc.free(old);
                    field.default_value = try valueText(alloc, value);
                }
            }
        }
        if (arrayField(obj, &.{ "options", "enum", "values" })) |options| {
            for (options) |*option| {
                if (try valueText(alloc, option.*)) |text| try field.options.append(alloc, text);
            }
            if (field.options.items.len > 0) field.kind = .enumeration;
        }
        try result.append(alloc, .{ .field = field });
    }
    return result;
}

fn parseKind(value: ?[]const u8) FieldKind {
    const raw = value orelse return .string;
    if (std.ascii.eqlIgnoreCase(raw, "number") or std.ascii.eqlIgnoreCase(raw, "int") or std.ascii.eqlIgnoreCase(raw, "integer") or std.ascii.eqlIgnoreCase(raw, "float") or std.ascii.eqlIgnoreCase(raw, "double")) return .number;
    if (std.ascii.eqlIgnoreCase(raw, "bool") or std.ascii.eqlIgnoreCase(raw, "boolean")) return .boolean;
    if (std.ascii.eqlIgnoreCase(raw, "enum") or std.ascii.eqlIgnoreCase(raw, "enumeration")) return .enumeration;
    if (std.ascii.eqlIgnoreCase(raw, "json") or std.ascii.eqlIgnoreCase(raw, "object") or std.ascii.eqlIgnoreCase(raw, "array")) return .json;
    return .string;
}

fn arrayFromRoot(root: *std.json.Value) ?[]std.json.Value {
    switch (root.*) {
        .array => |array| return array.items,
        .object => |obj| {
            const keys = [_][]const u8{ "fields", "items", "data" };
            for (keys) |key| {
                if (obj.get(key)) |value| {
                    var copy = value;
                    if (arrayFromRoot(&copy)) |array| return array;
                }
            }
        },
        else => {},
    }
    return null;
}

fn object(value: *std.json.Value) ?*std.json.ObjectMap {
    return switch (value.*) {
        .object => |*obj| obj,
        else => null,
    };
}

fn arrayField(obj: *std.json.ObjectMap, keys: []const []const u8) ?[]std.json.Value {
    for (keys) |key| {
        if (obj.get(key)) |value| {
            var copy = value;
            if (arrayFromRoot(&copy)) |items| return items;
        }
    }
    return null;
}

fn stringField(alloc: std.mem.Allocator, obj: *std.json.ObjectMap, keys: []const []const u8) !?[]u8 {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        if (try valueText(alloc, value)) |text| return text;
    }
    return null;
}

fn stringFieldBorrowed(obj: *std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .string => |s| return s,
            .number_string => |s| return s,
            else => {},
        }
    }
    return null;
}

fn valueText(alloc: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    return switch (value) {
        .string => |s| try alloc.dupe(u8, s),
        .number_string => |s| try alloc.dupe(u8, s),
        .integer => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(alloc, "{d}", .{f}),
        .bool => |b| try alloc.dupe(u8, if (b) "true" else "false"),
        else => null,
    };
}

fn boolField(obj: *std.json.ObjectMap, keys: []const []const u8) ?bool {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .bool => |b| return b,
            .string, .number_string => |s| return parseBool(s),
            else => {},
        }
    }
    return null;
}
