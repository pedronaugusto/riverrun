//! The run layer's tests: stories built by hand and told step by step.

const std = @import("std");
const facts = @import("../facts.zig");
const story = @import("../story.zig");
const Session = @import("Session.zig");
const testing = @import("testing.zig");
const run_host = @import("host.zig");

const Builder = story.Builder;
const Term = story.Term;
const Told = testing.Told;
const say = testing.say;
const gpa = std.testing.allocator;

// kitchen_1985: a letter with a value and words chosen by a condition, the
// father's "Go.", a gather the choices return to, a once-only choice, one
// closed until `carried has play`, a sticky one whose line carries an
// effect, a jump to the fork, a choice gated by a query, effects, the end.
fn kitchen() !testing.Built {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const life_scope = try b.scope("life");
    const player = try b.scope("player");
    const sides = try b.enumeration(&.{ "stay", "go" });
    const memories = try b.enumeration(&.{ "play", "gave", "hands" });
    const life = try b.fact(.{ .name = "life", .scope = life_scope, .kind = .one_of, .enumeration = sides });
    const carried = try b.fact(.{ .name = "carried", .scope = player, .kind = .set_of, .enumeration = memories });
    const dad = try b.castMember(.{ .name = "dad", .display = try b.line("cast.dad", "Dad") });
    const lived = try b.externFn("lived", &.{.{ .kind = .one_of, .enumeration = sides }}, .{ .kind = .boolean }, false);
    const go = Term.item(sides.raw(), 1);
    const kitchen_s = try testing.scene(&b, "kitchen_1985");
    const fork_s = try testing.scene(&b, "fork_1985");

    const ask = try b.reserve();
    const offer = try b.reserve();
    const letter = try b.text(try b.line("letter", "The last bus north leaves at {0}. {1:You came all this way.|You came.}"), &.{
        .{ .kind = .value, .expr = try b.expr(&.{.of(.text, try b.literal("22:40"))}) },
        .{ .kind = .choose, .expr = try b.expr(&.{ .of(.fact, life.raw()), go, .of(.eq, 0) }), .arity = 2 },
    });
    const go_line = try b.node(.{ .step = .{ .line = .{ .text = try testing.words(&b, "go", "Go."), .speaker = dad, .next = ask } } });
    b.enter(kitchen_s, try b.node(.{ .step = .{ .line = .{ .text = letter, .next = go_line } } }));
    b.define(ask, .{ .step = .{ .gather = .{ .visits = try b.visits("kitchen_1985.ask"), .next = offer } } });
    const leave = try b.node(.{ .step = .{ .jump = fork_s } });
    const kept = try b.effectList(&.{.{ .add = .{ .fact = carried, .item = 2 } }});
    const go_on = try b.node(.{ .step = .{ .line = .{ .text = try testing.words(&b, "go_on", "Go on. Go."), .speaker = dad, .effects = kept, .next = leave } } });
    b.define(offer, .{ .step = .{ .choices = .{ .choices = try b.choiceList(&.{
        .{ .text = try testing.words(&b, "shop", "Who'll run the shop?"), .visits = try b.visits("shop"), .target = try say(&b, "ran", "I ran it before you could walk.", ask) },
        .{
            .text = try testing.words(&b, "play", "You could still play, Dad."),
            .cond = try b.expr(&.{ .of(.fact, carried.raw()), Term.item(memories.raw(), 0), .of(.has, 0) }),
            .visits = try b.visits("play"),
            .target = try say(&b, "listen", "Who'd listen?", ask),
        },
        .{ .text = try testing.words(&b, "case", "Pick up the case."), .sticky = true, .visits = try b.visits("case"), .target = go_on },
    }) } } });

    const end = try b.node(.{ .step = .end });
    const board = try b.node(.{ .step = .{ .effects = .{ .effects = try b.effectList(&.{.{ .set = .{ .fact = life, .value = try b.expr(&.{go}) } }}), .next = end } } });
    const unlived = try b.expr(&.{ go, .of(.query, lived.raw()), .of(.not, 0) });
    b.enter(fork_s, try b.node(.{ .step = .{ .choices = .{ .choices = try b.choiceList(&.{
        .{ .text = try testing.words(&b, "get_on", "Get on"), .cond = unlived, .visits = try b.visits("get_on"), .target = board },
    }), .next = end } } }));
    return testing.finish(&b, gpa);
}

test "kitchen_1985 is told step by step: lines, choices open and closed, a gather, a jump, the end" {
    var lives: testing.Lives = .{};
    const t = try Told.init(gpa, try kitchen(), &lives, testing.Lives.impls);
    defer t.deinit();
    const s = &t.session;
    const flow: Session.FlowId = .fromRaw(0);
    try s.start(flow, t.section("kitchen_1985"));
    try t.expectLine(0, "The last bus north leaves at 22:40. You came.");
    const go = (try s.next(flow)).line;
    try std.testing.expectEqualStrings("Dad", s.speaker(go.speaker.?).?);

    var offered = (try s.next(flow)).choices;
    try std.testing.expectEqual(@as(usize, 3), offered.len);
    try std.testing.expect(offered[0].open and !offered[1].open and offered[2].open);
    try std.testing.expectEqualStrings("You could still play, Dad.", offered[1].text);
    try std.testing.expectError(error.AwaitingChoice, s.next(flow));
    try std.testing.expectError(error.ChoiceClosed, s.choose(flow, 1));
    try std.testing.expectError(error.NoSuchChoice, s.choose(flow, 3));
    try s.choose(flow, 0);
    try t.expectLine(0, "I ran it before you could walk.");

    offered = (try s.next(flow)).choices;
    try std.testing.expectEqual(@as(usize, 2), offered.len);
    try std.testing.expectEqualStrings("Pick up the case.", offered[1].text);
    try s.choose(flow, 1);
    const last = (try s.next(flow)).line;
    try std.testing.expectEqualStrings("Go on. Go.", last.text);
    try std.testing.expectEqual(@as(usize, 1), last.effects.len);
    try std.testing.expect(t.memory.get(t.fact("carried")).set_of.count() == 0);

    offered = (try s.next(flow)).choices;
    try std.testing.expect(offered[0].open);
    try std.testing.expect(lives.asked > 0);
    try s.choose(flow, 0);
    const board = (try s.next(flow)).effects;
    try std.testing.expectEqual(@as(u16, 1), board[0].set.value.one_of);
    try t.expectEnd(0);
    try t.expectEnd(0);
    try std.testing.expectEqual(@as(i64, 2), t.memory.get(t.fact("visits:kitchen_1985.ask")).int);
}

test "a choice opens when the facts say so, and a lived life closes the fork" {
    var lives: testing.Lives = .{ .lived = true };
    const t = try Told.init(gpa, try kitchen(), &lives, testing.Lives.impls);
    defer t.deinit();
    const s = &t.session;
    const flow: Session.FlowId = .fromRaw(0);
    var carried: facts.Set = .empty;
    carried.set(0);
    try t.memory.set(t.fact("carried"), .{ .set_of = carried });
    try t.memory.set(t.fact("life"), .{ .one_of = 1 });
    try s.start(flow, t.section("kitchen_1985"));
    try t.expectLine(0, "The last bus north leaves at 22:40. You came all this way.");
    _ = try t.line(0);
    const offered = (try s.next(flow)).choices;
    try std.testing.expect(offered[1].open);
    try s.choose(flow, 2);
    _ = try t.line(0);
    // Every choice at the fork is closed, so the flow goes past them.
    try t.expectEnd(0);
}

test "a line's effects are handed over with it and applied only by the host" {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const player = try b.scope("player");
    const memories = try b.enumeration(&.{ "play", "gave" });
    const carried = try b.fact(.{ .name = "carried", .scope = player, .kind = .set_of, .enumeration = memories });
    const hide = try testing.scene(&b, "hide_1969");
    const listen = try say(&b, "listen", "Who'd listen?", null);
    const effects = try b.effectList(&.{.{ .add = .{ .fact = carried, .item = 0 } }});
    b.enter(hide, try b.node(.{ .step = .{ .line = .{ .text = try testing.words(&b, "play", "You could still play, Frank."), .effects = effects, .next = listen } } }));
    const t = try Told.plain(gpa, try testing.finish(&b, gpa));
    defer t.deinit();
    try t.session.start(.fromRaw(0), t.section("hide_1969"));
    const heard = (try t.session.next(.fromRaw(0))).line;
    try std.testing.expect(t.memory.get(t.fact("carried")).set_of.count() == 0);
    _ = try facts.apply(t.memory.store(), heard.effects[0]);
    try std.testing.expect(t.memory.get(t.fact("carried")).set_of.isSet(0));
    try t.expectLine(0, "Who'd listen?");
    try t.expectEnd(0);
}

test "an int's change is handed over with its amount worked out" {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const life = try b.scope("life");
    const points = try b.fact(.{ .name = "ryuji_points", .scope = life, .kind = .int });
    const ramen = try testing.scene(&b, "ramen");
    const effects = try b.effectList(&.{
        .{ .change = .{ .fact = points, .by = try b.expr(&.{.of(.int, try b.int(2))}) } },
        .{ .change = .{ .fact = points, .by = try b.expr(&.{.of(.int, try b.int(-5))}) } },
    });
    b.enter(ramen, try b.node(.{ .step = .{ .line = .{ .text = try testing.words(&b, "sure", "Sure."), .effects = effects } } }));
    const t = try Told.plain(gpa, try testing.finish(&b, gpa));
    defer t.deinit();
    try t.session.start(.fromRaw(0), t.section("ramen"));
    const said = (try t.session.next(.fromRaw(0))).line;
    try std.testing.expectEqual(@as(i64, 2), said.effects[0].change.by);
    for (said.effects) |e| _ = try facts.apply(t.memory.store(), e);
    try std.testing.expectEqual(@as(i64, -3), t.memory.get(t.fact("ryuji_points")).int);
}

// A pool of the wake's night: a plain candidate, one for the front room, one
// for the front room at ten; and a pool of two equals.
fn night() !testing.Built {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const life = try b.scope("life");
    const rooms = try b.enumeration(&.{ "front", "kitchen" });
    const room = try b.fact(.{ .name = "room", .scope = life, .kind = .one_of, .enumeration = rooms, .role = .game });
    const hour = try b.fact(.{ .name = "hour", .scope = life, .kind = .int, .role = .game });
    const at_front = [_]Term{ .of(.fact, room.raw()), Term.item(rooms.raw(), 0), .of(.eq, 0) };
    const at_ten = [_]Term{ .of(.fact, hour.raw()), .of(.int, try b.int(22)), .of(.eq, 0) };
    const front_at_ten = [_]Term{ at_front[0], at_front[1], at_front[2], at_ten[0], at_ten[1], at_ten[2], .of(.@"and", 0) };
    const night_s = try b.section(.{ .name = "night", .kind = .pool, .visits = try b.visits("night") });
    try b.candidate(night_s, .{ .name = "plain", .entry = try say(&b, "plain", "The house is quiet.", null), .visits = try b.visits("night.plain"), .seen = try b.state("night.plain") });
    try b.candidate(night_s, .{ .name = "front", .when = try b.expr(&at_front), .entry = try say(&b, "front", "The front room is full.", null), .visits = try b.visits("night.front"), .seen = try b.state("night.front") });
    try b.candidate(night_s, .{ .name = "glasses", .when = try b.expr(&front_at_ten), .entry = try say(&b, "glasses", "Her reading glasses, folded.", null), .visits = try b.visits("night.glasses"), .seen = try b.state("night.glasses") });
    const twins = try b.section(.{ .name = "twins", .kind = .pool, .visits = try b.visits("twins") });
    try b.candidate(twins, .{ .name = "a", .entry = try say(&b, "a", "A.", null), .visits = try b.visits("twins.a"), .seen = try b.state("twins.a") });
    try b.candidate(twins, .{ .name = "b", .entry = try say(&b, "b", "B.", null), .visits = try b.visits("twins.b"), .seen = try b.state("twins.b") });
    const eulogy = try b.section(.{ .name = "eulogy", .kind = .pool, .pick = 2, .visits = try b.visits("eulogy") });
    try b.candidate(eulogy, .{ .name = "one", .entry = try say(&b, "one", "One.", null), .visits = try b.visits("eulogy.one"), .seen = try b.state("eulogy.one") });
    try b.candidate(eulogy, .{ .name = "two", .when = try b.expr(&at_front), .entry = try say(&b, "two", "Two.", null), .visits = try b.visits("eulogy.two"), .seen = try b.state("eulogy.two") });
    try b.candidate(eulogy, .{ .name = "three", .when = try b.expr(&front_at_ten), .entry = try say(&b, "three", "Three.", null), .visits = try b.visits("eulogy.three"), .seen = try b.state("eulogy.three") });
    return testing.finish(&b, gpa);
}

test "a pool gives the most specific candidate that holds, then takes turns among equals" {
    const t = try Told.plain(gpa, try night());
    defer t.deinit();
    const s = &t.session;
    const flow: Session.FlowId = .fromRaw(0);
    try s.start(flow, t.section("night"));
    try t.expectLine(0, "The house is quiet.");
    try t.expectEnd(0);
    try t.memory.set(t.fact("room"), .{ .one_of = 0 });
    try s.start(flow, t.section("night"));
    try t.expectLine(0, "The front room is full.");
    try t.memory.set(t.fact("hour"), .{ .int = 22 });
    try s.start(flow, t.section("night"));
    try t.expectLine(0, "Her reading glasses, folded.");

    var said: [4][]const u8 = undefined;
    for (&said) |*w| {
        try s.start(flow, t.section("twins"));
        w.* = try t.memory.gpa.dupe(u8, try t.line(0));
    }
    defer for (said) |w| gpa.free(w);
    try std.testing.expect(!std.mem.eql(u8, said[0], said[1]));
    try std.testing.expectEqualStrings(said[0], said[2]);
    try std.testing.expectEqualStrings(said[1], said[3]);

    try s.start(flow, t.section("eulogy"));
    try t.expectLine(0, "Three.");
    try t.expectLine(0, "Two.");
    try t.expectEnd(0);
}

// One line of each alternative, a scene each.
fn alternatives() !testing.Built {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    inline for (.{ .{ "sequence", story.SlotKind.sequence }, .{ "cycle", story.SlotKind.cycle }, .{ "once", story.SlotKind.once }, .{ "shuffle", story.SlotKind.shuffle } }) |alt| {
        const sec = try testing.scene(&b, alt[0]);
        const t = try b.text(try b.line(alt[0], "{0:a|b|c}"), &.{.{ .kind = alt[1], .arity = 3, .state = try b.state(alt[0]) }});
        b.enter(sec, try b.node(.{ .step = .{ .line = .{ .text = t } } }));
    }
    return testing.finish(&b, gpa);
}

fn tellAgain(t: *Told, section: []const u8) ![]const u8 {
    try t.session.start(.fromRaw(0), t.section(section));
    return t.line(0);
}

test "alternatives go in sequence, in a cycle, once, and shuffled by the seed" {
    const t = try Told.plain(gpa, try alternatives());
    defer t.deinit();
    for ([_][]const u8{ "a", "b", "c", "c" }) |w| try std.testing.expectEqualStrings(w, try tellAgain(t, "sequence"));
    for ([_][]const u8{ "a", "b", "c", "a" }) |w| try std.testing.expectEqualStrings(w, try tellAgain(t, "cycle"));
    for ([_][]const u8{ "a", "b", "c", "" }) |w| try std.testing.expectEqualStrings(w, try tellAgain(t, "once"));
    try t.memory.set(t.story.seed(), .{ .int = 7 });
    for (0..2) |_| {
        var seen: [3]bool = @splat(false);
        for (0..3) |_| seen[(try tellAgain(t, "shuffle"))[0] - 'a'] = true;
        try std.testing.expect(seen[0] and seen[1] and seen[2]);
    }
}

test "the same story, facts and choices tell the same way" {
    var said: [2][9]u8 = undefined;
    for (&said) |*run| {
        const t = try Told.plain(gpa, try alternatives());
        defer t.deinit();
        try t.memory.set(t.story.seed(), .{ .int = 41 });
        for (run) |*c| c.* = (try tellAgain(t, "shuffle"))[0];
    }
    try std.testing.expectEqualSlices(u8, &said[0], &said[1]);
}

// A scene that calls an aside and goes on, a scene with choices, and the aside.
fn calls() !testing.Built {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const main = try testing.scene(&b, "main");
    const aside = try testing.scene(&b, "aside");
    const ask = try testing.scene(&b, "ask");
    b.enter(aside, try say(&b, "two", "two", try b.node(.{ .step = .ret })));
    const three = try say(&b, "three", "three", null);
    b.enter(main, try say(&b, "one", "one", try b.node(.{ .step = .{ .call = .{ .section = aside, .next = three } } })));
    const done = try say(&b, "done", "done", null);
    const choices = try b.node(.{ .step = .{ .choices = .{ .choices = try b.choiceList(&.{
        .{ .text = try testing.words(&b, "yes", "Yes"), .visits = try b.visits("yes"), .target = done },
    }) } } });
    b.enter(ask, try say(&b, "first", "first", choices));
    return testing.finish(&b, gpa);
}

test "a call returns to the step after it, and an interruption to where the flow was" {
    const t = try Told.plain(gpa, try calls());
    defer t.deinit();
    const s = &t.session;
    const flow: Session.FlowId = .fromRaw(0);
    try s.start(flow, t.section("main"));
    for ([_][]const u8{ "one", "two", "three" }) |w| try t.expectLine(0, w);
    try t.expectEnd(0);

    try s.start(flow, t.section("main"));
    try t.expectLine(0, "one");
    try s.interrupt(flow, t.section("aside"));
    try t.expectLine(0, "two");
    try t.expectLine(0, "two");
    try t.expectLine(0, "three");

    try s.start(flow, t.section("ask"));
    try t.expectLine(0, "first");
    _ = (try s.next(flow)).choices;
    try s.interrupt(flow, t.section("aside"));
    try t.expectLine(0, "two");
    try std.testing.expectEqual(@as(usize, 1), (try s.next(flow)).choices.len);
    try s.choose(flow, 0);
    try t.expectLine(0, "done");
}

test "two flows tell over the same facts" {
    const t = try Told.plain(gpa, try calls());
    defer t.deinit();
    const s = &t.session;
    try s.start(.fromRaw(0), t.section("main"));
    try s.start(.fromRaw(1), t.section("main"));
    try t.expectLine(0, "one");
    try t.expectLine(1, "one");
    try t.expectLine(1, "two");
    try t.expectLine(0, "two");
    try std.testing.expectEqual(@as(i64, 2), t.memory.get(t.fact("visits:aside")).int);
    try s.stop(.fromRaw(1));
    try std.testing.expectError(error.FlowNotStarted, s.next(.fromRaw(1)));
    try t.expectLine(0, "three");
}

// `~ persuaded = persuade(12)` between two effects, then a branch on it.
fn persuasion() !testing.Built {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const life = try b.scope("life");
    const answers = try b.enumeration(&.{ "yes", "no" });
    const persuaded = try b.fact(.{ .name = "persuaded", .scope = life, .kind = .one_of, .enumeration = answers });
    const met = try b.fact(.{ .name = "met", .scope = life, .kind = .boolean });
    const tries = try b.fact(.{ .name = "tries", .scope = life, .kind = .int });
    const persuade = try b.externFn("persuade", &.{.{ .kind = .int }}, .{ .kind = .one_of, .enumeration = answers }, true);
    const talk = try testing.scene(&b, "talk");
    const agrees = try say(&b, "agrees", "She agrees.", null);
    const refuses = try say(&b, "refuses", "She doesn't.", null);
    const branch = try b.node(.{ .step = .{ .branch = .{ .cond = try b.expr(&.{ .of(.fact, persuaded.raw()), Term.item(answers.raw(), 0), .of(.eq, 0) }), .then = agrees, .otherwise = refuses } } });
    b.enter(talk, try b.node(.{ .step = .{ .effects = .{ .effects = try b.effectList(&.{
        .{ .set = .{ .fact = met, .value = try b.expr(&.{.of(.true, 0)}) } },
        .{ .call = .{ .action = persuade, .args = try b.expr(&.{.of(.int, try b.int(12))}), .result = persuaded } },
        .{ .set = .{ .fact = tries, .value = try b.expr(&.{.of(.int, try b.int(1))}) } },
    }), .next = branch } } }));
    return testing.finish(&b, gpa);
}

/// Persuades whoever is asked when the difficulty is below 20.
const Persuader = struct {
    tried: usize = 0,

    const impls = .{ .persuade = persuade };

    fn persuade(p: *Persuader, _: run_host.Context, difficulty: i64) u16 {
        p.tried += 1;
        return if (difficulty < 20) 0 else 1;
    }
};

test "an action with an outcome holds its flow until the host gives the outcome" {
    var persuader: Persuader = .{};
    const t = try Told.init(gpa, try persuasion(), &persuader, Persuader.impls);
    defer t.deinit();
    const s = &t.session;
    const flow: Session.FlowId = .fromRaw(0);
    try s.start(flow, t.section("talk"));
    try std.testing.expectError(error.NoOutcomePending, s.outcome(flow, .{ .one_of = 0 }));
    try std.testing.expect((try s.next(flow)).effects[0].set.value.boolean);
    const asked = (try s.next(flow)).action;
    try std.testing.expectEqual(@as(i64, 12), asked.call.args[0].int);
    try std.testing.expect(asked.call.result.?.eql(t.fact("persuaded")));
    try std.testing.expectError(error.AwaitingOutcome, s.next(flow));
    try std.testing.expectError(error.WrongKind, s.outcome(flow, .{ .int = 1 }));
    const answer = (try t.host.perform(asked.call, asked.context)).?;
    try std.testing.expectEqual(@as(usize, 1), persuader.tried);
    try s.outcome(flow, answer);
    try std.testing.expectEqual(@as(i64, 1), (try s.next(flow)).effects[0].set.value.int);
    try t.expectLine(0, "She agrees.");
    try t.expectEnd(0);
}

// Stories that break a bound: calls without end, jumps that say nothing, too many outcomes, a pool too generous.
fn unbounded() !testing.Built {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const life = try b.scope("life");
    const done = try b.fact(.{ .name = "done", .scope = life, .kind = .boolean });
    const check = try b.externFn("check", &.{}, .{ .kind = .boolean }, true);
    const deeper = try testing.scene(&b, "deeper");
    b.enter(deeper, try b.node(.{ .step = .{ .call = .{ .section = deeper } } }));
    const spin = try testing.scene(&b, "spin");
    b.enter(spin, try b.node(.{ .step = .{ .jump = spin } }));
    var nine: [9]story.Effect = undefined;
    for (&nine) |*e| e.* = .{ .call = .{ .action = check, .args = .empty, .result = done } };
    const owing = try testing.scene(&b, "owing");
    b.enter(owing, try b.node(.{ .step = .{ .line = .{ .text = try testing.words(&b, "owing", "Nine checks."), .effects = try b.effectList(&nine) } } }));
    const generous = try b.section(.{ .name = "generous", .kind = .pool, .pick = 9, .visits = try b.visits("generous") });
    try b.candidate(generous, .{ .name = "only", .entry = try say(&b, "only", "Only.", null), .visits = try b.visits("generous.only"), .seen = try b.state("generous.only") });
    return testing.finish(&b, gpa);
}

/// Answers every check true.
const Checker = struct {
    const impls = .{ .check = check };

    fn check(_: *Checker, _: run_host.Context) bool {
        return true;
    }
};

test "every bound is a named error" {
    var checker: Checker = .{};
    const t = try Told.init(gpa, try unbounded(), &checker, Checker.impls);
    defer t.deinit();
    const s = &t.session;
    const flow: Session.FlowId = .fromRaw(0);
    try std.testing.expectError(error.TooManyFlows, s.start(.fromRaw(Session.max_flows), t.section("spin")));
    try std.testing.expectError(error.FlowNotStarted, s.next(.fromRaw(3)));
    try s.start(flow, t.section("owing"));
    try std.testing.expectError(error.NoChoicePending, s.choose(flow, 0));
    try s.start(flow, t.section("deeper"));
    try std.testing.expectError(error.CallTooDeep, s.next(flow));
    try s.start(flow, t.section("spin"));
    s.options.max_walk = 1000;
    try std.testing.expectError(error.NoProgress, s.next(flow));
    try s.start(flow, t.section("owing"));
    try std.testing.expectError(error.TooManyOutcomes, s.next(flow));
    try std.testing.expectError(error.PickTooLarge, s.start(flow, t.section("generous")));
}

// A conversation in three lines; `before` puts a line ahead of them, `rename` moves the section.
fn conversation(before: bool, name: []const u8) !testing.Built {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const talk = try testing.scene(&b, name);
    const c = try say(&b, "c", "C.", null);
    const bb = try say(&b, "b", "B.", c);
    const a = try say(&b, "a", "A.", bb);
    b.enter(talk, if (before) try say(&b, "z", "Z.", a) else a);
    return testing.finish(&b, gpa);
}

test "where the flows are survives a recompiled story, found by line id" {
    const saved = blk: {
        const t = try Told.plain(gpa, try conversation(false, "talk"));
        defer t.deinit();
        try t.session.start(.fromRaw(0), t.section("talk"));
        try t.expectLine(0, "A.");
        const same = try t.session.saveCursors(gpa);
        defer gpa.free(same);
        try t.session.stop(.fromRaw(0));
        const report = try t.session.restoreCursors(gpa, same);
        try std.testing.expect(report.same_story);
        try std.testing.expectEqual(@as(u8, 0), report.moved);
        try t.expectLine(0, "B.");
        try t.session.start(.fromRaw(0), t.section("talk"));
        try t.expectLine(0, "A.");
        break :blk try t.session.saveCursors(gpa);
    };
    defer gpa.free(saved);

    const moved = try Told.plain(gpa, try conversation(true, "talk"));
    defer moved.deinit();
    const report = try moved.session.restoreCursors(gpa, saved);
    try std.testing.expect(!report.same_story);
    try std.testing.expectEqual(@as(u8, 1), report.moved);
    try moved.expectLine(0, "B.");
    try moved.expectLine(0, "C.");

    const gone = try Told.plain(gpa, try conversation(false, "elsewhere"));
    defer gone.deinit();
    try std.testing.expectEqual(@as(u8, 1), (try gone.session.restoreCursors(gpa, saved)).lost);
    try std.testing.expectError(error.FlowNotStarted, gone.session.next(.fromRaw(0)));
    try std.testing.expectError(error.BadCursors, gone.session.restoreCursors(gpa, saved[0 .. saved.len - 1]));
}

test "any bytes restore as flows or are refused, never crash" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [512]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];
            var lives: testing.Lives = .{};
            const t = try Told.init(gpa, try kitchen(), &lives, testing.Lives.impls);
            defer t.deinit();
            _ = t.session.restoreCursors(gpa, bytes) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return,
            };
            for (0..8) |_| _ = t.session.next(.fromRaw(0)) catch break;
        }
    }.one, .{});
}

test "any choices, interruptions and outcomes over a valid story are told or refused, never crash" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [256]u8 = undefined;
            const ops = input[0..smith.sliceWithHash(&input, 0)];
            var lives: testing.Lives = .{};
            var persuader: Persuader = .{};
            const told = [_]*Told{ try Told.init(gpa, try kitchen(), &lives, testing.Lives.impls), try Told.init(gpa, try persuasion(), &persuader, Persuader.impls), try Told.plain(gpa, try night()) };
            defer for (told) |t| t.deinit();
            for (ops, 0..) |op, i| {
                const t = told[i % told.len];
                try drive(t, op);
            }
        }
    }.one, .{});
}

fn drive(t: *Told, op: u8) !void {
    const s = &t.session;
    const flow: Session.FlowId = .fromRaw(op >> 6);
    const section: story.SectionId = .fromRaw(op % t.story.len(.sections));
    const result = switch (op % 5) {
        0 => s.start(flow, section),
        1, 2 => if (s.next(flow)) |_| {} else |err| err,
        3 => s.choose(flow, op % 4),
        else => if (op % 2 == 0) s.interrupt(flow, section) else s.outcome(flow, .{ .one_of = op % 3 }),
    };
    result catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    };
}

test "a host binds every extern by name and signature, or says what it lacks" {
    var built = try kitchen();
    defer built.deinit(gpa);
    const s: story.Story = try .init(built.graph, .{});
    var problems: std.ArrayList(run_host.Problem) = .empty;
    defer problems.deinit(gpa);
    var lives: testing.Lives = .{};
    try std.testing.expectError(error.UnboundExtern, run_host.Host.bind(gpa, &s, &lives, .{}, &problems));
    try std.testing.expectEqualStrings("lived", problems.items[0].name);
    problems.clearRetainingCapacity();
    const Wrong = struct {
        fn lived(_: *testing.Lives, _: run_host.Context, _: i64) bool {
            return false;
        }
    };
    try std.testing.expectError(error.MismatchedExtern, run_host.Host.bind(gpa, &s, &lives, .{ .lived = Wrong.lived }, &problems));
    try std.testing.expectEqual(@as(@TypeOf(problems.items[0].why), .mismatched), problems.items[0].why);
    var host = try run_host.Host.bind(gpa, &s, &lives, testing.Lives.impls, null);
    defer host.deinit();
    try std.testing.expect(host.serves(&s));

    const words: story.Strings = try .init(built.words, .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var memory: facts.Memory = try .init(gpa, try s.schema(arena.allocator()));
    defer memory.deinit();
    try std.testing.expectError(error.HostNotBound, Session.init(gpa, &s, &words, memory.store(), &run_host.Host.none, .{}));
}

test "a query is told which flow asked and whose facts it is about" {
    var lives: testing.Lives = .{};
    const t = try Told.init(gpa, try kitchen(), &lives, testing.Lives.impls);
    defer t.deinit();
    const s = &t.session;
    const flow: Session.FlowId = .fromRaw(5);
    s.setOwner(t.story.fact(t.fact("carried")).scope, 77);
    var carried: facts.Set = .empty;
    carried.set(0);
    try t.memory.set(t.fact("carried"), .{ .set_of = carried });
    try s.start(flow, t.section("fork_1985"));
    _ = (try s.next(flow)).choices;
    try std.testing.expectEqual(@as(u8, 5), lives.flow);
    try std.testing.expectEqual(@as(u64, 77), lives.owner);
}

test "the things a story names are resolved to the host's handles once, at load" {
    var host: run_host.Host = .none;
    defer host.deinit();
    const Items = struct {
        fn resolve(_: ?*anyopaque, kind: []const u8, id: []const u8) ?u64 {
            if (!std.mem.eql(u8, kind, "item_kind")) return null;
            if (std.mem.eql(u8, id, "wolf_pelt")) return 0xBEEF;
            return null;
        }
    };
    const resolver: run_host.Resolver = .{ .user = null, .resolve = Items.resolve };
    var problems: std.ArrayList(run_host.Problem) = .empty;
    defer problems.deinit(gpa);
    try std.testing.expectError(error.UnknownRef, host.resolve(gpa, &.{ .{ .kind = "item_kind", .id = "wolf_pelt" }, .{ .kind = "item_kind", .id = "bear_pelt" } }, resolver, &problems));
    try std.testing.expectEqualStrings("bear_pelt", problems.items[0].name);
    try host.resolve(gpa, &.{.{ .kind = "item_kind", .id = "wolf_pelt" }}, resolver, null);
    try std.testing.expectEqual(@as(u64, 0xBEEF), host.refs[0]);
}

test "a story's things are resolved once, compared as handles, and saved by their ids" {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const life = try b.scope("life");
    const person = try b.refKind("person");
    const target = try b.fact(.{ .name = "target", .scope = life, .kind = .ref, .ref_kind = person, .role = .game });
    const hunt = try testing.scene(&b, "hunt");
    const found = try testing.say(&b, "found", "It is Margaret.", null);
    const nobody = try testing.say(&b, "nobody", "Nobody.", null);
    const is_margaret = try b.expr(&.{ .of(.fact, target.raw()), .of(.thing, try b.thing(person, "margaret")), .of(.eq, 0) });
    b.enter(hunt, try b.node(.{ .step = .{ .branch = .{ .cond = is_margaret, .then = found, .otherwise = nobody } } }));
    var built = try testing.finish(&b, gpa);
    defer built.deinit(gpa);
    const s: story.Story = try .init(built.graph, .{});
    const words: story.Strings = try .init(built.words, .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var memory: facts.Memory = try .init(gpa, try s.schema(arena.allocator()));
    defer memory.deinit();

    var host: run_host.Host = .none;
    defer host.deinit();
    try std.testing.expect(!host.serves(&s));
    const People = struct {
        fn resolve(_: ?*anyopaque, kind: []const u8, id: []const u8) ?u64 {
            return if (std.mem.eql(u8, kind, "person") and std.mem.eql(u8, id, "margaret")) 41 else null;
        }
    };
    try host.resolveStory(gpa, &s, .{ .user = null, .resolve = People.resolve }, null);
    try std.testing.expect(host.serves(&s));
    var session: Session = try .init(gpa, &s, &words, memory.store(), &host, .{});
    defer session.deinit();

    try session.start(.fromRaw(0), s.sectionNamed("hunt").?);
    try std.testing.expectEqualStrings("Nobody.", (try session.next(.fromRaw(0))).line.text);
    try memory.set(target, .{ .ref = 41 });
    try session.start(.fromRaw(0), s.sectionNamed("hunt").?);
    try std.testing.expectEqualStrings("It is Margaret.", (try session.next(.fromRaw(0))).line.text);

    const lookup: run_host.RefLookup = .{ .story = &s, .host = &host };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try facts.snapshot.writeNamed(&memory, &out.writer, life, s.hash(), lookup.names());
    try std.testing.expect(std.mem.find(u8, out.written(), "margaret") != null);
}

test "a builtin is answered by the package that owns it, and nothing else" {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const life = try b.scope("life");
    const day = try b.fact(.{ .name = "day", .scope = life, .kind = .int, .role = .clock });
    const since = try b.builtinCall("quest", "since", &.{ 0, day.raw() }, .int);
    const journal = try b.section(.{ .name = "journal", .kind = .other, .kind_name = "quest", .visits = try b.visits("journal") });
    const late = try testing.say(&b, "late", "Too late.", null);
    const soon = try testing.say(&b, "soon", "There is time.", null);
    const when = try b.expr(&.{ .of(.builtin, since), .of(.int, try b.int(3)), .of(.gt, 0) });
    b.enter(journal, try b.node(.{ .step = .{ .branch = .{ .cond = when, .then = late, .otherwise = soon } } }));
    const Cairn = struct {
        days: i64 = 5,
        fn call(user: ?*anyopaque, s: *const story.Story, index: u32, _: run_host.Context) error{BuiltinFailed}!facts.Value {
            const self: *@This() = @ptrCast(@alignCast(user)); // safe: the test's own pointer
            if (!std.mem.eql(u8, s.builtin(index).name, "since")) return error.BuiltinFailed;
            return .{ .int = self.days };
        }
    };
    var cairn: Cairn = .{};
    const t = try Told.plain(gpa, try testing.finish(&b, gpa));
    defer t.deinit();
    try t.session.start(.fromRaw(0), t.section("journal"));
    try std.testing.expectError(error.NoBuiltins, t.session.next(.fromRaw(0)));
    t.session.options.builtins = .{ .user = &cairn, .call = Cairn.call };
    try t.session.start(.fromRaw(0), t.section("journal"));
    try t.expectLine(0, "Too late.");
}
