const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const smithers = @import("../smithers.zig");
const ui = @import("../ui.zig");
const Common = @import("../class.zig").Common;
const vh = @import("../features/view_helpers.zig");
const MainWindow = @import("main_window.zig").MainWindow;

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
        create_text: *gtk.TextView = undefined,
        editor: *gtk.TextView = undefined,
        tickets: std.ArrayList(vh.Item) = .empty,
        selected_index: ?usize = null,
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
        const header = vh.makeHeader("Tickets", null);
        self.private().search = gtk.Entry.new();
        self.private().search.setPlaceholderText("Search tickets");
        self.private().search.as(gtk.Widget).setSizeRequest(220, -1);
        _ = gtk.Entry.signals.activate.connect(self.private().search, *Self, searchActivated, self, .{});
        header.append(self.private().search.as(gtk.Widget));
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
        for (self.private().tickets.items, 0..) |ticket, index| {
            const row = try vh.itemRow(alloc, ticket, "text-x-generic-symbolic");
            vh.setIndex(row.as(gobject.Object), index);
            self.private().list.append(row.as(gtk.Widget));
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
        self.private().create_text = vh.textView(true);
        const scroll = ui.scrolled(self.private().create_text.as(gtk.Widget));
        scroll.as(gtk.Widget).setSizeRequest(-1, 240);
        detail.append(scroll.as(gtk.Widget));
        const create = ui.textButton("Create", true);
        _ = gtk.Button.signals.clicked.connect(create, *Self, createClicked, self, .{});
        detail.append(create.as(gtk.Widget));
        _ = alloc;
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
        self.private().editor = vh.textView(true);
        try vh.setTextViewText(alloc, self.private().editor, ticket.body orelse "");
        const scroll = ui.scrolled(self.private().editor.as(gtk.Widget));
        scroll.as(gtk.Widget).setSizeRequest(-1, 360);
        detail.append(scroll.as(gtk.Widget));
        const actions = gtk.Box.new(.horizontal, 8);
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
        const content = vh.getTextViewText(alloc, self.private().create_text) catch return;
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
        const content = vh.getTextViewText(alloc, self.private().editor) catch return;
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

    fn refreshClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn searchActivated(_: *gtk.Entry, self: *Self) callconv(.c) void {
        self.refresh();
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
        self.deleteTicket();
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
