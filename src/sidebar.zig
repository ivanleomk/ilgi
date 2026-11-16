//! Sidebar component: collapsible per-folder trees backed by `Config`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const config_mod = @import("config.zig");

const max_tree_depth = 16;

pub const TreeRow = struct {
    name: []const u8,
    full_path: []const u8,
    dir_path: []const u8,
    is_dir: bool,
    is_root: bool,
    depth: u16,
    expanded: bool,
};

const DirEntry = struct {
    name: []const u8,
    is_dir: bool,
};

pub const Sidebar = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod.Config,
    config_path: []const u8,

    expanded: std.StringHashMapUnmanaged(void) = .empty,
    tree_arena: std.heap.ArenaAllocator,
    rows: std.ArrayList(TreeRow) = .empty,

    selected_dir: ?[]const u8 = null,
    selected_name: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) Sidebar {
        const cfg = config_mod.Config.load(allocator, io, config_path) catch config_mod.Config.init(allocator);
        var s: Sidebar = .{
            .allocator = allocator,
            .io = io,
            .config = cfg,
            .config_path = allocator.dupe(u8, config_path) catch config_path,
            .tree_arena = .init(allocator),
        };
        for (s.config.folders.items) |folder| {
            s.setExpanded(folder.path, true);
        }
        s.rebuildTree();
        return s;
    }

    pub fn deinit(self: *Sidebar) void {
        self.clearSelection();
        var it = self.expanded.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.expanded.deinit(self.allocator);
        self.tree_arena.deinit();
        self.allocator.free(self.config_path);
        self.config.deinit();
    }

    /// Rebuilds the flattened visible tree from `config.folders` and `expanded`.
    pub fn rebuildTree(self: *Sidebar) void {
        self.rows = .empty;
        _ = self.tree_arena.reset(.retain_capacity);
        const arena = self.tree_arena.allocator();

        for (self.config.folders.items) |folder| {
            const is_open = self.expanded.contains(folder.path);
            const name = arena.dupe(u8, folder.name) catch continue;
            const path = arena.dupe(u8, folder.path) catch continue;
            self.rows.append(arena, .{
                .name = name,
                .full_path = path,
                .dir_path = path,
                .is_dir = true,
                .is_root = true,
                .depth = 0,
                .expanded = is_open,
            }) catch continue;
            if (is_open) self.appendChildren(arena, path, 1);
        }
    }

    /// Toggles a directory open/closed or selects a file at `index` in `rows`.
    pub fn selectRow(self: *Sidebar, index: usize) void {
        if (index >= self.rows.items.len) return;
        const row = self.rows.items[index];

        if (row.is_dir) {
            self.setExpanded(row.full_path, !row.expanded);
            self.rebuildTree();
            return;
        }

        self.clearSelection();
        self.selected_dir = self.allocator.dupe(u8, row.dir_path) catch null;
        self.selected_name = self.allocator.dupe(u8, row.name) catch null;
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

        ui.divider(c);
        const list = ui.div(c).column().grow().wFull().p(6).gap(2).scrollY();
        defer list.end();

        if (self.rows.items.len == 0) {
            const box = ui.div(c).wFull().p(12);
            defer box.end();
            ui.text(c, "No folders yet. Click + Add.", .{ .size = 12.5, .color = c.theme.muted });
            return;
        }

        for (self.rows.items, 0..) |row, i| {
            ui.keyInt(c, i);
            const selected = self.isSelectedFile(row);
            const indent: f32 = @as(f32, @floatFromInt(row.depth)) * 14 + 8;

            const outer = ui.div(c).row().wFull().itemsCenter().gap(2);
            defer outer.end();

            var btn = ui.div(c).row().grow().pl(indent).pr(8).py(5).rounded(6).itemsCenter().gap(6).control();
            btn = if (selected) btn.bg(c.theme.accent) else btn.hover(c.theme.surface_hover);
            {
                defer btn.end();
                const fg = if (selected) c.theme.accent_text else c.theme.text;
                const icon_fg = if (selected) c.theme.accent_text else c.theme.muted;

                if (row.is_dir) {
                    ui.icon(c, if (row.expanded) "chevron.down" else "chevron.right", .{ .size = 10, .color = icon_fg });
                    ui.icon(c, if (row.is_root) "folder.fill" else "folder", .{ .size = 13, .color = if (row.is_root) c.theme.accent else icon_fg });
                } else {
                    ui.icon(c, "doc.text", .{ .size = 13, .color = icon_fg });
                }

                const nb = ui.div(c).grow().clip();
                defer nb.end();
                ui.text(c, row.name, .{
                    .size = 13,
                    .weight = if (row.is_root) .semibold else .regular,
                    .color = fg,
                    .truncate = .ellipsis,
                });
            }

            if (btn.clicked()) {
                self.selectRow(i);
                return;
            }
            if (row.is_root and kit.iconButton(c, "xmark", .{ .size = .xs, .tooltip = "Remove folder" }).clicked) {
                if (self.config.removeFolder(row.full_path)) {
                    self.config.save(self.io, self.config_path) catch {};
                    self.setExpanded(row.full_path, false);
                    if (self.selected_dir) |sd| {
                        if (std.mem.startsWith(u8, sd, row.full_path)) self.clearSelection();
                    }
                    self.rebuildTree();
                }
                return;
            }
        }
    }

    fn appendChildren(self: *Sidebar, arena: std.mem.Allocator, dir_path: []const u8, depth: u16) void {
        if (depth > max_tree_depth) return;
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var items: std.ArrayList(DirEntry) = .empty;
        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            const name = arena.dupe(u8, entry.name) catch continue;
            items.append(arena, .{ .name = name, .is_dir = entry.kind == .directory }) catch continue;
        }
        std.mem.sort(DirEntry, items.items, {}, compareEntries);

        for (items.items) |entry| {
            const full = std.fs.path.join(arena, &.{ dir_path, entry.name }) catch continue;
            const is_open = entry.is_dir and self.expanded.contains(full);
            self.rows.append(arena, .{
                .name = entry.name,
                .full_path = full,
                .dir_path = dir_path,
                .is_dir = entry.is_dir,
                .is_root = false,
                .depth = depth,
                .expanded = is_open,
            }) catch continue;
            if (is_open) self.appendChildren(arena, full, depth + 1);
        }
    }

    fn setExpanded(self: *Sidebar, path: []const u8, expand: bool) void {
        if (expand) {
            if (self.expanded.contains(path)) return;
            const key = self.allocator.dupe(u8, path) catch return;
            self.expanded.put(self.allocator, key, {}) catch self.allocator.free(key);
        } else if (self.expanded.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    fn isSelectedFile(self: *const Sidebar, row: TreeRow) bool {
        if (row.is_dir) return false;
        const sd = self.selected_dir orelse return false;
        const sn = self.selected_name orelse return false;
        return std.mem.eql(u8, sd, row.dir_path) and std.mem.eql(u8, sn, row.name);
    }

    fn clearSelection(self: *Sidebar) void {
        if (self.selected_dir) |d| {
            self.allocator.free(d);
            self.selected_dir = null;
        }
        if (self.selected_name) |n| {
            self.allocator.free(n);
            self.selected_name = null;
        }
    }

    fn pickFolder(self: *Sidebar) void {
        const chosen = nanoui.dialog.open(self.allocator, .{
            .title = "Add Folder",
            .files = false,
            .directories = true,
            .multiple = false,
            .directory = ".",
        }) catch return;
        const paths = chosen orelse return;
        defer nanoui.dialog.freePaths(self.allocator, paths);
        if (paths.len > 0) {
            if (self.config.addFolder(paths[0], null) catch false) {
                self.config.save(self.io, self.config_path) catch {};
            }
            self.setExpanded(paths[0], true);
            self.rebuildTree();
        }
    }
};

fn compareEntries(_: void, a: DirEntry, b: DirEntry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
}
