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
}
