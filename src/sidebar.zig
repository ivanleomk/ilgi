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

    creating_kind: enum { file, folder } = .file,
    creating_in: ?[]const u8 = null,
    new_name_buf: ui.TextBuffer = .{},

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
        if (self.creating_in) |p| self.allocator.free(p);
        self.new_name_buf.deinit();
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

    /// Creates a new empty file in `dir_path` and selects it.
    pub fn createFile(self: *Sidebar, dir_path: []const u8, name: []const u8) !void {
        const clean = std.mem.trim(u8, name, " \t\r\n");
        if (clean.len == 0) return error.InvalidName;
        var dir = try std.Io.Dir.cwd().openDir(self.io, dir_path, .{});
        defer dir.close(self.io);
        try dir.writeFile(self.io, .{ .sub_path = clean, .data = "" });

        self.setExpanded(dir_path, true);
        self.clearSelection();
        self.selected_dir = self.allocator.dupe(u8, dir_path) catch null;
        self.selected_name = self.allocator.dupe(u8, clean) catch null;
        self.rebuildTree();
    }

    /// Creates a new subfolder in `dir_path` and expands it.
    pub fn createFolder(self: *Sidebar, dir_path: []const u8, name: []const u8) !void {
        const clean = std.mem.trim(u8, name, " \t\r\n");
        if (clean.len == 0) return error.InvalidName;
        var dir = try std.Io.Dir.cwd().openDir(self.io, dir_path, .{});
        defer dir.close(self.io);
        try dir.createDirPath(self.io, clean);

        self.setExpanded(dir_path, true);
        const full = try std.fs.path.join(self.allocator, &.{ dir_path, clean });
        defer self.allocator.free(full);
        self.setExpanded(full, true);
        self.rebuildTree();
    }

    /// Deletes a non-root file or folder at `index` in `rows`.
    pub fn deleteRow(self: *Sidebar, index: usize) !void {
        if (index >= self.rows.items.len) return;
        const row = self.rows.items[index];
        if (row.is_root) return;

        const parent_path = std.fs.path.dirname(row.full_path) orelse return;
        var parent = try std.Io.Dir.cwd().openDir(self.io, parent_path, .{});
        defer parent.close(self.io);

        if (row.is_dir) {
            try parent.deleteTree(self.io, row.name);
            self.setExpanded(row.full_path, false);
        } else {
            try parent.deleteFile(self.io, row.name);
        }

        if (self.selected_dir) |sd| {
            if (std.mem.startsWith(u8, sd, row.full_path) or
                (std.mem.eql(u8, sd, row.dir_path) and self.selected_name != null and std.mem.eql(u8, self.selected_name.?, row.name)))
            {
                self.clearSelection();
            }
        }
        self.rebuildTree();
    }

    pub fn view(self: *Sidebar, c: *ui.Context) void {
        const root = ui.div(c).column().w(260).hFull().bg(c.theme.surface);
        defer root.end();

        const header = ui.div(c).row().wFull().px(12).py(10).itemsCenter().justifyBetween().gap(4);
        {
            defer header.end();
            ui.text(c, "Ilgi", .{ .size = 15, .weight = .bold });
            if (kit.iconButton(c, "plus", .{ .size = .sm, .tooltip = "Add folder" }).clicked) {
                self.pickFolder();
            }
        }

        ui.divider(c);
        const list = ui.div(c).column().grow().wFull().p(8).gap(1).scrollY();
        defer list.end();

        if (self.rows.items.len == 0) {
            const box = ui.div(c).wFull().p(12);
            defer box.end();
            ui.text(c, "No folders yet. Click + to add one.", .{ .size = 12.5, .color = c.theme.muted });
            return;
        }

        for (self.rows.items, 0..) |row, i| {
            ui.keyInt(c, i);
            const selected = self.isSelectedFile(row);
            const indent: f32 = @as(f32, @floatFromInt(row.depth)) * 16 + 8;

            const outer = ui.div(c).row().wFull().itemsCenter().gap(2);
            {
                defer outer.end();

                var btn = ui.div(c).row().grow().pl(indent).pr(8).py(4).rounded(6).itemsCenter().gap(6).control();
                btn = if (selected) btn.bg(c.theme.surface_hover) else btn.hover(c.theme.surface_hover);
                {
                    defer btn.end();
                    const fg = if (selected) c.theme.accent else c.theme.text;
                    const icon_fg = if (selected) c.theme.accent else c.theme.muted;

                    if (row.is_dir) {
                        ui.icon(c, if (row.expanded) "chevron.down" else "chevron.right", .{ .size = 10, .frame = 14, .color = icon_fg });
                        ui.icon(c, if (row.is_root) "folder.fill" else "folder", .{ .size = 13, .color = if (row.is_root) c.theme.accent else icon_fg });
                    } else {
                        // Align file icons with the parent folder's icon (past the 14px chevron).
                        ui.div(c).w(14).end();
                        ui.icon(c, "doc.text", .{ .size = 12.5, .color = icon_fg });
                    }

                    const nb = ui.div(c).grow().clip();
                    defer nb.end();
                    ui.text(c, row.name, .{
                        .size = 13,
                        .weight = if (row.is_root or selected) .semibold else .regular,
                        .color = fg,
                        .truncate = .ellipsis,
                    });
                }

                if (btn.clicked()) {
                    self.selectRow(i);
                    return;
                }
                if (row.is_dir) {
                    if (kit.iconButton(c, "doc.badge.plus", .{ .size = .xs, .tooltip = "New file" }).clicked) {
                        self.startCreate(row.full_path, .file);
                        return;
                    }
                    if (kit.iconButton(c, "folder.badge.plus", .{ .size = .xs, .tooltip = "New folder" }).clicked) {
                        self.startCreate(row.full_path, .folder);
                        return;
                    }
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
                if (!row.is_root and selected and kit.iconButton(c, "trash", .{ .size = .xs, .tooltip = "Delete" }).clicked) {
                    self.deleteRow(i) catch {};
                    return;
                }
            }

            if (row.is_dir and self.creating_in != null and std.mem.eql(u8, self.creating_in.?, row.full_path)) {
                self.createInputRow(c, row.full_path, row.depth + 1);
            }
        }
    }

    fn createInputRow(self: *Sidebar, c: *ui.Context, dir_path: []const u8, depth: u16) void {
        const indent: f32 = @as(f32, @floatFromInt(depth)) * 16 + 22;
        const box = ui.div(c).row().wFull().pl(indent).pr(6).py(2).itemsCenter().gap(4);
        defer box.end();

        ui.icon(c, if (self.creating_kind == .file) "doc.text" else "folder", .{ .size = 12.5, .color = c.theme.accent });
        const ph = if (self.creating_kind == .file) "note.md" else "folder-name";
        const res = ui.textField(c, &self.new_name_buf, .{ .placeholder = ph, .width = .fill, .size = 12.5 });
        if (res.submitted) {
            const name = self.new_name_buf.buf.items;
            if (self.creating_kind == .file) {
                self.createFile(dir_path, name) catch {};
            } else {
                self.createFolder(dir_path, name) catch {};
            }
            self.cancelCreate();
            return;
        }
        if (kit.iconButton(c, "xmark", .{ .size = .xs, .tooltip = "Cancel" }).clicked) {
            self.cancelCreate();
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

    fn startCreate(self: *Sidebar, dir_path: []const u8, kind: @TypeOf(self.creating_kind)) void {
        if (self.creating_in) |old| self.allocator.free(old);
        self.creating_in = self.allocator.dupe(u8, dir_path) catch null;
        self.creating_kind = kind;
        self.setExpanded(dir_path, true);
        self.rebuildTree();
        self.new_name_buf.clear();
        self.new_name_buf.focus();
    }

    fn cancelCreate(self: *Sidebar) void {
        if (self.creating_in) |old| {
            self.allocator.free(old);
            self.creating_in = null;
        }
        self.new_name_buf.clear();
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
