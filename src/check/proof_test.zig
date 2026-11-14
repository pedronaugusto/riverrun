//! The proof, checked: the WAKE prototype's whole story against a schema
//! shaped like a game's, which is what a host gives the checker. riverrun
//! knows none of these words; the test is where they live.

const std = @import("std");
const syntax = @import("../syntax.zig");
const check = @import("../check.zig");

const Schema = check.Schema;

const files = .{ "cast", "1969", "1985", "1998", "years", "wake", "back", "rest" };

const mark_section: Schema.Places = .{ .section = true };
const on_line: Schema.Places = .{ .line = true };
const on_choice: Schema.Places = .{ .choice = true };
const on_both: Schema.Places = .{ .line = true, .choice = true };

/// A game's tags, as WAKE uses them: its mechanics' marks on sections, the
/// listen mechanic's times and places on lines, the day's slots on choices.
pub const wake_schema: Schema = .{ .keys = &.{
    .{ .name = "voice", .on = .{ .cast = true, .choice = true } },
    .{ .name = "card", .on = mark_section },
    .{ .name = "listen", .on = mark_section },
    .{ .name = "talk", .on = mark_section },
    .{ .name = "fork", .on = mark_section },
    .{ .name = "seam", .on = mark_section },
    .{ .name = "day", .on = mark_section },
    .{ .name = "tree", .on = mark_section },
    .{ .name = "sides", .on = mark_section },
    .{ .name = "years", .on = mark_section },
    .{ .name = "rests", .on = mark_section },
    .{ .name = "count", .on = mark_section, .value = .number },
    .{ .name = "beat", .on = mark_section, .value = .number },
    .{ .name = "dim", .on = mark_section, .value = .number },
    .{ .name = "hours", .on = mark_section, .value = .number, .count = .many },
    .{ .name = "slots", .on = mark_section, .value = .{ .values_of = "slot" }, .count = .many },
    .{ .name = "rooms", .on = mark_section, .value = .{ .values_of = "room" }, .count = .any },
    .{ .name = "forks", .on = mark_section, .value = .text, .count = .many },
    .{ .name = "then", .on = mark_section, .value = .section, .leads = true },
    .{ .name = "pool", .on = mark_section, .value = .section },
    .{ .name = "picture", .on = .{ .section = true, .choice = true }, .value = .word, .count = .many },
    .{ .name = "at", .on = on_line, .value = .number },
    .{ .name = "at", .on = on_choice, .value = .{ .values_of = "slot" }, .count = .many },
    .{ .name = "heard", .on = on_line, .value = .{ .values_of = "spot" }, .count = .many },
    .{ .name = "known", .on = on_both, .value = .{ .values_of = "carried" } },
    .{ .name = "who", .on = on_both, .value = .text },
    .{ .name = "marked", .on = on_both },
    .{ .name = "pause", .on = on_line, .value = .number },
    .{ .name = "year", .on = on_line, .value = .number },
    .{ .name = "bold", .on = on_line },
    .{ .name = "prompt", .on = on_line },
    .{ .name = "hint", .on = on_line },
    .{ .name = "warn", .on = on_line },
    .{ .name = "idle", .on = on_line },
    .{ .name = "quoted", .on = on_line },
    .{ .name = "side", .on = on_choice, .value = .{ .values_of = "life" } },
    .{ .name = "line", .on = on_choice, .value = .text },
    .{ .name = "cost", .on = on_choice, .value = .number },
    .{ .name = "while", .on = on_choice, .value = .text },
    .{ .name = "told", .on = on_choice, .value = .text },
    .{ .name = "choose", .on = on_choice },
} };

/// What WAKE checks the proof with.
pub const wake_options: check.Options = .{
    .entries = &.{"cold_open"},
    .schema = &wake_schema,
    .width = .{ .choice = 40 },
};

const Proof = struct {
    arena: std.heap.ArenaAllocator,
    diags: syntax.Diagnostics,
    trees: [files.len]syntax.ast.File,

    fn read(p: *Proof) !void {
        inline for (files, 0..) |name, i| {
            p.trees[i] = try syntax.parse(p.arena.allocator(), std.testing.allocator, &p.diags, i, name ++ ".river", @embedFile("../syntax/testdata/proof/" ++ name ++ ".river"));
        }
        try std.testing.expectEqual(@as(usize, 0), p.diags.list.items.len);
    }

    fn deinit(p: *Proof) void {
        p.diags.deinit(std.testing.allocator);
        p.arena.deinit();
    }

    fn print(p: *const Proof) void {
        for (p.diags.list.items) |d| {
            const tree = &p.trees[d.span.file];
            const at = tree.place(d.span);
            std.debug.print("{s}:{d}:{d}: {t}: {s}\n", .{ tree.path, at.line, at.col, d.severity, d.message });
        }
    }
};

fn proof() !*Proof {
    const p = try std.testing.allocator.create(Proof);
    p.* = .{ .arena = .init(std.testing.allocator), .diags = .{}, .trees = undefined };
    try p.read();
    return p;
}

fn done(p: *Proof) void {
    p.deinit();
    std.testing.allocator.destroy(p);
}

// The lines and choices of the trees, counted from the trees themselves.
fn said(trees: []const syntax.ast.File) usize {
    var n: usize = 0;
    for (trees) |t| for (t.sections) |s| {
        n += count(s.body);
        for (s.subsections) |sub| n += count(sub.body);
    };
    return n;
}

fn count(body: []const syntax.ast.Stmt) usize {
    var n: usize = 0;
    for (body) |s| n += switch (s.kind) {
        .line => 1,
        .choice => |ch| 1 + count(ch.body),
        .cond => |k| count(k.body),
        .gather => |g| if (g.then) |then| count(then[0..1]) else 0,
        else => 0,
    };
    return n;
}

test "the proof checks clean against WAKE's schema" {
    const p = try proof();
    defer done(p);
    var checked = try check.run(std.testing.allocator, &p.diags, &p.trees, wake_options);
    defer checked.deinit();
    if (p.diags.list.items.len > 0) p.print();
    try std.testing.expectEqual(@as(usize, 0), p.diags.list.items.len);
    // every line and choice has an id, derived in development
    try std.testing.expectEqual(said(&p.trees), checked.lines.count());
    try std.testing.expectEqual(@as(usize, 248), checked.lines.count());
    try std.testing.expectEqual(@as(usize, 1), checked.entries.len);
    const kitchen = checked.section("kitchen_1985").?;
    try std.testing.expectEqualStrings("kitchen_1985", checked.sections[kitchen.raw()].name);
    try std.testing.expect(checked.speaker("A CELLIST") != null);
    try std.testing.expect(checked.facts[checked.fact("spot").?.raw()].game);
}

test "without the host's schema, the mechanics' scenes run off their ends" {
    const p = try proof();
    defer done(p);
    var checked = try check.run(std.testing.allocator, &p.diags, &p.trees, .{});
    defer checked.deinit();
    // listening, the day and the rooms end by a tag that leads, which only a schema can say
    var ends: [3][]const u8 = undefined;
    var n: usize = 0;
    for (p.diags.list.items) |d| {
        try std.testing.expectEqual(syntax.source.Severity.err, d.severity);
        try std.testing.expect(std.mem.endsWith(u8, d.message, "can run off its end: end it with `-> end`, `<-` or a flow elsewhere"));
        ends[n] = d.message;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(std.mem.startsWith(u8, ends[0], "the scene `hide_1969`"));
    try std.testing.expect(std.mem.startsWith(u8, ends[1], "the scene `day_1998`"));
    try std.testing.expect(std.mem.startsWith(u8, ends[2], "the scene `wake`"));
}

test "a release refuses the proof, which has no written ids yet" {
    const p = try proof();
    defer done(p);
    var options = wake_options;
    options.mode = .release;
    var checked = try check.run(std.testing.allocator, &p.diags, &p.trees, options);
    defer checked.deinit();
    try std.testing.expectEqual(said(&p.trees), p.diags.errors());
    for (p.diags.list.items) |d| try std.testing.expectEqualStrings("a release needs every line's `# id`: `riverrun tag` writes them", d.message);
}
