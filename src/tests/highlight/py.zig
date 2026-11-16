const std = @import("std");
const highlight = @import("../../highlight.zig");
const h = @import("helper.zig");

test "highlight: Python" {
    try h.expectTokens("run.py",
        \\# compute value
        \\def greet(name):
        \\    if name == None:
        \\        return False
        \\    return "hi"
    , true, &.{
        .{ .text = "# compute value", .color = 0x8b949e },
        .{ .text = "def", .color = 0xff7b72 },
        .{ .text = "if", .color = 0xff7b72 },
        .{ .text = "None", .color = 0x79c0ff },
        .{ .text = "return", .color = 0xff7b72 },
        .{ .text = "False", .color = 0x79c0ff },
        .{ .text = "return", .color = 0xff7b72 },
        .{ .text = "\"hi\"", .color = 0xa5d6ff },
    });

    const plain = try highlight.highlight(std.testing.allocator, "README.md", "# Title", true);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqual(@as(usize, 0), plain.len);
}
