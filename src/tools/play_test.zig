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
        \\story.river:8:1-8:18: error: a sum, or a change, passed what an int holds (64 bits) (Overflow)
        \\
    );
}

test "a story that says something forever without waiting is stopped, named" {
    var p = try played(plain, &.{.{ .path = "story.river", .text = "== a\n- (top) Again.\n-> top\n" }}, .{}, &.{});
    defer p.deinit();
    try std.testing.expectEqual(script.Ending.stopped, p.ending);
    try std.testing.expect(std.mem.endsWith(u8, p.text, "a loop that says something each time round (Endless)\n"));
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

    fn hasRules(b: *const Built) bool {
        const s = &b.loaded.story;
        for (0..s.len(.sections)) |i| if (s.section(.fromRaw(@intCast(i))).kind == .rules) return true; // safe: below a u32 count
        return false;
    }
};

/// A row a player might type, of any kind, right or wrong: choices in and out of range, values of every kind, each
/// command with good and bad words, and any bytes.
fn anyRow(s: *shakedown.Source, a: std.mem.Allocator) ![]const u8 {
    return switch (gen.intRange(s, u8, 0, 9)) {
        0, 1, 2 => try a.print("{d}", .{gen.intRange(s, u8, 0, 6)}),
        3 => gen.oneOf(s, []const u8, &.{ "true", "false", "0", "-1", "3", "none", "\"words\"", "pelt" }),
        4 => gen.oneOf(s, []const u8, &.{ ":set met = true", ":set n += 2", ":set n = 99", ":set k -= 1", ":set got += pelt_bag", ":set got = pelt_bag, letter_bag", ":set mood = cross", ":set price(pelt) = 3", ":set price(letter) = -4", ":set who = pelt", ":set hour = 3", ":set furs = 2", ":set nothing = 1", ":set met += 1", ":set price = 3", ":set pay(1) = true" }),
        5 => gen.oneOf(s, []const u8, &.{ ":wait 2", ":wait 1 hour", ":wait 0", ":wait 1 met", ":wait x" }),
        6 => gen.oneOf(s, []const u8, &.{ ":back", ":back", ":restart", ":facts", ":facts met n got", ":facts nothing" }),
        7 => gen.oneOf(s, []const u8, &.{ ":quit", ":help", ":nonsense", "", "// a note", ":" }),
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
        }
    }.one, .{ .cases = 600, .seed = 0x91a7, .reach = &.{ "played", "took an input", "came to its end" } });
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

    fn chose(_: ?*anyopaque, _: usize) void {}
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
            // the walk fires no rules, and the play does: a story with rules is told the same only until one fires
            if (b.hasRules() or b.loaded.story.len(.sections) == 0) return;
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
            const told = try walk.walk(gpa, &b.loaded, .{ .sections = 1, .steps = 64, .seen = .{ .ctx = &walked, .step = Recording.seen, .chose = Recording.chose } }, .{ .ctx = &picker, .pick = Picker.pick });
            try std.testing.expect(!walked.failed);
            // the play: the same section, the same choices, every outcome its type's first value as the walk gives
            var played_: Recording = .{ .a = a };
            var p: Play = undefined;
            try p.init(gpa, &b.loaded, .{ .start = .fromRaw(0), .steps = 64 });
            defer p.deinit();
            var chosen: usize = 0;
            var stopped = false;
            while (played_.list.items.len < walked.list.items.len + 1) {
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
        }
    }.one, .{ .cases = 500, .seed = 0x2f0e7, .reach = &.{ "compared", "took a choice" } });
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
                    if (try script.one(a, &w.writer, &t, &p, row, true) != .taken) break;
                    try rows.append(a, row);
                    try first.append(a, w.written());
                }
            }
            if (rows.items.len == 0) return;
            // the second: the same rows, and one of them given, gone back from, and given again
            const j = gen.intRange(case.source, usize, 0, rows.items.len - 1);
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
                    if (gen.intRange(s, u8, 0, 4) == 0) return gen.oneOf(s, []const u8, &.{ ":set met = true", ":set n += 1", ":wait 1 hour", ":set price(pelt) = 2" });
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
    }.one, .{ .cases = 300, .seed = 0xbac4, .reach = &.{"went back"} });
}
