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

test "markdown.liveSpans styles bold, italic, and inline code inside raw Markdown" {
    const alloc = std.testing.allocator;
    const raw = "Hi **bold** and *it* and `code`";
    const spans = try markdown.liveSpans(alloc, raw, ui.Color.hex(0x6e6e73), ui.Color.hex(0x2c2c2e));
    defer alloc.free(spans);

    // 3 spans per inline marker group (open marker, inner styled text, close marker) = 9 spans.
    try std.testing.expectEqual(@as(usize, 9), spans.len);
    try std.testing.expectEqualStrings("bold", raw[spans[1].start..spans[1].end]);
    try std.testing.expectEqual(ui.Weight.bold, spans[1].weight.?);
    try std.testing.expectEqualStrings("it", raw[spans[4].start..spans[4].end]);
    try std.testing.expect(spans[4].italic);
    try std.testing.expectEqualStrings("code", raw[spans[7].start..spans[7].end]);
    try std.testing.expect(spans[7].mono);
}
