//! Ilgi's root state and config-backed folder/file viewer UI.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const config_mod = @import("config.zig");

const max_preview_bytes = 1024 * 1024;

pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod.Config,
    config_path: []const u8,

    current_dir: ?[]const u8 = null,
    entries_arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,

    selected_name: ?[]const u8 = null,
    file_content: ?[]const u8 = null,
    status_message: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config_path: []const u8) State {
        const cfg = config_mod.Config.load(allocator, io, config_path) catch config_mod.Config.init(allocator);

        var s: State = .{
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

    pub fn deinit(self: *State) void {
        self.clearPreview();
        self.entries_arena.deinit();
        if (self.current_dir) |d| self.allocator.free(d);
        self.allocator.free(self.config_path);
        self.config.deinit();
    }

    /// Opens `path` in the file browser pane.
    pub fn openDir(self: *State, path: []const u8) void {
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch {
            self.setStatus("Could not open folder.");
            return;
        };
        defer dir.close(self.io);

        if (self.current_dir) |old| self.allocator.free(old);
        self.current_dir = self.allocator.dupe(u8, path) catch null;
        self.clearPreview();

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

    /// Opens a subdirectory or previews a file from `self.entries`.
    pub fn selectEntry(self: *State, index: usize) void {
        const cur = self.current_dir orelse return;
        if (index >= self.entries.items.len) return;
        const entry = self.entries.items[index];

        if (entry.is_dir) {
            const next = std.fs.path.join(self.allocator, &.{ cur, entry.name }) catch return;
            defer self.allocator.free(next);
            self.openDir(next);
            return;
        }

        self.clearPreview();
        self.selected_name = self.allocator.dupe(u8, entry.name) catch null;

        var dir = std.Io.Dir.cwd().openDir(self.io, cur, .{}) catch {
            self.setStatus("Could not open folder.");
            return;
        };
        defer dir.close(self.io);

        const bytes = dir.readFileAlloc(self.io, entry.name, self.allocator, .limited(max_preview_bytes)) catch |err| {
            self.setStatus(if (err == error.StreamTooLong) "File is larger than 1 MB." else "Could not read file.");
            return;
        };
        if (std.mem.indexOfScalar(u8, bytes, 0) != null or !std.unicode.utf8ValidateSlice(bytes)) {
            self.allocator.free(bytes);
            self.setStatus("Binary or non-UTF-8 file (preview unavailable).");
            return;
        }
        self.file_content = bytes;
    }

    pub fn view(self: *State, c: *ui.Context) void {
        const root = ui.div(c).row().sizeFull().bg(c.theme.background);
        defer root.end();

        self.sidebarView(c);
        ui.div(c).w(1).hFull().bg(c.theme.border).end();
        self.contentView(c);
    }

    fn sidebarView(self: *State, c: *ui.Context) void {
        const sidebar = ui.div(c).column().w(260).hFull().bg(c.theme.surface);
        defer sidebar.end();

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
                            self.clearPreview();
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

    fn contentView(self: *State, c: *ui.Context) void {
        const pane = ui.div(c).column().grow().hFull();
        defer pane.end();

        if (self.selected_name) |name| {
            const topbar = ui.div(c).row().wFull().px(20).py(12).itemsCenter().bg(c.theme.surface);
            {
                defer topbar.end();
                ui.text(c, name, .{ .size = 14, .weight = .semibold });
            }
            ui.divider(c);

            const body = ui.div(c).column().grow().wFull().p(20).scrollY();
            defer body.end();
            if (self.file_content) |content| {
                ui.text(c, content, .{ .size = 13.5, .wrap = true, .mono = isCodeFile(name), .leading = 1.45 });
            } else if (self.status_message) |msg| {
                ui.text(c, msg, .{ .size = 13, .color = c.theme.muted });
            }
            return;
        }

        const empty = ui.div(c).column().sizeFull().itemsCenter().justifyCenter().gap(8);
        defer empty.end();
        ui.text(c, "Ilgi", .{ .size = 28, .weight = .bold });
        ui.text(c, self.status_message orelse "Add a folder or select a file from the sidebar.", .{
            .size = 14,
            .color = c.theme.muted,
        });
    }

    fn pickFolder(self: *State) void {
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

    fn clearPreview(self: *State) void {
        if (self.selected_name) |n| {
            self.allocator.free(n);
            self.selected_name = null;
        }
        if (self.file_content) |fc| {
            self.allocator.free(fc);
            self.file_content = null;
        }
        if (self.status_message) |msg| {
            self.allocator.free(msg);
            self.status_message = null;
        }
    }

    fn setStatus(self: *State, msg: []const u8) void {
        if (self.status_message) |old| self.allocator.free(old);
        self.status_message = self.allocator.dupe(u8, msg) catch null;
    }
};

fn compareEntries(_: void, a: Entry, b: Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
}

fn isCodeFile(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    for ([_][]const u8{ ".zig", ".zon", ".c", ".h", ".rs", ".go", ".py", ".js", ".ts", ".json", ".toml", ".sh" }) |ce| {
        if (std.ascii.eqlIgnoreCase(ext, ce)) return true;
    }
    return false;
}
