//! Sidebar component: saved folders from `Config` and directory entry browser.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const config_mod = @import("config.zig");

pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
};

pub const Sidebar = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod.Config,
    config_path: []const u8,

    current_dir: ?[]const u8 = null,
    entries_arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    selected_name: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) Sidebar {
        const cfg = config_mod.Config.load(allocator, io, config_path) catch config_mod.Config.init(allocator);
        var s: Sidebar = .{
            .allocator = allocator,
            .io = io,
            .config = cfg,
            .config_path = allocator.dupe(u8, config_path) catch config_path,
            .entries_arena = .init(allocator),
        };
        if (s.config.folders.items.len > 0) {
            s.openDir(s.config.folders.items[0].path);
        }
        return s;
    }

    pub fn deinit(self: *Sidebar) void {
        if (self.selected_name) |n| self.allocator.free(n);
        self.entries_arena.deinit();
        if (self.current_dir) |d| self.allocator.free(d);
        self.allocator.free(self.config_path);
        self.config.deinit();
    }

    /// Opens `path` and populates sorted directory entries.
    pub fn openDir(self: *Sidebar, path: []const u8) void {
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        if (self.current_dir) |old| self.allocator.free(old);
        self.current_dir = self.allocator.dupe(u8, path) catch null;
        if (self.selected_name) |n| {
            self.allocator.free(n);
            self.selected_name = null;
        }

        self.entries = .empty;
        _ = self.entries_arena.reset(.retain_capacity);
        const arena = self.entries_arena.allocator();

        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            const name = arena.dupe(u8, entry.name) catch continue;
            self.entries.append(arena, .{ .name = name, .is_dir = entry.kind == .directory }) catch continue;
        }
        std.mem.sort(Entry, self.entries.items, {}, compareEntries);
    }

    /// Selects a file or navigates into a subdirectory at `index`.
    pub fn selectEntry(self: *Sidebar, index: usize) void {
        const cur = self.current_dir orelse return;
        if (index >= self.entries.items.len) return;
        const entry = self.entries.items[index];

        if (entry.is_dir) {
            const next = std.fs.path.join(self.allocator, &.{ cur, entry.name }) catch return;
            defer self.allocator.free(next);
            self.openDir(next);
            return;
        }

        if (self.selected_name) |old| self.allocator.free(old);
        self.selected_name = self.allocator.dupe(u8, entry.name) catch null;
    }

    pub fn view(self: *Sidebar, c: *ui.Context) void {
        const root = ui.div(c).column().w(260).hFull().bg(c.theme.surface);
        defer root.end();

        const header = ui.div(c).row().wFull().p(12).itemsCenter().justifyBetween().gap(8);
        {
            defer header.end();
            ui.text(c, "Ilgi", .{ .size = 16, .weight = .bold });
            if (kit.button(c, "Add", .{ .variant = .secondary, .size = .sm, .icon = "plus" }).clicked) {
                self.pickFolder();
            }
        }

        if (self.config.folders.items.len > 0) {
            ui.divider(c);
            const folders_box = ui.div(c).column().wFull().p(6).gap(2);
            defer folders_box.end();

            for (self.config.folders.items, 0..) |folder, i| {
                ui.keyInt(c, 100_000 + i);
                const is_active = if (self.current_dir) |cur| std.mem.eql(u8, cur, folder.path) else false;
                const row = ui.div(c).row().wFull().itemsCenter().gap(2);
                defer row.end();

                var btn = ui.div(c).row().grow().px(8).py(5).rounded(6).itemsCenter().gap(6).control();
                btn = if (is_active) btn.bg(c.theme.surface_hover) else btn.hover(c.theme.surface_hover);
                {
                    defer btn.end();
                    ui.icon(c, "folder.fill", .{ .size = 12, .color = if (is_active) c.theme.accent else c.theme.muted });
                    const nb = ui.div(c).grow().clip();
                    defer nb.end();
                    ui.text(c, folder.name, .{ .size = 12.5, .weight = if (is_active) .semibold else .regular, .truncate = .ellipsis });
                }
                if (btn.clicked()) {
                    self.openDir(folder.path);
                    return;
                }
                if (kit.iconButton(c, "xmark", .{ .size = .xs, .tooltip = "Remove folder" }).clicked) {
                    if (self.config.removeFolder(folder.path)) {
                        self.config.save(self.io, self.config_path) catch {};
                        if (is_active) {
                            self.allocator.free(self.current_dir.?);
                            self.current_dir = null;
                            self.entries = .empty;
                            if (self.config.folders.items.len > 0) self.openDir(self.config.folders.items[0].path);
                        }
                    }
                    return;
                }
            }
        }

        ui.divider(c);
        const list = ui.div(c).column().grow().wFull().p(6).gap(2).scrollY();
        defer list.end();

        if (self.current_dir == null) {
            const box = ui.div(c).wFull().p(12);
            defer box.end();
            ui.text(c, "No folder open. Click + Add.", .{ .size = 12.5, .color = c.theme.muted });
            return;
        }

        if (std.fs.path.dirname(self.current_dir.?)) |parent| {
            ui.key(c, "..");
            const up = ui.div(c).row().wFull().px(8).py(6).rounded(6).itemsCenter().gap(8).control().hover(c.theme.surface_hover);
            {
                defer up.end();
                ui.icon(c, "arrow.up", .{ .size = 12, .color = c.theme.muted });
                ui.text(c, "..", .{ .size = 13, .color = c.theme.muted });
            }
            if (up.clicked()) {
                self.openDir(parent);
                return;
            }
        }

        for (self.entries.items, 0..) |entry, i| {
            ui.keyInt(c, i);
            const selected = if (self.selected_name) |sn| std.mem.eql(u8, sn, entry.name) else false;
            var row = ui.div(c).row().wFull().px(8).py(6).rounded(6).itemsCenter().gap(8).control();
            row = if (selected) row.bg(c.theme.accent) else row.hover(c.theme.surface_hover);
            {
                defer row.end();
                ui.icon(c, if (entry.is_dir) "folder" else "doc.text", .{
                    .size = 13,
                    .color = if (selected) c.theme.accent_text else c.theme.muted,
                });
                const nb = ui.div(c).grow().clip();
                defer nb.end();
                ui.text(c, entry.name, .{
                    .size = 13,
                    .color = if (selected) c.theme.accent_text else c.theme.text,
                    .truncate = .ellipsis,
                });
            }
            if (row.clicked()) {
                self.selectEntry(i);
                return;
            }
        }
    }

    fn pickFolder(self: *Sidebar) void {
        const chosen = nanoui.dialog.open(self.allocator, .{
            .title = "Add Folder",
            .files = false,
            .directories = true,
            .multiple = false,
            .directory = self.current_dir orelse ".",
        }) catch return;
        const paths = chosen orelse return;
        defer nanoui.dialog.freePaths(self.allocator, paths);
        if (paths.len > 0) {
            if (self.config.addFolder(paths[0], null) catch false) {
                self.config.save(self.io, self.config_path) catch {};
            }
            self.openDir(paths[0]);
        }
    }
};

fn compareEntries(_: void, a: Entry, b: Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
}
