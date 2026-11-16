const h = @import("helper.zig");

test "highlight: Zig" {
    try h.expectTokens("main.zig",
        \\const std = @import("std");
        \\pub fn add(a: u32, b: u32) u32 {
        \\    // sum
        \\    return a + b + 0x10;
        \\}
    , true, &.{
        .{ .text = "const", .color = 0xff7b72 },
        .{ .text = "@import", .color = 0xd2a8ff },
        .{ .text = "\"std\"", .color = 0xa5d6ff },
        .{ .text = "pub", .color = 0xff7b72 },
        .{ .text = "fn", .color = 0xff7b72 },
        .{ .text = "u32", .color = 0xffa657 },
        .{ .text = "u32", .color = 0xffa657 },
        .{ .text = "u32", .color = 0xffa657 },
        .{ .text = "// sum", .color = 0x8b949e },
        .{ .text = "return", .color = 0xff7b72 },
        .{ .text = "0x10", .color = 0x79c0ff },
    });
}
