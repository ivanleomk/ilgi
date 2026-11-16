//! Persistent TOML configuration for Ilgi (`~/.config/ilgi/config.toml`).
const std = @import("std");

pub const Folder = struct {
    name: []u8,
    path: []u8,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    folders: std.ArrayList(Folder) = .empty,

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{ .allocator = allocator };
    }

    /// Frees every folder's copied `name`/`path` strings, then the list buffer.
    pub fn deinit(self: *Config) void {
        for (self.folders.items) |folder| {
            self.allocator.free(folder.name);
            self.allocator.free(folder.path);
        }
        self.folders.deinit(self.allocator);
    }

    /// Returns `$HOME/.config/ilgi/config.toml`.
    pub fn defaultPath(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
        const home = try environ.getAlloc(allocator, "HOME");
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".config", "ilgi", "config.toml" });
    }

    /// Loads `path`, or returns an empty `Config` if the file does not exist yet.
    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) return Config.init(allocator);
            return err;
        };
        defer allocator.free(bytes);
        return parse(allocator, bytes);
    }

    /// Writes `Config` as TOML to `path`, creating parent directories if needed.
    pub fn save(self: *const Config, io: std.Io, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        const bytes = try self.serialize(self.allocator);
        defer self.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    }

    /// Parses `[[folders]]` sections (`name` and `path`) from TOML text.
    pub fn parse(allocator: std.mem.Allocator, toml: []const u8) !Config {
        var cfg = Config.init(allocator);
        errdefer cfg.deinit();

        var in_folders = false;
        var pending_name: ?[]u8 = null;
        var pending_path: ?[]u8 = null;
        defer {
            if (pending_name) |n| allocator.free(n);
            if (pending_path) |p| allocator.free(p);
        }

        var lines = std.mem.splitScalar(u8, toml, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            if (line[0] == '[') {
                if (in_folders) try flushPending(&cfg, &pending_name, &pending_path);
                in_folders = std.mem.eql(u8, line, "[[folders]]");
                continue;
            }
            if (!in_folders) continue;

            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidToml;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = try unquote(allocator, std.mem.trim(u8, line[eq + 1 ..], " \t"));
            errdefer allocator.free(val);

            if (std.mem.eql(u8, key, "name")) {
                if (pending_name) |old| allocator.free(old);
                pending_name = val;
            } else if (std.mem.eql(u8, key, "path")) {
                if (pending_path) |old| allocator.free(old);
                pending_path = val;
            } else {
                allocator.free(val);
            }
        }
        if (in_folders) try flushPending(&cfg, &pending_name, &pending_path);
        return cfg;
    }

    /// Serializes configured folders to TOML.
    pub fn serialize(self: *const Config, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "# Ilgi configuration\n");
        for (self.folders.items) |folder| {
            try out.appendSlice(allocator, "\n[[folders]]\nname = \"");
            try out.appendSlice(allocator, folder.name);
            try out.appendSlice(allocator, "\"\npath = \"");
            try out.appendSlice(allocator, folder.path);
            try out.appendSlice(allocator, "\"\n");
        }
        return out.toOwnedSlice(allocator);
    }
};

fn flushPending(cfg: *Config, pending_name: *?[]u8, pending_path: *?[]u8) !void {
    defer {
        if (pending_name.*) |n| cfg.allocator.free(n);
        if (pending_path.*) |p| cfg.allocator.free(p);
        pending_name.* = null;
        pending_path.* = null;
    }
    const p = pending_path.* orelse return;
    const base = std.fs.path.basename(p);
    const display_name = if (pending_name.*) |n| (if (n.len > 0) n else base) else base;

    const name_copy = try cfg.allocator.dupe(u8, if (display_name.len > 0) display_name else p);
    errdefer cfg.allocator.free(name_copy);
    const path_copy = try cfg.allocator.dupe(u8, p);
    errdefer cfg.allocator.free(path_copy);

    try cfg.folders.append(cfg.allocator, .{ .name = name_copy, .path = path_copy });
}

fn unquote(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len < 2 or raw[0] != raw[raw.len - 1] or (raw[0] != '"' and raw[0] != '\'')) {
        return error.InvalidToml;
    }
    return allocator.dupe(u8, raw[1 .. raw.len - 1]);
}

test "Config parses, saves, and loads TOML" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPathFile(io, ".", &buf);
    const cfg_path = try std.fs.path.join(alloc, &.{ buf[0..len], "ilgi", "config.toml" });
    defer alloc.free(cfg_path);

    // Missing file -> empty config.
    var empty = try Config.load(alloc, io, cfg_path);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.folders.items.len);

    var cfg = try Config.parse(alloc,
        \\# User folders
        \\[[folders]]
        \\name = "Notes"
        \\path = "/Users/ileo/notes"
        \\
        \\[[folders]]
        \\path = '/Users/ileo/work/ilgi'
        \\
    );
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 2), cfg.folders.items.len);
    try std.testing.expectEqualStrings("Notes", cfg.folders.items[0].name);
    try std.testing.expectEqualStrings("ilgi", cfg.folders.items[1].name);

    try cfg.save(io, cfg_path);
    var loaded = try Config.load(alloc, io, cfg_path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.folders.items.len);
    try std.testing.expectEqualStrings("/Users/ileo/notes", loaded.folders.items[0].path);
}
