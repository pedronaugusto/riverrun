//! The stories a package's documents show, held to the stories its tests
//! check: every block a document shows is rows of a checked story, one
//! after another as written, so a writer copying an example copies text
//! that checks. A Markdown document shows a story in a ```river block; a
//! Zig file shows one in its `//!` comment, indented four spaces past it.

const std = @import("std");

/// A file by its path, and its text.
pub const Named = struct { path: []const u8, text: []const u8 };

/// A story block of a document: the line it starts on, and its rows.
pub const Block = struct { line: u32, rows: []const []const u8 };

/// The story blocks of `doc`, by its path's extension.
pub fn blocks(arena: std.mem.Allocator, doc: Named) error{OutOfMemory}![]const Block {
    const zig = std.mem.endsWith(u8, doc.path, ".zig");
    var out: std.ArrayList(Block) = .empty;
    var rows: std.ArrayList([]const u8) = .empty;
    var start: u32 = 0;
    var inside = false;
    var it = std.mem.splitScalar(u8, doc.text, '\n');
    var n: u32 = 0;
    while (it.next()) |raw| {
        n += 1;
        const row = std.mem.trimEnd(u8, raw, "\r");
        if (zig) {
            const prefix = "//!     ";
            if (std.mem.startsWith(u8, row, prefix)) {
                if (!inside) start = n;
                inside = true;
                try rows.append(arena, row[prefix.len..]);
                continue;
            }
            if (inside) try out.append(arena, .{ .line = start, .rows = try rows.toOwnedSlice(arena) });
            inside = false;
        } else if (!inside) {
            if (std.mem.eql(u8, std.mem.trim(u8, row, " "), "```river")) {
                inside = true;
                start = n + 1;
            }
        } else if (std.mem.eql(u8, std.mem.trim(u8, row, " "), "```")) {
            try out.append(arena, .{ .line = start, .rows = try rows.toOwnedSlice(arena) });
            inside = false;
        } else try rows.append(arena, row);
    }
    if (inside and zig) try out.append(arena, .{ .line = start, .rows = try rows.toOwnedSlice(arena) });
    return out.items;
}

/// Whether `rows` are rows of `story`, one after another.
pub fn within(rows: []const []const u8, story: []const u8) bool {
    if (rows.len == 0) return true;
    var from = std.mem.splitScalar(u8, story, '\n');
    while (true) {
        // the story's rows from here, against the block's
        var here = from;
        for (rows) |want| {
            const have = here.next() orelse return false;
            if (!std.mem.eql(u8, want, std.mem.trimEnd(u8, have, "\r"))) break;
        } else return true;
        _ = from.next() orelse return false;
    }
}

/// A block a document shows that no checked story holds, or a document that shows none.
pub const Unshown = struct { path: []const u8, line: u32, why: []const u8 };

/// Every block of `documents` that is not rows of one of `stories`, and every document that shows no story at all,
/// since it was listed as one that does.
pub fn unshown(arena: std.mem.Allocator, documents: []const Named, stories: []const Named) error{OutOfMemory}![]const Unshown {
    var out: std.ArrayList(Unshown) = .empty;
    for (documents) |d| {
        const found = try blocks(arena, d);
        if (found.len == 0) try out.append(arena, .{ .path = d.path, .line = 1, .why = "shows no story block" });
        for (found) |b| {
            for (stories) |s| {
                if (within(b.rows, s.text)) break;
            } else try out.append(arena, .{ .path = d.path, .line = b.line, .why = "this story block is not rows of any checked story" });
        }
    }
    return out.items;
}

test "a document's story blocks are found and held to the stories" {
    const md: Named = .{ .path = "design.md", .text = "Words.\n\n```river\n== a\nGo.\n```\n\n```zig\nconst x = 1;\n```\n" };
    const zig: Named = .{ .path = "written.zig", .text = "//! A quest:\n//!\n//!     == a\n//!       [stage]\n//!\n//! More.\n" };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in_md = try blocks(a, md);
    try std.testing.expectEqual(@as(usize, 1), in_md.len);
    try std.testing.expectEqual(@as(u32, 4), in_md[0].line);
    const in_zig = try blocks(a, zig);
    try std.testing.expectEqual(@as(usize, 1), in_zig.len);
    try std.testing.expectEqualStrings("  [stage]", in_zig[0].rows[1]);
    try std.testing.expect(within(in_md[0].rows, "// a story\n== a\nGo.\n-> end\n"));
    try std.testing.expect(!within(in_md[0].rows, "== a\nStay.\nGo.\n"));
    try std.testing.expectEqual(@as(usize, 0), (try unshown(a, &.{ md, zig }, &.{ .{ .path = "a.river", .text = "== a\nGo.\n" }, .{ .path = "q.river", .text = "== a\n  [stage]\n" } })).len);
    const missed = try unshown(a, &.{md}, &.{.{ .path = "b.river", .text = "== b\n" }});
    try std.testing.expectEqual(@as(u32, 4), missed[0].line);
}
