//! The stories a package's documents show, held to the stories its tests
//! check, and the runs of the program they show, held to what the program
//! printed: so a writer copying an example copies text that checks, and
//! reads what the program says.
//!
//! - A Markdown document shows a story in a ```river block, and a Zig file
//!   in its `//!` comment, indented four spaces past it: rows of a story
//!   that checks, one after another as written.
//! - A ```river refused block shows rows of a story that `riverrun check`
//!   refuses, in a run the document shows.
//! - A ```console block shows a run: `$ riverrun …` and, on the rows under
//!   it, everything it printed, as pinned.
//! - A story shown before and after `riverrun tag` is held to what `tag`
//!   writes into it.

const std = @import("std");
const river = @import("riverrun-compiler");
const Manuscript = @import("Manuscript.zig");
const tag = @import("tag.zig");

/// A file by its path, and its text.
pub const Named = struct { path: []const u8, text: []const u8 };

/// A run of the program a document may show: the command as a writer types it, `riverrun …`, and what it printed.
pub const Run = struct {
    command: []const u8,
    output: []const u8,
    /// The stories `riverrun check` refuses in this run: what a ```river refused block may show.
    refused: []const Named = &.{},
};

/// A story as written, and as `riverrun tag` leaves it.
pub const Tagged = struct { before: Named, after: Named };

/// What a block of a document shows.
pub const Kind = enum {
    /// Rows of a story that checks.
    story,
    /// Rows of a story the checker refuses.
    refused,
    /// A run of the program and what it printed.
    run,
};

/// A block of a document: the line it starts on, what it shows, and its rows.
pub const Block = struct { line: u32, kind: Kind = .story, rows: []const []const u8 };

/// The blocks of `doc`, by its path's extension.
pub fn blocks(arena: std.mem.Allocator, doc: Named) error{OutOfMemory}![]const Block {
    const zig = std.mem.endsWith(u8, doc.path, ".zig");
    var out: std.ArrayList(Block) = .empty;
    var rows: std.ArrayList([]const u8) = .empty;
    var start: u32 = 0;
    var inside: ?Kind = null;
    var it = std.mem.splitScalar(u8, doc.text, '\n');
    var n: u32 = 0;
    while (it.next()) |raw| {
        n += 1;
        const row = std.mem.trimEnd(u8, raw, "\r");
        if (zig) {
            const prefix = "//!     ";
            if (std.mem.startsWith(u8, row, prefix)) {
                if (inside == null) start = n;
                inside = .story;
                try rows.append(arena, row[prefix.len..]);
                continue;
            }
            if (inside != null) try out.append(arena, .{ .line = start, .rows = try rows.toOwnedSlice(arena) });
            inside = null;
        } else if (inside) |kind| {
            if (std.mem.eql(u8, std.mem.trim(u8, row, " "), "```")) {
                try out.append(arena, .{ .line = start, .kind = kind, .rows = try rows.toOwnedSlice(arena) });
                inside = null;
            } else try rows.append(arena, row);
        } else {
            const fence = std.mem.trim(u8, row, " ");
            inside = if (std.mem.eql(u8, fence, "```river")) .story else if (std.mem.eql(u8, fence, "```river refused")) .refused else if (std.mem.eql(u8, fence, "```console")) .run else null;
            start = n + 1;
        }
    }
    if (inside != null and zig) try out.append(arena, .{ .line = start, .rows = try rows.toOwnedSlice(arena) });
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

/// Whether `rows` are all `output` printed, row for row: the last row's line ending is the output's end.
pub fn whole(rows: []const []const u8, output: []const u8) bool {
    const text = if (std.mem.endsWith(u8, output, "\n")) output[0 .. output.len - 1] else output;
    if (text.len == 0) return rows.len == 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    for (rows) |want| {
        const have = it.next() orelse return false;
        if (!std.mem.eql(u8, want, have)) return false;
    }
    return it.next() == null;
}

/// A block a document shows that nothing holds, a document that shows none, or a run no document shows.
pub const Unshown = struct { path: []const u8, line: u32, why: []const u8 };

/// What the documents show, held to what was checked and run.
pub const Shown = struct {
    /// Stories that check: what a ```river block shows rows of.
    stories: []const Named,
    /// Runs of the program: what a ```console block shows, and the refused stories a ```river refused block shows
    /// rows of. Each must be shown by a document.
    runs: []const Run = &.{},
};

/// Every block of `documents` that is not what `shown` holds, every document that shows no story at all (it was
/// listed as one that does), and every run no document shows.
pub fn unshown(arena: std.mem.Allocator, documents: []const Named, shown: Shown) error{OutOfMemory}![]const Unshown {
    var out: std.ArrayList(Unshown) = .empty;
    const seen = try arena.alloc(bool, shown.runs.len);
    @memset(seen, false);
    for (documents) |d| {
        const found = try blocks(arena, d);
        var stories: usize = 0;
        for (found) |b| switch (b.kind) {
            .story => {
                stories += 1;
                for (shown.stories) |s| {
                    if (within(b.rows, s.text)) break;
                } else try out.append(arena, .{ .path = d.path, .line = b.line, .why = "this story block is not rows of any checked story" });
            },
            .refused => {
                stories += 1;
                const held = refusedHolds(b.rows, shown.runs);
                if (!held) try out.append(arena, .{ .path = d.path, .line = b.line, .why = "this refused block is not rows of a story a shown `riverrun check` refuses" });
            },
            .run => {
                const first = if (b.rows.len > 0) b.rows[0] else "";
                const command = if (std.mem.startsWith(u8, first, "$ ")) first[2..] else {
                    try out.append(arena, .{ .path = d.path, .line = b.line, .why = "a console block begins with `$ riverrun …`, the command run" });
                    continue;
                };
                // one command may be run in several folders, each printing its own
                var named = false;
                const i = for (shown.runs, 0..) |r, i| {
                    if (!std.mem.eql(u8, r.command, command)) continue;
                    named = true;
                    if (whole(b.rows[1..], r.output)) break i;
                } else {
                    try out.append(arena, .{ .path = d.path, .line = b.line, .why = if (named) "the rows under this command are not all it printed, as pinned" else "this command is not one the test step runs and pins" });
                    continue;
                };
                seen[i] = true;
            },
        };
        if (stories == 0) try out.append(arena, .{ .path = d.path, .line = 1, .why = "shows no story block" });
    }
    for (shown.runs, seen) |r, s| if (!s) try out.append(arena, .{ .path = r.command, .line = 0, .why = "no document shows this run" });
    return out.items;
}

// Whether `rows` are rows of a story one of `runs` refuses.
fn refusedHolds(rows: []const []const u8, runs: []const Run) bool {
    for (runs) |r| for (r.refused) |s| if (within(rows, s.text)) return true;
    return false;
}

/// Whether `riverrun tag` makes `t.after` of `t.before`: every row as it was, and an id at the end of each line and
/// choice that had none. False also when the reader refuses `t.before`, since then `tag` writes nothing.
pub fn retagged(gpa: std.mem.Allocator, t: Tagged) error{ OutOfMemory, TooManyFiles }!bool {
    var m: Manuscript = try .read(gpa, &.{.{ .path = t.before.path, .text = t.before.text }});
    defer m.deinit();
    if (m.errors() > 0) return false;
    const given = try tag.give(m.arena.allocator(), m.files);
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    river.syntax.print(&text.writer, &given.files[0]) catch return error.OutOfMemory; // safe: an allocating writer fails only for memory
    return std.mem.eql(u8, text.written(), t.after.text);
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
    try std.testing.expectEqual(@as(usize, 0), (try unshown(a, &.{ md, zig }, .{ .stories = &.{ .{ .path = "a.river", .text = "== a\nGo.\n" }, .{ .path = "q.river", .text = "== a\n  [stage]\n" } } })).len);
    const missed = try unshown(a, &.{md}, .{ .stories = &.{.{ .path = "b.river", .text = "== b\n" }} });
    try std.testing.expectEqual(@as(u32, 4), missed[0].line);
}

test "a run a document shows is held whole to what it printed, and a refused block to the story it refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad: Named = .{ .path = "a.river", .text = "== a\nADDA: Go.\n-> end\n" };
    const runs = [_]Run{
        .{ .command = "riverrun play a.river", .output = "== a\nGo.\n-> end\n" },
        .{ .command = "riverrun check a.river", .output = "a.river:2:1-2:5: error: `ADDA` is not a speaker\n", .refused = &.{bad} },
    };
    const story: Named = .{ .path = "good.river", .text = "== a\nGo.\n-> end\n" };
    const doc: Named = .{ .path = "1.md", .text = "```river\n== a\nGo.\n```\n\n```console\n$ riverrun play a.river\n== a\nGo.\n-> end\n```\n\n" ++
        "```river refused\nADDA: Go.\n```\n\n```console\n$ riverrun check a.river\na.river:2:1-2:5: error: `ADDA` is not a speaker\n```\n" };
    const found = try blocks(a, doc);
    try std.testing.expectEqual(@as(usize, 4), found.len);
    try std.testing.expectEqual(Kind.refused, found[2].kind);
    try std.testing.expectEqual(Kind.run, found[3].kind);
    try std.testing.expectEqual(@as(usize, 0), (try unshown(a, &.{doc}, .{ .stories = &.{story}, .runs = &runs })).len);
    // a run shown in part, a command not run, a refused block of a story that checks, and a run nobody shows
    const wrong: Named = .{ .path = "2.md", .text = "```console\n$ riverrun play a.river\n== a\nGo.\n```\n\n```console\n$ riverrun play b.river\n```\n\n" ++
        "```river refused\n== a\nGo.\n-> end\n```\n" };
    const missed = try unshown(a, &.{wrong}, .{ .stories = &.{story}, .runs = &runs });
    try std.testing.expectEqual(@as(usize, 4), missed.len);
    try std.testing.expectEqualStrings("the rows under this command are not all it printed, as pinned", missed[0].why);
    try std.testing.expectEqualStrings("this command is not one the test step runs and pins", missed[1].why);
    try std.testing.expectEqualStrings("this refused block is not rows of a story a shown `riverrun check` refuses", missed[2].why);
    try std.testing.expectEqualStrings("riverrun check a.river", missed[3].path);
    try std.testing.expect(whole(&.{}, ""));
    try std.testing.expect(!whole(&.{""}, ""));
    // one command run in two folders, each printing its own: each block is held to the run whose output it shows
    const twice = [_]Run{
        .{ .command = "riverrun check a.river", .output = "a.river:2:1-2:5: error: one\n" },
        .{ .command = "riverrun check a.river", .output = "a.river:3:1-3:5: warning: two\n" },
    };
    const both: Named = .{ .path = "3.md", .text = "```river\n== a\n```\n\n```console\n$ riverrun check a.river\na.river:3:1-3:5: warning: two\n```\n\n" ++
        "```console\n$ riverrun check a.river\na.river:2:1-2:5: error: one\n```\n" };
    try std.testing.expectEqual(@as(usize, 0), (try unshown(a, &.{both}, .{ .stories = &.{story}, .runs = &twice })).len);
}

test "a story shown before and after `riverrun tag` is held to what tag writes" {
    const gpa = std.testing.allocator;
    const before: Named = .{ .path = "a.river", .text = "== a\nGo. // on\n-> end\n" };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // what tag writes, worked out once, and held to
    var m: Manuscript = try .read(gpa, &.{.{ .path = before.path, .text = before.text }});
    defer m.deinit();
    const given = try tag.give(arena.allocator(), m.files);
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try river.syntax.print(&text.writer, &given.files[0]);
    try std.testing.expect(std.mem.startsWith(u8, text.written(), "== a\nGo. ^"));
    try std.testing.expect(try retagged(gpa, .{ .before = before, .after = .{ .path = "b.river", .text = text.written() } }));
    try std.testing.expect(!try retagged(gpa, .{ .before = before, .after = before }));
    try std.testing.expect(!try retagged(gpa, .{ .before = .{ .path = "x.river", .text = "== a\n{ \n" }, .after = before }));
}
