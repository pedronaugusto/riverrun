//! The compiler's tests: small stories, written as a writer writes them,
//! compiled and told by a session, so what is checked is what a player sees.

const std = @import("std");
const check = @import("../check.zig");
const story = @import("riverrun").story;
const facts = @import("riverrun").facts;
const run = @import("riverrun").run;
const react = @import("riverrun").react;
const compile = @import("../compile.zig");
const testing = @import("testing.zig");

const Told = testing.Told;
const gpa = std.testing.allocator;

test "a kitchen: lines, choices open and closed, a gather, a jump and the end" {
    const t = try Told.init(gpa, &.{
        \\cast:
        \\  dad  "Dad"  — Frank, her father
        \\facts (player):
        \\  carried: set of play, gave
        \\== kitchen
        \\The bus leaves at {bus}. {carried has play: He knows you heard. | He doesn't know.}
        \\DAD: Go.
        \\- (ask)
        \\* Who'll run the shop?
        \\  DAD: I will.
        \\  -> ask
        \\* { carried has play } You could still play.
        \\  DAD: Who'd listen?
        \\  -> ask
        \\+ Pick up the case.
        \\  ~ carried += gave
        \\  -> fork
        \\== fork
        \\{ carried has gave } Gone.
        \\-> end
        \\const:
        \\  bus = "22:40"
    }, .{}, &.{}, testing.NoHost{});
    defer t.deinit();
    try t.session.start(.fromRaw(0), t.section("kitchen"));
    try t.line("The bus leaves at 22:40. He doesn't know.");
    try t.line("Go.");
    try t.choices(&.{ "Who'll run the shop?", "[You could still play.]", "Pick up the case." });
    try t.session.choose(.fromRaw(0), 0);
    try t.line("I will.");
    // a once-only choice taken is gone
    try t.choices(&.{ "[You could still play.]", "Pick up the case." });
    try t.session.choose(.fromRaw(0), 1);
    try t.effects();
    try t.line("Gone.");
    try t.end();
    try std.testing.expectEqualStrings("Dad", t.session.speaker(.fromRaw(0)).?);
}

test "conditions with else, ints changed by an amount, alternatives and a pool" {
    const t = try Told.init(gpa, &.{
        \\facts (life):
        \\  points: int
        \\  hour:   int   (game)
        \\const:
        \\  penalty = 5
        \\== a
        \\~ points += 2
        \\~ points -= penalty
        \\{ points < 0 }
        \\  Below zero.
        \\{ else }
        \\  Above.
        \\Margaret {cycle: counts | hums}.
        \\->> night
        \\-> end
        \\== night (pool)
        \\= plain   when { hour >= 0 }
        \\  The house is quiet.
        \\= ten     when { hour >= 0 and hour = 22 }
        \\  Her reading glasses, folded.
    }, .{}, &.{}, testing.NoHost{});
    defer t.deinit();
    try t.memory.set(t.fact("hour"), .{ .int = 22 });
    try t.session.start(.fromRaw(0), t.section("a"));
    try t.effects();
    try std.testing.expectEqual(@as(i64, -3), t.memory.get(t.fact("points")).int);
    try t.line("Below zero.");
    try t.line("Margaret counts.");
    try t.line("Her reading glasses, folded.");
    try t.end();
    try t.session.start(.fromRaw(0), t.section("a"));
    try t.effects();
    try t.line("Below zero.");
    try t.line("Margaret hums.");
}

pub const Persuasion = struct {
    fn persuade(_: *Persuasion, _: run.Context, _: i64) u16 {
        return 0;
    }
    fn name(_: *Persuasion, _: run.Context, who: u64) []const u8 {
        return if (who == 7) "Margaret" else "nobody";
    }
    const impls = .{ .persuade = persuade, .@"harbour.name" = name };

    var me: Persuasion = .{};
    pub fn host(_: Persuasion, g: std.mem.Allocator, s: *const story.Story) !run.Host {
        var h = try run.Host.bind(g, s, &me, impls, null);
        errdefer h.deinit();
        try h.resolveStory(g, s, .{ .user = null, .resolve = resolve }, null);
        return h;
    }
    fn resolve(_: ?*anyopaque, kind: []const u8, id: []const u8) ?u64 {
        return if (std.mem.eql(u8, kind, "person") and std.mem.eql(u8, id, "margaret")) 7 else null;
    }
};

test "an outcome, the host's things and another module's names" {
    const t = try Told.init(gpa, &.{
        \\module harbour
        \\facts (life):
        \\  target: ref of person   (game)
        \\extern:
        \\  name(who: ref of person) -> text
        \\== letter
        \\{ target = margaret } It is {name(target)}.
        \\-> end
        ,
        \\facts (life):
        \\  persuaded: one of yes, no
        \\extern:
        \\  persuade(against: int) -> one of yes, no   (action)
        \\== start
        \\~ persuaded = persuade(12)
        \\{ persuaded = yes } She agrees.
        \\-> harbour.letter
    }, .{}, &.{}, Persuasion{});
    defer t.deinit();
    try t.memory.set(t.fact("harbour.target"), .{ .ref = 7 });
    try t.session.start(.fromRaw(0), t.section("start"));
    const act = (try t.session.next(.fromRaw(0))).action;
    try std.testing.expectEqualStrings("persuade", t.story.externFn(act.call.action).name);
    try t.session.outcome(.fromRaw(0), .{ .one_of = 0 });
    try t.line("She agrees.");
    try t.line("It is Margaret.");
    try t.end();
}

test "a registered kind's builtin is compiled for its package, and its pass adds a block" {
    const quest: check.Kind = .{ .name = "quest", .builtins = &.{.{ .name = "since", .params = &.{ .part, .int_fact }, .returns = .int }} };
    const Pass = struct {
        fn add(_: ?*anyopaque, c: *compile.Compiler) compile.Compiler.Error!void {
            try c.b.block("cairn", 1, "stages");
        }
    };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out = try testing.compiled(gpa, arena.allocator(), &.{
        \\facts (life):
        \\  day: int   (clock)
        \\== pelts (quest)
        \\= asked   when { day > 0 }
        \\  Hilde wants ten pelts.
        \\= late    when { since(asked, day) > 3 }
        \\  { since(asked, day) > 5 } Far too late.
        \\  Too late.
    }, .{ .kinds = &.{quest} }, &.{.{ .run = Pass.add }});
    defer out.deinit(gpa);
    const s: story.Story = try .init(out.graph, .{});
    try std.testing.expectEqualStrings("stages", s.block("cairn").?.bytes);
    try std.testing.expectEqual(@as(u32, 1), s.len(.builtins));
    const call = s.builtin(0);
    try std.testing.expectEqualStrings("since", call.name);
    try std.testing.expectEqualStrings("pelts.asked", s.section(.fromRaw(s.builtinArg(call.args.start))).name);
    try std.testing.expectEqual(facts.Role.clock, s.fact(.fromRaw(@intCast(s.builtinArg(call.args.start + 1)))).role);
    try std.testing.expectEqual(story.Section.Kind.other, s.section(s.sectionNamed("pelts.late").?).kind);
}

test "rules from the text: a slight lowers honor, and time alone brings it back" {
    const t = try Told.init(gpa, &.{
        \\facts (world):
        \\  seconds:  int    (clock)
        \\  honor:    int
        \\  insulted: bool   (game)
        \\== honor (rules)
        \\= slight   when { insulted }
        \\  ~ honor -= 5
        \\= drift    when { since_changed(honor, seconds) >= 10 and honor < 0 }
        \\  ~ honor += 1
    }, .{}, &.{}, testing.NoHost{});
    defer t.deinit();
    var owners: [facts.max_scopes]u64 = @splat(0);
    var rules: react.Rules = try .init(gpa, &t.story, t.memory.store(), &t.host, &owners, .{});
    defer rules.deinit();
    try t.memory.set(t.fact("insulted"), .{ .boolean = true });
    var second: i64 = 0;
    var lowest: i64 = 0;
    while (second <= 60) : (second += 1) {
        try t.memory.set(t.fact("seconds"), .{ .int = second });
        for (try rules.step()) |fired| for (fired.effects) |e| {
            _ = try facts.apply(t.memory.store(), e);
        };
        lowest = @min(lowest, t.memory.get(t.fact("honor")).int);
    }
    try std.testing.expectEqual(@as(i64, -5), lowest);
    try std.testing.expectEqual(@as(i64, 0), t.memory.get(t.fact("honor")).int);
}

// Rounds of rules until none fires, their effects applied at once, as a host that applies effects does.
fn settle(t: *Told, rules: *react.Rules) !void {
    for (0..react.max_rounds) |_| {
        const fired = try rules.step();
        if (fired.len == 0) return;
        for (fired) |f| for (f.effects) |e| {
            _ = try facts.apply(t.memory.store(), e);
        };
    }
    return error.TestNoFixedPoint;
}

test "a lever puzzle: in order it opens, a wrong lever or a slow hand starts it over" {
    const t = try Told.init(gpa, &.{
        \\facts (world):
        \\  seconds: int                          (clock)
        \\  pulled:  one of a, b, c               (moment)
        \\  levers:  one of idle, one, two, open
        \\  door:    bool
        \\== chapel (rules)
        \\= first    when { levers = idle and pulled = a }
        \\  ~ levers = one
        \\= second   when { levers = one and pulled = c }
        \\  ~ levers = two
        \\= third    when { levers = two and pulled = b }
        \\  ~ levers = open
        \\  ~ door = true
        \\= wrong    when { levers != open and happened(pulled) }
        \\  ~ levers = idle
        \\= slow     when { (levers = one or levers = two) and since_changed(levers, seconds) > 10 }
        \\  ~ levers = idle
    }, .{}, &.{}, testing.NoHost{});
    defer t.deinit();
    var owners: [facts.max_scopes]u64 = @splat(0);
    var rules: react.Rules = try .init(gpa, &t.story, t.memory.store(), &t.host, &owners, .{});
    defer rules.deinit();
    const levers = t.fact("levers");
    const pulled = t.fact("pulled");
    const lever = struct {
        fn pull(told: *Told, r: *react.Rules, which: u16) !void {
            try told.memory.set(told.fact("pulled"), .{ .one_of = which });
            try settle(told, r);
        }
    }.pull;
    try t.memory.set(levers, .{ .one_of = 0 });
    try settle(t, &rules);
    try lever(t, &rules, 0);
    try std.testing.expectEqual(@as(u16, 1), t.memory.get(levers).one_of);
    // the moment is over: it holds nothing once every rule has seen it
    try std.testing.expectEqual(facts.Value.none, t.memory.get(pulled).one_of);
    try lever(t, &rules, 1);
    try std.testing.expectEqual(@as(u16, 0), t.memory.get(levers).one_of);
    try lever(t, &rules, 0);
    try lever(t, &rules, 2);
    try std.testing.expectEqual(@as(u16, 2), t.memory.get(levers).one_of);
    // too slow: eleven seconds after the second lever, it starts over
    for (1..12) |s| {
        try t.memory.set(t.fact("seconds"), .{ .int = @intCast(s) });
        try settle(t, &rules);
    }
    try std.testing.expectEqual(@as(u16, 0), t.memory.get(levers).one_of);
    try lever(t, &rules, 0);
    try lever(t, &rules, 2);
    try lever(t, &rules, 1);
    try std.testing.expectEqual(@as(u16, 3), t.memory.get(levers).one_of);
    try std.testing.expect(t.memory.get(t.fact("door")).boolean);
}

pub const Village = struct {
    var me: Village = .{};
    pub fn host(_: Village, g: std.mem.Allocator, s: *const story.Story) !run.Host {
        var h = try run.Host.bind(g, s, &me, .{}, null);
        errdefer h.deinit();
        try h.resolveStory(g, s, .{ .user = null, .resolve = resolve }, null);
        return h;
    }
    fn resolve(_: ?*anyopaque, kind: []const u8, id: []const u8) ?u64 {
        if (!std.mem.eql(u8, kind, "person")) return null;
        if (std.mem.eql(u8, id, "hank")) return 1;
        if (std.mem.eql(u8, id, "marta")) return 2;
        return null;
    }
};

test "facts kept per person: kill him, and his wife's opinion of you falls, and she says so" {
    const t = try Told.init(gpa, &.{
        \\facts (world):
        \\  opinion(person):  int
        \\  killed(person):   bool   (game)
        \\  furious:          bool
        \\== village (rules)
        \\= grief    when { killed(hank) }
        \\  ~ opinion(marta) -= 50
        \\= furor    when { opinion(marta) < 0 }
        \\  ~ furious = true
        \\== talk
        \\{ opinion(marta) < 0 }
        \\  She will not look at you.
        \\{ else }
        \\  She nods.
        \\-> end
    }, .{}, &.{}, Village{});
    defer t.deinit();
    var owners: [facts.max_scopes]u64 = @splat(0);
    var rules: react.Rules = try .init(gpa, &t.story, t.memory.store(), &t.host, &owners, .{});
    defer rules.deinit();
    try settle(t, &rules);
    // someone else killed: no rule reads that key, so none is evaluated
    try t.memory.setKey(t.fact("killed"), 3, .{ .boolean = true });
    _ = try rules.step();
    try std.testing.expectEqual(@as(usize, 0), rules.watch.evaluated.items.len);
    try t.memory.setKey(t.fact("killed"), 1, .{ .boolean = true });
    try settle(t, &rules);
    try std.testing.expectEqual(@as(i64, -50), t.memory.getKey(t.fact("opinion"), 2).int);
    try std.testing.expect(t.memory.get(t.fact("furious")).boolean);
    try t.session.start(.fromRaw(0), t.section("talk"));
    try t.line("She will not look at you.");
    try t.end();
}

test "honor is bounded: it stops at its ends however much it changes" {
    const t = try Told.init(gpa, &.{
        \\facts (world):
        \\  honor: int from -100 to 100
        \\== a
        \\~ honor += 80
        \\~ honor += 80
        \\{ honor = 100 } At the top.
        \\~ honor -= 500
        \\{ honor = -100 } At the bottom.
        \\-> end
    }, .{}, &.{}, testing.NoHost{});
    defer t.deinit();
    try t.session.start(.fromRaw(0), t.section("a"));
    try t.effects();
    try t.line("At the top.");
    try t.effects();
    try t.line("At the bottom.");
    try t.end();
    try std.testing.expectError(error.OutOfBounds, t.memory.set(t.fact("honor"), .{ .int = 101 }));
}

const quest_schema: check.Schema = .{ .keys = &.{.{ .name = "title", .on = .{ .section = true }, .value = .text, .count = .one }} };

test "translation: a title in the string table, a plural that falls back to other, a cast member's gender" {
    const t = try Told.init(gpa, &.{
        \\cast:
        \\  marta  "Marta"   # gender feminine
        \\facts (world):
        \\  pelts: int
        \\== a          # title "The pelts"
        \\MARTA: You have {pelts -> one: a pelt | other: {pelts} pelts}.
        \\{marta -> feminine: She | masculine: He | other: They} takes them.
        \\-> end
    }, .{ .schema = &quest_schema }, &.{}, testing.NoHost{});
    defer t.deinit();
    const title = t.story.tagNamed(t.story.section(t.section("a")).tags, "title").?;
    const line = t.story.tagValue(title.values.start).line.?;
    try std.testing.expectEqualStrings("The pelts", t.words.template(line).?);
    // a language whose 3 is `few`: English's words have no `few`, so they fall back to `other`
    const Few = struct {
        fn plural(_: ?*anyopaque, _: []const u8, n: i64) []const u8 {
            return if (n == 1) "one" else if (n < 5) "few" else "many";
        }
    };
    t.session.deinit();
    t.session = try .init(gpa, &t.story, &t.words, t.memory.store(), &t.host, .{ .language = .{ .plural = Few.plural } });
    try t.memory.set(t.fact("pelts"), .{ .int = 3 });
    try t.session.start(.fromRaw(0), t.section("a"));
    try t.line("You have 3 pelts.");
    try t.line("She takes them.");
    try t.end();
}
