//! A file as lines: each with its number, its indentation, what it says, and
//! the tags at its end, its comment gone. The reader works on these.
//!
//! A comment is `//` at the start of a line or after a space; tags are what
//! follows ` # `. Neither counts inside a quoted tag value.

const std = @import("std");
const source = @import("source.zig");
const aegis = @import("aegis");

pub const max_bytes = 16 * 1024 * 1024;
pub const max_line = 64 * 1024;

pub const Line = struct {
    number: u32,
    indent: u32,
    /// What the line says, without its indentation, comment or tags.
    text: []const u8,
    /// What follows ` # `, or empty.
    tags: []const u8,
    /// The column `text` starts at.
    col: u32,
    /// The column `tags` starts at.
    tags_col: u32 = 0,
};

pub fn split(arena: std.mem.Allocator, gpa: std.mem.Allocator, diags: *source.Diagnostics, file: source.FileId, bytes: []const u8) error{ OutOfMemory, Invalid }![]const Line {
    if (bytes.len > max_bytes) {
        try diags.add(gpa, .{ .file = file, .line = 1, .col = 1 }, .err, "the file is larger than {d} bytes", .{max_bytes});
        return error.Invalid;
    }
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        try diags.add(gpa, .{ .file = file, .line = 1, .col = 1 }, .err, "the file is not UTF-8", .{});
        return error.Invalid;
    }
    var out: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    var number: u32 = 0;
    while (it.next()) |raw_line| {
        number += 1;
        const raw = std.mem.trimEnd(u8, raw_line, "\r");
        if (raw.len > max_line) {
            try diags.add(gpa, .{ .file = file, .line = number, .col = 1 }, .err, "the line is longer than {d} bytes", .{max_line});
            continue;
        }
        var indent: u32 = 0;
        while (indent < raw.len and raw[indent] == ' ') indent += 1;
        if (indent < raw.len and raw[indent] == '\t') {
            try diags.add(gpa, .{ .file = file, .line = number, .col = indent + 1 }, .err, "indentation is spaces, not tabs", .{});
            continue;
        }
        const body = raw[indent..];
        const cut = strip(body);
        const text = std.mem.trimEnd(u8, body[0..cut.text_end], " ");
        if (text.len == 0 and cut.tags.len == 0) continue;
        aegis.assert.invariant(text.len <= body.len, "the text is a part of the line's body");
        try out.append(arena, .{ .number = number, .indent = indent, .text = text, .tags = cut.tags, .col = indent + 1, .tags_col = indent + 1 + @as(u32, @intCast(cut.tags_at)) });
    }
    return out.toOwnedSlice(arena);
}

const Cut = struct { text_end: usize, tags: []const u8, tags_at: usize = 0 };

// Where the line's words end, and its tags, outside quotes.
fn strip(s: []const u8) Cut {
    var quoted = false;
    var tag_start: ?usize = null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' and tag_start != null) quoted = !quoted;
        if (quoted) continue;
        if (c == '/' and i + 1 < s.len and s[i + 1] == '/' and (i == 0 or s[i - 1] == ' ')) {
            const end = tag_start orelse i;
            return if (tag_start) |t| tagsOf(s, t, i) else .{ .text_end = end, .tags = "" };
        }
        if (tag_start == null and c == '#' and (i == 0 or s[i - 1] == ' ') and (i + 1 == s.len or s[i + 1] == ' ')) tag_start = i;
    }
    if (tag_start) |t| return tagsOf(s, t, s.len);
    return .{ .text_end = s.len, .tags = "" };
}

// The tags between the `#` at `hash` and `end`, and where they start.
fn tagsOf(s: []const u8, hash: usize, end: usize) Cut {
    var a = hash + 1;
    while (a < end and s[a] == ' ') a += 1;
    return .{ .text_end = hash, .tags = std.mem.trimEnd(u8, s[a..end], " "), .tags_at = a };
}

test "a line loses its comment and keeps its tags apart" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    const text =
        \\// a comment
        \\== hide_1969          # listen · count 20
        \\MUM: You could still play, Frank.   # at 9.5 · heard piano, door
        \\  ~ carried += play   // the memory
        \\* Get on   # side go · line "the city · whoever she'd be"
    ;
    const lines = try split(arena.allocator(), gpa, &diags, 0, text);
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqualStrings("== hide_1969", lines[0].text);
    try std.testing.expectEqualStrings("listen · count 20", lines[0].tags);
    try std.testing.expectEqual(@as(u32, 25), lines[0].tags_col);
    try std.testing.expectEqualStrings("MUM: You could still play, Frank.", lines[1].text);
    try std.testing.expectEqual(@as(u32, 2), lines[2].indent);
    try std.testing.expectEqualStrings("~ carried += play", lines[2].text);
    try std.testing.expectEqualStrings("side go · line \"the city · whoever she'd be\"", lines[3].tags);
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
