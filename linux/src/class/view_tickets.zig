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
        id_entry: *gtk.Entry = undefined,
        create_editor: *MarkdownEditor = undefined,
        editor: *MarkdownEditor = undefined,
        tickets: std.ArrayList(vh.Item) = .empty,
        selected_index: ?usize = null,
        status_filter: ?[]const u8 = null,
        pending_delete_index: ?usize = null,
        create_visible: bool = false,
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
        inline for (.{ "All", "Open", "Closed" }) |label| {
            const button = ui.textButton(label, false);
            button.as(gobject.Object).setData("smithers-ticket-filter", @constCast(label.ptr));
            _ = gtk.Button.signals.clicked.connect(button, *Self, filterClicked, self, .{});
            header.append(button.as(gtk.Widget));
        }
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
        const query = std.mem.trim(u8, std.mem.span(self.private().search.as(gtk.Editable).getText()), &std.ascii.whitespace);
        const json = if (query.len == 0)
            try smithers.callJson(alloc, self.client(), "listTickets", "{}")
        else
            try vh.callJson(alloc, self.client(), "searchTickets", &.{.{ .key = "query", .value = .{ .string = query } }});
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
        self.private().selected_index = null;
        try self.renderList();
        if (self.private().create_visible) try self.renderCreate() else vh.setStatus(alloc, self.private().detail, "text-x-generic-symbolic", "Select a ticket", "Create, edit, and delete Smithers tickets.");
    }

    fn renderList(self: *Self) !void {
        const alloc = self.allocator();
        ui.clearList(self.private().list);
        if (self.private().tickets.items.len == 0) {
            self.private().list.append((try ui.row(alloc, "text-x-generic-symbolic", "No tickets found", "Create a ticket with the plus button.")).as(gtk.Widget));
            return;
        }
        var visible: usize = 0;
        for (self.private().tickets.items, 0..) |ticket, index| {
            if (self.private().status_filter) |status| {
                if (ticket.status == null or !std.ascii.eqlIgnoreCase(ticket.status.?, status)) continue;
            }
            const row = try vh.itemRow(alloc, ticket, "text-x-generic-symbolic");
            vh.setIndex(row.as(gobject.Object), index);
            self.private().list.append(row.as(gtk.Widget));
            visible += 1;
        }
        if (visible == 0) {
            self.private().list.append((try ui.row(alloc, "system-search-symbolic", "No tickets match filters", "Adjust search or status filter.")).as(gtk.Widget));
        }
    }

    fn renderCreate(self: *Self) !void {
        const alloc = self.allocator();
        const detail = self.private().detail;
        ui.clearBox(detail);
        detail.append(ui.heading("New Ticket").as(gtk.Widget));
        self.private().id_entry = gtk.Entry.new();
        self.private().id_entry.setPlaceholderText("ticket-id");
        detail.append(self.private().id_entry.as(gtk.Widget));
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
        const title_z = try alloc.dupeZ(u8, ticket.id);
        defer alloc.free(title_z);
        detail.append(ui.heading(title_z).as(gtk.Widget));
        try vh.detailRow(alloc, detail, "Status", ticket.status);
        self.private().editor = try MarkdownEditor.new(alloc, ticket.body orelse "");
        self.private().editor.as(gtk.Widget).setSizeRequest(-1, 380);
        detail.append(self.private().editor.as(gtk.Widget));
        const actions = vh.actionBar();
        const save = ui.textButton("Save", true);
        _ = gtk.Button.signals.clicked.connect(save, *Self, saveClicked, self, .{});
        actions.append(save.as(gtk.Widget));
        const delete = ui.textButton("Delete", false);
        delete.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(delete, *Self, deleteClicked, self, .{});
        actions.append(delete.as(gtk.Widget));
        detail.append(actions.as(gtk.Widget));
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

    fn saveTicket(self: *Self) void {
        const index = self.private().selected_index orelse return;
        if (index >= self.private().tickets.items.len) return;
        const ticket = self.private().tickets.items[index];
        const alloc = self.allocator();
        const content = vh.markdownEditorText(alloc, self.private().editor.as(gtk.Widget)) catch return;
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
        const ticket = self.private().tickets.items[index];
        const alloc = self.allocator();
        const body = std.fmt.allocPrintSentinel(alloc, "Delete ticket {s}? This cannot be undone.", .{ticket.id}, 0) catch return;
        defer alloc.free(body);
        const dialog = adw.AlertDialog.new("Delete Ticket", body.ptr);
        dialog.addResponse("cancel", "Cancel");
        dialog.addResponse("delete", "Delete");
        dialog.setCloseResponse("cancel");
        dialog.setDefaultResponse("cancel");
        dialog.setResponseAppearance("delete", .destructive);
        _ = adw.AlertDialog.signals.response.connect(dialog, *Self, deleteDialogResponse, self, .{});
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
    }

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn searchActivated(_: *gtk.Entry, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn searchChanged(_: *gtk.Editable, self: *Self) callconv(.c) void {
        self.refresh();
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
        const index = vh.getIndex(row.as(gobject.Object)) orelse return;
        self.private().selected_index = index;
        self.private().create_visible = false;
        self.renderDetail(index) catch {};
    }

    fn createClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.createTicket();
    }

    fn saveClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.saveTicket();
    }

    fn deleteClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.confirmDeleteTicket();
    }

    fn deleteDialogResponse(_: *adw.AlertDialog, response: [*:0]u8, self: *Self) callconv(.c) void {
        if (std.mem.orderZ(u8, response, "delete") != .eq) {
            self.private().pending_delete_index = null;
            return;
        }
        self.private().selected_index = self.private().pending_delete_index;
        self.private().pending_delete_index = null;
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
