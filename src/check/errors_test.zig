//! Each thing the checker refuses, or warns of, in the smallest story that
//! shows it, with the message and the place it is reported.

const std = @import("std");
const syntax = @import("../syntax.zig");
const check = @import("../check.zig");

const Severity = syntax.source.Severity;

const Outcome = struct {
    arena: std.heap.ArenaAllocator,
    diags: syntax.Diagnostics,
    checked: ?check.Checked = null,

    fn deinit(o: *Outcome) void {
        if (o.checked) |*c| c.deinit();
        o.diags.deinit(std.testing.allocator);
        o.arena.deinit();
    }

    /// The one diagnostic there is, which must be this one.
    fn only(o: *const Outcome, severity: Severity, line: u32, col: u32, message: []const u8) !void {
        if (o.diags.list.items.len != 1) {
            for (o.diags.list.items) |d| std.debug.print("{d}:{d}: {s}\n", .{ d.span.line, d.span.col, d.message });
            return error.TestExpectedOneDiagnostic;
        }
        try o.has(severity, line, col, message);
    }

    /// A diagnostic with this message, at this place.
    fn has(o: *const Outcome, severity: Severity, line: u32, col: u32, message: []const u8) !void {
        for (o.diags.list.items) |d| {
            if (d.severity == severity and d.span.line == line and d.span.col == col and std.mem.eql(u8, d.message, message)) return;
        }
        std.debug.print("wanted {t} {d}:{d}: {s}\n", .{ severity, line, col, message });
        for (o.diags.list.items) |d| std.debug.print("  have {t} {d}:{d}: {s}\n", .{ d.severity, d.span.line, d.span.col, d.message });
        return error.TestMissingDiagnostic;
    }
};

fn checkOne(story: []const u8, options: check.Options) !Outcome {
    var o: Outcome = .{ .arena = .init(std.testing.allocator), .diags = .{} };
    errdefer o.deinit();
    const tree = try o.arena.allocator().create(syntax.ast.File);
    tree.* = try syntax.parse(o.arena.allocator(), std.testing.allocator, &o.diags, 0, "a.river", story);
    if (o.diags.list.items.len > 0) return error.TestStoryDoesNotRead;
    o.checked = try check.run(std.testing.allocator, &o.diags, tree[0..1], options);
    return o;
}

test "a speaker comes from the cast or the extras" {
    var o = try checkOne(
        \\cast:
        \\  dad  "Dad"
        \\extras: a cellist
        \\== a
        \\DAD: Go.
        \\A CELLIST: She stopped us once.
        \\MUM: You could still play.
        \\-> end
    , .{});
    defer o.deinit();
    try o.only(.err, 7, 1, "`MUM` is not a speaker: speakers come from `cast:` and `extras:`");
}

test "a fact must be declared" {
    var o = try checkOne(
        \\== a
        \\~ carried += play
        \\-> end
    , .{});
    defer o.deinit();
    try o.only(.err, 2, 3, "nothing is called `carried`: no fact");
}

test "a comparison is of like with like" {
    var o = try checkOne(
        \\facts:
        \\  met: bool
        \\== a
        \\{ met = 3 }  Go.
        \\~ met = true
        \\-> end
    , .{});
    defer o.deinit();
    try o.only(.err, 4, 3, "`=` compares like with like: true or false and a number");
}

test "an effect's value is of its fact's type, and an item of its set" {
    var o = try checkOne(
        \\facts:
        \\  life: one of stay, go
        \\  carried: set of play, gave
        \\== a
        \\~ life = gone
        \\~ carried += hands
        \\-> end
    , .{});
    defer o.deinit();
    try o.has(.err, 5, 10, "`gone` is not one of stay, go");
    try o.has(.err, 6, 14, "`hands` is not in `carried`: play, gave");
}

test "the story never sets a fact the game writes" {
    var o = try checkOne(
        \\facts:
        \\  spot: one of stairs, piano   (game)
        \\== a
        \\~ spot = piano
        \\-> end
    , .{});
    defer o.deinit();
    try o.only(.err, 4, 3, "`spot` is the game's, declared `(game)`: the story reads it and never sets it");
}

test "a fact nothing sets is a warning" {
    var o = try checkOne(
        \\facts:
        \\  met: bool
        \\== a
        \\{ met } Hello again.
        \\-> end
    , .{});
    defer o.deinit();
    try o.only(.warning, 2, 3, "nothing sets `met`: declare it `(game)` if the game writes it");
}

test "a query is asked and an action is run" {
    var o = try checkOne(
        \\extern:
        \\  lived(one of stay, go) -> bool
        \\  rest_in(one of stay, go)
        \\== a
        \\{ rest_in(go) }  Go.
        \\~ lived(go)
        \\{ lived(gone) }  Stay.
        \\~ rest_in(go)
        \\-> end
    , .{});
    defer o.deinit();
    try o.has(.err, 5, 3, "`rest_in` is an action: it runs as an effect, `~ rest_in(…)`, and gives no value");
    try o.has(.err, 6, 3, "`lived` is a query: it answers in a condition, and an effect runs an action");
    try o.has(.err, 7, 9, "`gone` is not one of stay, go");
    try std.testing.expectEqual(@as(usize, 3), o.diags.list.items.len);
}

test "a section nothing reaches from the entries is refused" {
    var o = try checkOne(
        \\== a
        \\-> b
        \\== b
        \\-> end
        \\== island
        \\-> island
    , .{ .entries = &.{"a"} });
    defer o.deinit();
    try o.only(.err, 5, 4, "nothing reaches `island` from where the story starts");
}

test "with no entries, a loop nothing leads into is still unreached" {
    var o = try checkOne(
        \\== a
        \\-> end
        \\== b
        \\-> c
        \\== c
        \\-> b
    , .{});
    defer o.deinit();
    try o.has(.err, 3, 4, "nothing reaches `b` from where the story starts");
    try o.has(.err, 5, 4, "nothing reaches `c` from where the story starts");
}

test "a scene ends by a flow on every way through it" {
    var o = try checkOne(
        \\cast:
        \\  dad  "Dad"
        \\== kitchen
        \\DAD: Go.
        \\* Who'll run the shop?
        \\  DAD: I ran it before you could walk.
        \\* Pick up the case.
        \\  -> end
    , .{ .schema = &.{ .keys = &.{} } });
    defer o.deinit();
    try o.only(.err, 3, 4, "the scene `kitchen` can run off its end: end it with `-> end`, `<-` or a flow elsewhere");
}

test "what follows a flow away is unreached, unless a label lets flow back" {
    var o = try checkOne(
        \\== a
        \\- (again)
        \\* Once more.
        \\  -> again
        \\* Enough.
        \\  -> end
        \\Nobody hears this.
    , .{});
    defer o.deinit();
    try o.only(.warning, 7, 1, "nothing reaches this: the story always goes elsewhere before it");
}

test "a pool is called, and its candidates are picked" {
    var o = try checkOne(
        \\== a
        \\->> kept
        \\-> kept
        \\== kept (pool 2)
        \\= one   when { true }   One.
    , .{});
    defer o.deinit();
    try o.has(.err, 3, 4, "`kept` is a pool: call it, `->> kept`, and it gives its lines and comes back");
    try o.has(.err, 4, 4, "the pool `kept` gives 2, but has 1 candidates");
}

test "a tag is one the host knows, where it may stand, with values of its type" {
    const schema: check.Schema = .{ .keys = &.{
        .{ .name = "at", .on = .{ .line = true }, .value = .number },
        .{ .name = "heard", .on = .{ .line = true }, .value = .{ .values_of = "spot" }, .count = .many },
        .{ .name = "then", .on = .{ .section = true }, .value = .section, .leads = true },
    } };
    var o = try checkOne(
        \\cast:
        \\  mum  "Mum"
        \\  dad  "Dad"
        \\facts:
        \\  spot: one of stairs, piano   (game)
        \\== hide   # then found
        \\MUM: Then lock it.   # at 6.5 · heard piano, door
        \\DAD: Who'd listen?   # at soon
        \\MUM: You gave it up.   # pause 2
        \\== found   # at 3
        \\-> end
    , .{ .schema = &schema });
    defer o.deinit();
    try o.has(.err, 7, 34, "`heard` takes one of stairs, piano: `door` is not one");
    try o.has(.err, 8, 24, "`at` takes a number: `soon` is not one");
    try o.has(.err, 9, 26, "`pause` is not a tag the host knows");
    try o.has(.err, 10, 14, "`at` is not a tag of a section");
    try std.testing.expectEqual(@as(usize, 4), o.diags.list.items.len);
}

test "a line wider than the host allows is refused" {
    var o = try checkOne(
        \\const:
        \\  dies_at = "ten past nine"
        \\== a
        \\Frank died at {dies_at}.
        \\Frank Marlowe died at {dies_at} that night, with the radio on.
        \\-> end
    , .{ .width = .{ .line = 40, .value = 13 } });
    defer o.deinit();
    try o.only(.err, 5, 1, "the line is 66 columns wide, past the host's 40");
}

test "a name is declared once, and the second says where the first is" {
    var o = try checkOne(
        \\facts:
        \\  met: bool
        \\const:
        \\  met = true
        \\== a
        \\-> a
        \\== a
        \\-> end
    , .{});
    defer o.deinit();
    try o.has(.err, 4, 3, "`met` is declared twice: first at a.river:2:3");
    try o.has(.err, 7, 4, "the section `a` is declared twice: first at a.river:5:4");
}

test "a line id is used once, and a release needs one on every line" {
    var o = try checkOne(
        \\== a
        \\Go.   # id k7f3a2
        \\Stay.   # id k7f3a2
        \\Wait.
        \\-> end
    , .{ .mode = .release });
    defer o.deinit();
    try o.has(.err, 3, 1, "the line id `k7f3a2` is used twice: first at a.river:2:1");
    try o.has(.err, 4, 1, "a release needs every line's `# id`: `riverrun tag` writes them");
    try std.testing.expectEqual(@as(usize, 2), o.diags.list.items.len);
}

test "a choice that can never be offered is a warning" {
    var o = try checkOne(
        \\facts:
        \\  spot: one of stairs, piano   (game)
        \\  kept: set of dad, tom
        \\const:
        \\  demo = false
        \\== a
        \\~ kept += dad
        \\* { spot = piano and spot = stairs } Both.
        \\  -> end
        \\* { kept has dad and kept hasnt dad } Neither.
        \\  -> end
        \\* { demo } Only in the demo.
        \\  -> end
        \\* { kept has dad and kept has tom } Both kept.
        \\  -> end
    , .{});
    defer o.deinit();
    try o.has(.warning, 8, 5, "this choice can never be offered: its condition can never hold");
    try o.has(.warning, 10, 5, "this choice can never be offered: its condition can never hold");
    try o.has(.warning, 12, 5, "this choice can never be offered: its condition can never hold");
    try std.testing.expectEqual(@as(usize, 3), o.diags.list.items.len);
}

test "seen reads a visit count, which a condition takes as true once above zero" {
    var o = try checkOne(
        \\== a
        \\- (ask)
        \\* { not seen(ask) } First time.
        \\  -> ask
        \\* { seen(b) } Back again.
        \\  -> b
        \\* { seen(nowhere) } Nowhere.
        \\  -> end
        \\== b
        \\-> a
    , .{ .entries = &.{"a"} });
    defer o.deinit();
    try o.only(.err, 7, 10, "`seen` counts visits to a section, a part or a label: nothing is called `nowhere`");
    const c = o.checked.?;
    var read: usize = 0;
    for (c.visits) |v| read += @intFromBool(v.read);
    try std.testing.expectEqual(@as(usize, 2), read);
}

test "`<-` with nothing to go back to is a warning" {
    var o = try checkOne(
        \\== a
        \\-> b
        \\== b
        \\Back.
        \\<-
    , .{});
    defer o.deinit();
    try o.only(.warning, 5, 1, "`<-` goes back to a caller, but nothing calls `b` with `->>`");
}

test "any story is checked or refused, never crashes" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [1024]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var diags: syntax.Diagnostics = .{};
            defer diags.deinit(std.testing.allocator);
            const tree = try arena.allocator().create(syntax.ast.File);
            tree.* = try syntax.parse(arena.allocator(), std.testing.allocator, &diags, 0, "fuzz.river", bytes);
            var checked = try check.run(std.testing.allocator, &diags, tree[0..1], .{ .mode = .release, .width = .{ .line = 40 } });
            checked.deinit();
        }
    }.one, .{});
}

test "ints are ordered, and nothing else is" {
    var o = try checkOne(
        \\facts:
        \\  hour: int   (game)
        \\  met:  bool
        \\== a
        \\{ hour >= 6 and met < 2 } Dawn.
        \\~ met = true
        \\-> end
    , .{});
    defer o.deinit();
    try o.only(.err, 5, 17, "this is true or false, where a number is wanted");
}

test "an action with an outcome keeps it in a fact, and is never asked" {
    var o = try checkOne(
        \\facts:
        \\  persuaded: one of yes, no
        \\  rolled:    int
        \\extern:
        \\  persuade(who: int, against: int) -> one of yes, no   (action)
        \\== a
        \\~ persuaded = persuade(1, 12)
        \\~ rolled = persuade(1, 12)
        \\~ persuade(1, 12)
        \\{ persuade(1, 12) = yes } Fine.
        \\{ persuaded = yes } Fine.
        \\~ rolled = 3
        \\-> end
    , .{});
    defer o.deinit();
    try o.has(.err, 8, 12, "`persuade`'s outcome is one of yes, no, and the fact keeping it is a number");
    try o.has(.err, 9, 3, "`persuade` has an outcome, which a fact keeps: `~ fact = persuade(…)`");
    try o.has(.err, 10, 3, "`persuade` is an action with an outcome: it runs as an effect whose outcome a fact keeps, `~ fact = persuade(…)`");
    try std.testing.expectEqual(@as(usize, 3), o.diags.list.items.len);
}

test "a stamp is keyed by the query's own parameters" {
    var o = try checkOne(
        \\extern:
        \\  count(kind: ref of item_kind) -> int   (reads stock(kind))
        \\  gold() -> int   (reads purse(owner))
        \\== a
        \\{ count(wolf_pelt) >= 10 and gold() > 0 } Ten.
        \\-> end
    , .{});
    defer o.deinit();
    try o.only(.err, 3, 32, "`owner` keys the stamp of `gold`, and it has no parameter of that name");
}

test "the host's things are named by their ids, checked against its manifest" {
    var o = try checkOne(
        \\facts:
        \\  target: ref of person   (game)
        \\extern:
        \\  count(kind: ref of item_kind) -> int
        \\== a
        \\{ count(wolf_pelt) > 0 and count(wolf_pelf) > 0 and target = margaret } Pelts.
        \\-> end
    , .{ .things = &.{.{ .kind = "item_kind", .ids = &.{"wolf_pelt"} }} });
    defer o.deinit();
    try o.only(.err, 6, 34, "the host has no item_kind called `wolf_pelf`");
}

test "a clock is an int" {
    var o = try checkOne(
        \\facts:
        \\  day:  int    (clock)
        \\  dawn: bool   (clock)
        \\== a
        \\{ day > 3 and dawn } Morning.
        \\-> end
    , .{});
    defer o.deinit();
    try o.only(.err, 3, 3, "a clock counts, so `(clock)` is an int's: `dawn` is true or false");
}

test "an else block ends a scene when both branches do" {
    var o = try checkOne(
        \\facts:
        \\  met: bool   (game)
        \\== a
        \\{ met }
        \\  He looks up.
        \\  -> end
        \\{ else }
        \\  {once: He doesn't. | Still nothing.}
        \\  -> end
    , .{});
    defer o.deinit();
    try std.testing.expectEqual(@as(usize, 0), o.diags.list.items.len);
}

test "another module's names are reached qualified" {
    var o: Outcome = .{ .arena = .init(std.testing.allocator), .diags = .{} };
    defer o.deinit();
    const a = o.arena.allocator();
    const files = try a.alloc(syntax.ast.File, 2);
    files[0] = try syntax.parse(a, std.testing.allocator, &o.diags, 0, "harbour.river",
        \\module harbour
        \\facts:
        \\  met: bool
        \\== letter
        \\~ met = true
        \\-> end
    );
    files[1] = try syntax.parse(a, std.testing.allocator, &o.diags, 1, "main.river",
        \\== start
        \\{ harbour.met } -> end
        \\{ met } -> end
        \\-> harbour.letter
    );
    try std.testing.expectEqual(@as(usize, 0), o.diags.list.items.len);
    o.checked = try check.run(std.testing.allocator, &o.diags, files, .{});
    try o.only(.err, 3, 3, "nothing is called `met`: no fact or constant");
}

test "an int changes by a number or an int constant; a set by one of its items" {
    var o = try checkOne(
        \\facts:
        \\  points: int
        \\  kept:   set of ruth, dad
        \\  met:    bool
        \\const:
        \\  penalty = 3
        \\  word = "no"
        \\== a
        \\~ points += 2
        \\~ points -= penalty
        \\~ points += word
        \\~ kept += 2
        \\~ met += 1
        \\{ points > 0 and kept has dad and met } -> end
        \\-> end
    , .{});
    defer o.deinit();
    try o.has(.err, 11, 13, "`+=` changes the int `points` by a number or an int constant, and `word` is neither");
    try o.has(.err, 12, 11, "`+=` changes the set `kept` by an item: ruth, dad");
    try o.has(.err, 13, 3, "`+=` changes a set or an int; `met` is true or false");
    try std.testing.expectEqual(@as(usize, 3), o.diags.list.items.len);
}

test "a thing is said through a query, never as itself" {
    var o = try checkOne(
        \\facts:
        \\  target: ref of person   (game)
        \\extern:
        \\  name(who: ref of person) -> text
        \\== a
        \\It is {name(target)}.
        \\It is {target}.
        \\-> end
    , .{});
    defer o.deinit();
    try o.only(.err, 7, 8, "a thing is said through a query the host answers, such as `{name(…)}`");
}

test "a registered kind adds its tags and builtins to its own sections, and nowhere else" {
    const quest_tags: check.Schema = .{ .keys = &.{
        .{ .name = "stage", .on = .{ .part = true } },
        .{ .name = "after", .on = .{ .part = true }, .value = .word, .count = .many },
    } };
    const quest: check.Kind = .{ .name = "quest", .schema = &quest_tags, .builtins = &.{
        .{ .name = "since", .params = &.{ .part, .int_fact }, .returns = .int },
    } };
    var o = try checkOne(
        \\facts:
        \\  day:  int    (clock)
        \\  life: one of stay, go
        \\== pelts (quest)
        \\= asked      when { day > 1 }                    # stage
        \\= late       when { since(asked, day) > 3 }      # stage · after asked
        \\= wrong      when { since(gone, day) > 3 and since(asked, life) > 0 }
        \\== a
        \\~ life = go
        \\{ since(asked, day) > 3 } -> end
        \\-> end
    , .{ .kinds = &.{quest} });
    defer o.deinit();
    try o.has(.err, 7, 27, "`gone` is not a part of `pelts`");
    try o.has(.err, 7, 59, "`life` is one of stay, go, where an int fact is wanted");
    try o.has(.err, 10, 3, "nothing is called `since`: no query or action");
    try std.testing.expectEqual(@as(usize, 3), o.diags.errors());
}

test "rules: each a condition and its effects, reached by nothing, their queries stamped" {
    var o = try checkOne(
        \\facts:
        \\  honor:   int
        \\  seconds: int    (clock)
        \\  day:     int    (game)
        \\extern:
        \\  gold() -> int
        \\== a
        \\{ since_changed(honor, seconds) > 3 } -> drift
        \\-> honor_rules
        \\== honor_rules (rules)
        \\= drift    when { since_changed(honor, day) > 10 }
        \\  ~ honor += 1
        \\= rich     when { gold() > 100 }
        \\  ~ honor += 1
        \\= loose
        \\  ~ honor -= 1
        \\= loud     when { honor < 0 }
        \\  Honor is low.
    , .{});
    defer o.deinit();
    try o.has(.err, 8, 3, "`since_changed` is kept by what watches conditions: a rule or a quest, not `a`");
    try o.has(.err, 9, 4, "`honor_rules` holds rules: they fire when their conditions become true, and nothing goes to them");
    try o.has(.err, 11, 40, "`day` is not a clock: since_changed counts on a fact declared `(clock)`");
    try o.has(.err, 13, 19, "`gold` is asked by a rule, which wakes only when what it reads changes: declare what it reads, `(reads …)`");
    try o.has(.err, 15, 3, "the rule `loose` needs its condition: `= loose when { … }`, its effects under it");
    try o.has(.err, 18, 3, "a rule's body is its effects, `~ …`: a rule says nothing and goes nowhere");
}
