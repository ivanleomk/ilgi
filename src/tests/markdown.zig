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

test "markdown.liveSpans styles bold, italic, inline code, and wikilinks inside raw Markdown" {
    const alloc = std.testing.allocator;
    const raw = "Hi **bold** and *it* and `code` and [[Page]]";
    const spans = try markdown.liveSpans(alloc, raw, ui.Color.hex(0x6e6e73), ui.Color.hex(0x2c2c2e), ui.Color.hex(0x0a84ff));
    defer alloc.free(spans);

    // 3 spans per inline marker group (open marker, inner styled text, close marker) = 12 spans.
    try std.testing.expectEqual(@as(usize, 12), spans.len);
    try std.testing.expectEqualStrings("bold", raw[spans[1].start..spans[1].end]);
    try std.testing.expectEqual(ui.Weight.bold, spans[1].weight.?);
    try std.testing.expectEqualStrings("it", raw[spans[4].start..spans[4].end]);
    try std.testing.expect(spans[4].italic);
    try std.testing.expectEqualStrings("code", raw[spans[7].start..spans[7].end]);
    try std.testing.expect(spans[7].mono);
    try std.testing.expectEqualStrings("Page", raw[spans[10].start..spans[10].end]);
    try std.testing.expect(spans[10].underline);

    const links = try markdown.extractLinks(alloc, raw);
    defer alloc.free(links);
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqualStrings("Page", links[0]);

    const md_raw = "Visit [Zig](https://ziglang.org) and ![pic](a.png)";
    const md_links = try markdown.extractMarkdownLinks(alloc, md_raw);
    defer alloc.free(md_links);
    try std.testing.expectEqual(@as(usize, 1), md_links.len);
    try std.testing.expectEqualStrings("Zig", md_links[0].label);
    try std.testing.expectEqualStrings("https://ziglang.org", md_links[0].url);
}
