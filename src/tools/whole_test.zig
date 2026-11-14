//! The whole compiler's promise over any text: whatever the files of a story
//! hold, the reader, the checker with a package's kinds and checks, and the
//! compiler give a compiled story or diagnostics saying why not, placed in
//! the files they are about; never a crash, a hang, a leak, an unreachable,
//! or an error with no place. A story that compiles is loaded and told a
//! bounded number of steps with every choice taken by the generator, and
//! the runtime gives lines, choices, an end or a named error (`trial`). The
//! package here is the test package `addStory`'s test registers, and the
//! proof's game is the other host; cairn and tide hold the same property
//! with their own.

const std = @import("std");
const shakedown = @import("shakedown");
const river = @import("riverrun-compiler");
const stall = @import("stall-compiler");
const Manuscript = @import("Manuscript.zig");
const trial = @import("trial.zig");

const gen = shakedown.gen;
const check = river.check;
const gpa = std.testing.allocator;

/// A host's vocabulary with the test package registered: a section's tag, a choice's tag with words, a line's tag
/// with a number, a delivery, and the host's things.
const Vocabulary = struct {
    const schema: check.Schema = .{ .keys = &.{
        .{ .name = "stall", .on = .{ .section = true } },
        .{ .name = "side", .on = .{ .choice = true }, .value = .{ .words = &.{ "go", "stay" } } },
        .{ .name = "at", .on = .{ .line = true }, .value = .number },
        .{ .name = "how", .on = .{ .line = true }, .value = .text },
        .{ .name = "next", .on = .{ .section = true }, .value = .section, .leads = true },
    } };
    pub const options: check.Options = .{
        .schema = &schema,
        .delivery = "how",
        .things = &.{.{ .kind = "item_kind", .ids = &.{ "pelt", "letter" } }},
    };
    pub const packages: []const river.Package = &.{stall.package};
};
pub const joined = river.join(Vocabulary);

/// The proof's host, WAKE, as `check/proof_test.zig` gives it (the tests of another module, so written again
/// here): its mechanics' marks on sections, the listen mechanic's times and places on lines, the day's slots on
/// choices.
const Wake = struct {
    const mark_section: check.Schema.Places = .{ .section = true };
    const on_line: check.Schema.Places = .{ .line = true };
    const on_choice: check.Schema.Places = .{ .choice = true };
    const on_both: check.Schema.Places = .{ .line = true, .choice = true };
    const schema: check.Schema = .{ .keys = &.{
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
    pub const options: check.Options = .{ .entries = &.{"cold_open"}, .schema = &schema, .width = .{ .choice = 40 } };
};
pub const wake = river.join(Wake);

/// What the property saw over all its cases, so it is known to reach the compiler and the runtime.
pub const Seen = struct { compiled: u32 = 0, told: u32 = 0, chosen: u32 = 0 };

/// `trial` of `pages` with `with`, every choice taken by `source`: fails, saying how, on a fault.
pub fn expectWhole(with: river.Joined, pages: []const Manuscript.Page, options: trial.Options, source: *shakedown.Source, seen: *Seen) !void {
    const Picker = struct {
        fn pick(ctx: ?*anyopaque, open: usize) usize {
            const s: *shakedown.Source = @ptrCast(@alignCast(ctx.?));
            return gen.intRange(s, usize, 0, open - 1);
        }
    };
    switch (try trial.trial(gpa, pages, with, options, .{ .ctx = source, .pick = Picker.pick })) {
        .refused => {},
        .told => |t| {
            seen.compiled += 1;
            seen.told += t.lines;
            seen.chosen += t.chosen;
        },
        .fault => |f| {
            var buffer: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buffer);
            trial.describe(f, &w) catch {};
            std.debug.print("{s}\n", .{w.buffered()});
            return error.TestUnexpectedResult;
        },
    }
}

/// A story that mostly checks: declarations, then sections of lines, choices, conditions, sums, effects, actions,
/// words chosen and interpolated, ids, deliveries, flows, a pool, rules and the package's stock.
fn written(s: *shakedown.Source, a: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a,
        \\cast:
        \\  mum   "Mum"
        \\  dad   "Dad"   — her father
        \\facts:
        \\  met: bool
        \\  n: int from -5 to 9
        \\  k: int
        \\  mood: one of calm, cross
        \\  got: set of pelt_bag, letter_bag
        \\  paid: bool
        \\  who: ref of item_kind   (game)
        \\  hour: int   (clock)
        \\const:
        \\  fee = 3
        \\extern:
        \\  price(ref of item_kind) -> int
        \\  rest(int)
        \\  pay(int) -> bool (action)
        \\
    );
    const sections = gen.intRange(s, usize, 1, 4);
    for (0..sections) |i| {
        try out.print(a, "== s{d}\n", .{i});
        if (gen.intRange(s, u8, 0, 3) == 0) try out.print(a, "  [stall] [sells {s}]\n", .{gen.oneOf(s, []const u8, &.{ "furs", "salt", "furs", "salt", "gold" })});
        for (0..gen.intRange(s, usize, 1, 7)) |_| try statement(s, a, &out, sections, 0);
        switch (gen.intRange(s, u8, 0, 3)) {
            0 => try out.appendSlice(a, "-> end\n"),
            1 => try out.print(a, "-> s{d}\n", .{@min(i + 1, sections - 1)}),
            2 => try out.appendSlice(a, "-> helper ->\n-> end\n"),
            else => try out.print(a, "{{ met: -> s{d} | -> end }}\n", .{gen.intRange(s, usize, 0, sections - 1)}),
        }
    }
    try out.appendSlice(a,
        \\== helper
        \\MUM: Back soon.
        \\<-
        \\
    );
    if (gen.boolean(s)) try out.appendSlice(a,
        \\== night (pool)
        \\= early   when { hour < 3 }
        \\  It was early.
        \\= late    when { hour + 1 >= 3 and met }
        \\  [weight 2]
        \\  It was late.
        \\
    );
    if (gen.boolean(s)) try out.appendSlice(a,
        \\== watch (rules)
        \\= woke   when { n - k > 2 }
        \\  [met = true]
        \\
    );
    if (gen.intRange(s, u8, 0, 7) > 0) try out.appendSlice(a,
        \\== wares (stock)
        \\= furs
        \\= salt
        \\
    );
    return out.items;
}

fn indent(a: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize) !void {
    try out.appendNTimes(a, ' ', 2 * depth);
}

// Rows written at `depth`, each indented to it; the first is indented already.
fn rows(a: std.mem.Allocator, out: *std.ArrayList(u8), depth: usize, text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    try out.appendSlice(a, it.first());
    while (it.next()) |row| {
        try out.append(a, '\n');
        try indent(a, out, depth);
        try out.appendSlice(a, row);
    }
}

// One statement at `depth`, with what goes under it.
fn statement(s: *shakedown.Source, a: std.mem.Allocator, out: *std.ArrayList(u8), sections: usize, depth: usize) !void {
    try indent(a, out, depth);
    switch (gen.intRange(s, u8, 0, 11)) {
        0 => try out.appendSlice(a, gen.oneOf(s, []const u8, &.{
            "MUM: Something said.",
            "DAD (quietly): Go.",
            "Narration, {n}.",
            "MUM: {n as one: once | other: {n} times}.",
            "{ met: She knew. | She didn't. }",
            "{seq: Again. | Once more. | Enough.}",
            "DAD: That's {n - fee} you owe, {price(who) + 1} in all.",
            "\\[sic\\] she said.",
        })),
        1 => {
            try out.appendSlice(a, gen.oneOf(s, []const u8, &.{ "* ", "+ ", "* { met } ", "* { n + k > fee } " }));
            try out.appendSlice(a, gen.oneOf(s, []const u8, &.{ "Choose.", "Run.", "Stay a while." }));
            if (gen.boolean(s)) try out.print(a, " ^c{d}", .{gen.intRange(s, u8, 0, 40)});
            try out.append(a, '\n');
            if (gen.boolean(s)) {
                try indent(a, out, depth + 1);
                try out.appendSlice(a, gen.oneOf(s, []const u8, &.{ "[side go]", "[side stay] [met = true]", "[side go]", "[side stay]", "[side go] [k = 2]", "[side away]" }));
                try out.append(a, '\n');
            }
            if (depth < 2 and gen.boolean(s)) try statement(s, a, out, sections, depth + 1);
            try indent(a, out, depth + 1);
            try out.print(a, "-> s{d}", .{gen.intRange(s, usize, 0, sections - 1)});
        },
        2 => {
            try out.appendSlice(a, gen.oneOf(s, []const u8, &.{ "{ met }", "{ n + 2 > k }", "{ mood = calm or got has pelt_bag }", "{ k - n - 1 <= fee }", "{ paid and not met }" }));
            try out.append(a, '\n');
            try statement(s, a, out, sections, depth + 1);
            if (gen.boolean(s)) {
                try indent(a, out, depth);
                try out.appendSlice(a, "{ else }\n");
                try statement(s, a, out, sections, depth + 1);
                return;
            }
            return;
        },
        3 => try out.appendSlice(a, gen.oneOf(s, []const u8, &.{ "[n += k - 1]", "[met = true] [mood = cross]", "[got += pelt_bag]", "[k = n + fee]", "[n -= 2]" })),
        4 => try rows(a, out, depth, gen.oneOf(s, []const u8, &.{ "[rest(n)]", "[paid = pay(2)]\n{ paid }\n  MUM: Paid.", "[rest(k - 1)]" })),
        5 => {
            try out.appendSlice(a, gen.oneOf(s, []const u8, &.{ "- Home.", "- (ask)", "-> helper ->", "- (back) Home." }));
            return out.append(a, '\n');
        },
        6 => {
            try out.appendSlice(a, gen.oneOf(s, []const u8, &.{ "MUM: Go. ", "DAD: Wait. ", "Rain. " }));
            try out.print(a, "^k{d}", .{gen.intRange(s, u8, 0, 40)});
            if (gen.boolean(s)) {
                try out.append(a, '\n');
                try indent(a, out, depth + 1);
                try out.appendSlice(a, gen.oneOf(s, []const u8, &.{ "[at 2.5]", "[met = true]", "[at 1] [n += 1]" }));
            }
        },
        7 => try out.appendSlice(a, gen.oneOf(s, []const u8, &.{ "{ met } MUM: Inline.", "{ hour >= 2 } Late.", "// a writer's note", "" })),
        else => try out.appendSlice(a, "MUM: Something said."),
    }
    try out.append(a, '\n');
}

/// One change to `text`: a byte replaced, cut or added from the marks the language reads, a row cut, doubled or
/// moved, or the end cut off.
fn change(s: *shakedown.Source, a: std.mem.Allocator, text: *std.ArrayList(u8)) !void {
    if (text.items.len == 0) return text.appendSlice(a, "== a\n");
    const at = gen.intRange(s, usize, 0, text.items.len - 1);
    const alphabet = "=#{}()[]^<>:,.-+*/%\\\" \n\tabkmnsx019_~";
    const byte = alphabet[gen.intRange(s, usize, 0, alphabet.len - 1)];
    const start = if (std.mem.findScalarLast(u8, text.items[0..at], '\n')) |nl| nl + 1 else 0;
    const end = if (std.mem.findScalarPos(u8, text.items, at, '\n')) |nl| nl + 1 else text.items.len;
    switch (gen.intRange(s, u8, 0, 6)) {
        0 => text.items[at] = byte,
        1 => _ = text.orderedRemove(at),
        2 => try text.insert(a, at, byte),
        3 => text.replaceRangeAssumeCapacity(start, end - start, ""),
        4 => try text.insertSlice(a, start, try a.dupe(u8, text.items[start..end])),
        5 => {
            const row = try a.dupe(u8, text.items[start..end]);
            text.replaceRangeAssumeCapacity(start, end - start, "");
            const to = gen.intRange(s, usize, 0, text.items.len);
            const to_row = if (std.mem.findScalarLast(u8, text.items[0..to], '\n')) |nl| nl + 1 else 0;
            try text.insertSlice(a, to_row, row);
        },
        else => text.shrinkRetainingCapacity(at),
    }
}

/// The story of a case, as one or two files: written and changed, a file of the proof changed, or any bytes.
pub fn storyOf(s: *shakedown.Source, a: std.mem.Allocator) ![]const Manuscript.Page {
    var text: std.ArrayList(u8) = .empty;
    switch (gen.intRange(s, u8, 0, 7)) {
        0 => {
            var buffer: [512]u8 = undefined;
            try text.appendSlice(a, gen.bytesInto(s, &buffer));
        },
        1 => {
            try text.appendSlice(a, gen.oneOf(s, Manuscript.Page, &proof).text);
            for (0..gen.intRange(s, usize, 0, 4)) |_| try change(s, a, &text);
        },
        else => {
            try text.appendSlice(a, try written(s, a));
            for (0..gen.intRange(s, usize, 0, 3)) |_| try change(s, a, &text);
        },
    }
    // two files, cut before a section, one time in three
    if (gen.intRange(s, u8, 0, 2) == 0) {
        const at = gen.intRange(s, usize, 0, text.items.len);
        const cut = if (std.mem.findLast(u8, text.items[0..at], "\n== ")) |nl| nl + 1 else 0;
        return a.dupe(Manuscript.Page, &.{ .{ .path = "one.river", .text = text.items[0..cut] }, .{ .path = "two.river", .text = text.items[cut..] } });
    }
    return a.dupe(Manuscript.Page, &.{.{ .path = "story.river", .text = text.items }});
}

/// The proof's eight files, a whole game's story.
const proof = [_]Manuscript.Page{
    .{ .path = "cast.river", .text = @embedFile("../syntax/testdata/proof/cast.river") },
    .{ .path = "1969.river", .text = @embedFile("../syntax/testdata/proof/1969.river") },
    .{ .path = "1985.river", .text = @embedFile("../syntax/testdata/proof/1985.river") },
    .{ .path = "1998.river", .text = @embedFile("../syntax/testdata/proof/1998.river") },
    .{ .path = "years.river", .text = @embedFile("../syntax/testdata/proof/years.river") },
    .{ .path = "wake.river", .text = @embedFile("../syntax/testdata/proof/wake.river") },
    .{ .path = "back.river", .text = @embedFile("../syntax/testdata/proof/back.river") },
    .{ .path = "rest.river", .text = @embedFile("../syntax/testdata/proof/rest.river") },
};

/// The proof, with up to four changes to one of its files: checked with its own host, it reaches the compiler and
/// the runtime with everything a whole game writes.
pub fn proofChanged(s: *shakedown.Source, a: std.mem.Allocator) ![]const Manuscript.Page {
    const pages = try a.dupe(Manuscript.Page, &proof);
    const which = gen.intRange(s, usize, 0, pages.len - 1);
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, pages[which].text);
    for (0..gen.intRange(s, usize, 0, 4)) |_| try change(s, a, &text);
    pages[which].text = text.items;
    return pages;
}

test "any text through the reader, the checker with a package registered and the compiler is a story that is told, or diagnostics; never a crash" {
    var seen: Seen = .{};
    try shakedown.check(gpa, &seen, struct {
        fn one(counts: *Seen, case: *shakedown.Case) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const files = try storyOf(case.source, arena.allocator());
            const mode: check.Mode = if (gen.intRange(case.source, u8, 0, 7) == 0) .release else .development;
            expectWhole(joined, files, .{ .mode = mode }, case.source, counts) catch |e| {
                for (files) |f| std.debug.print("--- {s}\n{s}\n", .{ f.path, f.text });
                return e;
            };
        }
    }.one, .{ .cases = 1500, .seed = 0x3f00d });
    // the property reaches the compiler and the runtime, not only the reader's refusals
    try std.testing.expect(seen.compiled > 250);
    try std.testing.expect(seen.told > 2500);
}

test "the proof, any of its files changed, through the reader, the checker and the compiler with its host is a story that is told, or diagnostics; never a crash" {
    var seen: Seen = .{};
    try shakedown.check(gpa, &seen, struct {
        fn one(counts: *Seen, case: *shakedown.Case) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const files = try proofChanged(case.source, arena.allocator());
            expectWhole(wake, files, .{}, case.source, counts) catch |e| {
                for (files) |f| if (!isProof(f)) std.debug.print("--- {s}\n{s}\n", .{ f.path, f.text });
                return e;
            };
        }

        fn isProof(f: Manuscript.Page) bool {
            for (proof) |p| if (p.text.ptr == f.text.ptr) return true;
            return false;
        }
    }.one, .{
        .cases = 300,
        .seed = 0x9f00f,
        // back.river with its first section's row of tags twice: two `[forks …]`, whose words were given one line
        // id, and the compiler's refusal lost
        .regressions = &.{"6:1:cd:0:4"},
    });
    try std.testing.expect(seen.compiled > 30);
}
