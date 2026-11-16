const h = @import("helper.zig");

test "highlight: JavaScript" {
    try h.expectTokens("app.js",
        \\const msg = `hi \"there\"`;
        \\let count = 42;
        \\if (count > 0) console.log('ok');
    , false, &.{
        .{ .text = "const", .color = 0xcf222e },
        .{ .text = "`hi \\\"there\\\"`", .color = 0x0a3069 },
        .{ .text = "let", .color = 0xcf222e },
        .{ .text = "42", .color = 0x0550ae },
        .{ .text = "if", .color = 0xcf222e },
        .{ .text = "0", .color = 0x0550ae },
        .{ .text = "'ok'", .color = 0x0a3069 },
    });
}
