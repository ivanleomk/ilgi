//! Offscreen view and config tests.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("app.zig");
const config_mod = @import("config.zig");

comptime {
    _ = config_mod;
    _ = @import("tests/highlight/zig.zig");
    _ = @import("tests/highlight/ts.zig");
    _ = @import("tests/highlight/js.zig");
    _ = @import("tests/highlight/py.zig");
    _ = @import("tests/highlight/json.zig");
    _ = @import("tests/highlight/toml.zig");
    _ = @import("tests/highlight/sh.zig");
    _ = @import("tests/highlight/go.zig");
    _ = @import("tests/highlight/md.zig");
    _ = @import("tests/markdown.zig");
}

test "Sidebar renders per-folder collapsible trees and previews selected file" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "notes", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "notes/hello.md", .data = "# Hello Tree" });
    try tmp.dir.createDir(io, "scripts", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "scripts/refresh.sh", .data = "echo hi" });

    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_buf[0..try tmp.dir.realPathFile(io, ".", &tmp_buf)];
    const notes_path = try std.fs.path.join(alloc, &.{ tmp_path, "notes" });
    defer alloc.free(notes_path);
    const scripts_path = try std.fs.path.join(alloc, &.{ tmp_path, "scripts" });
    defer alloc.free(scripts_path);

    var cfg_tmp = std.testing.tmpDir(.{});
    defer cfg_tmp.cleanup();
    var cfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cfg_path = try std.fs.path.join(alloc, &.{ cfg_buf[0..try cfg_tmp.dir.realPathFile(io, ".", &cfg_buf)], "config.json" });
    defer alloc.free(cfg_path);

    // Pre-save both folders so Sidebar.init expands both trees on startup.
    {
        var seed = config_mod.Config.init(alloc);
        defer seed.deinit();
        _ = try seed.addFolder(notes_path, null);
        _ = try seed.addFolder(scripts_path, null);
        try seed.save(io, cfg_path);
    }

    var state = app_view.State.init(alloc, io, cfg_path);
    defer state.deinit();

    var t: ui.Tester = undefined;
    try t.init(alloc, .init(&state, app_view.State.view), .{ .width = 960, .height = 640 });
    defer t.deinit();
    t.settle(0.1);

    try std.testing.expect(t.hasText("notes"));
    try std.testing.expect(t.hasText("hello.md"));
    try std.testing.expect(t.hasText("scripts"));
    try std.testing.expect(t.hasText("refresh.sh"));

    // Rows: 0=notes, 1=hello.md, 2=scripts, 3=refresh.sh
    state.sidebar.selectRow(1);
    t.settle(0.1);
    try std.testing.expect(t.hasText("Hello Tree"));

    // Collapse "notes" (row 0): its child row disappears, while scripts & refresh.sh remain.
    state.sidebar.selectRow(0);
    t.settle(0.1);
    try std.testing.expectEqual(@as(usize, 3), state.sidebar.rows.items.len);
    try std.testing.expect(t.hasText("refresh.sh"));

    // Create a subfolder and a file, then delete the file.
    try state.sidebar.createFolder(notes_path, "sub");
    try state.sidebar.createFile(notes_path, "new.md");
    t.settle(0.1);
    try std.testing.expect(t.hasText("sub"));
    try std.testing.expect(t.hasText("new.md"));

    // Delete "new.md" (row 2 under notes: 0=notes, 1=sub, 2=hello.md, 3=new.md).
    try state.sidebar.deleteRow(3);
    t.settle(0.1);
    try std.testing.expect(!t.hasText("new.md"));
}
