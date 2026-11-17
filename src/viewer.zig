//! File viewer component: Read mode + smooth Obsidian-style single-pane Live Preview.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const highlight = @import("highlight.zig");
const markdown = @import("markdown.zig");

const max_preview_bytes = 1024 * 1024;

pub const ViewMode = enum { read, edit };

pub const NoteEntry = struct {
    name: []const u8,
    rel_path: []const u8 = "",
    full_path: []const u8,
};

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
    block_just_opened: bool = false,
    block_gen: usize = 0,
    active_range: markdown.BlockRange = .{ .start = 0, .end = 0 },
    block_buf: ui.TextBuffer = .{},
    pending_link: ?[]const u8 = null,
    note_entries: []const NoteEntry = &.{},
    ac_index: usize = 0,
    ac_dismissed_start: ?usize = null,
    last_caret: usize = 0,
    last_anchor: usize = 0,
    last_editor_id: u64 = 0,

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
            const is_md = markdown.isMarkdownFile(self.file_name orelse "");
            if (is_md and text.len == 0) {
                self.editBlock(.{ .start = 0, .end = 0 });
            } else if (!is_md) {
                self.edit_buf.focus();
            }
        }
        self.mode = .edit;
    }

    /// Activates a Markdown block `[range.start..range.end)` in `edit_buf` for inline editing.
    pub fn editBlock(self: *Viewer, range: markdown.BlockRange) void {
        self.editing_block = true;
        self.block_just_opened = true;
        self.block_gen +%= 1;
        self.active_range = range;
        self.block_buf.deinit();
        self.block_buf = .{};
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

        if (self.mode != .read and (c.shortcut(.{ .key = 's', .cmd = true }) or
            c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }) or
            (c.input.key == .enter and c.input.cmd)))
        {
            c.input.key = null;
            self.save();
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
        const tab_inserted = self.handleTabKey(c, &self.edit_buf);
        const code_spans = if (mono) (highlight.highlight(c.alloc(), name, self.edit_buf.buf.items, c.theme.dark) catch &.{}) else &.{};
        const res = ui.textArea(c, &self.edit_buf, .{
            .placeholder = "Start typing...",
            .width = .fill,
            .size = if (mono) 12 else 12.5,
            .leading = if (mono) 1.55 else 1.65,
            .caret_width = 2.5,
            .mono = mono,
            .spans = code_spans,
            .max_lines = 255,
            .submit_on_return = false,
            .bare = true,
        });
        if (c.focused_text) |ft| {
            self.last_caret = ft.caret;
            self.last_anchor = ft.anchor;
            self.last_editor_id = ft.id;
        }
        if (tab_inserted or res.changed) self.dirty = true;
    }

    fn renderLiveMarkdown(self: *Viewer, c: *ui.Context) void {
        const src = self.edit_buf.buf.items;
        const col = ui.div(c).column().wFull().gap(10);
        defer col.end();

        const ac_block_text = self.block_buf.buf.items;
        const ac_is_fenced = self.editing_block and std.mem.startsWith(u8, std.mem.trimStart(u8, ac_block_text, " \t"), "```");
        const pre_ac_query = if (self.editing_block and !ac_is_fenced)
            findLinkQuery(ac_block_text, @min(self.last_caret, ac_block_text.len))
        else
            null;
        var ac_matches: [6]NoteEntry = undefined;
        const ac_count = if (pre_ac_query) |q| self.collectLinkMatches(q.query, &ac_matches) else 0;
        const ac_open = pre_ac_query != null and ac_count > 0 and self.ac_dismissed_start != pre_ac_query.?.start;
        if (pre_ac_query == null) {
            self.ac_dismissed_start = null;
            self.ac_index = 0;
        } else if (ac_open) {
            if (isEscape(c)) {
                c.input.key = null;
                c.input.ops = &.{};
                self.ac_dismissed_start = pre_ac_query.?.start;
            } else if (c.shortcut(.{ .key = ui.Shortcut.down }) or c.shortcut(.{ .key = 'n', .ctrl = true }) or c.input.key == .down) {
                c.input.key = null;
                c.input.ops = &.{};
                self.ac_index = (self.ac_index + 1) % ac_count;
            } else if (c.shortcut(.{ .key = ui.Shortcut.up }) or c.shortcut(.{ .key = 'p', .ctrl = true }) or c.input.key == .up) {
                c.input.key = null;
                c.input.ops = &.{};
                self.ac_index = if (self.ac_index == 0) ac_count - 1 else self.ac_index - 1;
            }
        }

        if (self.editing_block and isEscape(c)) {
            c.input.key = null;
            c.input.ops = &.{};
            self.editing_block = false;
        }
        if (!self.editing_block) {
            const count = self.renderBlockSlice(c, src, 0, 0);
            if (count == 0) {
                const ph = ui.div(c).wFull().py(4).control();
                {
                    defer ph.end();
                    ui.text(c, "Start writing...", .{ .size = 13, .color = c.theme.muted });
                }
                if (ph.clicked()) self.editBlock(.{ .start = 0, .end = 0 });
            }
            return;
        }

        // Render blocks before the active range, the active editor, then blocks after.
        // Splitting before/after separately keeps `active_range` stable across newlines.
        if (!ac_open) {
            self.handleBlockUpDown(c);
        }
        const cur_src = self.edit_buf.buf.items;
        const r_start = @min(self.active_range.start, cur_src.len);
        var r_end = @min(@max(self.active_range.end, r_start), cur_src.len);

        if (self.block_buf.buf.items.len == 0 and r_start > 0 and isBackspace(c)) {
            c.input.key = null;
            self.deleteEmptyBlock(c.alloc(), r_start, r_end);
            return;
        }

        const next_id = self.renderBlockSlice(c, cur_src[0..r_start], 0, 0);

        ui.keyInt(c, 900_000 + self.block_gen);
        const just_opened = self.block_just_opened;
        self.block_just_opened = false;
        const tab_inserted = self.handleTabKey(c, &self.block_buf);
        const block_text = self.block_buf.buf.items;
        const is_fenced = std.mem.startsWith(u8, std.mem.trimStart(u8, block_text, " \t"), "```");
        const closed_fence = is_fenced and hasClosingFence(block_text);
        const active_query = if (!is_fenced) findLinkQuery(block_text, @min(self.last_caret, block_text.len)) else null;
        const live_spans = if (is_fenced)
            (highlight.highlight(c.alloc(), fenceFilename(c.alloc(), block_text), block_text, c.theme.dark) catch &.{})
        else
            (markdown.liveSpans(c.alloc(), block_text, c.theme.muted, c.theme.surface_hover, c.theme.accent) catch &.{});

        const res = ui.textArea(c, &self.block_buf, .{
            .width = .fill,
            .size = blockFontSize(block_text),
            .leading = if (is_fenced) 1.55 else 1.65,
            .caret_width = 2.5,
            .mono = is_fenced,
            .spans = live_spans,
            .max_lines = 64,
            .submit_on_return = !is_fenced or closed_fence,
            .bare = true,
        });
        if (c.focused_text) |ft| {
            self.last_caret = ft.caret;
            self.last_anchor = ft.anchor;
            self.last_editor_id = ft.id;
        }
        if (res.submitted and active_query != null and self.ac_dismissed_start != active_query.?.start) {
            var sub_matches: [6]NoteEntry = undefined;
            const sub_count = self.collectLinkMatches(active_query.?.query, &sub_matches);
            if (sub_count > 0) {
                const chosen = sub_matches[@min(self.ac_index, sub_count - 1)];
                self.ac_index = 0;
                self.acceptLinkCompletion(c, r_start, active_query.?, chosen);
                return;
            }
        }
        const md_shortcut = self.handleMarkdownShortcuts(c, &self.block_buf);
        const new_text = self.block_buf.buf.items;
        if (tab_inserted or md_shortcut or res.changed or !std.mem.eql(u8, new_text, self.edit_buf.buf.items[r_start..r_end])) {
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
        if (!just_opened and !res.focused) {
            self.editing_block = false;
        }

        const after_src = self.edit_buf.buf.items;
        const after_start = @min(self.active_range.end, after_src.len);
        self.renderLinkAutocomplete(c, r_start);
        _ = self.renderBlockSlice(c, after_src[after_start..], after_start, next_id);
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    fn isCurrentFile(self: *const Viewer, entry: NoteEntry) bool {
        if (self.loaded_path) |lp| {
            if (entry.full_path.len > 0) return std.mem.eql(u8, entry.full_path, lp);
        }
        if (self.file_name) |fnm| {
            if (entry.full_path.len == 0) return std.mem.eql(u8, entry.name, fnm);
        }
        return false;
    }

    pub fn collectLinkMatches(self: *const Viewer, query: []const u8, out: *[6]NoteEntry) usize {
        var count: usize = 0;
        for (self.note_entries) |entry| {
            if (self.isCurrentFile(entry)) continue;
            if (containsIgnoreCase(entry.name, query)) {
                out[count] = entry;
                count += 1;
                if (count == out.len) break;
            }
        }
        return count;
    }

    fn acceptLinkCompletion(self: *Viewer, c: *ui.Context, r_start: usize, q: LinkQuery, entry: NoteEntry) void {
        const target = if (entry.rel_path.len > 0) entry.rel_path else entry.name;
        const rep = if (q.is_wiki) c.print("{s}]]", .{std.fs.path.stem(entry.name)}) else c.print("{s})", .{target});
        _ = self.block_buf.replace(q.start, q.end, rep);
        self.block_buf.want_caret = q.start + rep.len;
        self.block_buf.focus();
        const updated = self.block_buf.buf.items;
        _ = self.edit_buf.replace(r_start, self.active_range.end, updated);
        self.active_range.end = r_start + updated.len;
        self.dirty = true;
    }

    fn readSnippet(self: *const Viewer, alloc: std.mem.Allocator, full_path: []const u8) []const u8 {
        if (!std.fs.path.isAbsolute(full_path)) return "";
        const file = std.Io.Dir.openFileAbsolute(self.io, full_path, .{}) catch return "";
        defer file.close(self.io);
        var buf: [256]u8 = undefined;
        const n = file.readPositionalAll(self.io, &buf, 0) catch return "";
        var it = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (it.next()) |raw_line| {
            const trimmed = std.mem.trim(u8, raw_line, " \t\r#");
            if (trimmed.len == 0) continue;
            const max_len: usize = 44;
            if (trimmed.len <= max_len) return alloc.dupe(u8, trimmed) catch "";
            const out = alloc.alloc(u8, max_len + 3) catch return "";
            @memcpy(out[0..max_len], trimmed[0..max_len]);
            @memcpy(out[max_len .. max_len + 3], "...");
            return out;
        }
        return "";
    }

    fn renderLinkAutocomplete(self: *Viewer, c: *ui.Context, r_start: usize) void {
        if (self.note_entries.len == 0) return;
        const text = self.block_buf.buf.items;
        const q = findLinkQuery(text, @min(self.last_caret, text.len)) orelse return;
        if (self.ac_dismissed_start == q.start) return;

        var matches: [6]NoteEntry = undefined;
        const count = self.collectLinkMatches(q.query, &matches);
        if (count == 0) return;
        const sel = @min(self.ac_index, count - 1);

        const caret = if (c.focused_text) |ft| ft.caret_rect else ui.Rect{ .x = 24, .y = 80, .w = 2, .h = 18 };
        const popup_w: f32 = 340;
        const est_h: f32 = @as(f32, @floatFromInt(count)) * 52 + 10;
        const px = @min(@max(8, caret.x), @max(8, c.size.w - popup_w - 8));
        const below_y = caret.y + caret.h + 6;
        const py = if (below_y + est_h > c.size.h - 8 and caret.y > est_h + 8) caret.y - est_h - 6 else below_y;

        const popup = ui.div(c).fixed().offset(px, py).layer(20).column().w(popup_w).bg(c.theme.surface).border(c.theme.border).borderW(1).rounded(8).p(4).gap(2).shadow(.{ .color = c.theme.shadow.alpha(0.6), .blur = 16, .y = 6 });
        defer popup.end();
        for (matches[0..count], 0..) |entry, mi| {
            ui.keyInt(c, 700_000 + mi);
            var row_div = ui.div(c).column().wFull().px(8).py(5).rounded(6).gap(1);
            row_div = if (mi == sel) row_div.bg(c.theme.surface_hover).control() else row_div.hover(c.theme.surface_hover).control();
            {
                defer row_div.end();
                const top = ui.div(c).row().wFull().itemsCenter().gap(6);
                {
                    defer top.end();
                    ui.icon(c, "doc.text", .{ .size = 12, .color = if (mi == sel) c.theme.accent else c.theme.muted });
                    ui.text(c, std.fs.path.stem(entry.name), .{ .size = 12.5, .weight = .medium, .color = c.theme.text, .truncate = .ellipsis });
                    ui.spacer(c);
                    const ext = std.fs.path.extension(entry.name);
                    if (ext.len > 0) {
                        ui.text(c, ext, .{ .size = 11, .mono = true, .color = c.theme.muted });
                    }
                }
                const path_label = if (entry.rel_path.len > 0) entry.rel_path else entry.name;
                ui.text(c, path_label, .{ .size = 10.5, .mono = true, .color = c.theme.muted, .truncate = .ellipsis });
                const snippet = self.readSnippet(c.alloc(), entry.full_path);
                if (snippet.len > 0) {
                    ui.text(c, snippet, .{ .size = 11, .color = c.theme.muted, .truncate = .ellipsis });
                }
            }
            if (row_div.clicked()) {
                self.ac_index = 0;
                self.acceptLinkCompletion(c, r_start, q, entry);
                return;
            }
        }
    }

    fn handleBlockUpDown(self: *Viewer, c: *ui.Context) void {
        const src = self.edit_buf.buf.items;
        const r_start = @min(self.active_range.start, src.len);
        var r_end = @min(@max(self.active_range.end, r_start), src.len);

        var on_first = self.last_caret == 0;
        var on_last = self.last_caret >= self.block_buf.buf.items.len;
        if (c.focused_text) |ft| {
            if (ft.id == self.last_editor_id) {
                if (c.rects.get(self.last_editor_id)) |box| {
                    on_first = ft.caret_rect.y < box.y + ft.caret_rect.h * 0.5;
                    on_last = ft.caret_rect.y + ft.caret_rect.h > box.y + box.h - ft.caret_rect.h * 0.5;
                }
            }
        }

        const has_prev = std.mem.trim(u8, src[0..r_start], "\r\n").len > 0;
        const has_next = std.mem.trim(u8, src[r_end..], "\r\n").len > 0;

        if (on_first and has_prev and (c.shortcut(.{ .key = ui.Shortcut.up }) or c.input.key == .up)) {
            c.input.key = null;
            c.input.ops = &.{};
            const cur_text = self.block_buf.buf.items;
            if (!std.mem.eql(u8, cur_text, src[r_start..r_end])) {
                _ = self.edit_buf.replace(r_start, r_end, cur_text);
                self.dirty = true;
            }
            const prev_blocks = markdown.splitBlocks(c.alloc(), self.edit_buf.buf.items[0..r_start]) catch return;
            if (prev_blocks.len == 0) return;
            const prev = prev_blocks[prev_blocks.len - 1];
            self.editBlock(prev);
            self.block_buf.want_caret = prev.end - prev.start;
            self.last_caret = prev.end - prev.start;
            self.last_anchor = self.last_caret;
            return;
        }

        if (on_last and has_next and (c.shortcut(.{ .key = ui.Shortcut.down }) or c.input.key == .down)) {
            c.input.key = null;
            c.input.ops = &.{};
            const cur_text = self.block_buf.buf.items;
            if (!std.mem.eql(u8, cur_text, src[r_start..r_end])) {
                _ = self.edit_buf.replace(r_start, r_end, cur_text);
                r_end = r_start + cur_text.len;
                self.dirty = true;
            }
            const next_blocks = markdown.splitBlocks(c.alloc(), self.edit_buf.buf.items[r_end..]) catch return;
            if (next_blocks.len == 0) return;
            const next = next_blocks[0];
            self.editBlock(.{ .start = r_end + next.start, .end = r_end + next.end });
            self.block_buf.want_caret = 0;
            self.last_caret = 0;
            self.last_anchor = 0;
        }
    }

    /// Deletes an empty active block's preceding newline and moves focus to the previous block.
    pub fn deleteEmptyBlock(self: *Viewer, alloc: std.mem.Allocator, r_start: usize, r_end: usize) void {
        if (r_start == 0) return;
        const del_from = if (self.edit_buf.buf.items[r_start - 1] == '\n') r_start - 1 else r_start;
        _ = self.edit_buf.replace(del_from, r_end, "");
        self.dirty = true;

        const before = self.edit_buf.buf.items[0..del_from];
        const prev_blocks = markdown.splitBlocks(alloc, before) catch {
            self.editing_block = false;
            return;
        };
        defer alloc.free(prev_blocks);
        if (prev_blocks.len > 0) {
            self.editBlock(prev_blocks[prev_blocks.len - 1]);
            self.block_buf.want_caret = self.block_buf.buf.items.len;
        } else {
            self.editing_block = false;
        }
    }

    fn renderBlockSlice(self: *Viewer, c: *ui.Context, slice: []const u8, base_offset: usize, start_id: usize) usize {
        const blocks = markdown.splitBlocks(c.alloc(), slice) catch return start_id;
        for (blocks, 0..) |b, i| {
            ui.keyInt(c, start_id + i);
            const block_src = slice[b.start..b.end];
            const row = ui.div(c).wFull().control();
            const row_id = c.node(row.index).id;
            {
                defer row.end();
                markdown.view(c, block_src);
            }
            const hovered_link = if (row.hovered()) self.hitTestBlockLink(c, row_id, block_src) else null;
            if (hovered_link != null) c.cursor_hand = true;
            if (row.clicked()) {
                if (self.hitTestBlockLink(c, row_id, block_src)) |target| {
                    self.openTarget(target);
                    return start_id + i + 1;
                }
                if (c.input.cmd and self.openFirstLink(c, block_src)) {
                    return start_id + i + 1;
                }
                self.editBlock(.{ .start = base_offset + b.start, .end = base_offset + b.end });
                return start_id + i + 1;
            }
        }
        return start_id + blocks.len;
    }

    fn openTarget(self: *Viewer, target: []const u8) void {
        if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://")) {
            _ = nanoui.shell.openUrl(target);
            return;
        }
        if (self.pending_link) |old| self.allocator.free(old);
        self.pending_link = self.allocator.dupe(u8, target) catch null;
    }

    fn hitTestBlockLink(self: *Viewer, c: *ui.Context, row_id: u64, block_src: []const u8) ?[]const u8 {
        _ = self;
        if (std.mem.indexOf(u8, block_src, "[[") == null and std.mem.indexOf(u8, block_src, "](") == null) return null;
        const rect = c.rects.get(row_id) orelse return null;
        if (rect.w <= 0) return null;

        const parsed = markdown.parseInlineWithLinks(c.alloc(), block_src, c.theme.surface_hover, c.theme.accent) catch return null;
        if (parsed.links.len == 0) return null;

        const style: ui.TextStyle = .{ .size = 13, .wrap = true, .leading = 1.65 };
        const lh = c.text.font(style).lineHeight() * style.leading;
        if (lh <= 0) return null;
        const lines = c.text.wrap(parsed.rich.text, style, rect.w);
        if (lines.len == 0) return null;

        const rel_y = c.input.mouse.y - rect.y;
        const rel_x = c.input.mouse.x - rect.x;
        if (rel_y < 0 or rel_x < 0) return null;
        const line_idx: usize = @intFromFloat(@floor(rel_y / lh));
        if (line_idx >= lines.len) return null;

        const line = lines[line_idx];
        const line_text = parsed.rich.text[line.start..line.end];
        const line_w = c.text.caretX(line_text, style, line_text.len);
        if (rel_x > line_w) return null;

        const byte_pos = line.start + c.text.indexAt(line_text, style, rel_x);
        for (parsed.links) |link| {
            if (byte_pos >= link.start and byte_pos <= link.end) return link.target;
        }
        return null;
    }

    fn openFirstLink(self: *Viewer, c: *ui.Context, src: []const u8) bool {
        const md_links = markdown.extractMarkdownLinks(c.alloc(), src) catch &.{};
        if (md_links.len > 0) {
            const url = md_links[0].url;
            if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
                _ = nanoui.shell.openUrl(url);
            } else {
                if (self.pending_link) |old| self.allocator.free(old);
                self.pending_link = self.allocator.dupe(u8, url) catch null;
            }
            return true;
        }
        const wiki_links = markdown.extractLinks(c.alloc(), src) catch &.{};
        if (wiki_links.len > 0) {
            if (self.pending_link) |old| self.allocator.free(old);
            self.pending_link = self.allocator.dupe(u8, wiki_links[0]) catch null;
            return true;
        }
        return false;
    }

    fn handleTabKey(self: *Viewer, c: *ui.Context, buf: *ui.TextBuffer) bool {
        var is_tab = (c.input.key == .tab and !c.input.shift);
        if (!is_tab) {
            for (c.input.ops) |op| {
                if (op == .command and op.command == .insert_tab) {
                    is_tab = true;
                    break;
                }
            }
        }
        if (!is_tab) return false;

        const pos = @min(self.last_caret, buf.buf.items.len);
        _ = buf.insert(pos, "    ");
        buf.want_caret = pos + 4;
        c.input.key = null;
        c.input.ops = &.{};
        return true;
    }

    fn handleMarkdownShortcuts(self: *Viewer, c: *ui.Context, buf: *ui.TextBuffer) bool {
        const marker: ?struct { open: []const u8, close: []const u8 } = if (c.shortcut(.{ .key = 'b', .cmd = true }))
            .{ .open = "**", .close = "**" }
        else if (c.shortcut(.{ .key = 'i', .cmd = true }))
            .{ .open = "*", .close = "*" }
        else if (c.shortcut(.{ .key = 'k', .cmd = true }))
            .{ .open = "[[", .close = "]]" }
        else
            null;

        const m = marker orelse return false;
        const len = buf.buf.items.len;
        const a = @min(self.last_caret, len);
        const b = @min(self.last_anchor, len);
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
            return;
        }

        const mono = highlight.isCodeFile(name);
        self.ensureHighlights(name, text, c.theme.dark);
        ui.richText(c, text, self.spans, .{
            .size = if (mono) 12 else 12.5,
            .wrap = true,
            .mono = mono,
            .leading = if (mono) 1.55 else 1.65,
        });
    }

    fn topbarView(self: *Viewer, c: *ui.Context, name: []const u8) void {
        const topbar = ui.div(c).row().wFull().px(20).py(8).itemsCenter().justifyBetween().bg(c.theme.surface);
        defer topbar.end();

        const title = if (self.dirty) c.print("{s} •", .{name}) else name;
        const title_col = ui.div(c).column().gap(1);
        {
            defer title_col.end();
            ui.text(c, title, .{ .size = 14, .weight = .semibold });
            if (self.loaded_path) |lp| {
                ui.text(c, lp, .{ .size = 11, .mono = true, .color = c.theme.muted, .truncate = .ellipsis });
            }
        }

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

pub const LinkQuery = struct {
    start: usize,
    end: usize,
    query: []const u8,
    is_wiki: bool,
};

/// Returns the active `[[query` or `[label](query` under `caret`.
pub fn findLinkQuery(src: []const u8, caret: usize) ?LinkQuery {
    const end = @min(caret, src.len);
    const slice = src[0..end];

    if (std.mem.lastIndexOf(u8, slice, "](")) |open_md| {
        const after = open_md + 2;
        if (std.mem.indexOfScalarPos(u8, slice, after, ')') == null and
            std.mem.indexOfScalarPos(u8, slice, after, '\n') == null)
        {
            return .{ .start = after, .end = end, .query = slice[after..end], .is_wiki = false };
        }
    }
    if (std.mem.lastIndexOf(u8, slice, "[[")) |open_wiki| {
        const after = open_wiki + 2;
        if (std.mem.indexOfPos(u8, slice, after, "]]") == null and
            std.mem.indexOfScalarPos(u8, slice, after, '\n') == null)
        {
            return .{ .start = after, .end = end, .query = slice[after..end], .is_wiki = true };
        }
    }
    return null;
}

fn isEscape(c: *const ui.Context) bool {
    if (c.input.key == .escape) return true;
    for (c.input.ops) |op| {
        if (op == .command and op.command == .cancel) return true;
    }
    return false;
}

fn isBackspace(c: *const ui.Context) bool {
    if (c.input.key == .backspace) return true;
    for (c.input.ops) |op| {
        if (op == .command and op.command == .delete_backward) return true;
    }
    return false;
}

pub fn hasClosingFence(src: []const u8) bool {
    const nl = std.mem.indexOfScalar(u8, src, '\n') orelse return false;
    var rest = src[nl + 1 ..];
    const last_nl = std.mem.lastIndexOfScalar(u8, rest, '\n');
    const last_line = if (last_nl) |idx| rest[idx + 1 ..] else rest;
    return std.mem.startsWith(u8, std.mem.trim(u8, last_line, " \t\r"), "```");
}

fn fenceFilename(alloc: std.mem.Allocator, src: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, src, '\n') orelse return "block.md";
    const first = std.mem.trim(u8, src[0..nl], " \t\r");
    if (!std.mem.startsWith(u8, first, "```")) return "block.md";
    const lang = std.mem.trim(u8, first[3..], " \t");
    if (lang.len == 0) return "block.md";
    return std.fmt.allocPrint(alloc, "block.{s}", .{lang}) catch "block.md";
}

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
