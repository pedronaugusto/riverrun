//! Integer `+` and `-`, end to end: stories that count their own state, told
//! by a session and watched by the react layer; and three properties, each
//! against a plain reference written here:
//!
//! - any sum the reader takes evaluates to what plain arithmetic says, left
//!   to right, or to `error.Overflow` exactly where a step leaves an i64;
//! - what the checker decides of a condition over bounded ints holds for
//!   every value each fact can have;
//! - a watched comparison is evaluated whenever its value changes, and a
//!   ticking clock wakes one that reads it once in a sum exactly then.

const std = @import("std");
const shakedown = @import("shakedown");
const syntax = @import("../syntax.zig");
const check = @import("../check.zig");
const facts = @import("riverrun").facts;
const react = @import("riverrun").react;
const testing = @import("testing.zig");

const Told = testing.Told;
const gen = shakedown.gen;
const gpa = std.testing.allocator;
const max = std.math.maxInt(i64);
const min = std.math.minInt(i64);

test "a story counts its own state: sums in conditions, effects and words, left to right" {
    const t = try Told.init(gpa, &.{
        \\cast:
        \\  dad  "Dad"
        \\facts (world):
        \\  coins: int
        \\  fee: int
        \\  owed: int
        \\  paid: int
        \\  trust: int
        \\  favour: int
        \\const:
        \\  tip = 2
        \\== a
        \\[coins = 10] [fee = 7] [owed = 12] [paid = 5] [favour = 3]
        \\{ coins >= fee + tip } You can pay.
        \\{ coins >= fee + tip + 2 } You are rich.
        \\DAD: That's {owed - paid} you still owe me.
        \\[trust += favour - 1] [trust -= favour + 1]
        \\{ trust = 0 - 2 } Trust fell.
        \\{ owed - paid - 1 = (owed - paid) - 1 and owed - (paid - 1) = 8 } Left to right.
        \\You owe {owed - paid as one: a coin | other: {owed - paid} coins}.
        \\-> end
    }, .{}, &.{}, testing.NoHost{});
    defer t.deinit();
    try t.session.start(.fromRaw(0), t.section("a"));
    try t.effects();
    try t.line("You can pay.");
    try t.line("That's 7 you still owe me.");
    try t.effects();
    try t.line("Trust fell.");
    try t.line("Left to right.");
    try t.line("You owe 7 coins.");
    try t.end();
}

test "a sum past what an int holds is a named error, never a wrap" {
    const t = try Told.init(gpa, &.{
        \\facts (world):
        \\  big: int
        \\  small: int
        \\== a
        \\{ big + 1 > 0 } It wrapped.
        \\-> end
        \\== b
        \\{ small - 1 < 0 } It wrapped.
        \\-> end
    }, .{}, &.{}, testing.NoHost{});
    defer t.deinit();
    try t.memory.set(t.fact("big"), .{ .int = max });
    try t.session.start(.fromRaw(0), t.section("a"));
    try std.testing.expectError(error.Overflow, t.session.next(.fromRaw(0)));
    try t.memory.set(t.fact("small"), .{ .int = min });
    try t.session.start(.fromRaw(0), t.section("b"));
    try std.testing.expectError(error.Overflow, t.session.next(.fromRaw(0)));
}

test "a bounded int changed by a sum stops at its nearer end" {
    const t = try Told.init(gpa, &.{
        \\facts (world):
        \\  honor: int from -100 to 100
        \\  slight: int
        \\== a
        \\[slight = 70]
        \\Slighted.
        \\[honor -= slight + slight]
        \\{ honor = -100 } At the bottom.
        \\-> end
    }, .{}, &.{}, testing.NoHost{});
    defer t.deinit();
    try t.session.start(.fromRaw(0), t.section("a"));
    try t.effects();
    try t.line("Slighted.");
    try t.effects();
    try t.line("At the bottom.");
    try t.end();
}

// A story's rules sections, each one rule, watched one by one: the user of each is its section's place.
const Watched = struct {
    t: *Told,
    owners: [facts.max_scopes]u64 = @splat(0),
    watch: react.Watch = undefined,

    fn init(w: *Watched, text: []const u8, sections: []const []const u8) !void {
        w.* = .{ .t = try Told.init(gpa, &.{text}, .{}, &.{}, testing.NoHost{}) };
        errdefer w.t.deinit();
        w.watch = try .init(gpa, &w.t.story, w.t.memory.store(), &w.t.host, &w.owners, .{});
        for (sections, 0..) |name, i| {
            const s = w.t.story.section(w.t.section(name));
            _ = try w.watch.add(w.t.story.candidate(s.candidates.start).when, @intCast(i), .{});
        }
    }

    fn deinit(w: *Watched) void {
        w.watch.deinit();
        w.t.deinit();
    }

    fn set(w: *Watched, fact: []const u8, v: i64) !void {
        try w.t.memory.set(w.t.fact(fact), .{ .int = v });
    }

    // A step: which of the conditions it evaluated, as bits by user.
    fn step(w: *Watched) !u32 {
        var bits: u32 = 0;
        for (try w.watch.step()) |e| bits |= @as(u32, 1) << @intCast(e.user);
        return bits;
    }
};

test "a clock compared with a sum waits where it next flips, and waits anew when the sum's other side changes" {
    var w: Watched = undefined;
    try w.init(
        \\facts (world):
        \\  hour: int   (clock)
        \\  day: int   (clock)
        \\  arrived: int   (game)
        \\== late (rules)
        \\= r   when { hour >= arrived + 3 }
        \\== early (rules)
        \\= r   when { arrived - hour > 0 }
        \\== exact (rules)
        \\= r   when { hour = arrived + 1 }
        \\== both (rules)
        \\= r   when { hour - day >= 2 }
    , &.{ "late", "early", "exact", "both" });
    defer w.deinit();
    try w.set("arrived", 5);
    try std.testing.expectEqual(@as(u32, 0b1111), try w.step());
    // `early` flips at 5, `exact` at 6 and 7, `late` at 8; `both` reads two clocks and wakes at every move
    const want = [_]u32{ 0, 0b1000, 0b1000, 0b1000, 0b1000, 0b1010, 0b1100, 0b1100, 0b1001, 0b1000 };
    for (want, 0..) |bits, hour| {
        if (hour == 0) continue;
        try w.set("hour", @intCast(hour));
        try std.testing.expectEqual(bits, try w.step());
    }
    try std.testing.expect(try w.watch.holds(.fromRaw(0)));
    // `arrived` moves on: everything that reads it wakes, and waits for the new instants
    try w.set("arrived", 10);
    try std.testing.expectEqual(@as(u32, 0b0111), try w.step());
    try std.testing.expect(!(try w.watch.holds(.fromRaw(0))));
    for (10..14) |hour| {
        try w.set("hour", @intCast(hour));
        const bits = try w.step();
        try std.testing.expectEqual(hour == 10 or hour == 11 or hour == 12 or hour == 13, bits & 0b1000 != 0);
        try std.testing.expectEqual(hour == 10, bits & 0b0010 != 0);
        try std.testing.expectEqual(hour == 11 or hour == 12, bits & 0b0100 != 0);
        try std.testing.expectEqual(hour == 13, bits & 0b0001 != 0);
    }
    // the other clock moves: only what reads it wakes
    try w.set("day", 1);
    try std.testing.expectEqual(@as(u32, 0b1000), try w.step());
    // a clock moved back, a moment restored, wakes every comparison with it
    try w.set("hour", 2);
    try std.testing.expectEqual(@as(u32, 0b1111), try w.step());
}

// ---------------------------------------------------------------- the evaluator against plain arithmetic

const fact_names = [_][]const u8{ "f0", "f1", "f2", "f3" };
const const_names = [_][]const u8{ "k0", "k1" };

// What a generated expression reads: the facts' values and the constants'.
const Values = struct { facts: [fact_names.len]i64, consts: [const_names.len]i64 };

fn anInt(s: *shakedown.Source) i64 {
    return switch (gen.intRange(s, u8, 0, 9)) {
        0 => max,
        1 => min,
        2 => max - gen.intRange(s, i64, 0, 3),
        3 => min + gen.intRange(s, i64, 0, 3),
        4 => gen.int(s, i64),
        else => gen.intRange(s, i64, -20, 20),
    };
}

// An int expression, written into `out`, and its value by plain arithmetic, left to right: null where a step of it
// leaves an i64, as evaluating it stops with `error.Overflow`.
fn sumOf(s: *shakedown.Source, v: *const Values, out: *std.ArrayList(u8), a: std.mem.Allocator, depth: u8) error{OutOfMemory}!?i64 {
    var value = try operand(s, v, out, a, depth);
    for (0..gen.intRange(s, usize, 0, if (depth == 0) 0 else 3)) |_| {
        const plus = gen.boolean(s);
        try out.appendSlice(a, if (plus) " + " else " - ");
        const next = try operand(s, v, out, a, depth);
        value = if (value) |x| (if (next) |y| (if (plus) std.math.add(i64, x, y) else std.math.sub(i64, x, y)) catch null else null) else null;
    }
    return value;
}

fn operand(s: *shakedown.Source, v: *const Values, out: *std.ArrayList(u8), a: std.mem.Allocator, depth: u8) error{OutOfMemory}!?i64 {
    switch (gen.intRange(s, u8, 0, 5)) {
        0, 1 => {
            const i = gen.intRange(s, usize, 0, fact_names.len - 1);
            try out.appendSlice(a, fact_names[i]);
            return v.facts[i];
        },
        2 => {
            const i = gen.intRange(s, usize, 0, const_names.len - 1);
            try out.appendSlice(a, const_names[i]);
            return v.consts[i];
        },
        3 => {
            const n = anInt(s);
            try out.print(a, "{d}", .{n});
            return n;
        },
        else => if (depth > 0) {
            try out.append(a, '(');
            const inner = try sumOf(s, v, out, a, depth - 1);
            try out.append(a, ')');
            return inner;
        } else {
            try out.appendSlice(a, fact_names[0]);
            return v.facts[0];
        },
    }
}

test "any sum evaluates as plain arithmetic does, left to right, or to the named error where a step leaves an i64" {
    try shakedown.check(gpa, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const s = case.source;
            var v: Values = undefined;
            for (&v.facts) |*f| f.* = anInt(s);
            for (&v.consts) |*k| k.* = gen.intRange(s, i64, -1000, 1000);
            var expr: std.ArrayList(u8) = .empty;
            const want = try sumOf(s, &v, &expr, a, 2);
            const minus = gen.boolean(s);
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(a, "facts (world):\n");
            for (fact_names) |f| try text.print(a, "  {s}: int\n", .{f});
            try text.appendSlice(a, "  out: int\nconst:\n");
            for (const_names, v.consts) |k, n| try text.print(a, "  {s} = {d}\n", .{ k, n });
            try text.print(a, "== a\n[out {s} {s}]\n-> end\n", .{ if (minus) "-=" else "=", expr.items });
            const t = Told.init(gpa, &.{text.items}, .{}, &.{}, testing.NoHost{}) catch |err| {
                // the checker refuses a sum only where it always overflows
                if (err == error.TestStoryRefused and want == null) return;
                std.debug.print("refused: {s}\n", .{expr.items});
                return err;
            };
            defer t.deinit();
            for (fact_names, v.facts) |f, n| try t.memory.set(t.fact(f), .{ .int = n });
            try t.session.start(.fromRaw(0), t.section("a"));
            const step = t.session.next(.fromRaw(0)) catch |err| {
                if (err == error.Overflow and (want == null or (minus and want.? == min))) return;
                std.debug.print("{s} = {?d}: {t}\n", .{ expr.items, want, err });
                return err;
            };
            const effect = step.effects[0];
            const have = if (minus) effect.change.by else effect.set.value.int;
            const expected = if (minus) (if (want) |w| std.math.sub(i64, 0, w) catch null else null) else want;
            if (expected == null or expected.? != have) {
                std.debug.print("{s}: {d}, where plain arithmetic gives {?d}\n", .{ expr.items, have, expected });
                return error.TestUnexpectedResult;
            }
        }
    }.one, .{ .cases = 600, .seed = 0x5a175 });
}

// ---------------------------------------------------------------- the checker's verdicts are sound

const Bounded = struct { least: i64, most: i64 };

// What a generated condition reads: three bounded ints, an unbounded one, a `one of` and a constant.
const Assignment = struct { ints: [3]i64, u: i64, mood: ?u8, k: i64 };

const Cond = union(enum) {
    compare: struct { op: Op, lhs: []const Leaf, rhs: []const Leaf },
    mood: struct { is: bool, value: u8 },
    not: *const Cond,
    both: [2]*const Cond,
    either: [2]*const Cond,

    const Op = enum { lt, le, gt, ge, eq, ne };
    const Leaf = struct { minus: bool, what: union(enum) { int: u8, u, k, n: i64 } };
};

const moods = [_][]const u8{ "calm", "angry", "sad" };

fn leaves(s: *shakedown.Source, a: std.mem.Allocator, unbounded: bool) ![]const Cond.Leaf {
    const out = try a.alloc(Cond.Leaf, gen.intRange(s, usize, 1, 3));
    for (out, 0..) |*l, i| l.* = .{ .minus = i > 0 and gen.boolean(s), .what = switch (gen.intRange(s, u8, 0, 5)) {
        0, 1, 2 => .{ .int = gen.intRange(s, u8, 0, 2) },
        3 => if (unbounded) .u else .{ .int = 0 },
        4 => .k,
        else => .{ .n = gen.intRange(s, i64, -15, 15) },
    } };
    return out;
}

fn condition(s: *shakedown.Source, a: std.mem.Allocator, depth: u8, unbounded: bool) error{OutOfMemory}!*const Cond {
    const c = try a.create(Cond);
    const kind = if (depth == 0) gen.intRange(s, u8, 0, 2) else gen.intRange(s, u8, 0, 5);
    c.* = switch (kind) {
        0, 1 => .{ .compare = .{ .op = gen.oneOf(s, Cond.Op, &.{ .lt, .le, .gt, .ge, .eq, .ne }), .lhs = try leaves(s, a, unbounded), .rhs = try leaves(s, a, unbounded) } },
        2 => .{ .mood = .{ .is = gen.boolean(s), .value = gen.intRange(s, u8, 0, moods.len - 1) } },
        3 => .{ .not = try condition(s, a, depth - 1, unbounded) },
        4 => .{ .both = .{ try condition(s, a, depth - 1, unbounded), try condition(s, a, depth - 1, unbounded) } },
        else => .{ .either = .{ try condition(s, a, depth - 1, unbounded), try condition(s, a, depth - 1, unbounded) } },
    };
    return c;
}

fn write(c: *const Cond, out: *std.ArrayList(u8), a: std.mem.Allocator) error{OutOfMemory}!void {
    switch (c.*) {
        .compare => |x| {
            try writeLeaves(x.lhs, out, a);
            try out.print(a, " {s} ", .{switch (x.op) {
                .lt => "<",
                .le => "<=",
                .gt => ">",
                .ge => ">=",
                .eq => "=",
                .ne => "!=",
            }});
            try writeLeaves(x.rhs, out, a);
        },
        .mood => |m| try out.print(a, "mood {s} {s}", .{ if (m.is) "=" else "!=", moods[m.value] }),
        .not => |inner| {
            try out.appendSlice(a, "not (");
            try write(inner, out, a);
            try out.append(a, ')');
        },
        .both, .either => |pair| {
            try out.append(a, '(');
            try write(pair[0], out, a);
            try out.appendSlice(a, if (c.* == .both) ") and (" else ") or (");
            try write(pair[1], out, a);
            try out.append(a, ')');
        },
    }
}

fn writeLeaves(list: []const Cond.Leaf, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    for (list, 0..) |l, i| {
        if (i > 0) try out.appendSlice(a, if (l.minus) " - " else " + ");
        switch (l.what) {
            .int => |n| try out.print(a, "i{d}", .{n}),
            .u => try out.appendSlice(a, "u"),
            .k => try out.appendSlice(a, "k"),
            .n => |n| try out.print(a, "{d}", .{n}),
        }
    }
}

// The plain value of a sum of leaves, null past an i64.
fn sumValue(list: []const Cond.Leaf, x: *const Assignment) ?i64 {
    var total: i64 = 0;
    for (list) |l| {
        const v: i64 = switch (l.what) {
            .int => |n| x.ints[n],
            .u => x.u,
            .k => x.k,
            .n => |n| n,
        };
        total = (if (l.minus) std.math.sub(i64, total, v) else std.math.add(i64, total, v)) catch return null;
    }
    return total;
}

// What the condition is under `x`: null where a sum in it overflows, so it gives no value.
fn truth(c: *const Cond, x: *const Assignment) ?bool {
    return switch (c.*) {
        .compare => |cmp| {
            const l = sumValue(cmp.lhs, x) orelse return null;
            const r = sumValue(cmp.rhs, x) orelse return null;
            return switch (cmp.op) {
                .lt => l < r,
                .le => l <= r,
                .gt => l > r,
                .ge => l >= r,
                .eq => l == r,
                .ne => l != r,
            };
        },
        .mood => |m| (x.mood != null and x.mood.? == m.value) == m.is,
        .not => |inner| !(truth(inner, x) orelse return null),
        .both => |p| (truth(p[0], x) orelse return null) and (truth(p[1], x) orelse return null),
        .either => |p| (truth(p[0], x) orelse return null) or (truth(p[1], x) orelse return null),
    };
}

// Every value a bounded int can hold: its bounds, and 0 before it is first set.
fn holdable(b: Bounded, out: *std.ArrayList(i64), a: std.mem.Allocator) !void {
    var n = b.least;
    while (n <= b.most) : (n += 1) try out.append(a, n);
    if (b.least > 0 or b.most < 0) try out.append(a, 0);
}

test "what the checker decides of a condition over bounded ints holds for every value they can have" {
    const Count = struct { decided: usize = 0 };
    var count: Count = .{};
    try shakedown.check(gpa, &count, struct {
        fn one(counted: *Count, case: *shakedown.Case) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const s = case.source;
            var bounds: [3]Bounded = undefined;
            for (&bounds) |*b| {
                const least = gen.intRange(s, i64, -6, 6);
                b.* = .{ .least = least, .most = least + gen.intRange(s, i64, 0, 6) };
            }
            const k = gen.intRange(s, i64, -10, 10);
            const unbounded = gen.intRange(s, u8, 0, 3) == 0;
            const cond = try condition(s, a, 2, unbounded);
            var written: std.ArrayList(u8) = .empty;
            try write(cond, &written, a);
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(a, "facts:\n");
            for (bounds, 0..) |b, i| try text.print(a, "  i{d}: int from {d} to {d}\n", .{ i, b.least, b.most });
            try text.appendSlice(a, "  u: int\n  mood: one of calm, angry, sad\n");
            try text.print(a, "const:\n  k = {d}\n== s\n* {{ {s} }} Never.\n  -> end\n* {{ not ({s}) }} Always.\n  -> end\n", .{ k, written.items, written.items });
            // the rows the two choices stand on
            const never_row: u32 = 10;
            const always_row: u32 = 12;
            var diags: syntax.Diagnostics = .{};
            defer diags.deinit(gpa);
            const tree = try syntax.parse(a, gpa, &diags, 0, "s.river", text.items);
            var checked = try check.run(gpa, &diags, (&tree)[0..1], .{});
            defer checked.deinit();
            var never = false;
            var always = false;
            for (diags.list.items) |d| {
                if (d.severity == .err) {
                    std.debug.print("{s}\n{s}\n", .{ text.items, d.message });
                    return error.TestStoryRefused;
                }
                if (!std.mem.startsWith(u8, d.message, "this choice can never be offered")) continue;
                const row = tree.place(d.span).line;
                if (row == never_row) never = true else if (row == always_row) always = true else return error.TestUnexpectedResult;
            }
            if (never or always) counted.decided += 1;
            if (!never and !always) return;
            // every assignment the facts can hold, the unbounded int at its extremes and about 0
            var values: [3]std.ArrayList(i64) = .{ .empty, .empty, .empty };
            for (&values, bounds) |*l, b| try holdable(b, l, a);
            const us: []const i64 = if (unbounded) &.{ min, -1, 0, 1, max } else &.{0};
            var x: Assignment = .{ .ints = undefined, .u = 0, .mood = null, .k = k };
            for (values[0].items) |v0| for (values[1].items) |v1| for (values[2].items) |v2| for (us) |u| for (0..moods.len + 1) |m| {
                x = .{ .ints = .{ v0, v1, v2 }, .u = u, .mood = if (m == moods.len) null else @intCast(m), .k = k };
                const holds = truth(cond, &x) orelse continue;
                if ((never and holds) or (always and !holds)) {
                    std.debug.print("{s}: the checker says {s}, and with i0 {d}, i1 {d}, i2 {d}, u {d}, mood {?d} it is {}\n", .{ written.items, if (never) "never" else "always", v0, v1, v2, u, x.mood, holds });
                    return error.TestUnexpectedResult;
                }
            };
        }
    }.one, .{ .cases = 1500, .seed = 0xc4ec7 });
    // the property is not vacuous: the checker decides some conditions
    try std.testing.expect(count.decided > 100);
}

// ---------------------------------------------------------------- the react layer wakes when a value changes

// A watched comparison over two clocks `c` and `d`, two ints and a constant: how often each clock is read, and
// whether each is read in its sums alone.
const Watchable = struct { text: []const u8, c: u8, d: u8 };

fn watchable(s: *shakedown.Source, a: std.mem.Allocator) !Watchable {
    var out: std.ArrayList(u8) = .empty;
    var c: u8 = 0;
    var d: u8 = 0;
    for (0..2) |side| {
        if (side == 1) try out.appendSlice(a, gen.oneOf(s, []const u8, &.{ " < ", " <= ", " > ", " >= ", " = ", " != " }));
        for (0..gen.intRange(s, usize, 1, 3)) |i| {
            if (i > 0) try out.appendSlice(a, if (gen.boolean(s)) " + " else " - ");
            const leaf = gen.oneOf(s, []const u8, &.{ "c", "c", "c", "d", "a", "b", "k", "2", "5" });
            if (leaf[0] == 'c') c += 1;
            if (leaf[0] == 'd') d += 1;
            try out.appendSlice(a, leaf);
        }
    }
    return .{ .text = out.items, .c = c, .d = d };
}

test "a watched comparison is evaluated whenever its value changes, and a ticking clock read once wakes it exactly then" {
    try shakedown.check(gpa, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const s = case.source;
            const cond = try watchable(s, a);
            const text = try a.print(
                \\facts (world):
                \\  c: int   (clock)
                \\  d: int   (clock)
                \\  a: int   (game)
                \\  b: int   (game)
                \\const:
                \\  k = {d}
                \\== w (rules)
                \\= r   when {{ {s} }}
            , .{ gen.intRange(s, i64, -5, 5), cond.text });
            var w: Watched = undefined;
            try w.init(text, &.{"w"});
            defer w.deinit();
            var last = (try w.watch.step())[0].holds;
            var clock: i64 = 0;
            var other: i64 = 0;
            for (0..80) |_| {
                const move = gen.intRange(s, u8, 0, 11);
                switch (move) {
                    0...5 => clock += 1,
                    6 => clock += gen.intRange(s, i64, 0, 6),
                    7 => clock -= gen.intRange(s, i64, 1, 3),
                    8 => other += 1,
                    9 => try w.set("a", gen.intRange(s, i64, -10, 30)),
                    else => try w.set("b", gen.intRange(s, i64, -10, 30)),
                }
                try w.set("c", clock);
                try w.set("d", other);
                const evaluated = try w.watch.step();
                const now = try w.watch.holds(.fromRaw(0));
                const woken = evaluated.len == 1;
                if (woken and evaluated[0].holds != now) return error.TestUnexpectedResult;
                if (now != last and !woken) {
                    std.debug.print("`{s}` became {} at c {d}, d {d}, and was not woken\n", .{ cond.text, now, clock, other });
                    return error.TestUnexpectedResult;
                }
                // a tick of a clock it reads once, and nothing else: woken exactly when its value changes
                if (move <= 5 and cond.c == 1 and cond.d == 0 and woken != (now != last)) {
                    std.debug.print("`{s}` was {s} at c {d}, its value {} as it was\n", .{ cond.text, if (woken) "woken" else "not woken", clock, now });
                    return error.TestUnexpectedResult;
                }
                // a comparison reading two clocks wakes when either moves
                if (cond.c > 0 and cond.d > 0 and (move <= 5 or move == 8) and !woken) return error.TestUnexpectedResult;
                last = now;
            }
        }
    }.one, .{ .cases = 600, .seed = 0x3ac7 });
}
