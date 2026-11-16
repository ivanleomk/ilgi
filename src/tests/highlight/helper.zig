//! Shared assertion helper for per-language syntax highlighting tests.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const highlight = @import("../../highlight.zig");

pub const ExpectedToken = struct {
    text: []const u8,
    color: u24,
};

pub fn expectTokens(file_name: []const u8, code: []const u8, dark: bool, expected: []const ExpectedToken) !void {
    const alloc = std.testing.allocator;
    const spans = try highlight.highlight(alloc, file_name, code, dark);
    defer alloc.free(spans);

    try std.testing.expectEqual(expected.len, spans.len);
    for (expected, spans) |exp, sp| {
        try std.testing.expectEqualStrings(exp.text, code[sp.start..sp.end]);
        try std.testing.expectEqual(ui.Color.hex(exp.color), sp.color.?);
    }
}
