//! A file as rows, and the rows the reader reads as lines.
//!
//! Every row keeps its layout: its indentation, its words, its id, its
//! comment, the spaces between and after them and its line ending, so the
//! rows print the file back byte for byte. The reader works on the lines:
//! each row that says something, with its indentation, its words and the id
//! at its end, its comment gone.
//!
//! A comment is `//` at the start of a row's words or after a space; in a row
//! of brackets, not inside a quoted value. An id is `^` and letters, digits,
//! `_` and `-`, the last of a row's words, after a space.

const std = @import("std");
const source = @import("source.zig");
const ast = @import("ast.zig");
const aegis = @import("aegis");

pub const max_bytes = 16 * 1024 * 1024;
pub const max_line = 64 * 1024;

pub const Line = struct {
    indent: u32,
    /// What the line says, without its indentation, id or comment, and where it starts.
    text: source.Placed,
    /// `^` and the id at its end, and where it starts; empty without one.
    id: source.Placed,

    /// From the line's words to the end of its id.
    pub fn span(l: Line, file: source.FileId) source.Span {
        const end = if (l.id.text.len > 0) l.id.span(file).end else l.text.span(file).end;
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
/// by tabs is reported and kept as a row, and not read; a control character in a row is reported where it is, and
/// the row kept as it is written.
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
        try controls(gpa, diags, file, content);
        if (content.text.len > max_line) {
            try diags.add(gpa, content.span(file), .err, "the line is longer than {d} bytes", .{max_line});
            continue;
        }
        const body = content.from(row.indent);
        if (body.text.len > 0 and body.text[0] == '\t') {
            try diags.add(gpa, body.to(1).span(file), .err, "indentation is spaces, not tabs", .{});
            continue;
        }
        if (row.text.len == 0 and row.id.len == 0) continue;
        const id_at = row.text.len + row.before_id;
        try lines.append(arena, .{ .indent = row.indent, .text = body.to(row.text.len), .id = body.cut(id_at, id_at + row.id.len) });
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

// Each control character in a row's content, reported over its bytes: C0 but a tab, DEL, and C1 (U+0080 to U+009F,
// two bytes in UTF-8). A carriage return before the line feed is the row's ending, not its content.
fn controls(gpa: std.mem.Allocator, diags: *source.Diagnostics, file: source.FileId, content: source.Placed) error{OutOfMemory}!void {
    const t = content.text;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        const n: usize = if ((c < 0x20 and c != '\t') or c == 0x7f) 1 else if (c == 0xc2 and i + 1 < t.len and t[i + 1] >= 0x80 and t[i + 1] <= 0x9f) 2 else 0;
        if (n == 0) continue;
        const code: u21 = if (n == 1) c else t[i + 1];
        try diags.add(gpa, content.cut(i, i + n).span(file), .err, "a control character, U+{X:0>4}, cannot stand in a story", .{code});
        i += n - 1;
    }
}

// A row's layout, from its content (the row without its line ending).
fn rowOf(content: source.Placed, ending: ast.Row.Ending) ast.Row {
    const raw = content.text;
    var indent: usize = 0;
    while (indent < raw.len and raw[indent] == ' ') indent += 1;
    const body = raw[indent..];
    const comment = commentAt(body);
    const words = std.mem.trimEnd(u8, body[0 .. comment orelse body.len], " ");
    const id = idAt(words);
    const text = if (id) |k| std.mem.trimEnd(u8, words[0..k], " ") else words;
    var row: ast.Row = .{ .start = content.at, .indent = @intCast(indent), .text = text, .ending = ending }; // safe: a row is a part of its file
    if (id) |k| {
        row.before_id = @intCast(k - text.len); // safe: as the row's
        row.id = words[k..];
    }
    var end = words.len;
    if (comment) |at| {
        row.before_comment = @intCast(at - end); // safe: as the row's
        row.comment = std.mem.trimEnd(u8, body[at..], " ");
        end = at + row.comment.len;
    }
    row.trailing = @intCast(body.len - end); // safe: as the row's
    return row;
}

// Where a row's comment starts, at `//` at the start of its words or after a space; in a row of brackets, outside
// quotes.
fn commentAt(s: []const u8) ?usize {
    const brackets = s.len > 0 and s[0] == '[';
    var quoted = false;
    for (s, 0..) |c, i| {
        if (brackets and c == '"') quoted = !quoted;
        if (quoted) continue;
        if (c == '/' and i + 1 < s.len and s[i + 1] == '/' and (i == 0 or s[i - 1] == ' ')) return i;
    }
    return null;
}

// Where the id at the end of a row's words starts: `^` and one or more of letters, digits, `_` and `-`, at the
// start of the words or after a space.
fn idAt(words: []const u8) ?usize {
    const at = if (std.mem.findScalarLast(u8, words, ' ')) |sp| sp + 1 else 0;
    const token = words[at..];
    if (token.len < 2 or token[0] != '^') return null;
    for (token[1..]) |c| if (!isIdChar(c)) return null;
    return at;
}

/// A letter, a digit, `_` or `-`: what a line's id is made of.
pub fn isIdChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

test "a line loses its comment and keeps its id apart; its row keeps both" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    const text = "// a comment\n" ++
        "== hide_1969\n" ++
        "MUM: You could still play, Frank.   ^k7f3a2  \r\n" ++
        "\n" ++
        "  [carried += play]   // the memory\n" ++
        "  [line \"the city // whoever she'd be\"] // why";
    const s = try split(arena.allocator(), gpa, &diags, 0, text);
    try std.testing.expectEqual(@as(usize, 6), s.rows.len);
    try std.testing.expectEqual(@as(usize, 4), s.lines.len);
    try std.testing.expectEqualStrings("== hide_1969", s.lines[0].text.text);
    try std.testing.expectEqualStrings("MUM: You could still play, Frank.", s.lines[1].text.text);
    try std.testing.expectEqualStrings("^k7f3a2", s.lines[1].id.text);
    try std.testing.expectEqual(@as(u32, 13 + 13 + 36), s.lines[1].id.at);
    try std.testing.expectEqual(@as(u32, 2), s.lines[2].indent);
    try std.testing.expectEqualStrings("[carried += play]", s.lines[2].text.text);
    try std.testing.expectEqualStrings("[line \"the city // whoever she'd be\"]", s.lines[3].text.text);
    // the rows keep the comments, the blank row, the spaces and the line endings
    try std.testing.expectEqualStrings("// a comment", s.rows[0].comment);
    try std.testing.expectEqual(@as(u32, 2), s.rows[2].trailing);
    try std.testing.expectEqual(ast.Row.Ending.crlf, s.rows[2].ending);
    try std.testing.expectEqual(@as(u32, 0), s.rows[3].len() - 1);
    try std.testing.expectEqual(@as(u32, 3), s.rows[4].before_comment);
    try std.testing.expectEqualStrings("// why", s.rows[5].comment);
    try std.testing.expectEqual(ast.Row.Ending.none, s.rows[5].ending);
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
}

test "words that only look like an id are words" {
    for ([_][]const u8{ "Smile ^_^", "x\\^k1", "^", "a ^ b" }) |words| try std.testing.expectEqual(@as(?usize, null), idAt(words));
    try std.testing.expectEqual(@as(?usize, 0), idAt("^k1"));
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

test "a control character is reported over its bytes, and its row kept" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    const text = "DAD: Go.\rNow.\nMUM:\x00 x\tthen \u{85}.\r\n";
    const s = try split(arena.allocator(), gpa, &diags, 0, text);
    try std.testing.expectEqual(@as(usize, 2), s.rows.len);
    try std.testing.expectEqual(@as(usize, 3), diags.errors());
    try std.testing.expectEqual(source.Span{ .file = 0, .start = 8, .end = 9 }, diags.list.items[0].span);
    try std.testing.expectEqualStrings("a control character, U+000D, cannot stand in a story", diags.list.items[0].message);
    try std.testing.expectEqual(source.Span{ .file = 0, .start = 18, .end = 19 }, diags.list.items[1].span);
    try std.testing.expectEqualStrings("a control character, U+0085, cannot stand in a story", diags.list.items[2].message);
    try std.testing.expectEqualStrings("DAD: Go.\rNow.", s.rows[0].text);
}
