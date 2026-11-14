//! Where things are in a story's files, and what is wrong there.
//!
//! Every node of the tree and every diagnostic carries a range of bytes in
//! its file, from where it starts to where it ends; a line and a column are
//! worked out from the range when one is printed. The reader collects every
//! diagnostic rather than stopping at the first, so a writer sees every
//! problem in a file at once.

const std = @import("std");

/// A file of the story, by its place in the list the reader was given.
pub const FileId = u16;

/// A range of a file's bytes: `start` is the first, `end` one past the last.
pub const Span = struct {
    file: FileId,
    start: u32,
    end: u32,

    /// No place in the text: what a host's vocabulary asks, which no file says. Placed at line 0, column 0.
    pub const none: Span = .{ .file = 0, .start = std.math.maxInt(u32), .end = std.math.maxInt(u32) };

    /// From the start of `a` to the end of `b`, both in one file.
    pub fn join(a: Span, b: Span) Span {
        return .{ .file = a.file, .start = @min(a.start, b.start), .end = @max(a.end, b.end) };
    }

    /// Whether `inner` lies inside `s`.
    pub fn holds(s: Span, inner: Span) bool {
        return s.file == inner.file and s.start <= inner.start and inner.end <= s.end;
    }
};

/// A line and a column, counted from one as editors show them; a column counts bytes from its row's start. A file's
/// tree works one out for a span (`ast.File.place`); `Span.none` is at line 0, column 0.
pub const Place = struct { line: u32, col: u32 };

/// The UTF-8 byte-order mark a file may begin with: the reader keeps it, before the file's first row.
pub const byte_order_mark = "\u{FEFF}";

/// Words of a file and where they start in it. The reader cuts and trims these, never bare slices, so every span it
/// makes is the exact range its words are written in.
pub const Placed = struct {
    text: []const u8,
    /// Where `text` starts in its file.
    at: u32,

    /// `text[a..b]`, placed.
    pub fn cut(p: Placed, a: usize, b: usize) Placed {
        return .{ .text = p.text[a..b], .at = p.at + @as(u32, @intCast(a)) }; // safe: a file is at most lines.max_bytes
    }

    /// `text[a..]`, placed.
    pub fn from(p: Placed, a: usize) Placed {
        return p.cut(a, p.text.len);
    }

    /// `text[0..b]`, placed.
    pub fn to(p: Placed, b: usize) Placed {
        return p.cut(0, b);
    }

    /// Without the spaces at either end.
    pub fn trim(p: Placed) Placed {
        var a: usize = 0;
        while (a < p.text.len and p.text[a] == ' ') a += 1;
        var b = p.text.len;
        while (b > a and p.text[b - 1] == ' ') b -= 1;
        return p.cut(a, b);
    }

    pub fn span(p: Placed, file: FileId) Span {
        return .{ .file = file, .start = p.at, .end = p.at + @as(u32, @intCast(p.text.len)) }; // safe: as `cut`
    }
};

pub const Severity = enum { err, warning };

pub const Diagnostic = struct {
    span: Span,
    severity: Severity,
    message: []const u8,
};

/// The most diagnostics kept for one story: past this, one more says so.
pub const max_diagnostics = 1024;

pub const Diagnostics = struct {
    list: std.ArrayList(Diagnostic) = .empty,
    dropped: usize = 0,

    pub fn deinit(d: *Diagnostics, gpa: std.mem.Allocator) void {
        for (d.list.items) |item| gpa.free(item.message);
        d.list.deinit(gpa);
        d.* = undefined;
    }

    pub fn add(d: *Diagnostics, gpa: std.mem.Allocator, span: Span, severity: Severity, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        if (d.list.items.len == max_diagnostics) {
            d.dropped += 1;
            return;
        }
        const message = try gpa.print(fmt, args);
        errdefer gpa.free(message);
        try d.list.append(gpa, .{ .span = span, .severity = severity, .message = message });
    }

    pub fn errors(d: *const Diagnostics) usize {
        var n: usize = 0;
        for (d.list.items) |item| n += @intFromBool(item.severity == .err);
        return n;
    }
};

test "diagnostics are collected, and counted by severity" {
    const gpa = std.testing.allocator;
    var d: Diagnostics = .{};
    defer d.deinit(gpa);
    try d.add(gpa, .{ .file = 0, .start = 3, .end = 6 }, .err, "unknown speaker {s}", .{"MUM"});
    try d.add(gpa, .{ .file = 0, .start = 9, .end = 12 }, .warning, "nothing sets {s}", .{"met"});
    try std.testing.expectEqual(@as(usize, 1), d.errors());
    try std.testing.expectEqualStrings("unknown speaker MUM", d.list.items[0].message);
}
