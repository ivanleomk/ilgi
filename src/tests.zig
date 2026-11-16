//! Offscreen view and config tests.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("app.zig");
const config_mod = @import("config.zig");

comptime {
    _ = config_mod;
}

test "Sidebar lists configured folder entries and persists add/remove" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "notes", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "# Hello Ilgi" });

    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_buf[0..try tmp.dir.realPathFile(io, ".", &tmp_buf)];

    var cfg_tmp = std.testing.tmpDir(.{});
    defer cfg_tmp.cleanup();
    var cfg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cfg_path = try std.fs.path.join(alloc, &.{ cfg_buf[0..try cfg_tmp.dir.realPathFile(io, ".", &cfg_buf)], "config.json" });
    defer alloc.free(cfg_path);

    var state = app_view.State.init(alloc, io, cfg_path);
    defer state.deinit();
    _ = try state.sidebar.config.addFolder(tmp_path, null);
    try state.sidebar.config.save(io, cfg_path);
    state.sidebar.openDir(tmp_path);

    var t: ui.Tester = undefined;
    try t.init(alloc, .init(&state, app_view.State.view), .{ .width = 960, .height = 640 });
    defer t.deinit();
    t.settle(0.1);

    try std.testing.expect(t.hasText("notes"));
    try std.testing.expect(t.hasText("README.md"));

    // Index 0 is "notes" dir, index 1 is "README.md".
    state.sidebar.selectEntry(1);
    t.settle(0.1);
    try std.testing.expectEqualStrings("README.md", state.sidebar.selected_name.?);

    try std.testing.expect(state.sidebar.config.removeFolder(tmp_path));
    try state.sidebar.config.save(io, cfg_path);
    var reloaded = try config_mod.Config.load(alloc, io, cfg_path);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), reloaded.folders.items.len);
}
