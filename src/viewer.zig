//! File viewer component: Read mode + smooth Obsidian-style single-pane Live Preview.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const highlight = @import("highlight.zig");
const markdown = @import("markdown.zig");

const max_preview_bytes = 1024 * 1024;

pub const ViewMode = enum { read, edit };

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
    editing_block: bool = false,
    active_range: markdown.BlockRange = .{ .start = 0, .end = 0 },
    block_buf: ui.TextBuffer = .{},
    pending_link: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Viewer {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Viewer) void {
        self.clear();
        self.edit_buf.deinit();
        self.block_buf.deinit();
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
        self.setMode(.edit);
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
        self.editing_block = false;
        if (self.pending_link) |pl| {
            self.allocator.free(pl);
            self.pending_link = null;
        }
        self.edit_buf.clear();
        self.block_buf.clear();
        // `status` only holds compile-time string literals, so it is never freed.
        self.status = null;
    }

    /// Switches between `.read` and `.edit` (single-pane Live Preview for Markdown).
    pub fn setMode(self: *Viewer, next_mode: ViewMode) void {
        if (next_mode == .read) {
            self.editing_block = false;
            self.mode = .read;
            return;
        }
        if (self.mode == .read) {
            const text = self.content orelse return;
            self.edit_buf.clear();
            _ = self.edit_buf.insert(0, text);
            self.editing_block = false;
            self.dirty = false;
            if (!markdown.isMarkdownFile(self.file_name orelse "")) self.edit_buf.focus();
        }
        self.mode = .edit;
    }

    /// Activates a Markdown block `[range.start..range.end)` in `edit_buf` for inline editing.
    pub fn editBlock(self: *Viewer, range: markdown.BlockRange) void {
        self.editing_block = true;
        self.active_range = range;
        self.block_buf.clear();
        _ = self.block_buf.insert(0, self.edit_buf.buf.items[range.start..range.end]);
        self.block_buf.focus();
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

        const body = ui.div(c).column().grow().wFull().p(20).scrollY();
        defer body.end();

        if (self.content == null) {
            if (self.status) |msg| ui.text(c, msg, .{ .size = 13, .color = c.theme.muted });
            return;
        }

        if (self.mode != .read) {
            if (c.input.shortcut) |sc| {
                if (sc.cmd and (sc.key == 's' or sc.key == 'S')) {
                    self.save();
                    c.input.shortcut = null;
                }
            }
        }

        if (self.mode == .read) {
            self.renderRead(c, name, self.content.?);
            return;
        }

        if (markdown.isMarkdownFile(name)) {
            self.renderLiveMarkdown(c);
            return;
        }

        const mono = highlight.isCodeFile(name);
        if (self.handleEditShortcuts(c, &self.edit_buf, false)) self.dirty = true;
        const code_spans = if (mono) (highlight.highlight(c.alloc(), name, self.edit_buf.buf.items, c.theme.dark) catch &.{}) else &.{};
        const res = ui.textArea(c, &self.edit_buf, .{
            .placeholder = "Start typing...",
            .width = .fill,
            .size = if (mono) 12 else 12.5,
            .mono = mono,
            .spans = code_spans,
            .max_lines = 255,
            .submit_on_return = false,
            .bare = true,
        });
        if (res.changed) self.dirty = true;
    }

    fn renderLiveMarkdown(self: *Viewer, c: *ui.Context) void {
        const src = self.edit_buf.buf.items;
        const col = ui.div(c).column().wFull().gap(10);
        defer col.end();

        if (!self.editing_block) {
            _ = self.renderBlockSlice(c, src, 0, 0);
            return;
        }

        // Render blocks before the active range, the active editor, then blocks after.
        // Splitting before/after separately keeps `active_range` stable across newlines.
        const r_start = @min(self.active_range.start, src.len);
        var r_end = @min(@max(self.active_range.end, r_start), src.len);
        const next_id = self.renderBlockSlice(c, src[0..r_start], 0, 0);

        ui.key(c, "active-md-block");
        _ = self.handleEditShortcuts(c, &self.block_buf, true);
        const block_text = self.block_buf.buf.items;
        const is_fenced = std.mem.startsWith(u8, std.mem.trimStart(u8, block_text, " \t"), "```");
        const live_spans = if (is_fenced)
            (highlight.highlight(c.alloc(), "block.md", block_text, c.theme.dark) catch &.{})
        else
            (markdown.liveSpans(c.alloc(), block_text, c.theme.muted, c.theme.surface_hover, c.theme.accent) catch &.{});

        const res = ui.textArea(c, &self.block_buf, .{
            .width = .fill,
            .size = blockFontSize(block_text),
            .mono = is_fenced,
            .spans = live_spans,
            .max_lines = 64,
            .submit_on_return = !is_fenced,
            .bare = true,
        });
        const new_text = self.block_buf.buf.items;
        if (res.changed or !std.mem.eql(u8, new_text, self.edit_buf.buf.items[r_start..r_end])) {
            _ = self.edit_buf.replace(r_start, r_end, new_text);
            r_end = r_start + new_text.len;
            self.active_range = .{ .start = r_start, .end = r_end };
            self.dirty = true;
        }
        if (res.submitted) {
            // Commit this block (formatting it immediately) and open a new block on the next line.
            const insert_at = self.active_range.end;
            _ = self.edit_buf.insert(insert_at, "\n");
            self.editBlock(.{ .start = insert_at + 1, .end = insert_at + 1 });
            self.dirty = true;
            return;
        }

        const after_src = self.edit_buf.buf.items;
        const after_start = @min(self.active_range.end, after_src.len);
        _ = self.renderBlockSlice(c, after_src[after_start..], after_start, next_id);
    }

    fn renderBlockSlice(self: *Viewer, c: *ui.Context, slice: []const u8, base_offset: usize, start_id: usize) usize {
        const blocks = markdown.splitBlocks(c.alloc(), slice) catch return start_id;
        for (blocks, 0..) |b, i| {
            ui.keyInt(c, start_id + i);
            const block_src = slice[b.start..b.end];
            const row = ui.div(c).wFull().control();
            {
                defer row.end();
                markdown.view(c, block_src);
            }
            if (row.clicked()) {
                self.editBlock(.{ .start = base_offset + b.start, .end = base_offset + b.end });
                return start_id + i + 1;
            }
            self.renderLinkChips(c, block_src, start_id + i);
        }
        return start_id + blocks.len;
    }

    fn renderLinkChips(self: *Viewer, c: *ui.Context, src: []const u8, seed: usize) void {
        const links = markdown.extractLinks(c.alloc(), src) catch return;
        if (links.len == 0) return;

        const bar = ui.div(c).row().wFull().gap(6).pt(2);
        defer bar.end();
        for (links, 0..) |target, li| {
            ui.keyInt(c, 500_000 + seed * 32 + li);
            const label = c.print("↗ {s}", .{target});
            if (kit.button(c, label, .{ .variant = .ghost, .size = .xs }).clicked) {
                if (self.pending_link) |old| self.allocator.free(old);
                self.pending_link = self.allocator.dupe(u8, target) catch null;
            }
        }
    }

    fn handleEditShortcuts(self: *Viewer, c: *ui.Context, buf: *ui.TextBuffer, allow_markdown: bool) bool {
        _ = self;
        if (c.input.key == .tab and !c.input.shift) {
            const pos = if (c.focused_text) |ft| @min(ft.caret, buf.buf.items.len) else buf.buf.items.len;
            _ = buf.insert(pos, "  ");
            buf.want_caret = pos + 2;
            c.input.key = null;
            return true;
        }
        const sc = c.input.shortcut orelse return false;
        if (!sc.cmd or !allow_markdown) return false;

        const marker: ?struct { open: []const u8, close: []const u8 } = switch (sc.key) {
            'b', 'B' => .{ .open = "**", .close = "**" },
            'i', 'I' => .{ .open = "*", .close = "*" },
            'k', 'K' => .{ .open = "[[", .close = "]]" },
            else => null,
        };
        const m = marker orelse return false;
        c.input.shortcut = null;

        const len = buf.buf.items.len;
        const a = if (c.focused_text) |ft| @min(ft.caret, len) else len;
        const b = if (c.focused_text) |ft| @min(ft.anchor, len) else len;
        const lo = @min(a, b);
        const hi = @max(a, b);
        _ = buf.insert(hi, m.close);
        _ = buf.insert(lo, m.open);
        buf.want_caret = if (lo == hi) lo + m.open.len else hi + m.open.len + m.close.len;
        return true;
    }

    fn renderRead(self: *Viewer, c: *ui.Context, name: []const u8, text: []const u8) void {
        if (markdown.isMarkdownFile(name)) {
            markdown.view(c, text);
            self.renderLinkChips(c, text, 0);
            return;
        }

        const mono = highlight.isCodeFile(name);
        self.ensureHighlights(name, text, c.theme.dark);
        ui.richText(c, text, self.spans, .{
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

fn blockFontSize(src: []const u8) f32 {
    if (std.mem.startsWith(u8, src, "# ")) return 20;
    if (std.mem.startsWith(u8, src, "## ")) return 17;
    if (std.mem.startsWith(u8, src, "### ")) return 15;
    if (std.mem.startsWith(u8, src, "```")) return 12;
    return 13;
}

fn emptyView(c: *ui.Context) void {
    const empty = ui.div(c).column().sizeFull().itemsCenter().justifyCenter().gap(8);
    defer empty.end();
    ui.text(c, "Ilgi", .{ .size = 28, .weight = .bold });
    ui.text(c, "Add a folder or select a file from the sidebar.", .{ .size = 14, .color = c.theme.muted });
}
