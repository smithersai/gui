const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;
const MarkdownEditor = @import("markdown_editor.zig").MarkdownEditor;
const MarkdownSurface = @import("markdown.zig").MarkdownSurface;

pub const TicketsView = extern struct {
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "SmithersTicketsView",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        window: *MainWindow = undefined,
        list: *gtk.ListBox = undefined,
        detail: *gtk.Box = undefined,
        search: *gtk.Entry = undefined,
        tag_entry: *gtk.Entry = undefined,
        id_entry: *gtk.Entry = undefined,
        rename_entry: *gtk.Entry = undefined,
        delete_dialog: ?*adw.AlertDialog = null,
        delete_confirm_entry: ?*gtk.Entry = null,
        create_editor: *MarkdownEditor = undefined,
        editor: *MarkdownEditor = undefined,
        tickets: std.ArrayList(vh.Item) = .empty,
        visible_rows: std.ArrayList(usize) = .empty,
        selected: std.ArrayList(bool) = .empty,
        draft_ticket_id: ?[]u8 = null,
        draft_content: ?[]u8 = null,
        selected_index: ?usize = null,
        status_filter: ?[]const u8 = null,
        pending_delete_index: ?usize = null,
        pending_bulk_delete: bool = false,
        create_visible: bool = false,
        preview_mode: bool = false,
        did_dispose: bool = false,

        pub var offset: c_int = 0;
    };

    pub fn new(window: *MainWindow) !*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        self.private().* = .{ .window = window };
        try self.build();
        return self;
    }

    pub fn refresh(self: *Self) void {
        self.load() catch |err| {
            vh.setStatus(self.allocator(), self.private().detail, "dialog-error-symbolic", "Tickets unavailable", @errorName(err));
        };
    }

    fn allocator(self: *Self) std.mem.Allocator {
        return self.private().window.allocator();
    }

    fn client(self: *Self) smithers.c.smithers_client_t {
        return self.private().window.app().client();
    }

    fn build(self: *Self) !void {
        const root = self.as(gtk.Box);
        root.as(gtk.Orientable).setOrientation(.vertical);
        vh.installShortcut(Self, root.as(gtk.Widget), "<Control>r", self, shortcutRefresh);
        vh.installShortcut(Self, root.as(gtk.Widget), "<Control>f", self, shortcutSearch);
        const header = vh.makeHeader("Tickets", null);
        self.private().search = gtk.Entry.new();
        self.private().search.setPlaceholderText("Search tickets");
        self.private().search.as(gtk.Widget).setSizeRequest(220, -1);
        _ = gtk.Editable.signals.changed.connect(self.private().search.as(gtk.Editable), *Self, searchChanged, self, .{});
        _ = gtk.Entry.signals.activate.connect(self.private().search, *Self, searchActivated, self, .{});
        header.append(self.private().search.as(gtk.Widget));
        self.private().tag_entry = gtk.Entry.new();
        self.private().tag_entry.setPlaceholderText("Tag");
        self.private().tag_entry.as(gtk.Widget).setSizeRequest(110, -1);
        _ = gtk.Editable.signals.changed.connect(self.private().tag_entry.as(gtk.Editable), *Self, tagChanged, self, .{});
        header.append(self.private().tag_entry.as(gtk.Widget));
        inline for (.{ "All", "Open", "Closed" }) |label| {
            const button = ui.textButton(label, false);
            button.as(gobject.Object).setData("smithers-ticket-filter", @constCast(label.ptr));
            _ = gtk.Button.signals.clicked.connect(button, *Self, filterClicked, self, .{});
            header.append(button.as(gtk.Widget));
        }
        const select_all = ui.textButton("Select All", false);
        _ = gtk.Button.signals.clicked.connect(select_all, *Self, selectAllClicked, self, .{});
        header.append(select_all.as(gtk.Widget));
        const bulk_delete = ui.textButton("Delete Selected", false);
        bulk_delete.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(bulk_delete, *Self, bulkDeleteClicked, self, .{});
        header.append(bulk_delete.as(gtk.Widget));
        const add = ui.iconButton("list-add-symbolic", "New ticket");
        _ = gtk.Button.signals.clicked.connect(add, *Self, newClicked, self, .{});
        header.append(add.as(gtk.Widget));
        const refresh_button = ui.iconButton("view-refresh-symbolic", "Refresh tickets");
        _ = gtk.Button.signals.clicked.connect(refresh_button, *Self, refreshClicked, self, .{});
        header.append(refresh_button.as(gtk.Widget));
        root.append(header.as(gtk.Widget));

        const split = vh.splitPane(340);
        self.private().list = vh.listBox();
        _ = gtk.ListBox.signals.row_activated.connect(self.private().list, *Self, rowActivated, self, .{});
        const list_scroll = ui.scrolled(self.private().list.as(gtk.Widget));
        list_scroll.as(gtk.Widget).setVexpand(1);
        split.left.append(list_scroll.as(gtk.Widget));

        self.private().detail = gtk.Box.new(.vertical, 12);
        ui.margin(self.private().detail.as(gtk.Widget), 18);
        const detail_scroll = ui.scrolled(self.private().detail.as(gtk.Widget));
        detail_scroll.as(gtk.Widget).setVexpand(1);
        split.right.append(detail_scroll.as(gtk.Widget));
        root.append(split.root.as(gtk.Widget));

        vh.setStatus(self.allocator(), self.private().detail, "text-x-generic-symbolic", "Select a ticket", "Create, edit, and delete Smithers tickets.");
    }

    fn load(self: *Self) !void {
        const alloc = self.allocator();
        const json = try smithers.callJson(alloc, self.client(), "listTickets", "{}");
        defer alloc.free(json);
        const parsed = try vh.parseItems(alloc, json, &.{ "tickets", "items", "data" }, .{
            .id = &.{ "id", "ticketId", "ticket_id" },
            .title = &.{ "id", "ticketId", "ticket_id", "title" },
            .subtitle = &.{ "status", "updatedAt", "updated_at" },
            .status = &.{"status"},
            .body = &.{ "content", "body", "description" },
        });
        vh.clearItems(alloc, &self.private().tickets);
        self.private().tickets = parsed;
        self.private().selected.clearRetainingCapacity();
        try self.private().selected.appendNTimes(alloc, false, self.private().tickets.items.len);
        self.private().selected_index = null;
        try self.renderList();
        if (self.private().create_visible) try self.renderCreate() else vh.setStatus(alloc, self.private().detail, "text-x-generic-symbolic", "Select a ticket", "Create, edit, and delete Smithers tickets.");
    }

    fn renderList(self: *Self) !void {
        const alloc = self.allocator();
        ui.clearList(self.private().list);
        self.private().visible_rows.clearRetainingCapacity();
        if (self.private().tickets.items.len == 0) {
            self.private().list.append((try ui.row(alloc, "text-x-generic-symbolic", "No tickets found", "Create a ticket with the plus button.")).as(gtk.Widget));
            return;
        }
        const query = vh.trimEntryText(self.private().search);
        const tag = vh.trimEntryText(self.private().tag_entry);
        for (self.private().tickets.items, 0..) |ticket, index| {
            if (query.len > 0 and !ticketMatchesQuery(ticket, query)) continue;
            if (tag.len > 0 and !ticketHasTag(ticket, tag)) continue;
            if (self.private().status_filter) |status| {
                if (ticket.status == null or !std.ascii.eqlIgnoreCase(ticket.status.?, status)) continue;
            }
            try self.private().visible_rows.append(alloc, index);
            const row = try self.ticketRow(ticket, index);
            vh.setIndex(row.as(gobject.Object), self.private().visible_rows.items.len - 1);
            self.private().list.append(row.as(gtk.Widget));
        }
        if (self.private().visible_rows.items.len == 0) {
            self.private().list.append((try ui.row(alloc, "system-search-symbolic", "No tickets match filters", "Search id/body, status, or tag.")).as(gtk.Widget));
        }
    }

    fn ticketRow(self: *Self, ticket: vh.Item, index: usize) !*gtk.ListBoxRow {
        const alloc = self.allocator();
        const row = gtk.ListBoxRow.new();
        row.setActivatable(1);
        const row_box = gtk.Box.new(.horizontal, 10);
        ui.margin(row_box.as(gtk.Widget), 10);
        const check = gtk.CheckButton.new();
        check.setActive(if (index < self.private().selected.items.len and self.private().selected.items[index]) 1 else 0);
        vh.setIndex(check.as(gobject.Object), index);
        _ = gtk.CheckButton.signals.toggled.connect(check, *Self, selectionToggled, self, .{});
        row_box.append(check.as(gtk.Widget));
        const icon = gtk.Image.newFromIconName("text-x-generic-symbolic");
        icon.setPixelSize(20);
        row_box.append(icon.as(gtk.Widget));
        const text_box = gtk.Box.new(.vertical, 3);
        text_box.as(gtk.Widget).setHexpand(1);
        const title_z = try alloc.dupeZ(u8, ticket.id);
        defer alloc.free(title_z);
        const title = ui.label(title_z, "heading");
        title.setWrap(0);
        title.setEllipsize(.end);
        text_box.append(title.as(gtk.Widget));
        const snippet = try ticketSnippet(alloc, ticket.body orelse ticket.subtitle orelse "");
        defer alloc.free(snippet);
        if (snippet.len > 0) {
            const snippet_z = try alloc.dupeZ(u8, snippet);
            defer alloc.free(snippet_z);
            text_box.append(ui.dim(snippet_z).as(gtk.Widget));
        }
        row_box.append(text_box.as(gtk.Widget));
        row.setChild(row_box.as(gtk.Widget));
        return row;
    }

    fn renderCreate(self: *Self) !void {
        const alloc = self.allocator();
        const detail = self.private().detail;
        ui.clearBox(detail);
        detail.append(ui.heading("New Ticket").as(gtk.Widget));
        self.private().id_entry = gtk.Entry.new();
        self.private().id_entry.setPlaceholderText("ticket-id");
        detail.append(self.private().id_entry.as(gtk.Widget));
        const templates = vh.actionBar();
        inline for (.{ "Feature", "Bug", "Task" }) |label| {
            const button = ui.textButton(label, false);
            button.as(gobject.Object).setData("smithers-ticket-template", @constCast(label.ptr));
            _ = gtk.Button.signals.clicked.connect(button, *Self, templateClicked, self, .{});
            templates.append(button.as(gtk.Widget));
        }
        detail.append(templates.as(gtk.Widget));
        self.private().create_editor = try MarkdownEditor.new(alloc, "");
        self.private().create_editor.as(gtk.Widget).setSizeRequest(-1, 300);
        detail.append(self.private().create_editor.as(gtk.Widget));
        const create = ui.textButton("Create", true);
        _ = gtk.Button.signals.clicked.connect(create, *Self, createClicked, self, .{});
        detail.append(create.as(gtk.Widget));
    }

    fn renderDetail(self: *Self, index: usize) !void {
        if (index >= self.private().tickets.items.len) return;
        const alloc = self.allocator();
        const ticket = self.private().tickets.items[index];
        const detail = self.private().detail;
        ui.clearBox(detail);
        const title_z = try alloc.dupeZ(u8, "Ticket");
        defer alloc.free(title_z);
        detail.append(ui.heading(title_z).as(gtk.Widget));
        self.private().rename_entry = gtk.Entry.new();
        const id_z = try alloc.dupeZ(u8, ticket.id);
        defer alloc.free(id_z);
        self.private().rename_entry.as(gtk.Editable).setText(id_z.ptr);
        self.private().rename_entry.setPlaceholderText("ticket-id");
        detail.append(self.private().rename_entry.as(gtk.Widget));
        try vh.detailRow(alloc, detail, "Status", ticket.status);
        const actions = vh.actionBar();
        const preview = ui.textButton(if (self.private().preview_mode) "Edit Markdown" else "Preview Markdown", false);
        _ = gtk.Button.signals.clicked.connect(preview, *Self, previewClicked, self, .{});
        actions.append(preview.as(gtk.Widget));
        const rename = ui.textButton("Rename", false);
        _ = gtk.Button.signals.clicked.connect(rename, *Self, renameClicked, self, .{});
        actions.append(rename.as(gtk.Widget));
        const save = ui.textButton("Save", true);
        _ = gtk.Button.signals.clicked.connect(save, *Self, saveClicked, self, .{});
        actions.append(save.as(gtk.Widget));
        const delete = ui.textButton("Delete", false);
        delete.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(delete, *Self, deleteClicked, self, .{});
        actions.append(delete.as(gtk.Widget));
        detail.append(actions.as(gtk.Widget));
        const content = self.currentDraftFor(ticket.id) orelse ticket.body orelse "";
        if (self.private().preview_mode) {
            const preview_surface = try MarkdownSurface.new(alloc, content);
            preview_surface.as(gtk.Widget).setSizeRequest(-1, 380);
            detail.append(preview_surface.as(gtk.Widget));
        } else {
            self.private().editor = try MarkdownEditor.new(alloc, content);
            self.private().editor.as(gtk.Widget).setSizeRequest(-1, 380);
            detail.append(self.private().editor.as(gtk.Widget));
        }
    }

    fn createTicket(self: *Self) void {
        const alloc = self.allocator();
        const id = std.mem.trim(u8, std.mem.span(self.private().id_entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        if (id.len == 0) {
            self.private().window.showToast("Ticket ID is required");
            return;
        }
        const content = vh.markdownEditorText(alloc, self.private().create_editor.as(gtk.Widget)) catch return;
        defer alloc.free(content);
        const json = vh.callJson(alloc, self.client(), "createTicket", &.{
            .{ .key = "ticketId", .value = .{ .string = id } },
            .{ .key = "content", .value = .{ .string = content } },
        }) catch |err| {
            self.private().window.showToastFmt("Create failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("Created {s}", .{id});
        self.private().create_visible = false;
        self.refresh();
    }

    fn renameTicket(self: *Self) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().tickets.items.len) return;
        const ticket = self.private().tickets.items[index];
        const new_id = vh.trimEntryText(self.private().rename_entry);
        if (new_id.len == 0 or std.mem.eql(u8, new_id, ticket.id)) return;
        for (self.private().tickets.items) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.id, new_id)) {
                self.private().window.showToast("A ticket with that ID already exists");
                return;
            }
        }
        const alloc = self.allocator();
        const content = self.currentEditorText() catch return;
        defer alloc.free(content);
        const created = vh.callJson(alloc, self.client(), "createTicket", &.{
            .{ .key = "ticketId", .value = .{ .string = new_id } },
            .{ .key = "content", .value = .{ .string = content } },
        }) catch |err| {
            self.private().window.showToastFmt("Rename create failed: {}", .{err});
            return;
        };
        alloc.free(created);
        const deleted = vh.callJson(alloc, self.client(), "deleteTicket", &.{.{ .key = "ticketId", .value = .{ .string = ticket.id } }}) catch |err| {
            self.private().window.showToastFmt("Rename cleanup failed: {}", .{err});
            return;
        };
        alloc.free(deleted);
        self.private().window.showToastFmt("Renamed {s} to {s}", .{ ticket.id, new_id });
        self.refresh();
    }

    fn saveTicket(self: *Self) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().tickets.items.len) return;
        const ticket = self.private().tickets.items[index];
        const alloc = self.allocator();
        const content = self.currentEditorText() catch return;
        defer alloc.free(content);
        const json = vh.callJson(alloc, self.client(), "updateTicket", &.{
            .{ .key = "ticketId", .value = .{ .string = ticket.id } },
            .{ .key = "content", .value = .{ .string = content } },
        }) catch |err| {
            self.private().window.showToastFmt("Save failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("Saved {s}", .{ticket.id});
        self.setDraft(ticket.id, content) catch {};
        self.refresh();
    }

    fn deleteTicket(self: *Self) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().tickets.items.len) return;
        const ticket = self.private().tickets.items[index];
        const alloc = self.allocator();
        const json = vh.callJson(alloc, self.client(), "deleteTicket", &.{.{ .key = "ticketId", .value = .{ .string = ticket.id } }}) catch |err| {
            self.private().window.showToastFmt("Delete failed: {}", .{err});
            return;
        };
        defer alloc.free(json);
        self.private().window.showToastFmt("Deleted {s}", .{ticket.id});
        self.refresh();
    }

    fn confirmDeleteTicket(self: *Self) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().tickets.items.len) return;
        self.private().pending_delete_index = index;
        self.private().pending_bulk_delete = false;
        const ticket = self.private().tickets.items[index];
        const alloc = self.allocator();
        const body = std.fmt.allocPrintSentinel(alloc, "Delete ticket {s}? Type the ticket ID to confirm.", .{ticket.id}, 0) catch return;
        defer alloc.free(body);
        const dialog = adw.AlertDialog.new("Delete Ticket", body.ptr);
        const entry = gtk.Entry.new();
        const id_z = alloc.dupeZ(u8, ticket.id) catch return;
        defer alloc.free(id_z);
        entry.setPlaceholderText(id_z.ptr);
        _ = gtk.Editable.signals.changed.connect(entry.as(gtk.Editable), *Self, deleteConfirmChanged, self, .{});
        dialog.setExtraChild(entry.as(gtk.Widget));
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("delete", "Delete");
        dialog.setCloseResponse("cancel");
        dialog.setDefaultResponse("cancel");
        dialog.setResponseAppearance("delete", .destructive);
        dialog.setResponseEnabled("delete", 0);
        self.private().delete_dialog = dialog;
        self.private().delete_confirm_entry = entry;
        _ = adw.AlertDialog.signals.response.connect(dialog, *Self, deleteDialogResponse, self, .{});
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
    }

    fn confirmBulkDelete(self: *Self) void {
        const count = self.selectedCount();
        if (count == 0) {
            self.private().window.showToast("Select tickets first");
            return;
        }
        self.private().pending_delete_index = null;
        self.private().pending_bulk_delete = true;
        const alloc = self.allocator();
        const body = std.fmt.allocPrintSentinel(alloc, "Delete {d} selected ticket(s)? Type DELETE to confirm.", .{count}, 0) catch return;
        defer alloc.free(body);
        const dialog = adw.AlertDialog.new("Delete Selected Tickets", body.ptr);
        const entry = gtk.Entry.new();
        entry.setPlaceholderText("DELETE");
        _ = gtk.Editable.signals.changed.connect(entry.as(gtk.Editable), *Self, deleteConfirmChanged, self, .{});
        dialog.setExtraChild(entry.as(gtk.Widget));
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("delete", "Delete");
        dialog.setCloseResponse("cancel");
        dialog.setDefaultResponse("cancel");
        dialog.setResponseAppearance("delete", .destructive);
        dialog.setResponseEnabled("delete", 0);
        self.private().delete_dialog = dialog;
        self.private().delete_confirm_entry = entry;
        _ = adw.AlertDialog.signals.response.connect(dialog, *Self, deleteDialogResponse, self, .{});
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
    }

    fn bulkDeleteSelected(self: *Self) void {
        const alloc = self.allocator();
        var deleted: usize = 0;
        for (self.private().tickets.items, 0..) |ticket, index| {
            if (index >= self.private().selected.items.len or !self.private().selected.items[index]) continue;
            const json = vh.callJson(alloc, self.client(), "deleteTicket", &.{.{ .key = "ticketId", .value = .{ .string = ticket.id } }}) catch continue;
            alloc.free(json);
            deleted += 1;
        }
        self.private().window.showToastFmt("Deleted {d} ticket(s)", .{deleted});
        self.refresh();
    }

    fn selectedCount(self: *Self) usize {
        var count: usize = 0;
        for (self.private().selected.items) |selected| {
            if (selected) count += 1;
        }
        return count;
    }

    fn setDraft(self: *Self, ticket_id: []const u8, content: []const u8) !void {
        const alloc = self.allocator();
        if (self.private().draft_ticket_id) |old| alloc.free(old);
        if (self.private().draft_content) |old| alloc.free(old);
        self.private().draft_ticket_id = try alloc.dupe(u8, ticket_id);
        self.private().draft_content = try alloc.dupe(u8, content);
    }

    fn currentDraftFor(self: *Self, ticket_id: []const u8) ?[]const u8 {
        if (self.private().draft_ticket_id) |id| {
            if (std.mem.eql(u8, id, ticket_id)) return self.private().draft_content;
        }
        return null;
    }

    fn currentEditorText(self: *Self) ![]u8 {
        const index = self.private().selected_index orelse return self.allocator().dupe(u8, "");
        if (index >= self.private().tickets.items.len) return self.allocator().dupe(u8, "");
        const ticket = self.private().tickets.items[index];
        if (self.private().preview_mode) {
            return self.allocator().dupe(u8, self.currentDraftFor(ticket.id) orelse ticket.body orelse "");
        }
        return vh.markdownEditorText(self.allocator(), self.private().editor.as(gtk.Widget));
    }

    fn templateText(alloc: std.mem.Allocator, kind: []const u8, ticket_id: []const u8) ![]u8 {
        const title = if (ticket_id.len == 0) "Untitled" else ticket_id;
        if (std.mem.eql(u8, kind, "Bug")) {
            return std.fmt.allocPrint(alloc, "# {s}\n\n## Summary\n\n## Steps to Reproduce\n- \n\n## Expected\n\n## Actual\n\nTags: bug\n", .{title});
        }
        if (std.mem.eql(u8, kind, "Task")) {
            return std.fmt.allocPrint(alloc, "# {s}\n\n## Summary\n\n## Checklist\n- [ ] \n\nTags: task\n", .{title});
        }
        return std.fmt.allocPrint(alloc, "# {s}\n\n## Summary\n\n## Acceptance Criteria\n- \n\nTags: feature\n", .{title});
    }

    fn ticketMatchesQuery(ticket: vh.Item, query: []const u8) bool {
        return vh.containsIgnoreCase(ticket.id, query) or
            vh.containsIgnoreCase(ticket.title, query) or
            (ticket.body != null and vh.containsIgnoreCase(ticket.body.?, query));
    }

    fn ticketHasTag(ticket: vh.Item, tag: []const u8) bool {
        const body = ticket.body orelse return false;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (std.mem.startsWith(u8, trimmed, "#")) continue;
            if (std.mem.indexOf(u8, trimmed, "Tags:")) |pos| {
                if (vh.containsIgnoreCase(trimmed[pos + 5 ..], tag)) return true;
            }
            if (std.mem.indexOf(u8, trimmed, "tags:")) |pos| {
                if (vh.containsIgnoreCase(trimmed[pos + 5 ..], tag)) return true;
            }
            if (std.mem.startsWith(u8, trimmed, "#") and vh.containsIgnoreCase(trimmed, tag)) return true;
        }
        return vh.containsIgnoreCase(body, "#") and vh.containsIgnoreCase(body, tag);
    }

    fn ticketSnippet(alloc: std.mem.Allocator, content: []const u8) ![]u8 {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#") or std.mem.startsWith(u8, trimmed, "---")) continue;
            if (trimmed.len <= 92) return alloc.dupe(u8, trimmed);
            return std.fmt.allocPrint(alloc, "{s}...", .{trimmed[0..89]});
        }
        return alloc.dupe(u8, "");
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn searchActivated(_: *gtk.Entry, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn searchChanged(_: *gtk.Editable, self: *Self) callconv(.c) void {
        self.renderList() catch {};
    }

    fn tagChanged(_: *gtk.Editable, self: *Self) callconv(.c) void {
        self.renderList() catch {};
    }

    fn filterClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const raw = button.as(gobject.Object).getData("smithers-ticket-filter") orelse return;
        const text = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        self.private().status_filter = if (std.mem.eql(u8, text, "All")) null else if (std.mem.eql(u8, text, "Open")) "open" else "closed";
        self.renderList() catch {};
    }

    fn newClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.private().create_visible = !self.private().create_visible;
        if (self.private().create_visible) self.renderCreate() catch {} else self.refresh();
    }

    fn rowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const visible_index = vh.getIndex(row.as(gobject.Object)) orelse return;
        if (visible_index >= self.private().visible_rows.items.len) return;
        const index = self.private().visible_rows.items[visible_index];
        self.private().selected_index = index;
        self.private().create_visible = false;
        self.private().preview_mode = false;
        const ticket = self.private().tickets.items[index];
        self.setDraft(ticket.id, ticket.body orelse "") catch {};
        self.renderDetail(index) catch {};
    }

    fn createClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.createTicket();
    }

    fn saveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.saveTicket();
    }

    fn renameClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.renameTicket();
    }

    fn previewClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().tickets.items.len) return;
        if (!self.private().preview_mode) {
            const ticket = self.private().tickets.items[index];
            const content = self.currentEditorText() catch return;
            defer self.allocator().free(content);
            self.setDraft(ticket.id, content) catch return;
        }
        self.private().preview_mode = !self.private().preview_mode;
        self.renderDetail(index) catch {};
    }

    fn deleteClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.confirmDeleteTicket();
    }

    fn templateClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const raw = button.as(gobject.Object).getData("smithers-ticket-template") orelse return;
        const kind = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
        const alloc = self.allocator();
        const text = templateText(alloc, kind, vh.trimEntryText(self.private().id_entry)) catch return;
        defer alloc.free(text);
        self.private().create_editor.setMarkdown(text) catch {};
    }

    fn selectAllClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const all_selected = self.selectedCount() == self.private().visible_rows.items.len and self.private().visible_rows.items.len > 0;
        for (self.private().visible_rows.items) |index| {
            if (index < self.private().selected.items.len) self.private().selected.items[index] = !all_selected;
        }
        self.renderList() catch {};
    }

    fn bulkDeleteClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.confirmBulkDelete();
    }

    fn selectionToggled(button: *gtk.CheckButton, self: *Self) callconv(.c) void {
        const index = vh.getIndex(button.as(gobject.Object)) orelse return;
        if (index >= self.private().selected.items.len) return;
        self.private().selected.items[index] = button.getActive() != 0;
    }

    fn deleteConfirmChanged(_: *gtk.Editable, self: *Self) callconv(.c) void {
        const dialog = self.private().delete_dialog orelse return;
        const entry = self.private().delete_confirm_entry orelse return;
        const text = vh.trimEntryText(entry);
        const enabled = if (self.private().pending_bulk_delete)
            std.mem.eql(u8, text, "DELETE")
        else enabled: {
            const index = self.private().pending_delete_index orelse break :enabled false;
            if (index >= self.private().tickets.items.len) break :enabled false;
            break :enabled std.mem.eql(u8, text, self.private().tickets.items[index].id);
        };
        dialog.setResponseEnabled("delete", if (enabled) 1 else 0);
    }

    fn deleteDialogResponse(_: *adw.AlertDialog, response: [*:0]u8, self: *Self) callconv(.c) void {
        defer {
            self.private().pending_delete_index = null;
            self.private().pending_bulk_delete = false;
            self.private().delete_dialog = null;
            self.private().delete_confirm_entry = null;
        }
        if (std.mem.orderZ(u8, response, "delete") != .eq) {
            return;
        }
        if (self.private().pending_bulk_delete) {
            self.bulkDeleteSelected();
            return;
        }
        self.private().selected_index = self.private().pending_delete_index;
        self.deleteTicket();
    }

    fn shortcutRefresh(self: *Self) void {
        self.refresh();
    }

    fn shortcutSearch(self: *Self) void {
        _ = self.private().search.as(gtk.Widget).grabFocus();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (!priv.did_dispose) {
            priv.did_dispose = true;
            vh.clearItems(self.allocator(), &priv.tickets);
            priv.tickets.deinit(self.allocator());
            priv.visible_rows.deinit(self.allocator());
            priv.selected.deinit(self.allocator());
            if (priv.draft_ticket_id) |id| self.allocator().free(id);
            if (priv.draft_content) |content| self.allocator().free(content);
            ui.clearBox(self.as(gtk.Box));
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
