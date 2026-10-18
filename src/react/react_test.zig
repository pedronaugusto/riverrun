//! The react layer on stories built by hand: a rule fires when its condition
//! becomes true and not while it stays true; a section fires its first such
//! rule; a clock wakes only what is due; a stamp wakes only the conditions
//! filed under its keys; a budget changes when, never what; what a rule held
//! survives a new watch over the same facts; rules that keep firing each
//! other end in a named error.

const std = @import("std");
const facts = @import("../facts.zig");
const story = @import("../story.zig");
const run = @import("../run.zig");
const Rules = @import("Rules.zig");
const testing = @import("../run/testing.zig");

const gpa = std.testing.allocator;
const Term = story.Term;
const Builder = story.Builder;

const Fixture = struct {
    built: testing.Built,
    story: story.Story,
    arena: std.heap.ArenaAllocator,
    memory: facts.Memory,
    host: run.Host,
    owners: [facts.max_scopes]u64 = @splat(0),

    fn init(f: *Fixture, built: testing.Built) !void {
        f.* = .{ .built = built, .story = try .init(built.graph, .{}), .arena = .init(gpa), .memory = undefined, .host = .none };
        f.memory = try .init(gpa, try f.story.schema(f.arena.allocator()));
    }

    fn deinit(f: *Fixture) void {
        f.memory.deinit();
        f.host.deinit();
        f.arena.deinit();
        f.built.deinit(gpa);
    }

    fn rules(f: *Fixture, options: run.Options) !Rules {
        _ = options;
        return .init(gpa, &f.story, f.memory.store(), &f.host, &f.owners, .{});
    }

    fn fact(f: *const Fixture, name: []const u8) facts.FactId {
        return f.story.factNamed(name).?;
    }

    fn apply(f: *Fixture, fired: []const Rules.Fired) !void {
        for (fired) |r| for (r.effects) |e| {
            _ = try facts.apply(f.memory.store(), e);
        };
    }
};

// A rules section and its rules, each a condition and one effect, in the order given.
fn rulesSection(b: *Builder, name: []const u8, list: []const struct { name: []const u8, when: []const Term, effect: story.Effect }) !void {
    const s = try b.section(.{ .name = name, .kind = .rules, .visits = try b.visits(name) });
    for (list) |r| {
        var buf: [64]u8 = undefined;
        const full = try std.mem.print(&buf, "{s}.{s}", .{ name, r.name });
        const entry = try b.node(.{ .step = .{ .effects = .{ .effects = try b.effectList(&.{r.effect}) } } });
        try b.candidate(s, .{ .name = r.name, .when = try b.expr(r.when), .entry = entry, .visits = try b.visits(full), .seen = try b.state(try b.arena.allocator().print("rule.{s}", .{full})) });
    }
}

test "a rule fires when its condition becomes true, and a section fires its first such rule" {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const world = try b.scope("world");
    const pulled = try b.fact(.{ .name = "pulled", .scope = world, .kind = .boolean, .role = .game });
    const lever = try b.fact(.{ .name = "lever", .scope = world, .kind = .int });
    try rulesSection(&b, "puzzle", &.{
        .{ .name = "first", .when = &.{.of(.fact, pulled.raw())}, .effect = .{ .change = .{ .fact = lever, .by = try b.expr(&.{.of(.int, try b.int(1))}) } } },
        .{ .name = "also", .when = &.{.of(.fact, pulled.raw())}, .effect = .{ .change = .{ .fact = lever, .by = try b.expr(&.{.of(.int, try b.int(100))}) } } },
    });
    var f: Fixture = undefined;
    try f.init(try testing.finish(&b, gpa));
    defer f.deinit();
    var r = try f.rules(.{});
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try r.step()).len);
    try f.memory.set(f.fact("pulled"), .{ .boolean = true });
    const fired = try r.step();
    try std.testing.expectEqual(@as(usize, 1), fired.len);
    try std.testing.expectEqualStrings("first", fired[0].name);
    try f.apply(fired);
    // still true: it does not fire again, and the rule that became true with it waits to become true again
    try std.testing.expectEqual(@as(usize, 0), (try r.step()).len);
    try f.memory.set(f.fact("pulled"), .{ .boolean = false });
    try std.testing.expectEqual(@as(usize, 0), (try r.step()).len);
    try f.memory.set(f.fact("pulled"), .{ .boolean = true });
    try f.apply(try r.step());
    try std.testing.expectEqual(@as(i64, 2), f.memory.get(f.fact("lever")).int);
}

test "a clock wakes only what is due: honor drifts back a point every ten seconds it is left alone" {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const world = try b.scope("world");
    const seconds = try b.fact(.{ .name = "seconds", .scope = world, .kind = .int, .role = .clock });
    const honor = try b.fact(.{ .name = "honor", .scope = world, .kind = .int });
    const since = try b.sinceChanged(honor, seconds);
    try rulesSection(&b, "honor", &.{.{
        .name = "drift",
        .when = &.{ .of(.since_changed, since), .of(.int, try b.int(10)), .of(.ge, 0), .of(.fact, honor.raw()), .of(.int, try b.int(0)), .of(.gt, 0), .of(.@"and", 0) },
        .effect = .{ .change = .{ .fact = honor, .by = try b.expr(&.{.of(.int, try b.int(-1))}) } },
    }});
    var f: Fixture = undefined;
    try f.init(try testing.finish(&b, gpa));
    defer f.deinit();
    try f.memory.set(f.fact("honor"), .{ .int = 3 });
    var r = try f.rules(.{});
    defer r.deinit();
    try f.apply(try r.step());
    var evaluated: usize = 0;
    var t: i64 = 0;
    while (t < 40) : (t += 1) {
        try f.memory.set(f.fact("seconds"), .{ .int = t });
        const fired = try r.step();
        evaluated += r.watch.evaluated.items.len;
        try f.apply(fired);
    }
    // ten seconds after each change: at 10, 20 and 30, then honor is 0 and it rests
    try std.testing.expectEqual(@as(i64, 0), f.memory.get(f.fact("honor")).int);
    try std.testing.expectEqual(@as(i64, 3), f.memory.get(f.story.candidate(f.story.section(f.story.sectionNamed("honor").?).candidates.start).visits).int);
    // the clock ticked 40 times and the rule was evaluated only where it could flip, or where honor changed
    try std.testing.expect(evaluated <= 8);
}

test "a budget changes when a condition is evaluated, never what fires" {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const world = try b.scope("world");
    const go = try b.fact(.{ .name = "go", .scope = world, .kind = .boolean, .role = .game });
    const n = try b.fact(.{ .name = "n", .scope = world, .kind = .int });
    for ([_][]const u8{ "a", "b", "c" }) |name| {
        try rulesSection(&b, name, &.{.{ .name = "r", .when = &.{.of(.fact, go.raw())}, .effect = .{ .change = .{ .fact = n, .by = try b.expr(&.{.of(.int, try b.int(1))}) } } }});
    }
    var f: Fixture = undefined;
    try f.init(try testing.finish(&b, gpa));
    defer f.deinit();
    var r = try Rules.init(gpa, &f.story, f.memory.store(), &f.host, &f.owners, .{ .budget = 1 });
    defer r.deinit();
    for (0..3) |_| try f.apply(try r.step());
    try f.memory.set(f.fact("go"), .{ .boolean = true });
    var steps: usize = 0;
    while (f.memory.get(f.fact("n")).int < 3) : (steps += 1) {
        if (steps == 10) return error.TestBudgetNeverFinished;
        try f.apply(try r.step());
    }
    try std.testing.expectEqual(@as(usize, 3), steps);
    try std.testing.expectEqual(@as(usize, 0), (try r.step()).len);
}

test "what a rule held is kept in the facts, so a new watch fires nothing twice" {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const world = try b.scope("world");
    const met = try b.fact(.{ .name = "met", .scope = world, .kind = .boolean, .role = .game });
    const times = try b.fact(.{ .name = "times", .scope = world, .kind = .int });
    try rulesSection(&b, "greet", &.{.{ .name = "hello", .when = &.{.of(.fact, met.raw())}, .effect = .{ .change = .{ .fact = times, .by = try b.expr(&.{.of(.int, try b.int(1))}) } } }});
    var f: Fixture = undefined;
    try f.init(try testing.finish(&b, gpa));
    defer f.deinit();
    try f.memory.set(f.fact("met"), .{ .boolean = true });
    {
        var r = try f.rules(.{});
        defer r.deinit();
        try f.apply(try r.step());
    }
    var again = try f.rules(.{});
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try again.step()).len);
    try std.testing.expectEqual(@as(i64, 1), f.memory.get(f.fact("times")).int);
}

test "rules that keep firing each other end in a named error" {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const world = try b.scope("world");
    const on = try b.fact(.{ .name = "on", .scope = world, .kind = .boolean });
    try rulesSection(&b, "up", &.{.{ .name = "r", .when = &.{ .of(.fact, on.raw()), .of(.not, 0) }, .effect = .{ .set = .{ .fact = on, .value = try b.expr(&.{.of(.true, 0)}) } } }});
    try rulesSection(&b, "down", &.{.{ .name = "r", .when = &.{.of(.fact, on.raw())}, .effect = .{ .set = .{ .fact = on, .value = try b.expr(&.{.of(.false, 0)}) } } }});
    var f: Fixture = undefined;
    try f.init(try testing.finish(&b, gpa));
    defer f.deinit();
    var r = try f.rules(.{});
    defer r.deinit();
    try std.testing.expectError(error.NoFixedPoint, r.settle(&f, Fixture.apply));
}

const Stock = struct {
    pelts: i64 = 0,
    fn count(s: *Stock, _: run.Context, kind: i64) i64 {
        return if (kind == 3) s.pelts else 0;
    }
};

test "a stamp wakes only the conditions filed under its keys" {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const world = try b.scope("world");
    const ten = try b.fact(.{ .name = "ten", .scope = world, .kind = .boolean });
    const count = try b.externFn("count", &.{.{ .kind = .int }}, .{ .kind = .int }, false);
    try b.stamp(count, "stock", 1);
    try rulesSection(&b, "pelts", &.{.{
        .name = "gathered",
        .when = &.{ .of(.int, try b.int(3)), .of(.query, count.raw()), .of(.int, try b.int(10)), .of(.ge, 0) },
        .effect = .{ .set = .{ .fact = ten, .value = try b.expr(&.{.of(.true, 0)}) } },
    }});
    var f: Fixture = undefined;
    try f.init(try testing.finish(&b, gpa));
    defer f.deinit();
    var stock: Stock = .{};
    f.host = try .bind(gpa, &f.story, &stock, .{ .count = Stock.count }, null);
    var r = try f.rules(.{});
    defer r.deinit();
    _ = try r.step();
    stock.pelts = 10;
    // another kind's stock moved: nothing is evaluated
    try r.watch.bump("stock", &.{.{ .int = 4 }});
    _ = try r.step();
    try std.testing.expectEqual(@as(usize, 0), r.watch.evaluated.items.len);
    try r.watch.bump("stock", &.{.{ .int = 3 }});
    try f.apply(try r.step());
    try std.testing.expect(f.memory.get(f.fact("ten")).boolean);
}
