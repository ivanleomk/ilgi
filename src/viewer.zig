//! File viewer component: loads and renders the currently selected text/code file.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const highlight = @import("highlight.zig");

const max_preview_bytes = 1024 * 1024;

pub const Viewer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    loaded_path: ?[]const u8 = null,
    file_name: ?[]const u8 = null,
    content: ?[]const u8 = null,
    spans: []const ui.Span = &.{},
    spans_dark: bool = false,
    spans_ready: bool = false,
    status: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Viewer {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Viewer) void {
        self.clear();
    }

    /// Loads `dir_path/file_name` if it isn't already loaded.
    pub fn open(self: *Viewer, dir_path: []const u8, file_name: []const u8) void {
        const full_path = std.fs.path.join(self.allocator, &.{ dir_path, file_name }) catch return;
        // Skip re-reading from disk if this file is already cached from an earlier frame.
        if (self.loaded_path) |cur| {
            if (std.mem.eql(u8, cur, full_path)) {
                self.allocator.free(full_path);
                return;
            }
        }

        self.clear();
        self.loaded_path = full_path;
        self.file_name = self.allocator.dupe(u8, file_name) catch null;

        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{}) catch {
            self.status = "Could not open parent folder.";
            return;
        };
        defer dir.close(self.io);

        const bytes = dir.readFileAlloc(self.io, file_name, self.allocator, .limited(max_preview_bytes)) catch |err| {
            self.status = if (err == error.StreamTooLong) "File is larger than 1 MB." else "Could not read file.";
            return;
        };
        // Guard against binary files or invalid UTF-8 before passing bytes to the text shaper.
        if (std.mem.indexOfScalar(u8, bytes, 0) != null or !std.unicode.utf8ValidateSlice(bytes)) {
            self.allocator.free(bytes);
            self.status = "Binary or non-UTF-8 file (preview unavailable).";
            return;
        }
        self.content = bytes;
    }

    /// Clears the loaded file and resets to the empty welcome state.
    pub fn clear(self: *Viewer) void {
        if (self.loaded_path) |p| {
            self.allocator.free(p);
            self.loaded_path = null;
        }
        if (self.file_name) |n| {
            self.allocator.free(n);
            self.file_name = null;
        }
        if (self.content) |c| {
            self.allocator.free(c);
            self.content = null;
        }
        if (self.spans.len > 0) {
            self.allocator.free(self.spans);
            self.spans = &.{};
        }
        self.spans_ready = false;
        // `status` only holds compile-time string literals, so it is never freed.
        self.status = null;
    }

    pub fn view(self: *Viewer, c: *ui.Context) void {
        const pane = ui.div(c).column().grow().hFull();
        defer pane.end();

        const name = self.file_name orelse {
            emptyView(c);
            return;
        };

        topbarView(c, name);
        ui.divider(c);

        const body = ui.div(c).column().grow().wFull().p(20).scrollY();
        defer body.end();

        const text = self.content orelse {
            if (self.status) |msg| ui.text(c, msg, .{ .size = 13, .color = c.theme.muted });
            return;
        };

        const mono = highlight.isCodeFile(name);
        self.ensureHighlights(name, text, c.theme.dark);
        ui.richText(c, text, self.spans, .{
            .size = if (mono) 12 else 12.5,
            .wrap = true,
            .mono = mono,
            .leading = 1.45,
        });
    }

    fn ensureHighlights(self: *Viewer, name: []const u8, text: []const u8, dark: bool) void {
        if (self.spans_ready and self.spans_dark == dark) return;
        if (self.spans.len > 0) self.allocator.free(self.spans);
        self.spans = highlight.highlight(self.allocator, name, text, dark) catch &.{};
        self.spans_dark = dark;
        self.spans_ready = true;
    }
};

fn topbarView(c: *ui.Context, name: []const u8) void {
    const topbar = ui.div(c).row().wFull().px(20).py(12).itemsCenter().bg(c.theme.surface);
    defer topbar.end();
    ui.text(c, name, .{ .size = 14, .weight = .semibold });
}

fn emptyView(c: *ui.Context) void {
    const empty = ui.div(c).column().sizeFull().itemsCenter().justifyCenter().gap(8);
    defer empty.end();
    ui.text(c, "Ilgi", .{ .size = 28, .weight = .bold });
    ui.text(c, "Add a folder or select a file from the sidebar.", .{ .size = 14, .color = c.theme.muted });
}
