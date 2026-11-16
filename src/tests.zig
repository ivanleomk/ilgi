//! Offscreen view tests using nanoui's ui.Tester.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("app.zig");

comptime {
    _ = @import("config.zig");
}

test "Ilgi renders initial welcome view" {
    var state: app_view.State = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, app_view.State.view), .{ .width = 960, .height = 640 });
    defer t.deinit();
    t.settle(0.1);
    try std.testing.expect(t.hasText("Ilgi"));
}
