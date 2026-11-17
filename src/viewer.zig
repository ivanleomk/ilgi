//! File viewer component: loads and renders the currently selected text/code file.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const highlight = @import("highlight.zig");
const markdown = @import("markdown.zig");

const max_preview_bytes = 1024 * 1024;

pub const ViewMode = enum { read, split, edit };

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
    mode: ViewMode = .read,
    dirty: bool = false,
    edit_buf: ui.TextBuffer = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Viewer {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Viewer) void {
        self.clear();
        self.edit_buf.deinit();
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
        self.mode = .read;
        self.dirty = false;
        self.edit_buf.clear();
        // `status` only holds compile-time string literals, so it is never freed.
        self.status = null;
    }

    /// Switches into `next_mode` (`.split` or `.edit`) and loads `content` if coming from `.read`.
    pub fn setMode(self: *Viewer, next_mode: ViewMode) void {
        if (next_mode == .read) {
            self.mode = .read;
            return;
        }
        if (self.mode == .read) {
            const text = self.content orelse return;
            self.edit_buf.clear();
            _ = self.edit_buf.insert(0, text);
            self.edit_buf.focus();
            self.dirty = false;
        }
        self.mode = next_mode;
    }

    /// Writes `edit_buf` back to disk and refreshes the preview content.
    pub fn save(self: *Viewer) void {
        const path = self.loaded_path orelse return;
        const data = self.edit_buf.buf.items;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data }) catch return;

        if (self.content) |old| self.allocator.free(old);
        self.content = self.allocator.dupe(u8, data) catch null;
        self.dirty = false;
        self.spans_ready = false;
    }

    pub fn view(self: *Viewer, c: *ui.Context) void {
        const pane = ui.div(c).column().grow().hFull();
        defer pane.end();

        const name = self.file_name orelse {
            emptyView(c);
            return;
        };

        self.topbarView(c, name);
        ui.divider(c);

        if (self.content == null) {
            const body = ui.div(c).column().grow().wFull().p(20).scrollY();
            defer body.end();
            if (self.status) |msg| ui.text(c, msg, .{ .size = 13, .color = c.theme.muted });
            return;
        }

        switch (self.mode) {
            .read => {
                const body = ui.div(c).column().grow().wFull().p(20).scrollY();
                defer body.end();
                self.renderPreview(c, name, self.content.?, false);
            },
            .edit => {
                const body = ui.div(c).column().grow().wFull().p(20).scrollY();
                defer body.end();
                self.renderEditor(c);
            },
            .split => {
                const split = ui.div(c).row().grow().wFull();
                defer split.end();

                const left = ui.div(c).column().grow().hFull().p(20).scrollY();
                {
                    defer left.end();
                    self.renderEditor(c);
                }
                ui.div(c).w(1).hFull().bg(c.theme.border).end();

                const right = ui.div(c).column().grow().hFull().p(20).scrollY();
                defer right.end();
                self.renderPreview(c, name, self.edit_buf.buf.items, true);
            },
        }
    }

    fn renderEditor(self: *Viewer, c: *ui.Context) void {
        const res = ui.textArea(c, &self.edit_buf, .{
            .placeholder = "Start typing...",
            .width = .fill,
            .size = 12.5,
            .max_lines = 255,
            .submit_on_return = false,
            .bare = true,
        });
        if (res.changed) self.dirty = true;
    }

    fn renderPreview(self: *Viewer, c: *ui.Context, name: []const u8, text: []const u8, live: bool) void {
        if (markdown.isMarkdownFile(name)) {
            markdown.view(c, text);
            return;
        }

        const mono = highlight.isCodeFile(name);
        const spans = if (live)
            (highlight.highlight(c.alloc(), name, text, c.theme.dark) catch &.{})
        else blk: {
            self.ensureHighlights(name, text, c.theme.dark);
            break :blk self.spans;
        };
        ui.richText(c, text, spans, .{
            .size = if (mono) 12 else 12.5,
            .wrap = true,
            .mono = mono,
            .leading = 1.45,
        });
    }

    fn topbarView(self: *Viewer, c: *ui.Context, name: []const u8) void {
        const topbar = ui.div(c).row().wFull().px(20).py(8).itemsCenter().justifyBetween().bg(c.theme.surface);
        defer topbar.end();

        const title = if (self.dirty) c.print("{s} •", .{name}) else name;
        ui.text(c, title, .{ .size = 14, .weight = .semibold });

        if (self.content == null) return;
        const actions = ui.div(c).row().itemsCenter().gap(4);
        defer actions.end();
        if (self.dirty and kit.button(c, "Save", .{ .variant = .primary, .size = .sm }).clicked) {
            self.save();
        }
        if (kit.button(c, "Read", .{ .variant = .ghost, .size = .sm, .selected = self.mode == .read }).clicked) {
            self.setMode(.read);
        }
        if (kit.button(c, "Split", .{ .variant = .ghost, .size = .sm, .selected = self.mode == .split }).clicked) {
            self.setMode(.split);
        }
        if (kit.button(c, "Edit", .{ .variant = .ghost, .size = .sm, .selected = self.mode == .edit }).clicked) {
            self.setMode(.edit);
        }
    }

    fn ensureHighlights(self: *Viewer, name: []const u8, text: []const u8, dark: bool) void {
        if (self.spans_ready and self.spans_dark == dark) return;
        if (self.spans.len > 0) self.allocator.free(self.spans);
        self.spans = highlight.highlight(self.allocator, name, text, dark) catch &.{};
        self.spans_dark = dark;
        self.spans_ready = true;
    }
};

fn emptyView(c: *ui.Context) void {
    const empty = ui.div(c).column().sizeFull().itemsCenter().justifyCenter().gap(8);
    defer empty.end();
    ui.text(c, "Ilgi", .{ .size = 28, .weight = .bold });
    ui.text(c, "Add a folder or select a file from the sidebar.", .{ .size = 14, .color = c.theme.muted });
}
