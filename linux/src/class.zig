//! GObject class exports and shared helpers for the Smithers GTK apprt.

const gobject = @import("gobject");

pub const Application = @import("class/application.zig").Application;
pub const MainWindow = @import("class/main_window.zig").MainWindow;
pub const Sidebar = @import("class/sidebar.zig").Sidebar;
pub const CommandPalette = @import("class/command_palette.zig").CommandPalette;
pub const NewTabPicker = @import("class/new_tab_picker.zig").NewTabPicker;
pub const SessionWidget = @import("class/session.zig").SessionWidget;

pub fn Common(comptime Self: type, comptime Private: ?type) type {
    return struct {
        pub fn as(self: *Self, comptime T: type) *T {
            return gobject.ext.as(T, self);
        }

        pub fn ref(self: *Self) *Self {
            return @ptrCast(@alignCast(gobject.Object.ref(self.as(gobject.Object))));
        }

        pub fn refSink(self: *Self) *Self {
            return @ptrCast(@alignCast(gobject.Object.refSink(self.as(gobject.Object))));
        }

        pub fn unref(self: *Self) void {
            gobject.Object.unref(self.as(gobject.Object));
        }

        pub const private = if (Private) |P| (struct {
            fn private(self: *Self) *P {
                return gobject.ext.impl_helpers.getPrivate(self, P, P.offset);
            }
        }).private else {};

        pub const Class = struct {
            pub fn as(class: *Self.Class, comptime T: type) *T {
                return gobject.ext.as(T, class);
            }
        };
    };
}

test {
    @import("std").testing.refAllDecls(@This());
}
