//! Lightweight syntax highlighter producing `ui.Span` slices with Shiki's
//! `github-dark` / `github-light` token colors.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Palette = struct {
    keyword: ui.Color,
    string: ui.Color,
    comment: ui.Color,
    number: ui.Color,
    type_name: ui.Color,
    builtin: ui.Color,

    pub fn forTheme(dark: bool) Palette {
        return if (dark) .{
            .keyword = .hex(0xff7b72),
            .string = .hex(0xa5d6ff),
            .comment = .hex(0x8b949e),
            .number = .hex(0x79c0ff),
            .type_name = .hex(0xffa657),
            .builtin = .hex(0xd2a8ff),
        } else .{
            .keyword = .hex(0xcf222e),
            .string = .hex(0x0a3069),
            .comment = .hex(0x6e7781),
            .number = .hex(0x0550ae),
            .type_name = .hex(0x953800),
            .builtin = .hex(0x8250df),
        };
    }
};

/// Tokenizes `src` according to `file_name`'s extension and returns owned `ui.Span`s.
pub fn highlight(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    src: []const u8,
    dark: bool,
) std.mem.Allocator.Error![]ui.Span {
    const ext = std.fs.path.extension(file_name);
    if (std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown")) {
        return highlightMarkdown(allocator, src, dark);
    }
    if (!isCodeFile(file_name)) return &.{};

    const hash_comments = std.ascii.eqlIgnoreCase(ext, ".py") or
        std.ascii.eqlIgnoreCase(ext, ".sh") or
        std.ascii.eqlIgnoreCase(ext, ".zsh") or
        std.ascii.eqlIgnoreCase(ext, ".toml") or
        std.ascii.eqlIgnoreCase(ext, ".yaml") or
        std.ascii.eqlIgnoreCase(ext, ".yml");

    const pal = Palette.forTheme(dark);
    var spans: std.ArrayList(ui.Span) = .empty;
    errdefer spans.deinit(allocator);

    var i: usize = 0;
    while (i < src.len) {
        // Line comments (`//` or `#` for Python/Shell/TOML/YAML)
        if ((i + 1 < src.len and src[i] == '/' and src[i + 1] == '/') or
            (hash_comments and src[i] == '#'))
        {
            const start = i;
            while (i < src.len and src[i] != '\n') : (i += 1) {}
            try appendSpan(&spans, allocator, start, i, pal.comment);
            continue;
        }

        // Block comments `/* ... */`
        if (i + 1 < src.len and src[i] == '/' and src[i + 1] == '*') {
            const start = i;
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) : (i += 1) {}
            i = @min(i + 2, src.len);
            try appendSpan(&spans, allocator, start, i, pal.comment);
            continue;
        }

        // Zig multiline string literals (`\\...`)
        if (i + 1 < src.len and src[i] == '\\' and src[i + 1] == '\\') {
            const start = i;
            while (i < src.len and src[i] != '\n') : (i += 1) {}
            try appendSpan(&spans, allocator, start, i, pal.string);
            continue;
        }

        // Quoted strings (`"`, `'`, `` ` ``)
        if (src[i] == '"' or src[i] == '\'' or src[i] == '`') {
            const quote = src[i];
            const start = i;
            i += 1;
            while (i < src.len and src[i] != quote) : (i += 1) {
                if (src[i] == '\\' and i + 1 < src.len) i += 1;
            }
            if (i < src.len) i += 1;
            try appendSpan(&spans, allocator, start, i, pal.string);
            continue;
        }

        // Zig builtins (`@import`, `@as`, ...)
        if (src[i] == '@' and i + 1 < src.len and isIdentStart(src[i + 1])) {
            const start = i;
            i += 1;
            while (i < src.len and isIdentCont(src[i])) : (i += 1) {}
            try appendSpan(&spans, allocator, start, i, pal.builtin);
            continue;
        }

        // Numbers (`0x...`, `123`, `1.5`)
        if (std.ascii.isDigit(src[i])) {
            const start = i;
            while (i < src.len and (isIdentCont(src[i]) or src[i] == '.')) : (i += 1) {}
            try appendSpan(&spans, allocator, start, i, pal.number);
            continue;
        }

        // Identifiers, keywords, constants, and types
        if (isIdentStart(src[i])) {
            const start = i;
            while (i < src.len and isIdentCont(src[i])) : (i += 1) {}
            const word = src[start..i];
            if (isKeyword(word)) {
                try appendSpan(&spans, allocator, start, i, pal.keyword);
            } else if (isConstant(word)) {
                try appendSpan(&spans, allocator, start, i, pal.number);
            } else if (isTypeName(word)) {
                try appendSpan(&spans, allocator, start, i, pal.type_name);
            }
            continue;
        }

        i += 1;
    }

    return spans.toOwnedSlice(allocator);
}

fn highlightMarkdown(allocator: std.mem.Allocator, src: []const u8, dark: bool) std.mem.Allocator.Error![]ui.Span {
    var out: std.ArrayList(ui.Span) = .empty;
    errdefer out.deinit(allocator);

    var pos: usize = 0;
    while (pos < src.len) {
        const line_end = std.mem.indexOfScalarPos(u8, src, pos, '\n') orelse src.len;
        const line = std.mem.trim(u8, src[pos..line_end], " \t\r");
        if (std.mem.startsWith(u8, line, "```")) {
            const lang = std.mem.trim(u8, line[3..], " \t\r");
            const code_start = if (line_end < src.len) line_end + 1 else src.len;
            var scan = code_start;
            var code_end = src.len;
            while (scan < src.len) {
                const next_end = std.mem.indexOfScalarPos(u8, src, scan, '\n') orelse src.len;
                const inner = std.mem.trim(u8, src[scan..next_end], " \t\r");
                if (std.mem.startsWith(u8, inner, "```")) {
                    code_end = scan;
                    pos = if (next_end < src.len) next_end + 1 else src.len;
                    break;
                }
                scan = if (next_end < src.len) next_end + 1 else src.len;
            } else {
                pos = src.len;
            }

            if (langToFilename(lang)) |virt_name| {
                const inner_spans = try highlight(allocator, virt_name, src[code_start..code_end], dark);
                defer allocator.free(inner_spans);
                for (inner_spans) |sp| {
                    var shifted = sp;
                    shifted.start += @intCast(code_start);
                    shifted.end += @intCast(code_start);
                    shifted.mono = true;
                    try out.append(allocator, shifted);
                }
            }
            continue;
        }
        pos = if (line_end < src.len) line_end + 1 else src.len;
    }
    return out.toOwnedSlice(allocator);
}

fn langToFilename(lang: []const u8) ?[]const u8 {
    const map = .{
        .{ "zig", "a.zig" },
        .{ "ts", "a.ts" },
        .{ "typescript", "a.ts" },
        .{ "js", "a.js" },
        .{ "javascript", "a.js" },
        .{ "py", "a.py" },
        .{ "python", "a.py" },
        .{ "json", "a.json" },
        .{ "toml", "a.toml" },
        .{ "sh", "a.sh" },
        .{ "bash", "a.sh" },
        .{ "zsh", "a.zsh" },
        .{ "go", "a.go" },
        .{ "rs", "a.rs" },
        .{ "rust", "a.rs" },
        .{ "c", "a.c" },
        .{ "cpp", "a.cpp" },
    };
    inline for (map) |entry| {
        if (std.ascii.eqlIgnoreCase(lang, entry[0])) return entry[1];
    }
    return null;
}

fn appendSpan(spans: *std.ArrayList(ui.Span), alloc: std.mem.Allocator, start: usize, end: usize, color: ui.Color) !void {
    try spans.append(alloc, .{
        .start = @intCast(start),
        .end = @intCast(end),
        .color = color,
    });
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentCont(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Returns true if `file_name` has a supported code/config extension.
pub fn isCodeFile(file_name: []const u8) bool {
    const ext = std.fs.path.extension(file_name);
    for ([_][]const u8{
        ".zig", ".zon", ".c",  ".h",    ".cpp", ".rs",   ".go", ".py",
        ".js",  ".ts",  ".jsx", ".tsx", ".json", ".toml", ".yaml", ".yml",
        ".sh",  ".zsh",
    }) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

fn isKeyword(word: []const u8) bool {
    const kws = [_][]const u8{
        "const",  "var",    "fn",     "pub",    "return",   "if",       "else",
        "for",    "while",  "switch", "break",  "continue", "defer",    "errdefer",
        "try",    "catch",  "orelse", "struct", "enum",     "union",    "error",
        "comptime", "inline", "test", "and",    "or",       "let",      "function",
        "import", "export", "from",   "as",     "async",    "await",    "def",
        "class",  "in",     "not",    "elif",   "pass",     "with",     "func",
        "package", "type",  "range",  "impl",   "trait",    "match",    "use",
    };
    for (kws) |kw| if (std.mem.eql(u8, word, kw)) return true;
    return false;
}

fn isConstant(word: []const u8) bool {
    for ([_][]const u8{ "true", "false", "null", "undefined", "None", "True", "False" }) |c| {
        if (std.mem.eql(u8, word, c)) return true;
    }
    return false;
}

fn isTypeName(word: []const u8) bool {
    if (std.ascii.isUpper(word[0])) return true;
    for ([_][]const u8{ "u8", "u16", "u32", "u64", "usize", "i8", "i16", "i32", "i64", "isize", "f32", "f64", "bool", "void", "anytype", "int", "char", "float", "double" }) |t| {
        if (std.mem.eql(u8, word, t)) return true;
    }
    return false;
}
