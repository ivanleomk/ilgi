const h = @import("helper.zig");

test "highlight: TypeScript" {
    try h.expectTokens("types.ts",
        \\import type { Config } from "./config";
        \\export async function load(ok: bool): Promise {
        \\  /* check */
        \\  if (!ok) return null;
        \\}
    , true, &.{
        .{ .text = "import", .color = 0xff7b72 },
        .{ .text = "type", .color = 0xff7b72 },
        .{ .text = "Config", .color = 0xffa657 },
        .{ .text = "from", .color = 0xff7b72 },
        .{ .text = "\"./config\"", .color = 0xa5d6ff },
        .{ .text = "export", .color = 0xff7b72 },
        .{ .text = "async", .color = 0xff7b72 },
        .{ .text = "function", .color = 0xff7b72 },
        .{ .text = "bool", .color = 0xffa657 },
        .{ .text = "Promise", .color = 0xffa657 },
        .{ .text = "/* check */", .color = 0x8b949e },
        .{ .text = "if", .color = 0xff7b72 },
        .{ .text = "return", .color = 0xff7b72 },
        .{ .text = "null", .color = 0x79c0ff },
    });
}
