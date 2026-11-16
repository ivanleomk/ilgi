const h = @import("helper.zig");

test "highlight: Go" {
    try h.expectTokens("main.go",
        \\package main
        \\func add(n int) int {
        \\    // add 1
        \\    return n + 1
        \\}
    , true, &.{
        .{ .text = "package", .color = 0xff7b72 },
        .{ .text = "func", .color = 0xff7b72 },
        .{ .text = "int", .color = 0xffa657 },
        .{ .text = "int", .color = 0xffa657 },
        .{ .text = "// add 1", .color = 0x8b949e },
        .{ .text = "return", .color = 0xff7b72 },
        .{ .text = "1", .color = 0x79c0ff },
    });
}
