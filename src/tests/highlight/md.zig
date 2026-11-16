const h = @import("helper.zig");

test "highlight: Markdown fenced code blocks" {
    try h.expectTokens("notes.md",
        \\# Example
        \\```zig
        \\const x: u32 = 42;
        \\```
    , true, &.{
        .{ .text = "const", .color = 0xff7b72 },
        .{ .text = "u32", .color = 0xffa657 },
        .{ .text = "42", .color = 0x79c0ff },
    });
}
