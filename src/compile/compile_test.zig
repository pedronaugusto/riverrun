//! The compiler's tests: small stories, written as a writer writes them,
//! compiled and told by a session, so what is checked is what a player sees.

const std = @import("std");
const syntax = @import("../syntax.zig");
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
    }, .{ .kinds = &.{quest} }, &.{.{ .name = "cairn", .run = Pass.add }});
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

test "a pass that refuses the story says where, and one that fails saying nothing is named" {
    const Passes = struct {
        fn refuse(_: ?*anyopaque, c: *compile.Compiler) compile.Compiler.Error!void {
            const s = c.checked.sections[c.checked.section("pelts").?.raw()];
            try c.err(s.node.name.span, "`{s}` has no stage", .{s.name});
        }
        fn silent(_: ?*anyopaque, _: *compile.Compiler) compile.Compiler.Error!void {
            return error.PassFailed;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const quest: check.Kind = .{ .name = "quest" };
    const cases = .{
        .{ Passes.refuse, 1, "`pelts` has no stage" },
        .{ Passes.silent, 0, "`cairn`'s pass failed and said nothing of why" },
    };
    inline for (cases) |case| {
        var diags: syntax.Diagnostics = .{};
        defer diags.deinit(gpa);
        const tree = try arena.allocator().create(syntax.ast.File);
        tree.* = try syntax.parse(arena.allocator(), gpa, &diags, 0, "a.river", "== pelts (quest)\nHilde wants ten pelts.\n");
        var checked = try check.run(gpa, &diags, tree[0..1], .{ .kinds = &.{quest} });
        defer checked.deinit();
        try std.testing.expectEqual(@as(usize, 0), diags.errors());
        try std.testing.expectError(error.PassFailed, compile.run(gpa, &diags, &checked, .{ .passes = &.{.{ .name = "cairn", .run = case[0] }} }));
        try std.testing.expectEqual(@as(usize, 1), diags.errors());
        const d = diags.list.items[diags.list.items.len - 1];
        try std.testing.expectEqual(@as(u32, case[1]), d.span.line);
        try std.testing.expectEqualStrings(case[2], d.message);
    }
}

test "the facts a registered kind declares are compiled and saved as the story's own" {
    const quest = @import("../check/errors_test.zig").quest_kind;
    const t = try Told.init(gpa, &.{
        \\== pelts (quest)
        \\= asked
        \\= late    when { asked }
        \\== a
        \\{ pelts.late } Too late.
        \\-> end
    }, .{ .kinds = &.{quest} }, &.{}, testing.NoHost{});
    defer t.deinit();
    const late = t.fact("pelts.late");
    try std.testing.expectEqual(facts.Role.game, t.story.fact(late).role);
    try std.testing.expectEqualStrings("quests", t.story.scope(t.story.fact(late).scope));
    try t.memory.set(late, .{ .boolean = true });
    try t.session.start(.fromRaw(0), t.section("a"));
    try t.line("Too late.");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try facts.snapshot.write(&t.memory, &out.writer, t.story.fact(late).scope, t.story.hash());
    try std.testing.expect(std.mem.find(u8, out.written(), "pelts.late") != null);
    // the quest's package runs its sections, so no visit count is kept for them but what `seen` reads
    try std.testing.expectEqual(@as(?facts.FactId, null), t.story.section(t.section("pelts")).visits);
    try std.testing.expectEqual(@as(?facts.FactId, null), t.story.section(t.section("pelts.asked")).visits);
    try std.testing.expect(t.story.section(t.section("a")).visits != null);
    // a part is a section of its own, which knows the section it is part of
    try std.testing.expect(t.story.section(t.section("pelts.asked")).part_of.?.eql(t.section("pelts")));
    try std.testing.expect(t.story.section(t.section("a")).part_of == null);
}

test "a section kept per thing is evaluated for one, its roles given or read as facts" {
    const Pass = struct {
        var when: story.Range = .empty;
        // the quest's package compiles its stages' conditions, as cairn's pass does
        fn conditions(_: ?*anyopaque, c: *compile.Compiler) compile.Compiler.Error!void {
            for (c.checked.sections) |s| for (s.parts) |p| if (p.node.when) |*w| {
                when = try compile.condition(c, w);
            };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out = try testing.compiled(gpa, arena.allocator(), &.{
        \\== bounty (quest)   # repeat
        \\facts:
        \\  target: ref of person   (role)
        \\  asked: set of tom, danny
        \\= ask   when { asked has tom and target = danny }
        \\  ~ asked += danny
    }, .{ .kinds = &.{@import("../check/errors_test.zig").repeat_kind} }, &.{.{ .name = "cairn", .run = Pass.conditions }});
    defer out.deinit(gpa);
    const s: story.Story = try .init(out.graph, .{});
    var memory: facts.Memory = try .init(gpa, try s.schema(arena.allocator()));
    defer memory.deinit();
    const People = struct {
        fn resolve(_: ?*anyopaque, _: []const u8, id: []const u8) ?u64 {
            return if (std.mem.eql(u8, id, "danny")) 41 else 42;
        }
    };
    var host: run.Host = .none;
    defer host.deinit();
    try host.resolveStory(gpa, &s, .{ .user = null, .resolve = People.resolve }, null);
    const owners: [facts.max_scopes]u64 = @splat(0);
    const asked = s.factNamed("bounty.asked").?;
    const target = s.factNamed("bounty.target").?;
    var cx: run.eval.Context = .{ .story = &s, .store = memory.store(), .host = &host, .call = .{ .flow = run.no_flow, .owners = &owners, .this = 7 }, .arena = arena.allocator() };
    // the stage's effect writes the instance's own set
    const entry = s.node(s.section(s.sectionNamed("bounty.ask").?).entry.?).step.effects.effects;
    _ = try facts.apply(memory.store(), try run.eval.effect(cx, s.effect(entry.start)));
    try std.testing.expect(memory.getKey(asked, 7).set_of.isSet(1));
    try std.testing.expectEqual(@as(usize, 0), memory.getKey(asked, 8).set_of.count());
    var both = memory.getKey(asked, 7).set_of;
    both.set(0);
    try memory.setKey(asked, 7, .{ .set_of = both });
    // the role read as its fact, for this instance, then as what the evaluation is given
    try std.testing.expect(!try run.eval.condition(cx, Pass.when));
    try memory.setKey(target, 7, .{ .ref = 41 });
    try std.testing.expect(try run.eval.condition(cx, Pass.when));
    cx.roles = &.{.{ .fact = target, .value = .{ .ref = 42 } }};
    try std.testing.expect(!try run.eval.condition(cx, Pass.when));
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

test "a weighted pool draws by weight, the same draws in a replay" {
    const t = try Told.init(gpa, &.{
        \\== talk
        \\->> merchant
        \\-> talk
        \\== merchant (pool)
        \\= rumour    when { true }   # weight 3
        \\  They say the mill burned.
        \\= weather   when { true }   # weight 7
        \\  Rain again.
    }, .{}, &.{}, testing.NoHost{});
    defer t.deinit();
    try t.session.start(.fromRaw(0), t.section("talk"));
    var rumours: usize = 0;
    for (0..1000) |_| {
        const step = try t.session.next(.fromRaw(0));
        if (std.mem.eql(u8, step.line.text, "They say the mill burned.")) rumours += 1;
    }
    // three in ten, give or take what a thousand draws give
    try std.testing.expect(rumours > 240 and rumours < 360);
}

test "a migration runs once, when an older save loads, and never in a new game" {
    const t = try Told.init(gpa, &.{
        \\version: 2
        \\facts (world):
        \\  honor:  int from -100 to 100
        \\  karma:  int
        \\== fixes (rules)
        \\= karma_is_honor    # migrate 2
        \\  ~ honor += 10
        \\= noticed   when { honor > 50 }
        \\  ~ karma += 1
    }, .{}, &.{}, testing.NoHost{});
    defer t.deinit();
    var owners: [facts.max_scopes]u64 = @splat(0);
    var rules: react.Rules = try .init(gpa, &t.story, t.memory.store(), &t.host, &owners, .{});
    defer rules.deinit();
    // a save from version 1: its version fact says so
    try t.memory.set(t.story.versionFact(), .{ .int = 1 });
    const fired = try rules.migrate();
    try std.testing.expectEqual(@as(usize, 1), fired.len);
    for (fired[0].effects) |e| _ = try facts.apply(t.memory.store(), e);
    try std.testing.expectEqual(@as(i64, 10), t.memory.get(t.fact("honor")).int);
    try std.testing.expectEqual(@as(usize, 0), (try rules.migrate()).len);
    // a new game is of this version from the start
    try t.memory.set(t.story.versionFact(), .{ .int = 0 });
    try rules.start();
    try std.testing.expectEqual(@as(usize, 0), (try rules.migrate()).len);
}
