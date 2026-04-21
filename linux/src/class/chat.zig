const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const markdown = @import("markdown.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;

pub const ChatBlock = struct {
    id: ?[]u8 = null,
    item_id: ?[]u8 = null,
    run_id: ?[]u8 = null,
    node_id: ?[]u8 = null,
    attempt: ?i64 = null,
    role: []u8,
    content: []u8,
    timestamp_ms: ?i64 = null,

    pub fn init(
        alloc: std.mem.Allocator,
        role: []const u8,
        content: []const u8,
    ) !ChatBlock {
        return .{
            .role = try alloc.dupe(u8, role),
            .content = try alloc.dupe(u8, content),
        };
    }

    pub fn clone(self: ChatBlock, alloc: std.mem.Allocator) !ChatBlock {
        return .{
            .id = if (self.id) |v| try alloc.dupe(u8, v) else null,
            .item_id = if (self.item_id) |v| try alloc.dupe(u8, v) else null,
            .run_id = if (self.run_id) |v| try alloc.dupe(u8, v) else null,
            .node_id = if (self.node_id) |v| try alloc.dupe(u8, v) else null,
            .attempt = self.attempt,
            .role = try alloc.dupe(u8, self.role),
            .content = try alloc.dupe(u8, self.content),
            .timestamp_ms = self.timestamp_ms,
        };
    }

    pub fn deinit(self: *ChatBlock, alloc: std.mem.Allocator) void {
        if (self.id) |v| alloc.free(v);
        if (self.item_id) |v| alloc.free(v);
        if (self.run_id) |v| alloc.free(v);
        if (self.node_id) |v| alloc.free(v);
        alloc.free(self.role);
        alloc.free(self.content);
    }

    pub fn lifecycleId(self: ChatBlock) ?[]const u8 {
        if (self.item_id) |v| if (std.mem.trim(u8, v, &std.ascii.whitespace).len > 0) return v;
        if (self.id) |v| if (std.mem.trim(u8, v, &std.ascii.whitespace).len > 0) return v;
        return null;
    }

    pub fn assistantLike(self: ChatBlock) bool {
        return std.ascii.eqlIgnoreCase(std.mem.trim(u8, self.role, &std.ascii.whitespace), "assistant") or
            std.ascii.eqlIgnoreCase(std.mem.trim(u8, self.role, &std.ascii.whitespace), "agent");
    }

    fn canMergeAssistantStream(self: ChatBlock, incoming: ChatBlock) bool {
        if (!self.assistantLike() or !incoming.assistantLike()) return false;
        if ((self.attempt orelse 0) != (incoming.attempt orelse 0)) return false;
        if (!compatibleIdentifier(self.run_id, incoming.run_id)) return false;
        if (!compatibleIdentifier(self.node_id, incoming.node_id)) return false;
        return true;
    }

    fn mergingAssistantStream(self: ChatBlock, incoming: ChatBlock, alloc: std.mem.Allocator) !ChatBlock {
        var merged = try incoming.clone(alloc);
        errdefer merged.deinit(alloc);
        alloc.free(merged.content);
        merged.content = try mergedStreamingContent(alloc, self.content, incoming.content, self.timestamp_ms, incoming.timestamp_ms);
        if (merged.id == null and self.id) |v| merged.id = try alloc.dupe(u8, v);
        if (merged.item_id == null and self.item_id) |v| merged.item_id = try alloc.dupe(u8, v);
        if (merged.run_id == null and self.run_id) |v| merged.run_id = try alloc.dupe(u8, v);
        if (merged.node_id == null and self.node_id) |v| merged.node_id = try alloc.dupe(u8, v);
        if (merged.attempt == null) merged.attempt = self.attempt;
        if (merged.timestamp_ms == null) merged.timestamp_ms = self.timestamp_ms;
        return merged;
    }
};

pub const ChatBlockMergeStats = struct {
    appended: usize = 0,
    replaced: usize = 0,
    merged: usize = 0,
};

const FileRef = struct {
    label: []u8,
    path: []u8,
    line: ?usize = null,

    fn deinit(self: *FileRef, alloc: std.mem.Allocator) void {
        alloc.free(self.label);
        alloc.free(self.path);
    }
};

pub const ChatBlockMerger = struct {
    blocks: std.ArrayList(ChatBlock) = .empty,

    pub fn deinit(self: *ChatBlockMerger, alloc: std.mem.Allocator) void {
        self.reset(alloc);
        self.blocks.deinit(alloc);
    }

    pub fn reset(self: *ChatBlockMerger, alloc: std.mem.Allocator) void {
        for (self.blocks.items) |*block| block.deinit(alloc);
        self.blocks.clearRetainingCapacity();
    }

    pub fn append(self: *ChatBlockMerger, alloc: std.mem.Allocator, block: ChatBlock) !ChatBlockMergeStats {
        if (block.lifecycleId()) |lifecycle_id| {
            if (self.resolveIndex(lifecycle_id)) |index| {
                const existing = self.blocks.items[index];
                if (existing.canMergeAssistantStream(block)) {
                    const merged = try existing.mergingAssistantStream(block, alloc);
                    self.blocks.items[index].deinit(alloc);
                    var incoming = block;
                    incoming.deinit(alloc);
                    self.blocks.items[index] = merged;
                    return .{ .merged = 1 };
                }

                self.blocks.items[index].deinit(alloc);
                self.blocks.items[index] = block;
                return .{ .replaced = 1 };
            }
        }

        if (self.blocks.items.len > 0) {
            const last_index = self.blocks.items.len - 1;
            const existing = self.blocks.items[last_index];
            const distinct_lifecycle_ids = existing.lifecycleId() != null and block.lifecycleId() != null and
                !std.mem.eql(u8, existing.lifecycleId().?, block.lifecycleId().?);
            if (!distinct_lifecycle_ids and existing.canMergeAssistantStream(block) and hasStreamingContentOverlap(existing.content, block.content)) {
                const merged = try existing.mergingAssistantStream(block, alloc);
                self.blocks.items[last_index].deinit(alloc);
                var incoming = block;
                incoming.deinit(alloc);
                self.blocks.items[last_index] = merged;
                return .{ .merged = 1 };
            }
        }

        try self.blocks.append(alloc, block);
        return .{ .appended = 1 };
    }

    fn resolveIndex(self: ChatBlockMerger, lifecycle_id: []const u8) ?usize {
        var index = self.blocks.items.len;
        while (index > 0) {
            index -= 1;
            if (self.blocks.items[index].lifecycleId()) |candidate| {
                if (std.mem.eql(u8, candidate, lifecycle_id)) return index;
            }
        }
        return null;
    }
};

pub const ChatView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersChatView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        alloc: std.mem.Allocator = undefined,
        body: *gtk.Box = undefined,
        merger: ChatBlockMerger = .{},
        copy_texts: std.ArrayList([]u8) = .empty,
        file_refs: std.ArrayList(FileRef) = .empty,
        hide_noise: bool = true,
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

    pub fn clear(self: *Self) void {
        const priv = self.private();
        priv.merger.reset(priv.alloc);
        clearRenderCaches(priv);
        ui.clearBox(priv.body);
    }

    pub fn appendBlock(self: *Self, block: ChatBlock) !void {
        const priv = self.private();
        _ = try priv.merger.append(priv.alloc, block);
        try self.rebuild();
    }

    pub fn appendChunk(self: *Self, role: []const u8, chunk: []const u8) !void {
        const priv = self.private();
        if (priv.merger.blocks.items.len > 0) {
            const last = &priv.merger.blocks.items[priv.merger.blocks.items.len - 1];
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, last.role, &std.ascii.whitespace), std.mem.trim(u8, role, &std.ascii.whitespace))) {
                const merged = try std.mem.concat(priv.alloc, u8, &.{ last.content, chunk });
                priv.alloc.free(last.content);
                last.content = merged;
                try self.rebuild();
                return;
            }
        }

        var block = try ChatBlock.init(priv.alloc, role, chunk);
        errdefer block.deinit(priv.alloc);
        try self.appendBlock(block);
    }

    pub fn appendJson(self: *Self, json: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.private().alloc, json, .{}) catch {
            var block = try ChatBlock.init(self.private().alloc, "assistant", json);
            errdefer block.deinit(self.private().alloc);
            return self.appendBlock(block);
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |*obj| obj,
            else => {
                var block = try ChatBlock.init(self.private().alloc, "assistant", json);
                errdefer block.deinit(self.private().alloc);
                return self.appendBlock(block);
            },
        };

        var block = ChatBlock{
            .id = try stringField(self.private().alloc, obj, &.{ "id", "messageId", "message_id" }),
            .item_id = try stringField(self.private().alloc, obj, &.{ "itemId", "item_id" }),
            .run_id = try stringField(self.private().alloc, obj, &.{ "runId", "run_id" }),
            .node_id = try stringField(self.private().alloc, obj, &.{ "nodeId", "node_id" }),
            .attempt = intField(obj, &.{"attempt"}),
            .role = (try stringField(self.private().alloc, obj, &.{ "role", "author", "speaker" })) orelse try self.private().alloc.dupe(u8, "assistant"),
            .content = (try stringField(self.private().alloc, obj, &.{ "content", "markdown", "text", "message" })) orelse try self.private().alloc.dupe(u8, ""),
            .timestamp_ms = intField(obj, &.{ "timestampMs", "timestamp_ms" }),
        };
        errdefer block.deinit(self.private().alloc);
        try self.appendBlock(block);
    }

    fn build(self: *Self) !void {
        const body = gtk.Box.new(.vertical, 10);
        ui.margin(body.as(gtk.Widget), 18);
        self.private().body = body;
        const scroll = ui.scrolled(body.as(gtk.Widget));
        scroll.as(gtk.Widget).setVexpand(1);
        self.as(adw.Bin).setChild(scroll.as(gtk.Widget));
    }

    fn rebuild(self: *Self) !void {
        const priv = self.private();
        clearRenderCaches(priv);
        ui.clearBox(priv.body);
        for (priv.merger.blocks.items) |block| {
            if (shouldHideNoise(block, priv.hide_noise)) continue;
            priv.body.append((try self.renderBlock(block)).as(gtk.Widget));
        }
    }

    fn renderBlock(self: *Self, block: ChatBlock) !*gtk.Widget {
        const alloc = self.private().alloc;
        const root = gtk.Box.new(.vertical, 6);
        ui.margin(root.as(gtk.Widget), 10);
        root.as(gtk.Widget).addCssClass("card");

        const role = std.mem.trim(u8, block.role, &std.ascii.whitespace);
        const timestamp_text = if (block.timestamp_ms) |ms| try std.fmt.allocPrint(alloc, "{d}", .{ms}) else null;
        defer if (timestamp_text) |text| alloc.free(text);
        const header_text = try std.fmt.allocPrintSentinel(alloc, "{s}{s}{s}", .{
            roleLabel(role),
            if (timestamp_text != null) "  " else "",
            timestamp_text orelse "",
        }, 0);
        defer alloc.free(header_text);
        const header_row = gtk.Box.new(.horizontal, 6);
        const image = gtk.Image.newFromIconName(roleIcon(role).ptr);
        image.setPixelSize(14);
        header_row.append(image.as(gtk.Widget));
        const header = ui.label(header_text, "heading");
        header.as(gtk.Widget).addCssClass(roleCss(role));
        header.as(gtk.Widget).setHexpand(1);
        header_row.append(header.as(gtk.Widget));
        root.append(header_row.as(gtk.Widget));

        const decoded = try decodeHtmlEntities(alloc, block.content);
        defer alloc.free(decoded);
        if (decoded.len == 0) {
            root.append(ui.dim("[empty]").as(gtk.Widget));
            return root.as(gtk.Widget);
        }

        const is_tool = std.ascii.eqlIgnoreCase(role, "tool") or std.ascii.eqlIgnoreCase(role, "tool_call") or
            std.ascii.eqlIgnoreCase(role, "tool_result") or std.ascii.eqlIgnoreCase(role, "stderr");
        if (is_tool and lineCount(decoded) > 6) {
            const title = try std.fmt.allocPrintSentinel(alloc, "{s} details", .{roleLabel(role)}, 0);
            defer alloc.free(title);
            const expander = gtk.Expander.new(title.ptr);
            expander.setExpanded(0);
            const content = try monospaceLabel(alloc, decoded);
            expander.setChild(content.as(gtk.Widget));
            root.append(expander.as(gtk.Widget));
        } else if (is_tool) {
            root.append((try monospaceLabel(alloc, decoded)).as(gtk.Widget));
        } else {
            root.append((try self.richContent(decoded)).as(gtk.Widget));
        }

        return root.as(gtk.Widget);
    }

    fn richContent(self: *Self, text: []const u8) !*gtk.Widget {
        const priv = self.private();
        const root = gtk.Box.new(.vertical, 8);
        var blocks = try markdown.parseBlocks(priv.alloc, text);
        defer {
            for (blocks.items) |*block| block.deinit(priv.alloc);
            blocks.deinit(priv.alloc);
        }

        if (blocks.items.len == 0) {
            root.append(ui.dim("[empty]").as(gtk.Widget));
        } else {
            for (blocks.items) |block| {
                switch (block) {
                    .code_block => |code| root.append((try self.codeBlock(code.language, code.code)).as(gtk.Widget)),
                    else => root.append((try markdown.renderBlock(priv.alloc, block)).as(gtk.Widget)),
                }
            }
        }

        var refs = try collectFileRefs(priv.alloc, text);
        defer refs.deinit(priv.alloc);
        if (refs.items.len > 0) {
            const ref_box = gtk.Box.new(.horizontal, 6);
            ref_box.as(gtk.Widget).addCssClass("dim-label");
            ref_box.append(ui.dim("Files").as(gtk.Widget));
            for (refs.items) |ref_value| {
                const stored_index = priv.file_refs.items.len;
                try priv.file_refs.append(priv.alloc, ref_value);
                const label_z = try priv.alloc.dupeZ(u8, ref_value.label);
                defer priv.alloc.free(label_z);
                const button = ui.textButton(label_z, false);
                button.as(gtk.Widget).addCssClass("flat");
                ui.setIndex(button.as(gobject.Object), stored_index);
                _ = gtk.Button.signals.clicked.connect(button, *Self, fileRefClicked, self, .{});
                ref_box.append(button.as(gtk.Widget));
            }
            root.append(ref_box.as(gtk.Widget));
        }
        return root.as(gtk.Widget);
    }

    fn codeBlock(self: *Self, language: ?[]const u8, code: []const u8) !*gtk.Widget {
        const priv = self.private();
        const root = gtk.Box.new(.vertical, 6);
        root.as(gtk.Widget).addCssClass("card");
        ui.margin(root.as(gtk.Widget), 10);

        const header = gtk.Box.new(.horizontal, 6);
        const lang_text = language orelse "code";
        const lang_z = try priv.alloc.dupeZ(u8, lang_text);
        defer priv.alloc.free(lang_z);
        const lang = ui.label(lang_z, "dim-label");
        lang.as(gtk.Widget).addCssClass("monospace");
        lang.as(gtk.Widget).setHexpand(1);
        header.append(lang.as(gtk.Widget));

        const copy_index = priv.copy_texts.items.len;
        try priv.copy_texts.append(priv.alloc, try priv.alloc.dupe(u8, code));
        const copy = ui.iconButton("edit-copy-symbolic", "Copy code");
        ui.setIndex(copy.as(gobject.Object), copy_index);
        _ = gtk.Button.signals.clicked.connect(copy, *Self, copyClicked, self, .{});
        header.append(copy.as(gtk.Widget));
        root.append(header.as(gtk.Widget));

        const z = try priv.alloc.dupeZ(u8, code);
        defer priv.alloc.free(z);
        const label = ui.label(z, null);
        label.as(gtk.Widget).addCssClass("monospace");
        label.as(gtk.Widget).addCssClass(languageCss(language).ptr);
        label.setSelectable(1);
        root.append(label.as(gtk.Widget));
        return root.as(gtk.Widget);
    }

    fn copyClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const index = ui.getIndex(button.as(gobject.Object)) orelse return;
        const priv = self.private();
        if (index >= priv.copy_texts.items.len) return;
        const display = gdk.Display.getDefault() orelse return;
        const text = priv.copy_texts.items[index];
        const z = priv.alloc.dupeZ(u8, text) catch return;
        defer priv.alloc.free(z);
        display.getClipboard().setText(z.ptr);
    }

    fn fileRefClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const index = ui.getIndex(button.as(gobject.Object)) orelse return;
        const priv = self.private();
        if (index >= priv.file_refs.items.len) return;
        const ref_value = priv.file_refs.items[index];
        const uri = fileUri(priv.alloc, ref_value.path) catch return;
        defer priv.alloc.free(uri);
        var err: ?*glib.Error = null;
        _ = gio.AppInfo.launchDefaultForUri(uri.ptr, null, &err);
        if (err) |e| e.free();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            self.as(adw.Bin).setChild(null);
            clearRenderCaches(priv);
            priv.copy_texts.deinit(priv.alloc);
            priv.file_refs.deinit(priv.alloc);
            priv.merger.deinit(priv.alloc);
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

fn clearRenderCaches(priv: anytype) void {
    for (priv.copy_texts.items) |text| priv.alloc.free(text);
    priv.copy_texts.clearRetainingCapacity();
    for (priv.file_refs.items) |*ref_value| ref_value.deinit(priv.alloc);
    priv.file_refs.clearRetainingCapacity();
}

pub fn roleLabel(role: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(role, "assistant") or std.ascii.eqlIgnoreCase(role, "agent")) return "ASSISTANT";
    if (std.ascii.eqlIgnoreCase(role, "user") or std.ascii.eqlIgnoreCase(role, "prompt")) return "PROMPT";
    if (std.ascii.eqlIgnoreCase(role, "tool") or std.ascii.eqlIgnoreCase(role, "tool_call")) return "TOOL";
    if (std.ascii.eqlIgnoreCase(role, "tool_result")) return "TOOL RESULT";
    if (std.ascii.eqlIgnoreCase(role, "stderr")) return "STDERR";
    if (std.ascii.eqlIgnoreCase(role, "status")) return "STATUS";
    if (std.ascii.eqlIgnoreCase(role, "system")) return "SYSTEM";
    return role;
}

fn roleIcon(role: []const u8) [:0]const u8 {
    if (std.ascii.eqlIgnoreCase(role, "assistant") or std.ascii.eqlIgnoreCase(role, "agent")) return "emblem-ok-symbolic";
    if (std.ascii.eqlIgnoreCase(role, "user") or std.ascii.eqlIgnoreCase(role, "prompt")) return "avatar-default-symbolic";
    if (std.ascii.eqlIgnoreCase(role, "tool") or std.ascii.eqlIgnoreCase(role, "tool_call")) return "applications-system-symbolic";
    if (std.ascii.eqlIgnoreCase(role, "tool_result")) return "emblem-default-symbolic";
    if (std.ascii.eqlIgnoreCase(role, "stderr")) return "dialog-warning-symbolic";
    if (std.ascii.eqlIgnoreCase(role, "status")) return "dialog-information-symbolic";
    return "text-x-generic-symbolic";
}

pub fn plainText(alloc: std.mem.Allocator, block: ChatBlock, timestamp: ?[]const u8) ![]u8 {
    const decoded = try decodeHtmlEntities(alloc, block.content);
    defer alloc.free(decoded);
    if (timestamp) |ts| {
        if (ts.len > 0) return try std.fmt.allocPrint(alloc, "[{s}] {s}\n{s}", .{ ts, roleLabel(block.role), decoded });
    }
    return try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ roleLabel(block.role), decoded });
}

pub fn shouldHideNoise(block: ChatBlock, enabled: bool) bool {
    if (!enabled) return false;
    const role = std.mem.trim(u8, block.role, &std.ascii.whitespace);
    if (!(std.ascii.eqlIgnoreCase(role, "system") or std.ascii.eqlIgnoreCase(role, "stderr") or std.ascii.eqlIgnoreCase(role, "status"))) return false;

    const trimmed = std.mem.trim(u8, block.content, &std.ascii.whitespace);
    if (trimmed.len == 0) return true;

    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    var saw_line = false;
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, &std.ascii.whitespace);
        if (line.len == 0) continue;
        saw_line = true;
        if (!matchesDefaultNoise(line)) return false;
    }
    return saw_line;
}

fn matchesDefaultNoise(line: []const u8) bool {
    if (startsWithIgnoreCase(line, "warning:")) return true;
    if (startsWithIgnoreCase(line, "ERROR codex_core::")) return true;
    if (startsWithIgnoreCase(line, "ERROR codex_")) return true;
    if (startsWithIgnoreCase(line, "state db missing rollout path")) return true;
    if (looksLikeTimestampedLogNoise(line)) return true;
    return false;
}

fn looksLikeTimestampedLogNoise(line: []const u8) bool {
    if (line.len < "2026-04-21T00:00:00Z WARN ".len) return false;
    if (line[4] != '-' or line[7] != '-' or line[10] != 'T') return false;
    return std.mem.indexOf(u8, line, " ERROR ") != null or std.mem.indexOf(u8, line, " WARN ") != null;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (prefix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn compatibleIdentifier(left: ?[]const u8, right: ?[]const u8) bool {
    const l = left orelse return true;
    const r = right orelse return true;
    if (l.len == 0 or r.len == 0) return true;
    return std.mem.eql(u8, l, r);
}

fn hasStreamingContentOverlap(existing: []const u8, incoming: []const u8) bool {
    if (existing.len == 0 or incoming.len == 0) return false;
    if (std.mem.eql(u8, existing, incoming)) return true;
    if (std.mem.startsWith(u8, existing, incoming) or std.mem.startsWith(u8, incoming, existing)) return true;
    if (std.mem.indexOf(u8, existing, incoming) != null or std.mem.indexOf(u8, incoming, existing) != null) return true;
    return suffixPrefixOverlap(existing, incoming) > 0 or suffixPrefixOverlap(incoming, existing) > 0;
}

fn mergedStreamingContent(
    alloc: std.mem.Allocator,
    existing: []const u8,
    incoming: []const u8,
    existing_timestamp_ms: ?i64,
    incoming_timestamp_ms: ?i64,
) ![]u8 {
    if (existing.len == 0) return alloc.dupe(u8, incoming);
    if (incoming.len == 0) return alloc.dupe(u8, existing);
    if (std.mem.eql(u8, existing, incoming)) return alloc.dupe(u8, existing);
    if (std.mem.startsWith(u8, incoming, existing)) return alloc.dupe(u8, incoming);
    if (std.mem.startsWith(u8, existing, incoming)) return alloc.dupe(u8, existing);
    if (std.mem.indexOf(u8, existing, incoming) != null) return alloc.dupe(u8, existing);
    if (std.mem.indexOf(u8, incoming, existing) != null) return alloc.dupe(u8, incoming);

    const forward = suffixPrefixOverlap(existing, incoming);
    const reverse = suffixPrefixOverlap(incoming, existing);
    if (forward > 0 or reverse > 0) {
        if (reverse > forward) return std.mem.concat(alloc, u8, &.{ incoming, existing[reverse..] });
        return std.mem.concat(alloc, u8, &.{ existing, incoming[forward..] });
    }

    if (existing_timestamp_ms != null and incoming_timestamp_ms != null and incoming_timestamp_ms.? < existing_timestamp_ms.?) {
        return std.mem.concat(alloc, u8, &.{ incoming, existing });
    }
    return std.mem.concat(alloc, u8, &.{ existing, incoming });
}

fn suffixPrefixOverlap(left: []const u8, right: []const u8) usize {
    const max = @min(left.len, right.len);
    var len = max;
    while (len > 0) : (len -= 1) {
        if (std.mem.eql(u8, left[left.len - len ..], right[0..len])) return len;
    }
    return 0;
}

pub fn decodeHtmlEntities(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, text, '&') == null) return alloc.dupe(u8, text);
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, text.len);
    defer out.deinit();
    const writer = &out.writer;
    var index: usize = 0;
    while (index < text.len) {
        if (entityAt(text[index..])) |entity| {
            try writer.writeAll(entity.replacement);
            index += entity.source.len;
        } else {
            try writer.writeByte(text[index]);
            index += 1;
        }
    }
    return try out.toOwnedSlice();
}

fn entityAt(text: []const u8) ?struct { source: []const u8, replacement: []const u8 } {
    const Entity = struct { source: []const u8, replacement: []const u8 };
    const entities = [_]Entity{
        .{ .source = "&quot;", .replacement = "\"" },
        .{ .source = "&amp;", .replacement = "&" },
        .{ .source = "&lt;", .replacement = "<" },
        .{ .source = "&gt;", .replacement = ">" },
        .{ .source = "&apos;", .replacement = "'" },
        .{ .source = "&#39;", .replacement = "'" },
        .{ .source = "&#x27;", .replacement = "'" },
        .{ .source = "&#34;", .replacement = "\"" },
        .{ .source = "&#x22;", .replacement = "\"" },
        .{ .source = "&nbsp;", .replacement = " " },
    };
    inline for (entities) |entity| {
        if (std.mem.startsWith(u8, text, entity.source)) return entity;
    }
    return null;
}

fn roleCss(role: []const u8) [:0]const u8 {
    if (std.ascii.eqlIgnoreCase(role, "stderr")) return "error";
    if (std.ascii.eqlIgnoreCase(role, "tool") or std.ascii.eqlIgnoreCase(role, "tool_call")) return "warning";
    if (std.ascii.eqlIgnoreCase(role, "assistant") or std.ascii.eqlIgnoreCase(role, "agent")) return "accent";
    return "dim-label";
}

fn languageCss(language: ?[]const u8) [:0]const u8 {
    const lang = language orelse return "source-plain";
    if (std.ascii.eqlIgnoreCase(lang, "zig")) return "source-zig";
    if (std.ascii.eqlIgnoreCase(lang, "swift")) return "source-swift";
    if (std.ascii.eqlIgnoreCase(lang, "typescript") or std.ascii.eqlIgnoreCase(lang, "ts")) return "source-typescript";
    if (std.ascii.eqlIgnoreCase(lang, "javascript") or std.ascii.eqlIgnoreCase(lang, "js")) return "source-javascript";
    if (std.ascii.eqlIgnoreCase(lang, "json")) return "source-json";
    if (std.ascii.eqlIgnoreCase(lang, "sh") or std.ascii.eqlIgnoreCase(lang, "bash")) return "source-shell";
    return "source-plain";
}

fn monospaceLabel(alloc: std.mem.Allocator, text: []const u8) !*gtk.Label {
    const z = try alloc.dupeZ(u8, text);
    defer alloc.free(z);
    const label = ui.label(z, null);
    label.as(gtk.Widget).addCssClass("monospace");
    label.setSelectable(1);
    return label;
}

fn lineCount(text: []const u8) usize {
    var count: usize = 1;
    for (text) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

fn collectFileRefs(alloc: std.mem.Allocator, text: []const u8) !std.ArrayList(FileRef) {
    var refs = std.ArrayList(FileRef).empty;
    errdefer {
        for (refs.items) |*ref_value| ref_value.deinit(alloc);
        refs.deinit(alloc);
    }

    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n()[]{}<>\"'");
    while (tokens.next()) |raw| {
        const token = std.mem.trimRight(u8, raw, ".,;:");
        if (!looksLikeFileRef(token)) continue;
        const parsed = parseFileRef(token);
        if (hasFileRef(refs.items, parsed.path)) continue;
        try refs.append(alloc, .{
            .label = try alloc.dupeZ(u8, token),
            .path = try alloc.dupe(u8, parsed.path),
            .line = parsed.line,
        });
        if (refs.items.len >= 8) break;
    }
    return refs;
}

fn looksLikeFileRef(token: []const u8) bool {
    if (token.len < 3) return false;
    if (std.mem.startsWith(u8, token, "http://") or std.mem.startsWith(u8, token, "https://")) return false;
    if (std.mem.indexOfScalar(u8, token, '/') == null and std.mem.indexOfScalar(u8, token, '.') == null) return false;
    const path = parseFileRef(token).path;
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return false;
    return true;
}

fn parseFileRef(token: []const u8) struct { path: []const u8, line: ?usize } {
    if (std.mem.lastIndexOfScalar(u8, token, ':')) |colon| {
        if (colon + 1 < token.len) {
            const maybe_line = std.fmt.parseInt(usize, token[colon + 1 ..], 10) catch null;
            if (maybe_line) |line| return .{ .path = token[0..colon], .line = line };
        }
    }
    return .{ .path = token, .line = null };
}

fn hasFileRef(refs: []const FileRef, path: []const u8) bool {
    for (refs) |ref_value| {
        if (std.mem.eql(u8, ref_value.path, path)) return true;
    }
    return false;
}

fn fileUri(alloc: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const absolute = if (std.fs.path.isAbsolute(path))
        try alloc.dupe(u8, path)
    else blk: {
        const cwd = try std.process.getCwdAlloc(alloc);
        defer alloc.free(cwd);
        break :blk try std.fs.path.join(alloc, &.{ cwd, path });
    };
    defer alloc.free(absolute);

    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, absolute.len + "file://".len);
    defer out.deinit();
    try out.writer.writeAll("file://");
    for (absolute) |ch| {
        if (ch == ' ') {
            try out.writer.writeAll("%20");
        } else {
            try out.writer.writeByte(ch);
        }
    }
    return try out.toOwnedSliceSentinel(0);
}

fn stringField(alloc: std.mem.Allocator, obj: *std.json.ObjectMap, keys: []const []const u8) !?[]u8 {
    for (keys) |key| {
        const value = obj.get(key) orelse continue;
        switch (value) {
            .string => |s| return try alloc.dupe(u8, s),
            .number_string => |s| return try alloc.dupe(u8, s),
            .integer => |i| return try std.fmt.allocPrint(alloc, "{d}", .{i}),
            .float => |f| return try std.fmt.allocPrint(alloc, "{d}", .{f}),
            .bool => |b| return try alloc.dupe(u8, if (b) "true" else "false"),
            else => {},
        }
    }
    return null;
}

fn intField(obj: *std.json.ObjectMap, keys: []const []const u8) ?i64 {
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
