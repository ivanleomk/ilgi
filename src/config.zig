//! Persistent JSON configuration for Ilgi (`~/.config/ilgi/config.json`).
const std = @import("std");

pub const Folder = struct {
    name: []const u8,
    path: []const u8,
};

const JsonConfig = struct {
    folders: []const Folder = &.{},
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

    /// Returns `$HOME/.config/ilgi/config.json`.
    pub fn defaultPath(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
        const home = try environ.getAlloc(allocator, "HOME");
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".config", "ilgi", "config.json" });
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

    /// Writes `Config` as JSON to `path`, creating parent directories if needed.
    pub fn save(self: *const Config, io: std.Io, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        const bytes = try self.serialize(self.allocator);
        defer self.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    }

    /// Parses `Config` from JSON using `std.json`.
    pub fn parse(allocator: std.mem.Allocator, json_bytes: []const u8) !Config {
        var cfg = Config.init(allocator);
        errdefer cfg.deinit();

        const parsed = try std.json.parseFromSlice(JsonConfig, allocator, json_bytes, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        for (parsed.value.folders) |folder| {
            const name_copy = try allocator.dupe(u8, folder.name);
            errdefer allocator.free(name_copy);
            const path_copy = try allocator.dupe(u8, folder.path);
            errdefer allocator.free(path_copy);
            try cfg.folders.append(allocator, .{ .name = name_copy, .path = path_copy });
        }
        return cfg;
    }

    /// Serializes configured folders to pretty-printed JSON.
    pub fn serialize(self: *const Config, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(
            allocator,
            JsonConfig{ .folders = self.folders.items },
            .{ .whitespace = .indent_2 },
        );
    }
};

test "Config parses, saves, and loads JSON" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPathFile(io, ".", &buf);
    const cfg_path = try std.fs.path.join(alloc, &.{ buf[0..len], "ilgi", "config.json" });
    defer alloc.free(cfg_path);

    // Missing file -> empty config.
    var empty = try Config.load(alloc, io, cfg_path);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.folders.items.len);

    var cfg = try Config.parse(alloc,
        \\{
        \\  "folders": [
        \\    { "name": "Notes", "path": "/Users/ileo/notes" },
        \\    { "name": "ilgi", "path": "/Users/ileo/work/ilgi" }
        \\  ]
        \\}
    );
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 2), cfg.folders.items.len);
    try std.testing.expectEqualStrings("Notes", cfg.folders.items[0].name);

    try cfg.save(io, cfg_path);
    var loaded = try Config.load(alloc, io, cfg_path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.folders.items.len);
    try std.testing.expectEqualStrings("/Users/ileo/notes", loaded.folders.items[0].path);
}
