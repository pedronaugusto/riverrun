//! A file as rows, and the rows the reader reads as lines.
//!
//! Every row keeps its layout: its indentation, its words, its tags, its
//! comment, the spaces between and after them and its line ending, so the
//! rows print the file back byte for byte. The reader works on the lines:
//! each row that says something, with its indentation, its words and the
//! tags at its end, its comment gone.
//!
//! A comment is `//` at the start of a row's words or after a space; tags are
//! what follows ` # `. Neither counts inside a quoted tag value.

const std = @import("std");
const source = @import("source.zig");
const ast = @import("ast.zig");
const aegis = @import("aegis");

pub const max_bytes = 16 * 1024 * 1024;
pub const max_line = 64 * 1024;

pub const Line = struct {
    indent: u32,
    /// What the line says, without its indentation, comment or tags, and where it starts.
    text: source.Placed,
    /// What follows ` # `, and where it starts; empty without tags.
    tags: source.Placed,

    /// From the line's words to the end of its tags.
    pub fn span(l: Line, file: source.FileId) source.Span {
        const end = if (l.tags.text.len > 0) l.tags.span(file).end else l.text.span(file).end;
        return .{ .file = file, .start = l.text.at, .end = end };
    }
};

/// A file split: its rows, and the lines among them the reader reads.
pub const Split = struct {
    bom: bool = false,
    rows: []const ast.Row = &.{},
    lines: []const Line = &.{},
};

/// Splits `bytes` into rows and lines. A file too large, or not UTF-8, is refused whole; a row too long or indented
/// by tabs is reported and kept as a row, and not read.
pub fn split(arena: std.mem.Allocator, gpa: std.mem.Allocator, diags: *source.Diagnostics, file: source.FileId, bytes: []const u8) error{ OutOfMemory, Invalid }!Split {
    if (bytes.len > max_bytes) {
        try diags.add(gpa, .{ .file = file, .start = 0, .end = 0 }, .err, "the file is larger than {d} bytes", .{max_bytes});
        return error.Invalid;
    }
    if (invalid(bytes)) |at| {
        const start: u32 = @intCast(at); // safe: the file is at most max_bytes
        try diags.add(gpa, .{ .file = file, .start = start, .end = start + 1 }, .err, "the file is not UTF-8", .{});
        return error.Invalid;
    }
    const bom = std.mem.startsWith(u8, bytes, source.byte_order_mark);
    var rows: std.ArrayList(ast.Row) = .empty;
    var lines: std.ArrayList(Line) = .empty;
    var start: usize = if (bom) source.byte_order_mark.len else 0;
    while (start < bytes.len) {
        const newline = std.mem.findScalarPos(u8, bytes, start, '\n');
        const stop = newline orelse bytes.len;
        const crlf = newline != null and stop > start and bytes[stop - 1] == '\r';
        const content: source.Placed = .{ .text = bytes[start .. stop - @intFromBool(crlf)], .at = @intCast(start) }; // safe: the file is at most max_bytes
        const row = rowOf(content, if (crlf) .crlf else if (newline != null) .lf else .none);
        aegis.assert.invariant(row.len() == (if (newline) |n| n + 1 else bytes.len) - start, "a row is every byte from its start to the next");
        try rows.append(arena, row);
        start = if (newline) |n| n + 1 else bytes.len;
        if (content.text.len > max_line) {
            try diags.add(gpa, content.span(file), .err, "the line is longer than {d} bytes", .{max_line});
            continue;
        }
        const body = content.from(row.indent);
        if (body.text.len > 0 and body.text[0] == '\t') {
            try diags.add(gpa, body.to(1).span(file), .err, "indentation is spaces, not tabs", .{});
            continue;
        }
        if (row.text.len == 0 and row.tags.len == 0) continue;
        // the tags the reader reads: what follows `#` and the spaces after it
        const tags = if (row.tags.len == 0) body.cut(0, 0) else body.cut(row.text.len + row.before_tags + 1, row.text.len + row.before_tags + row.tags.len).trim();
        try lines.append(arena, .{ .indent = row.indent, .text = body.to(row.text.len), .tags = tags });
    }
    return .{ .bom = bom, .rows = try rows.toOwnedSlice(arena), .lines = try lines.toOwnedSlice(arena) };
}

// Where the first byte that is not UTF-8 is, if one is.
fn invalid(bytes: []const u8) ?usize {
    if (std.unicode.utf8ValidateSlice(bytes)) return null;
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return i;
        if (i + n > bytes.len) return i;
        if (!std.unicode.utf8ValidateSlice(bytes[i .. i + n])) return i;
        i += n;
    }
    // the whole slice decodes piece by piece, yet failed as one: say so at its start
    return 0;
}

// A row's layout, from its content (the row without its line ending).
fn rowOf(content: source.Placed, ending: ast.Row.Ending) ast.Row {
    const raw = content.text;
    var indent: usize = 0;
    while (indent < raw.len and raw[indent] == ' ') indent += 1;
    const body = raw[indent..];
    const cut = strip(body);
    const words_end = cut.hash orelse cut.comment orelse body.len;
    const text = std.mem.trimEnd(u8, body[0..words_end], " ");
    var row: ast.Row = .{ .start = content.at, .indent = @intCast(indent), .text = text, .ending = ending }; // safe: a row is a part of its file
    var end = text.len;
    if (cut.hash) |hash| {
        row.before_tags = @intCast(hash - end); // safe: as the row's
        row.tags = std.mem.trimEnd(u8, body[hash .. cut.comment orelse body.len], " ");
        end = hash + row.tags.len;
    }
    if (cut.comment) |comment| {
        row.before_comment = @intCast(comment - end); // safe: as the row's
        row.comment = std.mem.trimEnd(u8, body[comment..], " ");
        end = comment + row.comment.len;
    }
    row.trailing = @intCast(body.len - end); // safe: as the row's
    return row;
}

const Cut = struct { hash: ?usize = null, comment: ?usize = null };

// Where a row's tags start, at `#`, and its comment, at `//`, outside quotes.
fn strip(s: []const u8) Cut {
    var quoted = false;
    var cut: Cut = .{};
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' and cut.hash != null) quoted = !quoted;
        if (quoted) continue;
        if (c == '/' and i + 1 < s.len and s[i + 1] == '/' and (i == 0 or s[i - 1] == ' ')) {
            cut.comment = i;
            return cut;
        }
        if (cut.hash == null and c == '#' and (i == 0 or s[i - 1] == ' ') and (i + 1 == s.len or s[i + 1] == ' ')) cut.hash = i;
    }
    return cut;
}

test "a line loses its comment and keeps its tags apart; its row keeps both" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    const text = "// a comment\n" ++
        "== hide_1969          # listen · count 20\n" ++
        "MUM: You could still play, Frank.   # at 9.5 · heard piano, door  \r\n" ++
        "\n" ++
        "  ~ carried += play   // the memory\n" ++
        "* Get on   # side go · line \"the city · whoever she'd be\" // why";
    const s = try split(arena.allocator(), gpa, &diags, 0, text);
    try std.testing.expectEqual(@as(usize, 6), s.rows.len);
    try std.testing.expectEqual(@as(usize, 4), s.lines.len);
    try std.testing.expectEqualStrings("== hide_1969", s.lines[0].text.text);
    try std.testing.expectEqualStrings("listen · count 20", s.lines[0].tags.text);
    try std.testing.expectEqual(@as(u32, 13 + 24), s.lines[0].tags.at);
    try std.testing.expectEqualStrings("MUM: You could still play, Frank.", s.lines[1].text.text);
    try std.testing.expectEqual(@as(u32, 2), s.lines[2].indent);
    try std.testing.expectEqualStrings("~ carried += play", s.lines[2].text.text);
    try std.testing.expectEqualStrings("side go · line \"the city · whoever she'd be\"", s.lines[3].tags.text);
    // the rows keep the comments, the blank row, the spaces and the line endings
    try std.testing.expectEqualStrings("// a comment", s.rows[0].comment);
    try std.testing.expectEqual(@as(u32, 2), s.rows[2].trailing);
    try std.testing.expectEqual(ast.Row.Ending.crlf, s.rows[2].ending);
    try std.testing.expectEqual(@as(u32, 0), s.rows[3].len() - 1);
    try std.testing.expectEqual(@as(u32, 3), s.rows[4].before_comment);
    try std.testing.expectEqualStrings("// why", s.rows[5].comment);
    try std.testing.expectEqual(ast.Row.Ending.none, s.rows[5].ending);
}

test "tabs are refused" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    _ = try split(arena.allocator(), gpa, &diags, 0, "\tDAD: Go.");
    try std.testing.expectEqual(@as(usize, 1), diags.errors());
}
