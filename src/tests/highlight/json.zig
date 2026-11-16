const h = @import("helper.zig");

test "highlight: JSON" {
    try h.expectTokens("config.json",
        \\{
        \\  "name": "ilgi",
        \\  "count": 3,
        \\  "ok": true
        \\}
    , false, &.{
        .{ .text = "\"name\"", .color = 0x0a3069 },
        .{ .text = "\"ilgi\"", .color = 0x0a3069 },
        .{ .text = "\"count\"", .color = 0x0a3069 },
        .{ .text = "3", .color = 0x0550ae },
        .{ .text = "\"ok\"", .color = 0x0a3069 },
        .{ .text = "true", .color = 0x0550ae },
    });
}
