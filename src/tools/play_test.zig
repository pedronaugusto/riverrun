//! A story played as `riverrun play` plays it, written down: what the
//! game is given, in order, and what it gives back, pinned.

const std = @import("std");
const river = @import("riverrun-compiler");
const Manuscript = @import("Manuscript.zig");
const walk = @import("walk.zig");
const Play = @import("Play.zig");
const transcript = @import("transcript.zig");
const script = @import("script.zig");
const whole = @import("whole_test.zig");

const gpa = std.testing.allocator;
const check = river.check;

/// A story, compiled with `with` and played from its entry (or `from`) by `rows`: its transcript and how it ended.
pub const Played = struct {
    text: []u8,
    ending: script.Ending,

    pub fn deinit(p: *Played) void {
        gpa.free(p.text);
    }
};

pub const How = struct {
    /// Where to start, by name: the entry where null.
    from: ?[]const u8 = null,
    /// What the game has set at the start, as `:set` and `:wait` take it (`:set spot = door`).
    given: []const []const u8 = &.{},
};

pub fn played(with: river.Joined, pages: []const Manuscript.Page, how: How, rows: []const []const u8) !Played {
    var m, var out = try Manuscript.build(gpa, pages, with, .development);
    defer m.deinit();
    defer if (out) |*o| o.deinit(gpa);
    if (out == null) {
        for (m.diags.list.items) |d| std.debug.print("{s}\n", .{d.message});
        return error.TestStoryRefused;
    }
    const compiled = &out.?;
    var loaded: walk.Loaded = undefined;
    try loaded.init(gpa, compiled.graph, compiled.words);
    defer loaded.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const start = if (how.from) |name| loaded.story.sectionNamed(name).? else Play.entry(&m.checked.?, &loaded.story).?;
    var p: Play = undefined;
    try p.init(gpa, &loaded, .{ .start = start, .leads = try Play.leadsOf(a, with.options), .delivery = with.options.delivery, .running = with.running });
    defer p.deinit();
    const t: transcript.Transcript = .{ .play = &p, .files = m.files, .where = &compiled.where };
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    var given: std.ArrayList(Play.Input) = .empty;
    for (how.given) |row| {
        var why: []const u8 = "";
        try given.append(a, (try script.read(a, &p, row, &why)).?.input);
        try t.echo(&text.writer, row);
    }
    if (given.items.len > 0) try p.startWith(given.items);
    const list = try a.alloc(script.Row, rows.len);
    for (list, rows, 1..) |*r, row, n| r.* = .{ .text = row, .path = "script", .line = @intCast(n) };
    const ending = try script.run(gpa, &text.writer, &t, &p, list);
    return .{ .text = try text.toOwnedSlice(), .ending = ending };
}

fn expectPlayed(with: river.Joined, story: []const u8, rows: []const []const u8, ending: script.Ending, want: []const u8) !void {
    var p = try played(with, &.{.{ .path = "story.river", .text = story }}, .{}, rows);
    defer p.deinit();
    std.testing.expectEqualStrings(want, p.text) catch |e| {
        std.debug.print("--- got\n{s}", .{p.text});
        return e;
    };
    try std.testing.expectEqual(ending, p.ending);
}

const Plain = struct {
    const schema: check.Schema = .{ .keys = &.{
        .{ .name = "at", .on = .{ .line = true }, .value = .number },
        .{ .name = "how", .on = .{ .line = true }, .value = .text },
        .{ .name = "side", .on = .{ .choice = true }, .value = .word },
        .{ .name = "then", .on = .{ .section = true }, .value = .section, .leads = true },
    } };
    pub const options: check.Options = .{ .schema = &schema, .delivery = "how", .things = &.{.{ .kind = "item", .ids = &.{ "pelt", "letter" } }} };
};
const plain = river.join(Plain);

test "a story is played as a game plays it: lines, choices, effects when a line is delivered, rules after them, the end" {
    try expectPlayed(plain,
        \\cast:
        \\  mum  "Mum"
        \\  dad  "Dad"
        \\facts:
        \\  met: bool
        \\  carried: set of play, gave
        \\  told: int
        \\== kitchen
        \\MUM: You could still play, Frank.
        \\  [at 9.5]
        \\  [carried += play]
        \\DAD (quietly): Who'd listen?
        \\* Who'll run the shop?
        \\  [side shop]
        \\  DAD: I will.
        \\  -> end
        \\* { carried has gave } You gave yours up.
        \\  -> end
        \\* { carried has play } You could still play.
        \\  [met = true]
        \\  -> end
        \\== watch (rules)
        \\= heard   when { carried has play }
        \\  [told += 1]
    , &.{ "3", ":facts" }, .ended,
        \\== kitchen
        \\MUM: You could still play, Frank.
        \\  [at 9.5]
        \\  [carried += play]
        \\! rule watch.heard
        \\  [told += 1]
        \\DAD (quietly): Who'd listen?
        \\* 1 Who'll run the shop?
        \\  [side shop]
        \\* 2 (closed) You gave yours up.
        \\* 3 You could still play.
        \\> 3
        \\[met = true]
        \\-> end
        \\> :facts
        \\  met = true
        \\  carried = play
        \\  told = 1
        \\
    );
}

test "the proof, played by a fixed script with a fact the game set at the start, reads as its pinned transcript" {
    var rows: std.ArrayList([]const u8) = .empty;
    defer rows.deinit(gpa);
    var it = std.mem.splitScalar(u8, @embedFile("testdata/proof.play"), '\n');
    while (it.next()) |row| if (row.len > 0) try rows.append(gpa, row);
    var p = try played(whole.wake, &whole.proof, .{ .given = &.{":set spot = door"} }, rows.items);
    defer p.deinit();
    std.testing.expectEqualStrings(@embedFile("testdata/proof.transcript"), p.text) catch |e| {
        std.debug.print("--- got\n{s}", .{p.text});
        return e;
    };
    try std.testing.expectEqual(script.Ending.ended, p.ending);
}

/// A story loaded and played through the session's own calls, for what a transcript cannot show.
const Loose = struct {
    m: Manuscript,
    out: river.compile.Compiled,
    loaded: walk.Loaded,
    play: Play,

    fn init(l: *Loose, with: river.Joined, text: []const u8) !void {
        l.m, const out = try Manuscript.build(gpa, &.{.{ .path = "story.river", .text = text }}, with, .development);
        l.out = out orelse return error.TestStoryRefused;
        try l.loaded.init(gpa, l.out.graph, l.out.words);
        try l.play.init(gpa, &l.loaded, .{ .start = Play.entry(&l.m.checked.?, &l.loaded.story).?, .running = with.running, .delivery = with.options.delivery });
    }

    fn deinit(l: *Loose) void {
        l.play.deinit();
        l.loaded.deinit();
        l.out.deinit(gpa);
        l.m.deinit();
    }

    fn fact(l: *Loose, name: []const u8) river.compile.Compiler.Error!@import("riverrun").facts.Value {
        return l.loaded.memory.store().get(l.loaded.story.factNamed(name).?);
    }
};

test "a line's effects are applied when it is delivered, once the next thing is asked for, and never before" {
    var l: Loose = undefined;
    try l.init(plain,
        \\facts:
        \\  met: bool
        \\== a
        \\MUM: Hello.
        \\  [met = true]
        \\-> end
        \\
        \\cast:
        \\  mum  "Mum"
    );
    defer l.deinit();
    try std.testing.expect((try l.play.next()).? == .section);
    const line = (try l.play.next()).?;
    try std.testing.expectEqualStrings("Hello.", line.line.text);
    try std.testing.expect(!(try l.fact("met")).boolean);
    try std.testing.expect((try l.play.next()).? == .end);
    try std.testing.expect((try l.fact("met")).boolean);
    try std.testing.expectEqual(Play.Waiting.end, l.play.waitingFor().?);
}

test "a closed choice is shown closed and cannot be taken; a choice not offered is refused by its number" {
    try expectPlayed(plain,
        \\facts:
        \\  met: bool
        \\== a
        \\* { met } Open sesame.
        \\  -> end
        \\* Walk on.
        \\  -> end
    , &.{"1"}, .refused,
        \\== a
        \\* 1 (closed) Open sesame.
        \\* 2 Walk on.
        \\> 1
        \\script:1:1-1:2: error: choice 1 is closed: its condition does not hold
        \\
    );
    try expectPlayed(plain,
        \\facts:
        \\  met: bool
        \\== a
        \\* { met } Open sesame.
        \\  -> end
        \\* Walk on.
        \\  -> end
    , &.{ ":set met = true", "1" }, .ended,
        \\== a
        \\* 1 (closed) Open sesame.
        \\* 2 Walk on.
        \\> :set met = true
        \\* 1 Open sesame.
        \\* 2 Walk on.
        \\> 1
        \\-> end
        \\
    );
    try expectPlayed(plain,
        \\== a
        \\* Walk on.
        \\  -> end
        \\* Run.
        \\  -> end
    , &.{"3"}, .refused,
        \\== a
        \\* 1 Walk on.
        \\* 2 Run.
        \\> 3
        \\script:1:1-1:2: error: there is no choice 3: 2 are offered
        \\
    );
}

test "a query is answered with what the player set, else its type's first value, and told where it is asked; an outcome is waited for" {
    try expectPlayed(plain,
        \\facts:
        \\  paid: bool
        \\extern:
        \\  price(ref of item) -> int
        \\  pay(int) -> bool (action)
        \\  give(ref of item)
        \\== a
        \\{ price(pelt) > 3 } It costs {price(pelt)}.
        \\[paid = pay(price(pelt))]
        \\{ paid }
        \\  [give(letter)]
        \\  Paid.
        \\-> end
    , &.{ "true", ":back", ":set price(pelt) = 5", "true" }, .ended,
        \\== a
        \\? price(pelt) = 0 (not set)
        \\? pay(0) -> true or false
        \\> true
        \\[give(letter)]
        \\Paid.
        \\-> end
        \\> :back
        \\== a
        \\? price(pelt) = 0 (not set)
        \\? pay(0) -> true or false
        \\> :set price(pelt) = 5
        \\? pay(0) -> true or false
        \\> true
        \\[give(letter)]
        \\Paid.
        \\-> end
        \\
    );
}

test "what the player set a query to answer is what the story reads from then on, and is shown so" {
    var p = try played(plain, &.{.{ .path = "story.river", .text =
        \\extern:
        \\  price(ref of item) -> int
        \\== a
        \\{ price(pelt) > 3 } It costs {price(pelt)}.
        \\{ price(letter) > 3 } It costs too much.
        \\-> end
    }}, .{ .given = &.{":set price(pelt) = 5"} }, &.{});
    defer p.deinit();
    try std.testing.expectEqualStrings(
        \\> :set price(pelt) = 5
        \\== a
        \\? price(pelt) = 5
        \\It costs 5.
        \\? price(letter) = 0 (not set)
        \\-> end
        \\
    , p.text);
}

test "going back plays again from the start with the inputs but the last, and tells again what the input before it told" {
    try expectPlayed(plain,
        \\facts:
        \\  n: int
        \\== a
        \\- (top) Round {n}.
        \\+ Again.
        \\  [n += 1]
        \\  -> top
        \\* Stop.
        \\  -> end
    , &.{ "1", "1", ":back", ":back", "2", ":restart", ":back" }, .refused,
        \\== a
        \\Round 0.
        \\* 1 Again.
        \\* 2 Stop.
        \\> 1
        \\[n += 1]
        \\Round 1.
        \\* 1 Again.
        \\* 2 Stop.
        \\> 1
        \\[n += 1]
        \\Round 2.
        \\* 1 Again.
        \\* 2 Stop.
        \\> :back
        \\[n += 1]
        \\Round 1.
        \\* 1 Again.
        \\* 2 Stop.
        \\> :back
        \\== a
        \\Round 0.
        \\* 1 Again.
        \\* 2 Stop.
        \\> 2
        \\-> end
        \\> :restart
        \\== a
        \\Round 0.
        \\* 1 Again.
        \\* 2 Stop.
        \\> :back
        \\script:7:1-7:6: error: there is nothing to go back to
        \\
    );
}

test "a run-time error is the story's, said where it is written, and the play stops there" {
    try expectPlayed(plain,
        \\facts:
        \\  big: int
        \\const:
        \\  most = 9223372036854775807
        \\== a
        \\[big = most]
        \\Almost.
        \\That's {big + 1}.
        \\-> end
    , &.{"1"}, .stopped,
        \\== a
        \\[big = 9223372036854775807]
        \\Almost.
        \\story.river:8:9-8:16: error: a sum, or a change, passed what an int holds (64 bits) (Overflow)
        \\
    );
}

test "a story that says something forever without waiting is stopped, named, with the sections it goes round, where it goes round" {
    var p = try played(plain, &.{.{ .path = "story.river", .text = "== start\nOnce.\n-> a\n== a\nAgain.\n-> b\n== b\nAnd again.\n-> a\n" }}, .{}, &.{});
    defer p.deinit();
    try std.testing.expectEqual(script.Ending.stopped, p.ending);
    const last = p.text[std.mem.findScalarLast(u8, p.text[0 .. p.text.len - 1], '\n').? + 1 ..];
    try std.testing.expectEqualStrings("story.river:6:1-6:5: error: the story went on without waiting for the player: a loop that says something each time round: it keeps coming back to `a`, `b` (Endless)\n", last);
}

test "a run-time error is placed at the effect that met it: the Nth of a run, of a line, of a rule; at a rule's condition" {
    const head =
        \\facts:
        \\  big: int
        \\  n: int
        \\  met: bool
        \\const:
        \\  most = 9223372036854775807
        \\
    ;
    // the third effect of a run, applied
    try expectPlayed(plain, head ++
        \\== a
        \\[big = most]
        \\[n = 1]
        \\[big += 1]
        \\[n = 2]
        \\-> end
    , &.{}, .stopped,
        \\== a
        \\[big = 9223372036854775807] [n = 1] [big += 1] [n = 2]
        \\story.river:10:1-10:11: error: a sum, or a change, passed what an int holds (64 bits) (Overflow)
        \\
    );
    // the second effect under a line, worked out
    try expectPlayed(plain, head ++
        \\== a
        \\[big = most]
        \\Then.
        \\  [n = 1] [n = big + 1]
        \\-> end
    , &.{}, .stopped,
        \\== a
        \\[big = 9223372036854775807]
        \\story.river:10:11-10:24: error: a sum, or a change, passed what an int holds (64 bits) (Overflow)
        \\
    );
    // a rule's second effect, applied, not the line that woke it
    try expectPlayed(plain, head ++
        \\== a
        \\[big = most]
        \\Then.
        \\  [met = true]
        \\-> end
        \\== watch (rules)
        \\= woke   when { met }
        \\  [n = 1]
        \\  [big += 1]
    , &.{}, .stopped,
        \\== a
        \\[big = 9223372036854775807]
        \\Then.
        \\  [met = true]
        \\! rule watch.woke
        \\  [n = 1] [big += 1]
        \\story.river:15:3-15:13: error: a sum, or a change, passed what an int holds (64 bits) (Overflow)
        \\
    );
    // a rule's condition, worked out
    try expectPlayed(plain, head ++
        \\== a
        \\[big = most]
        \\Then.
        \\-> end
        \\== watch (rules)
        \\= woke   when { big + 1 > n and met }
        \\  [met = true]
    , &.{}, .stopped,
        \\== a
        \\[big = 9223372036854775807]
        \\story.river:12:17-12:36: error: a sum, or a change, passed what an int holds (64 bits) (Overflow)
        \\
    );
}

/// The test package's vocabulary: a stall, whose stocks the game opens and whose wares it restocks.
const Stalled = struct {
    pub const options: check.Options = .{ .things = &.{.{ .kind = "item_kind", .ids = &.{ "pelt", "letter" } }} };
    pub const packages: []const river.Package = &.{@import("stall-compiler").package};
};
const stalled = river.join(Stalled);

const market =
    \\facts:
    \\  keeper: ref of item_kind   (game)
    \\== market
    \\{ furs > 2 } HILDE: Plenty of furs.
    \\* Buy.
    \\  -> end
    \\* Leave.
    \\  -> end
    \\== wares (stock)
    \\= furs
    \\= salt
    \\
    \\cast:
    \\  hilde  "Hilde"
;

test "a package's command is an input like any other: taken and told as the row typed, gone back from and given again" {
    try expectPlayed(stalled, market, &.{ ":restock furs count=3", ":open wares keeper = pelt", ":back", ":open wares keeper=hilde", "1" }, .ended,
        \\! opens stall
        \\  2 wares
        \\== market
        \\* 1 Buy.
        \\* 2 Leave.
        \\> :restock furs count=3
        \\! restocked furs
        \\  [furs += 3]
        \\* 1 Buy.
        \\* 2 Leave.
        \\> :open wares keeper = pelt
        \\! opened wares
        \\* 1 Buy.
        \\* 2 Leave.
        \\> :back
        \\! restocked furs
        \\  [furs += 3]
        \\* 1 Buy.
        \\* 2 Leave.
        \\> :open wares keeper=hilde
        \\! opened wares
        \\* 1 Buy.
        \\* 2 Leave.
        \\> 1
        \\-> end
        \\
    );
}

test "a package's command that does not fit is refused in words a writer acts on" {
    const refusals = [_]struct { []const []const u8, []const u8 }{
        .{ &.{ ":open wares keeper=pelt", ":open wares keeper=letter" }, "`wares` is open already: a stock opens once" },
        .{ &.{":open nowhere keeper=pelt"}, "there is no stock `nowhere` to :open: wares" },
        .{ &.{":open"}, ":open takes a stock: wares" },
        .{ &.{":open wares"}, ":open wares takes keeper=ITEM_KIND: `keeper` is missing" },
        .{ &.{":open wares keeper=pelt size=2"}, ":open wares takes keeper=ITEM_KIND, not `size`" },
        .{ &.{":open wares keeper=pelt keeper=pelt"}, "`keeper` is given twice" },
        .{ &.{":open wares keeper"}, "write each of what :open takes as name=value: keeper=ITEM_KIND" },
        .{ &.{":open wares keeper=\"x\""}, "`keeper` takes a thing by its name, not `\"x\"`" },
        .{ &.{":restock salt count=pelt"}, "a number, not `pelt`" },
        .{ &.{":restock salt count=0"}, "a ware is restocked by 1 or more, not 0" },
        .{ &.{":nothing"}, "there is no command :nothing: :set, :wait, :facts, :back, :restart, :quit, :help, :open, :restock" },
    };
    for (refusals) |r| {
        var p = try played(stalled, &.{.{ .path = "story.river", .text = market }}, .{}, r[0]);
        defer p.deinit();
        try std.testing.expectEqual(script.Ending.refused, p.ending);
        const last = p.text[std.mem.findScalarLast(u8, p.text[0 .. p.text.len - 1], '\n').? + 1 ..];
        const message = last[(std.mem.find(u8, last, "error: ") orelse return error.TestUnexpectedResult) + 7 .. last.len - 1];
        std.testing.expectEqualStrings(r[1], message) catch |e| {
            std.debug.print("--- after {s}\n", .{r[0][r[0].len - 1]});
            return e;
        };
    }
}

test "the packages' commands are listed by :help with what each applies to in this story" {
    var p = try played(stalled, &.{.{ .path = "story.river", .text = market }}, .{}, &.{":help"});
    defer p.deinit();
    try std.testing.expect(std.mem.endsWith(u8, p.text,
        \\  :open STOCK               the game opens a stock for trade, its keeper given (stall)
        \\      :open wares keeper=ITEM_KIND
        \\  :restock WARE             the game adds to a ware's count (stall)
        \\      :restock furs count=NUMBER
        \\      :restock salt count=NUMBER
        \\
    ));
}

/// A package with a runtime of its own and nothing else: a bell that rings, and comes due, when the clock `hour`
/// passes 3, as tide's schedules come due; and that says it is hung when it starts.
const Bell = struct {
    const State = struct { story: *const @import("riverrun").story.Story, rung: bool = false };

    const running: river.Running = .{ .name = "bell", .start = start, .stop = stop, .advance = advance };

    fn start(a: std.mem.Allocator, game: river.Running.Game, told: *river.Running.Told) error{ OutOfMemory, Stopped }!?*anyopaque {
        const s = game.story.sectionNamed("bell") orelse return null;
        _ = s;
        const state = try a.create(State);
        state.* = .{ .story = game.story };
        try told.say(.{ .what = "hung", .name = "bell" });
        return state;
    }

    fn stop(a: std.mem.Allocator, state: *anyopaque) void {
        a.destroy(@as(*State, @ptrCast(@alignCast(state))));
    }

    fn advance(state: *anyopaque, clock: @import("riverrun").facts.FactId, by: u64, told: *river.Running.Told) error{ OutOfMemory, Stopped }!bool {
        const st: *State = @ptrCast(@alignCast(state));
        if (!std.mem.eql(u8, st.story.fact(clock).name, "hour")) return false;
        _ = by;
        if (!st.rung) {
            st.rung = true;
            try told.say(.{ .what = "due", .name = "bell", .words = &.{"Ding."}, .section = st.story.sectionNamed("bell") });
        }
        return false;
    }

    const Vocabulary = struct {
        pub const options: check.Options = .{};
        pub const packages: []const river.Package = &.{.{ .running = running }};
    };
};

const bell = river.join(Bell.Vocabulary);

test "a package's runtime runs as in a game: what it says it did is told, and a section it says came due is told into the flow" {
    try expectPlayed(bell,
        \\facts:
        \\  hour: int   (clock)
        \\== a
        \\- (top) Waiting.
        \\+ Wait.
        \\  -> top
        \\* Leave.
        \\  -> end
        \\== bell
        \\The bell rings at {hour}.
        \\<-
    , &.{ ":wait 4", "2" }, .ended,
        \\! hung bell
        \\== a
        \\Waiting.
        \\* 1 Wait.
        \\* 2 Leave.
        \\> :wait 4
        \\! due bell
        \\  Ding.
        \\== bell
        \\The bell rings at 4.
        \\== a
        \\* 1 Wait.
        \\* 2 Leave.
        \\> 2
        \\-> end
        \\
    );
}

// ---------------------------------------------------------------- properties

const shakedown = @import("shakedown");
const gen = shakedown.gen;
const facts = @import("riverrun").facts;

/// A story of a case compiled and loaded, as the whole compiler's property writes them; null where it is refused,
/// or where compiling or loading it is a fault, which is that property's to find.
const Built = struct {
    m: Manuscript,
    out: river.compile.Compiled,
    loaded: walk.Loaded,

    fn of(b: *Built, a: std.mem.Allocator, case: *shakedown.Case) !bool {
        const pages = try whole.storyOf(case.source, a);
        b.m, const out = Manuscript.build(gpa, pages, whole.joined, .development) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // a story the checker passed and the compiler could not build: the whole compiler's property's
            else => return false,
        };
        b.out = out orelse {
            b.m.deinit();
            return false;
        };
        b.loaded.init(gpa, b.out.graph, b.out.words) catch {
            // what the compiler wrote and the runtime refused: the whole compiler's property's
            b.out.deinit(gpa);
            b.m.deinit();
            return false;
        };
        return true;
    }

    fn deinit(b: *Built) void {
        b.loaded.deinit();
        b.out.deinit(gpa);
        b.m.deinit();
    }
};

/// A row a player might type, of any kind, right or wrong: choices in and out of range, values of every kind, each
/// command with good and bad words, and any bytes.
fn anyRow(s: *shakedown.Source, a: std.mem.Allocator) ![]const u8 {
    return switch (gen.intRange(s, u8, 0, 10)) {
        0, 1, 2 => try a.print("{d}", .{gen.intRange(s, u8, 0, 6)}),
        3 => gen.oneOf(s, []const u8, &.{ "true", "false", "0", "-1", "3", "none", "\"words\"", "pelt" }),
        4 => gen.oneOf(s, []const u8, &.{ ":set met = true", ":set n += 2", ":set n = 99", ":set k -= 1", ":set got += pelt_bag", ":set got = pelt_bag, letter_bag", ":set mood = cross", ":set price(pelt) = 3", ":set price(letter) = -4", ":set who = pelt", ":set hour = 3", ":set furs = 2", ":set nothing = 1", ":set met += 1", ":set price = 3", ":set pay(1) = true" }),
        5 => gen.oneOf(s, []const u8, &.{ ":wait 2", ":wait 1 hour", ":wait 0", ":wait 1 met", ":wait x" }),
        6 => gen.oneOf(s, []const u8, &.{ ":back", ":back", ":restart", ":facts", ":facts met n got", ":facts nothing" }),
        7 => gen.oneOf(s, []const u8, &.{ ":quit", ":help", ":nonsense", "", "// a note", ":" }),
        // the test package's commands, good and bad: a stock that is there and one that is not, a keeper the story
        // names, one the game stands in for, none, twice; a ware restocked by a number, by nothing, by a word
        8 => gen.oneOf(s, []const u8, &.{ ":open wares keeper=pelt", ":open wares keeper = hilde", ":open nowhere keeper=pelt", ":open wares", ":open wares keeper=none", ":open wares keeper=pelt keeper=letter", ":open", ":restock furs count=2", ":restock salt count = 1", ":restock furs count=-1", ":restock furs count=pelt", ":restock gold count=1", ":restock furs" }),
        else => blk: {
            var buffer: [24]u8 = undefined;
            break :blk try a.dupe(u8, gen.bytesInto(s, &buffer));
        },
    };
}

test "any story played by any script gives a transcript and a named ending; never a crash, a hang or a leak" {
    try shakedown.check(gpa, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            var b: Built = undefined;
            if (!try b.of(a, case)) return;
            defer b.deinit();
            const s = &b.loaded.story;
            if (s.len(.sections) == 0) return;
            // where the game starts it, or any section a writer names
            const start = if (gen.boolean(case.source)) Play.entry(&b.m.checked.?, s) orelse return else s.sectionNamed(s.section(.fromRaw(gen.intRange(case.source, u32, 0, s.len(.sections) - 1))).name).?;
            var p: Play = undefined;
            try p.init(gpa, &b.loaded, .{ .start = start, .steps = 300, .running = whole.joined.running, .delivery = whole.joined.options.delivery });
            defer p.deinit();
            const t: transcript.Transcript = .{ .play = &p, .files = b.m.files, .where = &b.out.where };
            const rows = try a.alloc(script.Row, gen.intRange(case.source, usize, 0, 16));
            for (rows, 1..) |*r, n| r.* = .{ .text = try anyRow(case.source, a), .path = "script", .line = @intCast(n) };
            var text: std.Io.Writer.Allocating = .init(gpa);
            defer text.deinit();
            const ending = try script.run(gpa, &text.writer, &t, &p, rows);
            case.reached("played");
            if (std.mem.find(u8, text.written(), "\n> ") != null) case.reached("took an input");
            if (ending == .ended) case.reached("came to its end");
            if (std.mem.find(u8, text.written(), "\n! restocked ") != null or std.mem.find(u8, text.written(), "\n! opened ") != null) case.reached("took a package's command");
            if (ending == .refused) {
                // the row refused, by the line its refusal is placed at
                const at = std.mem.findLast(u8, text.written(), "\nscript:") orelse 0;
                const line = std.fmt.parseInt(usize, text.written()[at + 8 ..][0 .. std.mem.findScalar(u8, text.written()[at + 8 ..], ':') orelse 0], 10) catch 0;
                if (line > 0 and line <= rows.len and isCommand(rows[line - 1].text)) case.reached("refused a package's command");
            }
        }
    }.one, .{ .cases = 600, .seed = 0x91a7, .reach = &.{ "played", "took an input", "came to its end", "took a package's command", "refused a package's command" } });
}

fn isCommand(row: []const u8) bool {
    return std.mem.startsWith(u8, row, ":open") or std.mem.startsWith(u8, row, ":restock");
}

/// What a front was told by the session, as both fronts see it: a line's speaker and words, the choices with
/// whether each is open, effects reached on their own (how many), the end.
const Told = union(enum) {
    line: struct { speaker: ?u16, text: []const u8 },
    choices: []const struct { text: []const u8, open: bool },
    effects: usize,
    end,

    fn eql(x: Told, y: Told) bool {
        if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
        return switch (x) {
            .line => |l| l.speaker == y.line.speaker and std.mem.eql(u8, l.text, y.line.text),
            .choices => |c| c.len == y.choices.len and for (c, y.choices) |m, n| {
                if (m.open != n.open or !std.mem.eql(u8, m.text, n.text)) break false;
            } else true,
            .effects => |n| n == y.effects,
            .end => true,
        };
    }
};

const Recording = struct {
    a: std.mem.Allocator,
    list: std.ArrayList(Told) = .empty,
    failed: bool = false,

    fn add(r: *Recording, step: @import("riverrun").run.Step) !void {
        try r.list.append(r.a, switch (step) {
            .line => |l| .{ .line = .{ .speaker = if (l.speaker) |c| c.raw() else null, .text = try r.a.dupe(u8, l.text) } },
            .choices => |list| blk: {
                const out = try r.a.alloc(@typeInfo(@FieldType(Told, "choices")).pointer.child, list.len);
                for (out, list) |*o, c| o.* = .{ .text = try r.a.dupe(u8, c.text), .open = c.open };
                break :blk .{ .choices = out };
            },
            .effects => |list| .{ .effects = list.len },
            .end => .end,
            .action => return,
        });
    }

    fn seen(ctx: ?*anyopaque, step: @import("riverrun").run.Step) void {
        const r: *Recording = @ptrCast(@alignCast(ctx.?));
        // a recording that cannot grow fails the case, said after the walk
        r.add(step) catch {
            r.failed = true;
        };
    }
};

test "what play tells is what walk tells for the same choices: one runtime, two fronts" {
    try shakedown.check(gpa, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            var b: Built = undefined;
            if (!try b.of(a, case)) return;
            defer b.deinit();
            if (b.loaded.story.len(.sections) == 0) return;
            const picks = try a.alloc(usize, 64);
            for (picks) |*k| k.* = gen.intRange(case.source, usize, 0, 7);
            // the walk: the first section, every step recorded, the k-th open choice taken each time
            var walked: Recording = .{ .a = a };
            const Picker = struct {
                picks: []const usize,
                next: usize = 0,
                fn pick(ctx: ?*anyopaque, open: usize) usize {
                    const p: *@This() = @ptrCast(@alignCast(ctx.?));
                    defer p.next += 1;
                    return p.picks[p.next % p.picks.len] % open;
                }
            };
            var picker: Picker = .{ .picks = picks };
            const told = try walk.walk(gpa, &b.loaded, .{ .sections = 1, .steps = 64, .seen = .{ .ctx = &walked, .step = Recording.seen } }, .{ .ctx = &picker, .pick = Picker.pick });
            try std.testing.expect(!walked.failed);
            // the play: the same section, the same choices, every outcome its type's first value as the walk gives
            var played_: Recording = .{ .a = a };
            var p: Play = undefined;
            try p.init(gpa, &b.loaded, .{ .start = .fromRaw(0), .steps = 64 });
            defer p.deinit();
            var chosen: usize = 0;
            var stopped = false;
            var given: usize = 0;
            while (played_.list.items.len < walked.list.items.len + 1) : (given += 1) {
                // every input moves the play on or ends it: rules that keep asking are stopped, never given forever
                if (given == 10_000) return error.TestPlayNeverEnds;
                while (try p.next()) |e| switch (e) {
                    .line => |l| try played_.add(.{ .line = l }),
                    .choices => |list| {
                        const out = try a.alloc(@typeInfo(@FieldType(Told, "choices")).pointer.child, list.len);
                        for (out, list) |*o, c| o.* = .{ .text = try a.dupe(u8, c.text), .open = c.open };
                        try played_.list.append(a, .{ .choices = out });
                    },
                    .effects => |list| try played_.list.append(a, .{ .effects = list.len }),
                    .end => try played_.list.append(a, .end),
                    .stopped => stopped = true,
                    .section, .asked, .asks, .rule, .news => {},
                };
                switch (p.waitingFor().?) {
                    .choice => {
                        var open: usize = 0;
                        for (p.choices()) |c| open += @intFromBool(c.open);
                        var left = picks[chosen % picks.len] % open;
                        chosen += 1;
                        const number = for (p.choices()) |c| {
                            if (!c.open) continue;
                            if (left == 0) break c.number;
                            left -= 1;
                        } else unreachable;
                        try p.give(.{ .choose = number });
                    },
                    .outcome => try p.give(.{ .outcome = facts.Value.initial(b.loaded.story.fact(p.asking().?.result.?).kind) }),
                    .end, .stopped => break,
                }
            }
            const n = walked.list.items.len;
            try std.testing.expect(played_.list.items.len >= n);
            for (walked.list.items, played_.list.items[0..n]) |x, y| try std.testing.expect(x.eql(y));
            // a walk that ended or stopped on a named error did so where the play did
            if (told.ends > 0) try std.testing.expect(played_.list.items.len == n and walked.list.items[n - 1] == .end);
            if (told.stopped > 0) try std.testing.expect(stopped and played_.list.items.len == n);
            case.reached("compared");
            if (told.chosen > 0) case.reached("took a choice");
            if (told.fired > 0) case.reached("fired a rule");
        }
    }.one, .{ .cases = 500, .seed = 0x2f0e7, .reach = &.{ "compared", "took a choice", "fired a rule" } });
}

test "going back one input then giving it again tells what giving it once told, and the play goes on the same" {
    try shakedown.check(gpa, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            var b: Built = undefined;
            if (!try b.of(a, case)) return;
            defer b.deinit();
            const start = Play.entry(&b.m.checked.?, &b.loaded.story) orelse return;
            const options: Play.Options = .{ .start = start, .steps = 300, .running = whole.joined.running, .delivery = whole.joined.options.delivery };
            // the first play: rows that fit what is waited for, and what each told
            var rows: std.ArrayList([]const u8) = .empty;
            var first: std.ArrayList([]const u8) = .empty;
            {
                var p: Play = undefined;
                try p.init(gpa, &b.loaded, options);
                defer p.deinit();
                const t: transcript.Transcript = .{ .play = &p, .files = b.m.files, .where = &b.out.where };
                try first.append(a, try toldAll(a, &t, &p));
                for (0..gen.intRange(case.source, usize, 1, 12)) |_| {
                    const row = try fitting(a, case.source, &p) orelse break;
                    var w: std.Io.Writer.Allocating = .init(a);
                    const took = try script.one(a, &w.writer, &t, &p, row, true);
                    if (took != .taken) break;
                    try rows.append(a, row);
                    try first.append(a, w.written());
                }
            }
            if (rows.items.len == 0) return;
            // the second: the same rows, and one of them given, gone back from, and given again: a package's command
            // where there is one, one time in two
            var j = gen.intRange(case.source, usize, 0, rows.items.len - 1);
            if (gen.boolean(case.source)) for (rows.items, 0..) |row, i| if (isCommand(row)) {
                j = i;
            };
            var p: Play = undefined;
            try p.init(gpa, &b.loaded, options);
            defer p.deinit();
            const t: transcript.Transcript = .{ .play = &p, .files = b.m.files, .where = &b.out.where };
            try std.testing.expectEqualStrings(first.items[0], try toldAll(a, &t, &p));
            for (rows.items, 0..) |row, i| {
                try std.testing.expectEqualStrings(first.items[i + 1], try rowTold(a, &t, &p, row));
                if (i != j) continue;
                // back: what the row before it told, told again
                var w: std.Io.Writer.Allocating = .init(a);
                try std.testing.expectEqual(script.Took.taken, try script.one(a, &w.writer, &t, &p, ":back", true));
                // the row before's own echo is not told again: what it told is
                const before = if (i == 0) first.items[0] else first.items[i][(std.mem.findScalar(u8, first.items[i], '\n') orelse 0) + 1 ..];
                try std.testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ "> :back\n", before }), w.written());
                try std.testing.expectEqualStrings(first.items[i + 1], try rowTold(a, &t, &p, row));
                case.reached("went back");
                if (isCommand(row)) case.reached("went back over a package's command");
            }
        }

        fn toldAll(a: std.mem.Allocator, t: *const transcript.Transcript, p: *Play) ![]const u8 {
            var w: std.Io.Writer.Allocating = .init(a);
            try script.tellAll(&w.writer, t, p);
            return w.written();
        }

        fn rowTold(a: std.mem.Allocator, t: *const transcript.Transcript, p: *Play, row: []const u8) ![]const u8 {
            var w: std.Io.Writer.Allocating = .init(a);
            try std.testing.expectEqual(script.Took.taken, try script.one(a, &w.writer, t, p, row, true));
            return w.written();
        }

        // A row that fits what the play waits for: a choice open now, an outcome of its kind, a fact set, a clock
        // moved; null once it has ended or stopped.
        fn fitting(a: std.mem.Allocator, s: *shakedown.Source, p: *const Play) !?[]const u8 {
            switch (p.waitingFor() orelse return null) {
                .choice => {
                    switch (gen.intRange(s, u8, 0, 5)) {
                        0 => return gen.oneOf(s, []const u8, &.{ ":restock furs count=1", ":open wares keeper=hilde" }),
                        1 => return gen.oneOf(s, []const u8, &.{ ":set met = true", ":set n += 1", ":wait 1 hour", ":set price(pelt) = 2" }),
                        else => {},
                    }
                    var open: std.ArrayList(usize) = .empty;
                    for (p.choices()) |c| if (c.open) try open.append(a, c.number);
                    return try a.print("{d}", .{gen.oneOf(s, usize, open.items)});
                },
                .outcome => return switch (p.loaded.story.fact(p.asking().?.result.?).kind) {
                    .boolean => gen.oneOf(s, []const u8, &.{ "true", "false" }),
                    .int => "2",
                    else => null,
                },
                .end, .stopped => return null,
            }
        }
    }.one, .{ .cases = 300, .seed = 0xbac4, .reach = &.{ "went back", "went back over a package's command" } });
}

test "a run-time error is placed at the effect that met it, wherever that effect stands: the Nth of a run, of a line, of a rule" {
    try shakedown.check(gpa, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            // a story whose `big` holds the most an int holds, then a run of effects, one of which adds to it
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(a, "facts:\n  big: int\n  n: int\n  met: bool\nconst:\n  most = 9223372036854775807\n== a\n[big = most]\n");
            const count = gen.intRange(case.source, usize, 1, 6);
            const bad = gen.intRange(case.source, usize, 0, count - 1);
            const where = gen.oneOf(case.source, enum { run, line, rule }, &.{ .run, .line, .rule });
            const indent: []const u8 = if (where == .run) "" else "  ";
            switch (where) {
                .run => {},
                .line => try text.appendSlice(a, "Then.\n"),
                .rule => try text.appendSlice(a, "Then.\n  [met = true]\n-> end\n== watch (rules)\n= woke   when { met }\n"),
            }
            // each on a row of its own, or several to a row
            const together = gen.boolean(case.source);
            var row: u32 = @intCast(std.mem.countScalar(u8, text.items, '\n') + 1);
            var col: u32 = 1;
            var want: ?struct { u32, u32 } = null;
            for (0..count) |i| {
                if (i == 0 or !together) {
                    if (i > 0) {
                        try text.append(a, '\n');
                        row += 1;
                    }
                    try text.appendSlice(a, indent);
                    col = @intCast(indent.len + 1);
                } else {
                    try text.append(a, ' ');
                    col += 1;
                }
                const effect = if (i == bad) try a.dupe(u8, "[big += 1]") else try a.print("[n = {d}]", .{i});
                if (i == bad) want = .{ row, col };
                try text.appendSlice(a, effect);
                col += @intCast(effect.len);
            }
            try text.appendSlice(a, if (where == .rule) "\n" else "\n-> end\n");
            var p = try played(plain, &.{.{ .path = "story.river", .text = text.items }}, .{}, &.{});
            defer p.deinit();
            try std.testing.expectEqual(script.Ending.stopped, p.ending);
            const last = p.text[std.mem.findScalarLast(u8, p.text[0 .. p.text.len - 1], '\n').? + 1 ..];
            const expected = try a.print("story.river:{d}:{d}-{d}:{d}: error:", .{ want.?[0], want.?[1], want.?[0], want.?[1] + 10 });
            std.testing.expect(std.mem.startsWith(u8, last, expected)) catch |e| {
                std.debug.print("--- story\n{s}\n--- want {s}\n--- got\n{s}", .{ text.items, expected, p.text });
                return e;
            };
            case.reached(@tagName(where));
            if (bad > 0) case.reached("not the first");
        }
    }.one, .{ .cases = 200, .seed = 0xe44, .reach = &.{ "run", "line", "rule", "not the first" } });
}

test "rules that keep asking the game an outcome that sets them off again are stopped, in play and in walk alike" {
    const text =
        \\facts:
        \\  r: bool
        \\extern:
        \\  pay() -> bool (action)
        \\== a
        \\Hello.
        \\-> end
        \\== loop (rules)
        \\= unset  when { not r }
        \\  [r = true]
        \\= ask    when { r }
        \\  [r = pay()]
    ;
    var m, var out = try Manuscript.build(gpa, &.{.{ .path = "story.river", .text = text }}, plain, .development);
    defer m.deinit();
    defer if (out) |*o| o.deinit(gpa);
    var loaded: walk.Loaded = undefined;
    try loaded.init(gpa, out.?.graph, out.?.words);
    defer loaded.deinit();
    const Never = struct {
        fn pick(_: ?*anyopaque, _: usize) usize {
            return 0;
        }
    };
    const told = try walk.walk(gpa, &loaded, .{ .sections = 1 }, .{ .ctx = null, .pick = Never.pick });
    try std.testing.expectEqual(@as(u32, 1), told.stopped);
    var p: Play = undefined;
    try p.init(gpa, &loaded, .{ .start = loaded.story.sectionNamed("a").? });
    defer p.deinit();
    var given: usize = 0;
    while (given < 1000) : (given += 1) {
        while (try p.next()) |_| {}
        if (p.waitingFor().? != .outcome) break;
        try p.give(.{ .outcome = .{ .boolean = false } });
    }
    try std.testing.expectEqual(Play.Waiting.stopped, p.waitingFor().?);
    try std.testing.expect(given < 100);
}
