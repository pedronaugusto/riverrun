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
//! - A ```zig block shows rows of a Zig file that builds, one after another,
//!   indented as written there or all less by the same number of spaces.
//! - A ```text block shows rows of a text the package keeps (its design's
//!   grammar), or of what a run printed.
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
    /// Rows of a Zig file that builds.
    zig,
    /// Rows of a text kept, or of what a run printed.
    text,
    /// A block in any other language, or none: held by nothing.
    other,
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
            if (!std.mem.startsWith(u8, fence, "```")) continue;
            inside = fenced(fence["```".len..]);
            start = n + 1;
        }
    }
    if (inside != null and zig) try out.append(arena, .{ .line = start, .rows = try rows.toOwnedSlice(arena) });
    return out.items;
}

// What a block opened by ``` and `info` shows.
fn fenced(info: []const u8) Kind {
    const kinds = [_]struct { []const u8, Kind }{ .{ "river", .story }, .{ "river refused", .refused }, .{ "console", .run }, .{ "zig", .zig }, .{ "text", .text } };
    for (kinds) |k| if (std.mem.eql(u8, info, k[0])) return k[1];
    return .other;
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

/// Whether `rows` are rows of `text`, one after another, as written there or each indented there by the same number of
/// spaces more (a row with no words, by none): what a block shows of the inside of a function.
pub fn withinIndented(arena: std.mem.Allocator, rows: []const []const u8, text: []const u8) error{OutOfMemory}!bool {
    if (within(rows, text)) return true;
    const spaces = " " ** 40;
    const shifted = try arena.alloc([]const u8, rows.len);
    var indent: usize = 1;
    while (indent <= spaces.len) : (indent += 1) {
        for (rows, shifted) |r, *s| s.* = if (r.len == 0) r else try std.mem.concat(arena, u8, &.{ spaces[0..indent], r });
        if (within(shifted, text)) return true;
    }
    return false;
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
    /// rows of. Each must be shown by a document. A ```text block may show rows of what one printed.
    runs: []const Run = &.{},
    /// Zig files that build: what a ```zig block shows rows of.
    sources: []const Named = &.{},
    /// Texts kept beside the stories (a design's grammar): what a ```text block shows rows of.
    texts: []const Named = &.{},
    /// Whether every fenced block must be one these hold, so a document shows nothing unchecked; otherwise a block in
    /// another language, or none, is left alone.
    every: bool = false,
};

/// Every block of `documents` that is not what `shown` holds, every document that shows no block they hold (it was
/// listed as one that does), and every run no document shows.
pub fn unshown(arena: std.mem.Allocator, documents: []const Named, shown: Shown) error{OutOfMemory}![]const Unshown {
    var out: std.ArrayList(Unshown) = .empty;
    const seen = try arena.alloc(bool, shown.runs.len);
    @memset(seen, false);
    for (documents) |d| {
        const found = try blocks(arena, d);
        var held: usize = 0;
        for (found) |b| switch (b.kind) {
            .story => {
                held += 1;
                for (shown.stories) |s| {
                    if (within(b.rows, s.text)) break;
                } else try out.append(arena, .{ .path = d.path, .line = b.line, .why = "this story block is not rows of any checked story" });
            },
            .refused => {
                held += 1;
                if (!refusedHolds(b.rows, shown.runs)) try out.append(arena, .{ .path = d.path, .line = b.line, .why = "this refused block is not rows of a story a shown `riverrun check` refuses" });
            },
            .run => {
                held += 1;
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
            .zig => {
                held += 1;
                for (shown.sources) |f| {
                    if (try withinIndented(arena, b.rows, f.text)) break;
                } else try out.append(arena, .{ .path = d.path, .line = b.line, .why = "this zig block is not rows of any Zig file that builds" });
            },
            .text => {
                held += 1;
                const kept = for (shown.texts) |t| {
                    if (within(b.rows, t.text)) break true;
                } else for (shown.runs) |r| {
                    if (within(b.rows, r.output)) break true;
                } else false;
                if (!kept) try out.append(arena, .{ .path = d.path, .line = b.line, .why = "this text block is not rows of a text kept or of what a shown run printed" });
            },
            .other => if (shown.every) try out.append(arena, .{ .path = d.path, .line = b.line, .why = "this block is held by nothing: show a story, a run, a Zig file or a text kept, in a block of its kind" }),
        };
        if (held == 0) try out.append(arena, .{ .path = d.path, .line = 1, .why = "shows no block the test holds" });
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
    try std.testing.expectEqual(@as(usize, 2), in_md.len);
    try std.testing.expectEqual(@as(u32, 4), in_md[0].line);
    try std.testing.expectEqual(Kind.zig, in_md[1].kind);
    const in_zig = try blocks(a, zig);
    try std.testing.expectEqual(@as(usize, 1), in_zig.len);
    try std.testing.expectEqualStrings("  [stage]", in_zig[0].rows[1]);
    try std.testing.expect(within(in_md[0].rows, "// a story\n== a\nGo.\n-> end\n"));
    try std.testing.expect(!within(in_md[0].rows, "== a\nStay.\nGo.\n"));
    const source: Named = .{ .path = "x.zig", .text = "const x = 1;\n" };
    try std.testing.expectEqual(@as(usize, 0), (try unshown(a, &.{ md, zig }, .{ .stories = &.{ .{ .path = "a.river", .text = "== a\nGo.\n" }, .{ .path = "q.river", .text = "== a\n  [stage]\n" } }, .sources = &.{source} })).len);
    const missed = try unshown(a, &.{md}, .{ .stories = &.{.{ .path = "b.river", .text = "== b\n" }} });
    try std.testing.expectEqual(@as(usize, 2), missed.len);
    try std.testing.expectEqual(@as(u32, 4), missed[0].line);
    try std.testing.expectEqualStrings("this zig block is not rows of any Zig file that builds", missed[1].why);
}

test "a zig block is rows of a file that builds, a text block rows of a text kept or a run's output, and a manual holds every block" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const build: Named = .{ .path = "build.zig", .text = "pub fn build(b: *std.Build) void {\n    const exe = b.addExecutable(.{});\n\n    b.installArtifact(exe);\n}\n" };
    // rows from inside the function, shown at the margin, an empty row among them
    try std.testing.expect(try withinIndented(a, &.{ "const exe = b.addExecutable(.{});", "", "b.installArtifact(exe);" }, build.text));
    try std.testing.expect(try withinIndented(a, &.{"    b.installArtifact(exe);"}, build.text));
    // not one indentation for all, or not one after another
    try std.testing.expect(!try withinIndented(a, &.{ "pub fn build(b: *std.Build) void {", "const exe = b.addExecutable(.{});" }, build.text));
    try std.testing.expect(!try withinIndented(a, &.{ "const exe = b.addExecutable(.{});", "b.installArtifact(exe);" }, build.text));
    const grammar: Named = .{ .path = "design.md", .text = "## Grammar\n\n```text\nfile = { row }\nrow  = words NL\n```\n" };
    const runs = [_]Run{.{ .command = "riverrun check a.river", .output = "a.river:2:1-2:5: error: one\na.river:3:1-3:5: error: two\n" }};
    const doc: Named = .{ .path = "14.md", .text = "```zig\nconst exe = b.addExecutable(.{});\n```\n\n```text\nrow  = words NL\n```\n\n" ++
        "```console\n$ riverrun check a.river\na.river:2:1-2:5: error: one\na.river:3:1-3:5: error: two\n```\n\n```text\na.river:3:1-3:5: error: two\n```\n\n```\nfree\n```\n" };
    const found = try blocks(a, doc);
    try std.testing.expectEqual(@as(usize, 5), found.len);
    try std.testing.expectEqual(Kind.other, found[4].kind);
    const shown: Shown = .{ .stories = &.{}, .runs = &runs, .sources = &.{build}, .texts = &.{grammar} };
    try std.testing.expectEqual(@as(usize, 0), (try unshown(a, &.{doc}, shown)).len);
    var every = shown;
    every.every = true;
    const strict = try unshown(a, &.{doc}, every);
    try std.testing.expectEqual(@as(usize, 1), strict.len);
    try std.testing.expectEqual(@as(u32, 20), strict[0].line);
    // a text not kept, a zig row changed
    const drifted: Named = .{ .path = "15.md", .text = "```text\nrow = words NL\n```\n\n```zig\nconst exe = b.addExecutable(.{ .name = \"x\" });\n```\n" };
    const missed = try unshown(a, &.{drifted}, shown);
    try std.testing.expectEqual(@as(usize, 3), missed.len);
    try std.testing.expectEqualStrings("this text block is not rows of a text kept or of what a shown run printed", missed[0].why);
    try std.testing.expectEqualStrings("this zig block is not rows of any Zig file that builds", missed[1].why);
    try std.testing.expectEqualStrings("no document shows this run", missed[2].why);
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
    // a run shown in part, a command not run, a refused block of a story that checks: and so neither run is shown
    const wrong: Named = .{ .path = "2.md", .text = "```console\n$ riverrun play a.river\n== a\nGo.\n```\n\n```console\n$ riverrun play b.river\n```\n\n" ++
        "```river refused\n== a\nGo.\n-> end\n```\n" };
    const missed = try unshown(a, &.{wrong}, .{ .stories = &.{story}, .runs = &runs });
    try std.testing.expectEqual(@as(usize, 5), missed.len);
    try std.testing.expectEqualStrings("the rows under this command are not all it printed, as pinned", missed[0].why);
    try std.testing.expectEqualStrings("this command is not one the test step runs and pins", missed[1].why);
    try std.testing.expectEqualStrings("this refused block is not rows of a story a shown `riverrun check` refuses", missed[2].why);
    try std.testing.expectEqualStrings("riverrun play a.river", missed[3].path);
    try std.testing.expectEqualStrings("riverrun check a.river", missed[4].path);
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
