//! Block-level Markdown renderer built on `nanoui`'s `ui.markdown` + `highlight.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const highlight = @import("highlight.zig");

pub fn isMarkdownFile(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown");
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
        richLine(c, raw_line, .{ .size = 13, .wrap = true, .leading = 1.5 });
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
    ui.richText(c, code, spans, .{ .size = 12, .wrap = true, .mono = true, .leading = 1.45 });
}

fn richLine(c: *ui.Context, text: []const u8, style: ui.TextStyle) void {
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
