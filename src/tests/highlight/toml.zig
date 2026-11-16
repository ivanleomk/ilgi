const h = @import("helper.zig");

test "highlight: TOML" {
    try h.expectTokens("config.toml",
        \\# Ilgi config
        \\name = "ilgi"
        \\port = 8080
        \\enabled = true
    , true, &.{
        .{ .text = "# Ilgi config", .color = 0x8b949e },
        .{ .text = "\"ilgi\"", .color = 0xa5d6ff },
        .{ .text = "8080", .color = 0x79c0ff },
        .{ .text = "true", .color = 0x79c0ff },
    });
}
