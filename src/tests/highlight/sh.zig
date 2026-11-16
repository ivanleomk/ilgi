const h = @import("helper.zig");

test "highlight: Shell" {
    try h.expectTokens("refresh.sh",
        \\# reload app
        \\for f in "a" "b"; do
        \\  echo 1
        \\done
    , true, &.{
        .{ .text = "# reload app", .color = 0x8b949e },
        .{ .text = "for", .color = 0xff7b72 },
        .{ .text = "in", .color = 0xff7b72 },
        .{ .text = "\"a\"", .color = 0xa5d6ff },
        .{ .text = "\"b\"", .color = 0xa5d6ff },
        .{ .text = "1", .color = 0x79c0ff },
    });
}
