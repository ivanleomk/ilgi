//! Ilgi's root layout shell.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const sidebar_mod = @import("sidebar.zig");

pub const State = struct {
    sidebar: sidebar_mod.Sidebar,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) State {
        return .{ .sidebar = .init(allocator, io, config_path) };
    }

    pub fn deinit(self: *State) void {
        self.sidebar.deinit();
    }

    pub fn view(self: *State, c: *ui.Context) void {
        const root = ui.div(c).row().sizeFull().bg(c.theme.background);
        defer root.end();

        self.sidebar.view(c);
        ui.div(c).w(1).hFull().bg(c.theme.border).end();

        const main_pane = ui.div(c).column().grow().hFull().itemsCenter().justifyCenter().gap(8);
        defer main_pane.end();
        ui.text(c, self.sidebar.selected_name orelse "Ilgi", .{ .size = 24, .weight = .bold });
        if (self.sidebar.selected_name == null) {
            ui.text(c, "Local-first Markdown & knowledge vault", .{ .size = 14, .color = c.theme.muted });
        }
    }
};
