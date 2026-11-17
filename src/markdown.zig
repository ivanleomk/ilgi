//! Block-level Markdown renderer built on `nanoui`'s `ui.markdown` + `highlight.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const highlight = @import("highlight.zig");

pub fn isMarkdownFile(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown");
}

pub const BlockRange = struct {
    start: usize,
    end: usize,
};

/// Splits Markdown `src` into top-level block byte ranges `[start, end)`.
pub fn splitBlocks(allocator: std.mem.Allocator, src: []const u8) ![]BlockRange {
    var out: std.ArrayList(BlockRange) = .empty;
    errdefer out.deinit(allocator);

    var pos: usize = 0;
    while (pos < src.len) {
        const line_end = std.mem.indexOfScalarPos(u8, src, pos, '\n') orelse src.len;
        const raw_line = std.mem.trimEnd(u8, src[pos..line_end], "\r");
        const trimmed = std.mem.trim(u8, raw_line, " \t");
        const block_start = pos;
        pos = if (line_end < src.len) line_end + 1 else src.len;

        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "```")) {
            var block_end = src.len;
            while (pos < src.len) {
                const next_end = std.mem.indexOfScalarPos(u8, src, pos, '\n') orelse src.len;
                const inner = std.mem.trim(u8, src[pos..next_end], " \t\r");
                pos = if (next_end < src.len) next_end + 1 else src.len;
                if (std.mem.startsWith(u8, inner, "```")) {
                    block_end = next_end;
                    break;
                }
            }
            try out.append(allocator, .{ .start = block_start, .end = block_end });
            continue;
        }

        try out.append(allocator, .{ .start = block_start, .end = line_end });
    }
    return out.toOwnedSlice(allocator);
}

pub const MdLink = struct {
    label: []const u8,
    url: []const u8,
};

/// Extracts all `[label](url)` Markdown links from `src` (ignoring `![alt](img)`).
pub fn extractMarkdownLinks(allocator: std.mem.Allocator, src: []const u8) ![]const MdLink {
    var links: std.ArrayList(MdLink) = .empty;
    errdefer links.deinit(allocator);
    var i: usize = 0;
    while (i + 3 < src.len) {
        if (src[i] == '[' and (i == 0 or src[i - 1] != '!') and src[i + 1] != '[') {
            if (std.mem.indexOfPos(u8, src, i + 1, "](")) |mid| {
                if (std.mem.indexOfScalarPos(u8, src, mid + 2, ')')) |close| {
                    const label = std.mem.trim(u8, src[i + 1 .. mid], " \t");
                    const url = std.mem.trim(u8, src[mid + 2 .. close], " \t");
                    if (label.len > 0 and url.len > 0) {
                        try links.append(allocator, .{ .label = label, .url = url });
                    }
                    i = close + 1;
                    continue;
                }
            }
        }
        i += 1;
    }
    return links.toOwnedSlice(allocator);
}

/// Extracts all `[[target]]` wikilink targets from `src`.
pub fn extractLinks(allocator: std.mem.Allocator, src: []const u8) ![]const []const u8 {
    var links: std.ArrayList([]const u8) = .empty;
    errdefer links.deinit(allocator);
    var i: usize = 0;
    while (i + 3 < src.len) {
        if (src[i] == '[' and src[i + 1] == '[') {
            if (std.mem.indexOfPos(u8, src, i + 2, "]]")) |close| {
                const target = std.mem.trim(u8, src[i + 2 .. close], " \t");
                if (target.len > 0) try links.append(allocator, target);
                i = close + 2;
                continue;
            }
        }
        i += 1;
    }
    return links.toOwnedSlice(allocator);
}

/// Produces ordered, non-overlapping `ui.Span`s for raw Markdown `src` so
/// `ui.textArea` can style **bold**, *italic*, `code`, [[links]], and # headings live.
pub fn liveSpans(
    allocator: std.mem.Allocator,
    src: []const u8,
    muted: ui.Color,
    code_bg: ui.Color,
    accent: ui.Color,
) ![]ui.Span {
    var spans: std.ArrayList(ui.Span) = .empty;
    errdefer spans.deinit(allocator);

    var i: usize = 0;
    // Dim leading `# ` heading markers on the first line.
    if (headingLevel(src)) |h| {
        const prefix_len = src.len - h.text.len;
        try spans.append(allocator, .{ .start = 0, .end = @intCast(prefix_len), .color = muted });
        try spans.append(allocator, .{ .start = @intCast(prefix_len), .end = @intCast(src.len), .weight = .bold });
        return spans.toOwnedSlice(allocator);
    }

    while (i < src.len) {
        if (src[i] == '[' and (i == 0 or src[i - 1] != '!') and (i + 1 >= src.len or src[i + 1] != '[')) {
            if (std.mem.indexOfPos(u8, src, i + 1, "](")) |mid| {
                if (std.mem.indexOfScalarPos(u8, src, mid + 2, ')')) |close| {
                    if (mid > i + 1 and close > mid + 2) {
                        try spans.append(allocator, .{ .start = @intCast(i), .end = @intCast(i + 1), .color = muted });
                        try spans.append(allocator, .{ .start = @intCast(i + 1), .end = @intCast(mid), .color = accent, .underline = true });
                        try spans.append(allocator, .{ .start = @intCast(mid), .end = @intCast(close + 1), .color = muted });
                        i = close + 1;
                        continue;
                    }
                }
            }
        }
        if (i + 1 < src.len and src[i] == '[' and src[i + 1] == '[') {
            if (std.mem.indexOfPos(u8, src, i + 2, "]]")) |close| {
                if (close > i + 2) {
                    try spans.append(allocator, .{ .start = @intCast(i), .end = @intCast(i + 2), .color = muted });
                    try spans.append(allocator, .{ .start = @intCast(i + 2), .end = @intCast(close), .color = accent, .underline = true });
                    try spans.append(allocator, .{ .start = @intCast(close), .end = @intCast(close + 2), .color = muted });
                    i = close + 2;
                    continue;
                }
            }
        }
        if (src[i] == '`' and i + 1 < src.len) {
            if (std.mem.indexOfScalarPos(u8, src, i + 1, '`')) |close| {
                if (close > i + 1) {
                    try spans.append(allocator, .{ .start = @intCast(i), .end = @intCast(i + 1), .color = muted });
                    try spans.append(allocator, .{ .start = @intCast(i + 1), .end = @intCast(close), .mono = true, .background = code_bg });
                    try spans.append(allocator, .{ .start = @intCast(close), .end = @intCast(close + 1), .color = muted });
                    i = close + 1;
                    continue;
                }
            }
        }
        if (i + 1 < src.len and ((src[i] == '*' and src[i + 1] == '*') or (src[i] == '_' and src[i + 1] == '_'))) {
            const marker = src[i .. i + 2];
            if (std.mem.indexOfPos(u8, src, i + 2, marker)) |close| {
                if (close > i + 2) {
                    try spans.append(allocator, .{ .start = @intCast(i), .end = @intCast(i + 2), .color = muted });
                    try spans.append(allocator, .{ .start = @intCast(i + 2), .end = @intCast(close), .weight = .bold });
                    try spans.append(allocator, .{ .start = @intCast(close), .end = @intCast(close + 2), .color = muted });
                    i = close + 2;
                    continue;
                }
            }
        }
        if ((src[i] == '*' or src[i] == '_') and i + 1 < src.len and src[i + 1] != ' ') {
            if (std.mem.indexOfScalarPos(u8, src, i + 1, src[i])) |close| {
                if (close > i + 1) {
                    try spans.append(allocator, .{ .start = @intCast(i), .end = @intCast(i + 1), .color = muted });
                    try spans.append(allocator, .{ .start = @intCast(i + 1), .end = @intCast(close), .italic = true });
                    try spans.append(allocator, .{ .start = @intCast(close), .end = @intCast(close + 1), .color = muted });
                    i = close + 1;
                    continue;
                }
            }
        }
        i += 1;
    }
    return spans.toOwnedSlice(allocator);
}

/// Strips inline Markdown markers (`[label](url)`, `[[wiki]]`, `` `code` ``,
/// `**bold**`, `*italic*`) and returns the display text with matching `ui.Span`s.
pub fn parseInline(
    allocator: std.mem.Allocator,
    src: []const u8,
    code_bg: ui.Color,
    accent: ui.Color,
) !ui.markdown.Rich {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var spans: std.ArrayList(ui.Span) = .empty;
    errdefer spans.deinit(allocator);

    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '[' and (i == 0 or src[i - 1] != '!') and (i + 1 >= src.len or src[i + 1] != '[')) {
            if (std.mem.indexOfPos(u8, src, i + 1, "](")) |mid| {
                if (std.mem.indexOfScalarPos(u8, src, mid + 2, ')')) |close| {
                    if (mid > i + 1 and close > mid + 2) {
                        const start: u32 = @intCast(out.items.len);
                        try out.appendSlice(allocator, src[i + 1 .. mid]);
                        try spans.append(allocator, .{ .start = start, .end = @intCast(out.items.len), .color = accent, .underline = true });
                        i = close + 1;
                        continue;
                    }
                }
            }
        }
        if (i + 1 < src.len and src[i] == '[' and src[i + 1] == '[') {
            if (std.mem.indexOfPos(u8, src, i + 2, "]]")) |close| {
                if (close > i + 2) {
                    const start: u32 = @intCast(out.items.len);
                    try out.appendSlice(allocator, src[i + 2 .. close]);
                    try spans.append(allocator, .{ .start = start, .end = @intCast(out.items.len), .color = accent, .underline = true });
                    i = close + 2;
                    continue;
                }
            }
        }
        if (src[i] == '`' and i + 1 < src.len) {
            if (std.mem.indexOfScalarPos(u8, src, i + 1, '`')) |close| {
                if (close > i + 1) {
                    const start: u32 = @intCast(out.items.len);
                    try out.appendSlice(allocator, src[i + 1 .. close]);
                    try spans.append(allocator, .{ .start = start, .end = @intCast(out.items.len), .mono = true, .background = code_bg });
                    i = close + 1;
                    continue;
                }
            }
        }
        if (i + 1 < src.len and ((src[i] == '*' and src[i + 1] == '*') or (src[i] == '_' and src[i + 1] == '_'))) {
            const marker = src[i .. i + 2];
            if (std.mem.indexOfPos(u8, src, i + 2, marker)) |close| {
                if (close > i + 2) {
                    const start: u32 = @intCast(out.items.len);
                    try out.appendSlice(allocator, src[i + 2 .. close]);
                    try spans.append(allocator, .{ .start = start, .end = @intCast(out.items.len), .weight = .bold });
                    i = close + 2;
                    continue;
                }
            }
        }
        if ((src[i] == '*' or src[i] == '_') and i + 1 < src.len and src[i + 1] != ' ') {
            if (std.mem.indexOfScalarPos(u8, src, i + 1, src[i])) |close| {
                if (close > i + 1) {
                    const start: u32 = @intCast(out.items.len);
                    try out.appendSlice(allocator, src[i + 1 .. close]);
                    try spans.append(allocator, .{ .start = start, .end = @intCast(out.items.len), .italic = true });
                    i = close + 1;
                    continue;
                }
            }
        }
        try out.append(allocator, src[i]);
        i += 1;
    }
    return .{
        .text = try out.toOwnedSlice(allocator),
        .spans = try spans.toOwnedSlice(allocator),
    };
}

/// Renders `src` as formatted Markdown blocks inside a vertical column.
pub fn view(c: *ui.Context, src: []const u8) void {
    const col = ui.div(c).column().wFull().gap(10);
    defer col.end();

    var pos: usize = 0;
    while (pos < src.len) {
        const line_end = std.mem.indexOfScalarPos(u8, src, pos, '\n') orelse src.len;
        const raw_line = std.mem.trimEnd(u8, src[pos..line_end], "\r");
        const trimmed = std.mem.trim(u8, raw_line, " \t");
        pos = if (line_end < src.len) line_end + 1 else src.len;

        if (trimmed.len == 0) continue;

        // Fenced code block (```lang ... ```)
        if (std.mem.startsWith(u8, trimmed, "```")) {
            const lang = std.mem.trim(u8, trimmed[3..], " \t");
            const code_start = pos;
            var code_end = src.len;
            while (pos < src.len) {
                const next_end = std.mem.indexOfScalarPos(u8, src, pos, '\n') orelse src.len;
                const inner = std.mem.trim(u8, src[pos..next_end], " \t\r");
                if (std.mem.startsWith(u8, inner, "```")) {
                    code_end = pos;
                    pos = if (next_end < src.len) next_end + 1 else src.len;
                    break;
                }
                pos = if (next_end < src.len) next_end + 1 else src.len;
            }
            const code = std.mem.trimEnd(u8, src[code_start..code_end], "\r\n");
            codeBlockView(c, lang, code);
            continue;
        }

        // Horizontal rule (--- or ***)
        if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "***")) {
            ui.divider(c);
            continue;
        }

        // Headings (# .. ####)
        if (headingLevel(trimmed)) |h| {
            const sizes = [_]f32{ 22, 18, 15.5, 14 };
            const size = sizes[@min(h.level, 4) - 1];
            richLine(c, h.text, .{ .size = size, .weight = .bold, .wrap = true, .leading = 1.3 });
            continue;
        }

        // Blockquote (> ...)
        if (std.mem.startsWith(u8, trimmed, "> ")) {
            const quote = ui.div(c).row().wFull().gap(10);
            defer quote.end();
            ui.div(c).w(3).hFull().bg(c.theme.border).rounded(2).end();
            richLine(c, trimmed[2..], .{ .size = 13, .color = c.theme.muted, .wrap = true, .leading = 1.45 });
            continue;
        }

        // Bullet list item (- ... or * ...)
        if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
            const item = ui.div(c).row().wFull().pl(8).gap(8);
            defer item.end();
            ui.text(c, "•", .{ .size = 13, .color = c.theme.muted });
            const body = ui.div(c).grow();
            defer body.end();
            richLine(c, trimmed[2..], .{ .size = 13, .wrap = true, .leading = 1.45 });
            continue;
        }

        // Paragraph
        richLine(c, raw_line, .{ .size = 13, .wrap = true, .leading = 1.65 });
    }
}

fn codeBlockView(c: *ui.Context, lang: []const u8, code: []const u8) void {
    const card = ui.div(c).column().wFull().bg(c.theme.surface).border(c.theme.border).borderW(1).rounded(8).p(12).gap(6);
    defer card.end();

    if (lang.len > 0) {
        ui.text(c, lang, .{ .size = 11, .color = c.theme.muted, .mono = true });
    }

    const virt_name = if (lang.len > 0) c.print("block.{s}", .{langAlias(lang)}) else "block.txt";
    const spans = highlight.highlight(c.alloc(), virt_name, code, c.theme.dark) catch &.{};
    ui.richText(c, code, spans, .{ .size = 12, .wrap = true, .mono = true, .leading = 1.55 });
}

fn richLine(c: *ui.Context, text: []const u8, style: ui.TextStyle) void {
    // If the line has `[[wikilinks]]` or `[label](url)`, strip markers and style links + bold/italic/code.
    if (std.mem.indexOf(u8, text, "[[") != null or std.mem.indexOf(u8, text, "](") != null) {
        const rich = parseInline(c.alloc(), text, c.theme.surface_hover, c.theme.accent) catch {
            ui.text(c, text, style);
            return;
        };
        ui.richText(c, rich.text, rich.spans, style);
        return;
    }
    const rich = ui.markdown.parse(c.alloc(), text, .{}) catch {
        ui.text(c, text, style);
        return;
    };
    ui.richText(c, rich.text, rich.spans, style);
}

fn headingLevel(line: []const u8) ?struct { level: usize, text: []const u8 } {
    var level: usize = 0;
    while (level < line.len and line[level] == '#') : (level += 1) {}
    if (level == 0 or level > 6 or level >= line.len or line[level] != ' ') return null;
    return .{ .level = level, .text = std.mem.trimStart(u8, line[level + 1 ..], " ") };
}

fn langAlias(lang: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(lang, "python")) return "py";
    if (std.ascii.eqlIgnoreCase(lang, "typescript")) return "ts";
    if (std.ascii.eqlIgnoreCase(lang, "javascript")) return "js";
    if (std.ascii.eqlIgnoreCase(lang, "bash")) return "sh";
    if (std.ascii.eqlIgnoreCase(lang, "rust")) return "rs";
    return lang;
}
