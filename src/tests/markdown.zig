const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const markdown = @import("../markdown.zig");

const MdHarness = struct {
    src: []const u8,
    pub fn view(self: *MdHarness, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(16);
        defer root.end();
        markdown.view(c, self.src);
    }
};

test "markdown.view renders headings, bullets, inline formatting, and code blocks" {
    var h: MdHarness = .{
        .src =
        \\# Title
        \\Hello **world** and `inline`
        \\- First item
        \\> Quoted note
        \\```zig
        \\const x: u32 = 42;
        \\```
        ,
    };
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&h, MdHarness.view), .{ .width = 800, .height = 600 });
    defer t.deinit();
    t.settle(0.1);

    try std.testing.expect(t.hasText("Title"));
    try std.testing.expect(t.hasText("Hello world and inline"));
    try std.testing.expect(t.hasText("First item"));
    try std.testing.expect(t.hasText("Quoted note"));
    try std.testing.expect(t.hasText("const x: u32 = 42;"));
}
