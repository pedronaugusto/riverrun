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
const Watch = @import("Watch.zig");
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

test "a condition watched for a thing, with its roles, wakes for that thing's keys alone" {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const world = try b.scope("world");
    const bounty = try b.refKind("bounty");
    const person = try b.refKind("person");
    const alive = try b.fact(.{ .name = "alive", .scope = world, .kind = .boolean, .key = .{ .ref = person } });
    const asked = try b.fact(.{ .name = "bounty.asked", .scope = world, .kind = .boolean, .key = .{ .ref = bounty } });
    const giver = try b.fact(.{ .name = "bounty.giver", .scope = world, .kind = .ref, .ref_kind = person, .role = .game, .key = .{ .ref = bounty } });
    // `asked and not alive(giver)`, in a quest kept per bounty
    const when = try b.expr(&.{ .of(.this, bounty.raw()), .of(.keyed, asked.raw()), .of(.role, giver.raw()), .of(.keyed, alive.raw()), .of(.not, 0), .of(.@"and", 0) });
    var f: Fixture = undefined;
    try f.init(try testing.finish(&b, gpa));
    defer f.deinit();
    var w: Watch = try .init(gpa, &f.story, f.memory.store(), &f.host, &f.owners, .{});
    defer w.deinit();
    const first = try w.add(when, 1, .{ .this = 7, .roles = &.{.{ .fact = giver, .value = .{ .ref = 41 } }} });
    _ = try w.add(when, 2, .{ .this = 8, .roles = &.{.{ .fact = giver, .value = .{ .ref = 42 } }} });
    try std.testing.expectEqual(@as(usize, 2), (try w.step()).len);
    // the first bounty's giver dies, and another bounty is asked: each wakes its own condition
    try f.memory.setKey(alive, 41, .{ .boolean = false });
    try f.memory.setKey(asked, 7, .{ .boolean = true });
    const after = try w.step();
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqual(@as(u32, 1), after[0].user);
    try std.testing.expect(after[0].holds);
    try f.memory.setKey(alive, 99, .{ .boolean = true });
    try std.testing.expectEqual(@as(usize, 0), (try w.step()).len);
    // removed, it is never evaluated, and its id is the next condition's
    try w.remove(first);
    try f.memory.setKey(asked, 7, .{ .boolean = false });
    try std.testing.expectEqual(@as(usize, 0), (try w.step()).len);
    try std.testing.expectEqual(first, try w.add(when, 3, .{ .this = 7, .roles = &.{.{ .fact = giver, .value = .{ .ref = 41 } }} }));
    const again = try w.step();
    try std.testing.expectEqual(@as(usize, 1), again.len);
    try std.testing.expectEqual(@as(u32, 3), again[0].user);
}

test "a builtin that moves with a clock waits in the clock's heap" {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const world = try b.scope("world");
    const day = try b.fact(.{ .name = "day", .scope = world, .kind = .int, .role = .clock });
    const since = try b.builtinCall("quest", "since", &.{ 0, day.raw() }, .int, day);
    const when = try b.expr(&.{ .of(.builtin, since), .of(.int, try b.int(3)), .of(.gt, 0) });
    var f: Fixture = undefined;
    try f.init(try testing.finish(&b, gpa));
    defer f.deinit();
    // the package's answer: days since the second
    const Since = struct {
        fn call(user: ?*anyopaque, s: *const story.Story, _: u32, _: run.Context) error{BuiltinFailed}!facts.Value {
            const m: *facts.Memory = @ptrCast(@alignCast(user)); // safe: the test's own store
            return .{ .int = m.get(s.factNamed("day").?).int - 2 };
        }
    };
    var w: Watch = try .init(gpa, &f.story, f.memory.store(), &f.host, &f.owners, .{ .builtins = .{ .user = &f.memory, .call = Since.call } });
    defer w.deinit();
    try f.memory.set(day, .{ .int = 2 });
    _ = try w.add(when, 0, .{});
    try std.testing.expect(!(try w.step())[0].holds);
    var evaluated: usize = 0;
    var t: i64 = 3;
    while (t <= 4) : (t += 1) {
        try f.memory.set(day, .{ .int = t });
        evaluated += (try w.step()).len;
    }
    // nothing is evaluated until the clock comes near the number it is compared with
    try std.testing.expectEqual(@as(usize, 0), evaluated);
    try f.memory.set(day, .{ .int = 6 });
    const due = try w.step();
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expect(due[0].holds);
}

test "what changed is read from the store's log, or from every stamp once the log is left behind" {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const world = try b.scope("world");
    const lit = try b.fact(.{ .name = "lit", .scope = world, .kind = .boolean });
    const noise = try b.fact(.{ .name = "noise", .scope = world, .kind = .int });
    const when = try b.expr(&.{.of(.fact, lit.raw())});
    var f: Fixture = undefined;
    try f.init(try testing.finish(&b, gpa));
    defer f.deinit();
    var w: Watch = try .init(gpa, &f.story, f.memory.store(), &f.host, &f.owners, .{});
    defer w.deinit();
    _ = try w.add(when, 0, .{});
    _ = try w.step();
    for ([_]usize{ 10, facts.log_size }) |n| {
        // many marks of what nothing reads, and one of what the condition reads, among them
        for (0..n) |k| try f.memory.set(noise, .{ .int = @intCast(k + 1) }); // safe: a small count
        try f.memory.set(lit, .{ .boolean = !f.memory.get(lit).boolean });
        const after = try w.step();
        try std.testing.expectEqual(@as(usize, 1), after.len);
        try std.testing.expectEqual(f.memory.get(lit).boolean, after[0].holds);
        try f.memory.set(noise, .{ .int = 0 });
        try std.testing.expectEqual(@as(usize, 0), (try w.step()).len);
    }
}

test "conditions taken out of a list one by one leave the rest filed where they are" {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const world = try b.scope("world");
    const person = try b.refKind("person");
    const lit = try b.fact(.{ .name = "lit", .scope = world, .kind = .boolean });
    const seen = try b.fact(.{ .name = "seen", .scope = world, .kind = .boolean, .key = .{ .ref = person } });
    // `lit and seen(tom) and lit`: one fact read twice, and one key
    const when = try b.expr(&.{ .of(.fact, lit.raw()), .of(.thing, try b.thing(person, "tom")), .of(.keyed, seen.raw()), .of(.@"and", 0), .of(.fact, lit.raw()), .of(.@"and", 0) });
    var f: Fixture = undefined;
    try f.init(try testing.finish(&b, gpa));
    defer f.deinit();
    const Tom = struct {
        fn resolve(_: ?*anyopaque, _: []const u8, _: []const u8) ?u64 {
            return 7;
        }
    };
    try f.host.resolveStory(gpa, &f.story, .{ .user = null, .resolve = Tom.resolve }, null);
    var w: Watch = try .init(gpa, &f.story, f.memory.store(), &f.host, &f.owners, .{});
    defer w.deinit();
    var ids: [6]Watch.CondId = undefined;
    for (&ids, 0..) |*id, i| id.* = try w.add(when, @intCast(i), .{}); // safe: a few
    _ = try w.step();
    try w.remove(ids[1]);
    try w.remove(ids[4]);
    try w.remove(ids[0]);
    try f.memory.set(lit, .{ .boolean = true });
    var users: u32 = 0;
    for (try w.step()) |e| users |= @as(u32, 1) << @intCast(e.user); // safe: a few
    try std.testing.expectEqual(@as(u32, 0b101100), users);
    try f.memory.setKey(seen, 7, .{ .boolean = true });
    try std.testing.expectEqual(@as(usize, 3), (try w.step()).len);
    for ([_]usize{ 2, 3, 5 }) |i| try w.remove(ids[i]);
    try f.memory.set(lit, .{ .boolean = false });
    try f.memory.setKey(seen, 7, .{ .boolean = false });
    try std.testing.expectEqual(@as(usize, 0), (try w.step()).len);
    // the ids are the next conditions', filed afresh
    _ = try w.add(when, 9, .{});
    try std.testing.expectEqual(@as(u32, 9), (try w.step())[0].user);
}
