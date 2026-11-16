//! Ilgi's root layout shell.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const sidebar_mod = @import("sidebar.zig");
const viewer_mod = @import("viewer.zig");

pub const State = struct {
    sidebar: sidebar_mod.Sidebar,
    viewer: viewer_mod.Viewer,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) State {
        return .{
            .sidebar = .init(allocator, io, config_path),
            .viewer = .init(allocator, io),
        };
    }

    pub fn deinit(self: *State) void {
        self.viewer.deinit();
        self.sidebar.deinit();
    }

    pub fn view(self: *State, c: *ui.Context) void {
        const root = ui.div(c).row().sizeFull().bg(c.theme.background);
        defer root.end();

        self.sidebar.view(c);
        ui.div(c).w(1).hFull().bg(c.theme.border).end();

        if (self.sidebar.current_dir != null and self.sidebar.selected_name != null) {
            self.viewer.open(self.sidebar.current_dir.?, self.sidebar.selected_name.?);
        } else {
            self.viewer.clear();
        }
        self.viewer.view(c);
    }
};
