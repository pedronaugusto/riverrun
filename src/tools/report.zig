//! Diagnostics in the one form every command writes, one to a line, which a
//! person reads, an editor jumps to and an AI parses:
//!
//!     story/kitchen.river:12:5-12:19: error: `MUMM` is not a speaker: speakers come from `cast:` and `extras:`
//!
//! the file's path as it was given, the range from its first byte's line and
//! column to the line and column just past its last (both from 1, columns
//! counting bytes, so an empty range is a place to insert at), the severity
//! (`error` or `warning`), and the message. What is about a whole file, one
//! that cannot be read, has its path alone (`story/x.river: error: …`), and
//! what is about no file, the host's vocabulary, has the program's name
//! (`riverrun: error: …`).

const std = @import("std");
const river = @import("riverrun-compiler");

const syntax = river.syntax;
const ast = syntax.ast;

/// What a diagnostic about no place in the text is written under.
pub const program = "riverrun";

pub const Severity = syntax.source.Severity;

/// The word a severity is written as.
pub fn word(s: Severity) []const u8 {
    return switch (s) {
        .err => "error",
        .warning => "warning",
    };
}

/// Where a range is: its first byte's line and column, and the line and column just past its last.
pub const Range = struct { from: syntax.Place, to: syntax.Place };

/// The lines and columns of `span` in `file`.
pub fn range(file: *const ast.File, span: syntax.Span) Range {
    return .{ .from = file.place(span), .to = file.place(.{ .file = span.file, .start = span.end, .end = span.end }) };
}

/// One diagnostic, in the form above, with its line ending.
pub fn line(w: *std.Io.Writer, files: []const ast.File, d: syntax.source.Diagnostic) std.Io.Writer.Error!void {
    if (d.span.start == syntax.Span.none.start or d.span.file >= files.len) {
        return w.print("{s}: {s}: {s}\n", .{ program, word(d.severity), d.message });
    }
    const f = &files[d.span.file];
    const r = range(f, d.span);
    try w.print("{s}:{d}:{d}-{d}:{d}: {s}: {s}\n", .{ f.path, r.from.line, r.from.col, r.to.line, r.to.col, word(d.severity), d.message });
}

/// Every diagnostic in the order they were given, then, where more were found than are kept, a line that says
/// how many were left out.
pub fn all(w: *std.Io.Writer, files: []const ast.File, diags: *const syntax.Diagnostics) std.Io.Writer.Error!void {
    for (diags.list.items) |d| try line(w, files, d);
    if (diags.dropped > 0) try w.print("{s}: error: {d} more problems were found than are listed: fix these and check again\n", .{ program, diags.dropped });
}

/// A problem with a whole file, by its path alone: one that cannot be read.
pub fn whole(w: *std.Io.Writer, path: []const u8, severity: Severity, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
    try w.print("{s}: {s}: ", .{ path, word(severity) });
    try w.print(fmt, args);
    try w.writeByte('\n');
}

test "a diagnostic is its path, its range from line and column to line and column, its severity and its message" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: syntax.Diagnostics = .{};
    defer diags.deinit(gpa);
    const text = "== a\nMUMM: Go.\n";
    const tree = try syntax.parse(arena.allocator(), gpa, &diags, 0, "story/a.river", text);
    const files: []const ast.File = &.{tree};
    try diags.add(gpa, .{ .file = 0, .start = 5, .end = 9 }, .err, "`MUMM` is not a speaker", .{});
    try diags.add(gpa, .{ .file = 0, .start = 9, .end = 9 }, .warning, "here", .{});
    try diags.add(gpa, .none, .err, "the host starts the story at `x`, and the story has no such section", .{});
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try all(&out.writer, files, &diags);
    try std.testing.expectEqualStrings(
        \\story/a.river:2:1-2:5: error: `MUMM` is not a speaker
        \\story/a.river:2:5-2:5: warning: here
        \\riverrun: error: the host starts the story at `x`, and the story has no such section
        \\
    , out.written());
}
