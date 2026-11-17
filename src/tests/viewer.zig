//! State machine tests for `Viewer` Live Preview transitions.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const viewer_mod = @import("../viewer.zig");
const markdown = @import("../markdown.zig");

const ViewerHarness = struct {
    viewer: viewer_mod.Viewer,

    pub fn view(self: *ViewerHarness, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        self.viewer.view(c);
    }
};

test "Viewer Live Preview state machine: open, block focus, fenced code, save, and read mode" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "note.md",
        .data = "# Heading\n\n```zig\nconst x = 1;\n```\n\nTail",
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = buf[0..try tmp.dir.realPathFile(io, ".", &buf)];

    var h: ViewerHarness = .{ .viewer = .init(alloc, io) };
    defer h.viewer.deinit();

    // 1. Opening a file defaults to Edit (Live Preview) with no active block yet.
    h.viewer.open(tmp_path, "note.md");
    try std.testing.expectEqual(viewer_mod.ViewMode.edit, h.viewer.mode);
    try std.testing.expect(!h.viewer.editing_block);
    try std.testing.expect(!h.viewer.dirty);

    var t: ui.Tester = undefined;
    try t.init(alloc, .init(&h, ViewerHarness.view), .{ .width = 800, .height = 600 });
    defer t.deinit();
    t.settle(0.1);

    // 2. Opening block 0 keeps `editing_block == true` across multiple frames.
    const blocks = try markdown.splitBlocks(alloc, h.viewer.edit_buf.buf.items);
    defer alloc.free(blocks);
    try std.testing.expectEqual(@as(usize, 3), blocks.len);

    h.viewer.editBlock(blocks[0]);
    try std.testing.expect(h.viewer.editing_block);
    t.settle(0.1);
    try std.testing.expect(h.viewer.editing_block);

    // 3. Fenced code block detection: unclosed vs closed fence.
    try std.testing.expect(!viewer_mod.hasClosingFence("```zig\nconst x = 1;"));
    try std.testing.expect(viewer_mod.hasClosingFence("```zig\nconst x = 1;\n```"));

    // 4. Editing block 0 syncs to edit_buf, marks dirty, and save() persists it.
    _ = h.viewer.block_buf.insert(h.viewer.block_buf.buf.items.len, " Updated");
    t.settle(0.1);
    try std.testing.expect(h.viewer.dirty);
    h.viewer.save();
    try std.testing.expect(!h.viewer.dirty);

    // 5. Backspace on an empty block deletes the newline and focuses the previous block.
    const end_pos = h.viewer.edit_buf.buf.items.len;
    _ = h.viewer.edit_buf.insert(end_pos, "\n");
    h.viewer.editBlock(.{ .start = end_pos + 1, .end = end_pos + 1 });
    h.viewer.deleteEmptyBlock(alloc, h.viewer.active_range.start, h.viewer.active_range.end);
    try std.testing.expectEqualStrings("Tail", h.viewer.block_buf.buf.items);

    // 6. Switching to Read mode exits the active block and renders formatted text.
    h.viewer.setMode(.read);
    t.settle(0.1);
    try std.testing.expect(!h.viewer.editing_block);
    try std.testing.expect(t.hasText("Heading Updated"));

    // 7. Opening an empty Markdown file immediately activates block 0 for typing.
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.md", .data = "" });
    h.viewer.open(tmp_path, "empty.md");
    try std.testing.expect(h.viewer.editing_block);
}

test "Viewer shortcuts: Tab inserts 4 spaces, Esc exits block, Cmd+B/I/K wrap, Cmd+Enter saves" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "doc.md", .data = "hello" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = buf[0..try tmp.dir.realPathFile(io, ".", &buf)];

    var h: ViewerHarness = .{ .viewer = .init(alloc, io) };
    defer h.viewer.deinit();
    h.viewer.open(tmp_path, "doc.md");

    var t: ui.Tester = undefined;
    try t.init(alloc, .init(&h, ViewerHarness.view), .{ .width = 800, .height = 600 });
    defer t.deinit();
    t.settle(0.1);

    const blocks = try markdown.splitBlocks(alloc, h.viewer.edit_buf.buf.items);
    defer alloc.free(blocks);
    h.viewer.editBlock(blocks[0]);
    h.viewer.block_buf.want_caret = 0;
    h.viewer.last_caret = 0;
    h.viewer.last_anchor = 0;
    t.settle(0.1);

    // 1. Tab via macOS `.insert_tab` TextOp inserts 4 spaces at caret (0 -> "    hello").
    t.textOps(&.{.{ .command = .insert_tab }});
    t.settle(0.1);
    try std.testing.expectEqualStrings("    hello", h.viewer.block_buf.buf.items);

    // 2. Cmd+B at caret 4 inserts **** around the caret ("    ****hello").
    try std.testing.expect(t.shortcut(.{ .key = 'b', .cmd = true }));
    t.settle(0.1);
    try std.testing.expectEqualStrings("    ****hello", h.viewer.block_buf.buf.items);

    // 3. Cmd+Enter saves and clears dirty.
    try std.testing.expect(h.viewer.dirty);
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    t.settle(0.1);
    try std.testing.expect(!h.viewer.dirty);

    // 4. Esc via `.cancel` TextOp exits block editing cleanly.
    t.textOps(&.{.{ .command = .cancel }});
    t.settle(0.1);
    try std.testing.expect(!h.viewer.editing_block);

    // 5. LinkQuery detects unclosed `[[` and `[label](` under caret.
    const q = viewer_mod.findLinkQuery("See [[sam", 9).?;
    try std.testing.expectEqualStrings("sam", q.query);
    try std.testing.expect(q.is_wiki);
    const md_q = viewer_mod.findLinkQuery("Open [note](hel", 15).?;
    try std.testing.expectEqualStrings("hel", md_q.query);
    try std.testing.expect(!md_q.is_wiki);
    try std.testing.expect(viewer_mod.findLinkQuery("See [[done]] ok", 15) == null);
    try std.testing.expect(viewer_mod.findLinkQuery("Open [n](a.md) ok", 17) == null);
}

test "Link autocomplete: Up/Down navigates, Enter accepts selected item, Esc closes only popup" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "note.md", .data = "See [ref](sam" });
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);

    var viewer = viewer_mod.Viewer.init(alloc, io);
    defer viewer.deinit();
    const entries = [_]viewer_mod.NoteEntry{
        .{ .name = "note.md", .full_path = "" },
        .{ .name = "sample.js", .full_path = "" },
        .{ .name = "sample.md", .full_path = "" },
        .{ .name = "sample.py", .full_path = "" },
    };
    viewer.note_entries = &entries;
    viewer.open(dir_path, "note.md");
    viewer.editBlock(.{ .start = 0, .end = "See [ref](sam".len });
    viewer.block_buf.want_caret = "See [ref](sam".len;
    viewer.last_caret = "See [ref](sam".len;
    viewer.last_anchor = viewer.last_caret;

    const Harness = struct {
        viewer: *viewer_mod.Viewer,
        fn view(h: *@This(), c: *ui.Context) void {
            h.viewer.view(c);
        }
    };
    var h: Harness = .{ .viewer = &viewer };
    var t: ui.Tester = undefined;
    try t.init(alloc, .init(&h, Harness.view), .{ .width = 800, .height = 600 });
    defer t.deinit();
    t.settle(0.1);

    // Down arrow moves selection from 0 (sample.js) -> 1 (sample.md).
    t.key(.down);
    t.settle(0.1);
    try std.testing.expectEqual(@as(usize, 1), viewer.ac_index);

    // Up arrow wraps back from 1 -> 0, then Up again wraps to 2 (sample.py).
    t.key(.up);
    t.key(.up);
    t.settle(0.1);
    try std.testing.expectEqual(@as(usize, 2), viewer.ac_index);

    // Esc closes ONLY the autocomplete popup while keeping editing_block open.
    t.key(.escape);
    t.settle(0.1);
    try std.testing.expect(viewer.editing_block);
    try std.testing.expect(viewer.ac_dismissed_start != null);

    // Re-open autocomplete by clearing dismissal, then Down -> 1 and Enter accepts sample.md.
    // Also verify current file (note.md) is excluded even for an empty query.
    var all_matches: [6]viewer_mod.NoteEntry = undefined;
    const all_count = viewer.collectLinkMatches("", &all_matches);
    try std.testing.expectEqual(@as(usize, 3), all_count);

    viewer.ac_dismissed_start = null;
    viewer.ac_index = 1;
    t.settle(0.1);
    t.key(.enter);
    t.settle(0.1);
    try std.testing.expectEqualStrings("See [ref](sample.md)", viewer.block_buf.buf.items);
}

test "markdown.parseInline strips [label](url) and **bold** markers" {
    const alloc = std.testing.allocator;
    const rich = try @import("../markdown.zig").parseInline(
        alloc,
        "That's **famously** nice [testing](sample.md) is",
        .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1 },
        .{ .r = 0.2, .g = 0.6, .b = 1, .a = 1 },
    );
    defer alloc.free(rich.text);
    defer alloc.free(rich.spans);
    try std.testing.expectEqualStrings("That's famously nice testing is", rich.text);
    try std.testing.expectEqual(@as(usize, 2), rich.spans.len);
    try std.testing.expectEqualStrings("famously", rich.text[rich.spans[0].start..rich.spans[0].end]);
    try std.testing.expectEqualStrings("testing", rich.text[rich.spans[1].start..rich.spans[1].end]);
    try std.testing.expect(rich.spans[1].underline);
}

test "Live Preview: Cmd+Z on new block after Enter does not duplicate previous block" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "note.md", .data = "First block" });
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);

    var viewer = viewer_mod.Viewer.init(alloc, io);
    defer viewer.deinit();
    viewer.open(dir_path, "note.md");
    viewer.editBlock(.{ .start = 0, .end = "First block".len });

    const Harness = struct {
        viewer: *viewer_mod.Viewer,
        fn view(h: *@This(), c: *ui.Context) void {
            h.viewer.view(c);
        }
    };
    var h: Harness = .{ .viewer = &viewer };
    var t: ui.Tester = undefined;
    try t.init(alloc, .init(&h, Harness.view), .{ .width = 800, .height = 600 });
    defer t.deinit();
    t.settle(0.1);

    // Edit first block, then press Enter to start a new empty block.
    t.textOps(&.{.{ .insert = " edited" }});
    t.settle(0.1);
    t.key(.enter);
    t.settle(0.1);
    try std.testing.expectEqualStrings("", viewer.block_buf.buf.items);

    // Cmd+Z in the new block must NOT restore the first block's text.
    _ = t.shortcut(.{ .key = 'z', .cmd = true });
    t.settle(0.1);
    try std.testing.expectEqualStrings("", viewer.block_buf.buf.items);
}

test "Live Preview: Up and Down move between adjacent blocks at line boundaries" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "note.md", .data = "First block\n\nSecond block" });
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);

    var viewer = viewer_mod.Viewer.init(alloc, io);
    defer viewer.deinit();
    viewer.open(dir_path, "note.md");
    const blocks = try markdown.splitBlocks(alloc, viewer.edit_buf.buf.items);
    defer alloc.free(blocks);
    viewer.editBlock(blocks[0]);

    const Harness = struct {
        viewer: *viewer_mod.Viewer,
        fn view(h: *@This(), c: *ui.Context) void {
            h.viewer.view(c);
        }
    };
    var h: Harness = .{ .viewer = &viewer };
    var t: ui.Tester = undefined;
    try t.init(alloc, .init(&h, Harness.view), .{ .width = 800, .height = 600 });
    defer t.deinit();
    t.settle(0.1);

    // Down from single-line First block moves to Second block (caret 0).
    t.key(.down);
    t.settle(0.1);
    try std.testing.expectEqualStrings("Second block", viewer.block_buf.buf.items);

    // Up from single-line Second block moves back to First block.
    t.key(.up);
    t.settle(0.1);
    try std.testing.expectEqualStrings("First block", viewer.block_buf.buf.items);
}
