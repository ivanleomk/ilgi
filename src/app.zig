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

        if (self.viewer.pending_link) |target| {
            self.sidebar.openLink(target);
            self.viewer.allocator.free(target);
            self.viewer.pending_link = null;
        }

        if (self.sidebar.selected_dir != null and self.sidebar.selected_name != null) {
            self.viewer.open(self.sidebar.selected_dir.?, self.sidebar.selected_name.?);
        } else {
            self.viewer.clear();
        }
        var entries: std.ArrayList(viewer_mod.NoteEntry) = .empty;
        for (self.sidebar.rows.items) |row| {
            if (row.is_dir) continue;
            var rel: []const u8 = row.name;
            for (self.sidebar.config.folders.items) |f| {
                if (std.mem.startsWith(u8, row.full_path, f.path) and row.full_path.len > f.path.len + 1 and row.full_path[f.path.len] == '/') {
                    rel = row.full_path[f.path.len + 1 ..];
                    break;
                }
            }
            entries.append(c.alloc(), .{ .name = row.name, .rel_path = rel, .full_path = row.full_path }) catch break;
        }
        self.viewer.note_entries = entries.items;
        self.viewer.view(c);
    }
};
