const glib = @import("glib");
const gtk = @import("gtk");

pub const App = opaque {};
pub const Surface = opaque {};

pub const Error = error{
    AppCreateFailed,
    SurfaceCreateFailed,
};

extern fn ghostty_gtk_app_new() ?*App;
extern fn ghostty_gtk_app_free(app: *App) void;
extern fn ghostty_gtk_app_tick(app: *App) void;
extern fn ghostty_gtk_surface_new(app: *App) ?*Surface;
extern fn ghostty_gtk_surface_widget(surface: *Surface) *gtk.Widget;
extern fn ghostty_gtk_surface_free(surface: *Surface) void;
extern fn ghostty_gtk_surface_redraw(surface: *Surface) void;
extern fn ghostty_gtk_surface_title(surface: *Surface) ?[*:0]const u8;
extern fn ghostty_gtk_surface_binding_action(surface: *Surface, action_ptr: [*]const u8, action_len: usize) bool;

var app: ?*App = null;
var tick_source: ?c_uint = null;

pub fn ensureApp() Error!*App {
    if (app) |existing| return existing;
    const created = ghostty_gtk_app_new() orelse return error.AppCreateFailed;
    app = created;
    tick_source = glib.timeoutAdd(8, tickCallback, null);
    return created;
}

pub fn shutdown() void {
    if (tick_source) |source| {
        _ = glib.Source.remove(source);
        tick_source = null;
    }
    if (app) |existing| {
        ghostty_gtk_app_free(existing);
        app = null;
    }
}

pub fn newSurface() Error!*Surface {
    const existing = try ensureApp();
    return ghostty_gtk_surface_new(existing) orelse error.SurfaceCreateFailed;
}

pub fn widget(surface: *Surface) *gtk.Widget {
    return ghostty_gtk_surface_widget(surface);
}

pub fn freeSurface(surface: *Surface) void {
    ghostty_gtk_surface_free(surface);
}

pub fn redraw(surface: *Surface) void {
    ghostty_gtk_surface_redraw(surface);
}

pub fn title(surface: *Surface) ?[*:0]const u8 {
    return ghostty_gtk_surface_title(surface);
}

pub fn bindingAction(surface: *Surface, action: []const u8) bool {
    return ghostty_gtk_surface_binding_action(surface, action.ptr, action.len);
}

fn tickCallback(_: ?*anyopaque) callconv(.c) c_int {
    if (app) |existing| {
        ghostty_gtk_app_tick(existing);
        return @intFromBool(glib.SOURCE_CONTINUE);
    }
    tick_source = null;
    return @intFromBool(glib.SOURCE_REMOVE);
}
