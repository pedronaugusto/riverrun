//! Each thing the checker refuses, or warns of, in the smallest story that
//! shows it, with the message and the place it is reported.

const std = @import("std");
const syntax = @import("../syntax.zig");
const check = @import("../check.zig");

const Severity = syntax.source.Severity;

const Outcome = struct {
    arena: std.heap.ArenaAllocator,
    diags: syntax.Diagnostics,
    files: []const syntax.ast.File = &.{},
    checked: ?check.Checked = null,

    // Where a diagnostic is, as a line and a column.
    fn at(o: *const Outcome, d: syntax.source.Diagnostic) syntax.Place {
        return o.files[d.span.file].place(d.span);
    }

    fn deinit(o: *Outcome) void {
        if (o.checked) |*c| c.deinit();
        o.diags.deinit(std.testing.allocator);
        o.arena.deinit();
    }

    /// The one diagnostic there is, which must be this one.
    fn only(o: *const Outcome, severity: Severity, line: u32, col: u32, message: []const u8) !void {
        if (o.diags.list.items.len != 1) {
            for (o.diags.list.items) |d| std.debug.print("{d}:{d}: {s}\n", .{ o.at(d).line, o.at(d).col, d.message });
            return error.TestExpectedOneDiagnostic;
        }
        try o.has(severity, line, col, message);
    }

    /// A diagnostic with this message, at this place.
    fn has(o: *const Outcome, severity: Severity, line: u32, col: u32, message: []const u8) !void {
        for (o.diags.list.items) |d| {
            if (d.severity == severity and o.at(d).line == line and o.at(d).col == col and std.mem.eql(u8, d.message, message)) return;
        }
        std.debug.print("wanted {t} {d}:{d}: {s}\n", .{ severity, line, col, message });
        for (o.diags.list.items) |d| std.debug.print("  have {t} {d}:{d}: {s}\n", .{ d.severity, o.at(d).line, o.at(d).col, d.message });
        return error.TestMissingDiagnostic;
    }
};

fn checkOne(story: []const u8, options: check.Options) !Outcome {
    var o: Outcome = .{ .arena = .init(std.testing.allocator), .diags = .{} };
    errdefer o.deinit();
    const tree = try o.arena.allocator().create(syntax.ast.File);
    tree.* = try syntax.parse(o.arena.allocator(), std.testing.allocator, &o.diags, 0, "a.river", story);
    o.files = tree[0..1];
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

test "narration that reads like a line is a warning naming a line's form; narration with a colon after other words is not" {
    var o = try checkOne(
        \\cast:
        \\  ada  "Ada Lane"
        \\extras: a courier
        \\== a
        \\Ada: Not tonight.
        \\ADA:No space.
        \\ADA : Spaced.
        \\Ada (quietly): Go.
        \\A courier: Letter.
        \\ada lane: The name.
        \\Ada had one thing to say: no.
        \\The rule: pay first.
        \\Otto: Not in the cast.
        \\-> end
    , .{});
    defer o.deinit();
    const form = "reads like a line, and is narration: a line is its speaker's id in capitals, then `:` and a space: ";
    try o.has(.warning, 5, 1, "`Ada:` " ++ form ++ "`ADA: …`");
    try o.has(.warning, 6, 1, "`ADA:` " ++ form ++ "`ADA: …`");
    try o.has(.warning, 7, 1, "`ADA :` " ++ form ++ "`ADA: …`");
    try o.has(.warning, 8, 1, "`Ada (quietly):` " ++ form ++ "`ADA: …`");
    try o.has(.warning, 9, 1, "`A courier:` " ++ form ++ "`A COURIER: …`");
    try o.has(.warning, 10, 1, "`ada lane:` " ++ form ++ "`ADA: …`");
    try std.testing.expectEqual(@as(usize, 6), o.diags.list.items.len);
}

test "a line that can say nothing and carries effects is a warning: such a line is not delivered" {
    var o = try checkOne(
        \\facts:
        \\  waved: int
        \\  rain: bool   (game)
        \\== a
        \\{once: The boy waves.}
        \\  [waved += 1]
        \\{ rain: Wet. | }
        \\  [waved += 1]
        \\{once: Once.} And always.
        \\  [waved += 1]
        \\{once: Said once, no effects.}
        \\{seq: First. | Then.}
        \\  [waved += 1]
        \\-> end
    , .{});
    defer o.deinit();
    const why = "this line can say nothing (a `once` used up, or words chosen with none), and a line with nothing to say is not delivered: the effects under it are applied only when it says something";
    try o.has(.warning, 5, 1, why);
    try o.has(.warning, 7, 1, why);
    try std.testing.expectEqual(@as(usize, 2), o.diags.list.items.len);
}

test "a fact must be declared" {
    var o = try checkOne(
        \\== a
        \\[carried += play]
        \\-> end
    , .{});
    defer o.deinit();
    try o.only(.err, 2, 2, "nothing is called `carried`: no fact");
}

test "a comparison is of like with like" {
    var o = try checkOne(
        \\facts:
        \\  met: bool
        \\== a
        \\{ met = 3 }  Go.
        \\[met = true]
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
        \\[life = gone]
        \\[carried += hands]
        \\-> end
    , .{});
    defer o.deinit();
    try o.has(.err, 5, 9, "`gone` is not one of stay, go");
    try o.has(.err, 6, 13, "`hands` is not in `carried`: play, gave");
}

test "the story never sets a fact the game writes" {
    var o = try checkOne(
        \\facts:
        \\  spot: one of stairs, piano   (game)
        \\== a
        \\[spot = piano]
        \\-> end
    , .{});
    defer o.deinit();
    try o.only(.err, 4, 2, "`spot` is the game's, declared `(game)`: the story reads it and never sets it");
}

test "an effect the reader refuses for its value is said once: its fact is not also one nothing sets" {
    var o: Outcome = .{ .arena = .init(std.testing.allocator), .diags = .{} };
    defer o.deinit();
    const tree = try o.arena.allocator().create(syntax.ast.File);
    tree.* = try syntax.parse(o.arena.allocator(), std.testing.allocator, &o.diags, 0, "a.river",
        \\facts:
        \\  owes: int
        \\  price: int   (game)
        \\== a
        \\[owes += price * 2]
        \\-> end
    );
    o.files = tree[0..1];
    o.checked = try check.run(std.testing.allocator, &o.diags, tree[0..1], .{});
    try o.only(.err, 5, 16, "`*` multiplies, and a formula is the game's: a story adds and subtracts, and asks the game by name, through a query in `extern:`");
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
        \\[lived(go)]
        \\{ lived(gone) }  Stay.
        \\[rest_in(go)]
        \\-> end
    , .{});
    defer o.deinit();
    try o.has(.err, 5, 3, "`rest_in` is an action: it runs as an effect, `[rest_in(…)]`, and gives no value");
    try o.has(.err, 6, 2, "`lived` is a query: it answers in a condition, and an effect runs an action");
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

test "a registered kind's section is an entry by its kind, the host's entries naming it or not" {
    var o = try checkOne(
        \\== a
        \\-> end
        \\== pelts (quest)
        \\= asked
    , .{ .entries = &.{"a"}, .kinds = &.{quest_kind} });
    defer o.deinit();
    try std.testing.expectEqual(@as(usize, 0), o.diags.list.items.len);
    const entries = o.checked.?.entries;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("pelts", o.checked.?.sections[entries[1].raw()].name);
    // named among the entries too, it is one entry still
    var named = try checkOne(
        \\== a
        \\-> end
        \\== pelts (quest)
        \\= asked
    , .{ .entries = &.{ "a", "pelts" }, .kinds = &.{quest_kind} });
    defer named.deinit();
    try std.testing.expectEqual(@as(usize, 2), named.checked.?.entries.len);
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
    try o.only(.err, 6, 3, "the scene `kitchen` can run off its end after this row: end it with `-> end`, `<-` or a flow elsewhere");
}

test "a way that runs off is placed at its last row, one error to a way, naming the scene or the part" {
    var o = try checkOne(
        \\facts:
        \\  met: bool   (game)
        \\== a
        \\-> p
        \\= p
        \\  { met }
        \\    He looks up.
        \\  * Stay.
        \\    -> end
        \\  * Go.
        \\    He goes.
    , .{});
    defer o.deinit();
    const off = "the part `p` can run off its end after this row: end it with `-> end`, `<-` or a flow elsewhere";
    try o.has(.err, 11, 5, off);
    try std.testing.expectEqual(@as(usize, 1), o.diags.list.items.len);
}

test "the flow goes past a choice point once every choice there is used up or closed, as the runtime does" {
    // every choice taken comes back: what follows is reached, and the scene can run off after the point
    var o = try checkOne(
        \\== a
        \\- (ask)
        \\* One.
        \\  -> ask
        \\* Two.
        \\  -> ask
        \\- Nothing left.
        \\-> end
    , .{});
    defer o.deinit();
    try std.testing.expectEqual(@as(usize, 0), o.diags.list.items.len);
    var off = try checkOne(
        \\== a
        \\- (ask)
        \\* One.
        \\  -> ask
        \\* Two.
        \\  -> ask
    , .{});
    defer off.deinit();
    try off.only(.err, 5, 1, "the scene `a` can run off its end after this row: end it with `-> end`, `<-` or a flow elsewhere");
    // past choices the game's facts close, what follows is reached, and the scene is not said to run off there
    var closed = try checkOne(
        \\facts:
        \\  coins: int   (game)
        \\== a
        \\- (ask)
        \\* One.
        \\  -> ask
        \\+ { coins > 0 } Pay.
        \\  -> ask
        \\
        \\== b
        \\* { coins > 0 } Pay.
        \\  -> end
        \\Nothing to pay with.
        \\-> end
    , .{});
    defer closed.deinit();
    try std.testing.expectEqual(@as(usize, 0), closed.diags.list.items.len);
    // a sticky choice always open keeps the flow at its point; a choice that ends cannot be used up
    var kept = try checkOne(
        \\== a
        \\- (ask)
        \\* One.
        \\  -> ask
        \\+ Wait.
        \\  -> ask
        \\Never said.
        \\== b
        \\* Stay.
        \\  -> end
        \\* Go.
        \\  -> b
        \\Never said either.
    , .{});
    defer kept.deinit();
    try kept.has(.warning, 7, 1, "nothing reaches this: the story always goes elsewhere before it");
    try kept.has(.warning, 13, 1, "nothing reaches this: the story always goes elsewhere before it");
    try std.testing.expectEqual(@as(usize, 2), kept.diags.list.items.len);
    // a choice that only leads on to a place that never comes back is not used up there
    var on = try checkOne(
        \\== a
        \\-> p
        \\= p
        \\  * Hold still.
        \\    -> q
        \\  * Stand up.
        \\    -> p
        \\= q
        \\  -> b
        \\== b
        \\-> end
    , .{});
    defer on.deinit();
    try std.testing.expectEqual(@as(usize, 0), on.diags.list.items.len);
}

test "a gather or a condition with a choice on its row checks as a choice point of that one choice" {
    var o = try checkOne(
        \\facts:
        \\  met: bool   (game)
        \\== a
        \\- * Go.
        \\  -> b
        \\- (ask) * Run.
        \\  -> ask
        \\{ met } * Wave.
        \\  -> end
        \\-> end
        \\== b
        \\- * Stay.
        \\  Said.
    , .{});
    defer o.deinit();
    try o.only(.err, 13, 3, "the scene `b` can run off its end after this row: end it with `-> end`, `<-` or a flow elsewhere");
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
        \\-> kept ->
        \\-> kept
        \\== kept (pool 2)
        \\= one   when { true }   One.
    , .{});
    defer o.deinit();
    try o.has(.err, 3, 4, "`kept` is a pool: call it, `-> kept ->`, and it gives its lines and comes back");
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
        \\== hide
        \\  [then found]
        \\MUM: Then lock it.
        \\  [at 6.5] [heard piano, door]
        \\DAD: Who'd listen?
        \\  [at soon]
        \\MUM: You gave it up.
        \\  [pause 2]
        \\== found
        \\  [at 3]
        \\-> end
    , .{ .schema = &schema });
    defer o.deinit();
    try o.has(.err, 9, 26, "`heard` takes one of stairs, piano: `door` is not one");
    try o.has(.err, 11, 7, "`at` takes a number: `soon` is not one");
    try o.has(.err, 13, 4, "`pause` is not a tag the game knows");
    try o.has(.err, 15, 4, "`at` is not a tag of a section");
    try std.testing.expectEqual(@as(usize, 4), o.diags.list.items.len);
}

test "a key stands once where it is, all its values in its one bracket" {
    const schema: check.Schema = .{ .keys = &.{
        .{ .name = "card", .on = .{ .section = true } },
        .{ .name = "forks", .on = .{ .section = true }, .value = .text, .count = .many },
        .{ .name = "heard", .on = .{ .line = true }, .value = .word, .count = .many },
        .{ .name = "how", .on = .{ .line = true }, .value = .text },
    } };
    var o = try checkOne(
        \\cast:
        \\  dad  "Dad"
        \\== tree
        \\  [card] [forks 1969 locked, 1985 open] [card]
        \\  [forks 1998 locked]
        \\DAD (quietly): Who'd listen?
        \\  [heard piano] [heard door] [how loud]
        \\-> end
    , .{ .schema = &schema, .delivery = "how" });
    defer o.deinit();
    try o.has(.err, 4, 42, "`card` is already given here, at a.river:4:4: write all its values in that one bracket");
    try o.has(.err, 5, 4, "`forks` is already given here, at a.river:4:11: write all its values in that one bracket");
    try o.has(.err, 7, 18, "`heard` is already given here, at a.river:7:4: write all its values in that one bracket");
    try o.has(.err, 7, 31, "`how` is already given here, at a.river:6:5: write all its values in that one bracket");
    try std.testing.expectEqual(@as(usize, 4), o.diags.list.items.len);
}

test "a line or a choice wider than the host allows is refused, on its own row" {
    var o = try checkOne(
        \\const:
        \\  dies_at = "ten past nine"
        \\facts:
        \\  x: bool
        \\== a
        \\Frank died at {dies_at}.
        \\Frank Marlowe died at {dies_at} that night, with the radio on.
        \\  [x = true]
        \\* Go to the hospital, and sit with him all night.
        \\  Frank died at {dies_at}.
        \\  -> end
    , .{ .width = .{ .line = 40, .choice = 20, .value = 13 } });
    defer o.deinit();
    try o.has(.err, 7, 1, "the line is 66 columns wide, past the game's 40");
    try o.has(.err, 9, 1, "the choice is 47 columns wide, past the game's 20");
    try std.testing.expectEqual(@as(usize, 2), o.diags.list.items.len);
    // each on its own row, to its words' end, never over what stands under it
    for (o.diags.list.items, [_]u32{ 7, 9 }, [_]u32{ 63, 50 }) |d, row, end| {
        const at = o.files[0].place(.{ .file = 0, .start = d.span.end, .end = d.span.end });
        try std.testing.expectEqual(row, at.line);
        try std.testing.expectEqual(end, at.col);
    }
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

test "a line id is used once, and a release needs one on every line and choice, placed on its row" {
    var o = try checkOne(
        \\facts:
        \\  x: bool
        \\== a
        \\Go. ^k7f3a2
        \\Stay. ^k7f3a2
        \\Wait.
        \\  [x = true]
        \\* Run. ^m2c9qd
        \\  -> end
        \\* Walk.
        \\  Far. ^p4w8e1
        \\  -> end
    , .{ .mode = .release });
    defer o.deinit();
    try o.has(.err, 5, 7, "the line id `k7f3a2` is used twice: first at a.river:4:5");
    const missing = "a release needs an id on every line and choice, `^…` at the end of its row: `riverrun tag` writes them";
    try o.has(.err, 6, 1, missing);
    try o.has(.err, 10, 1, missing);
    try std.testing.expectEqual(@as(usize, 3), o.diags.list.items.len);
    // each on its own row, to its words' end, never over what stands under it
    for (o.diags.list.items[1..], [_]u32{ 6, 8 }) |d, end| try std.testing.expectEqual(end, o.files[0].place(.{ .file = 0, .start = d.span.end, .end = d.span.end }).col);
}

test "a choice that can never be offered is a warning" {
    var o = try checkOne(
        \\facts:
        \\  spot: one of stairs, piano   (game)
        \\  kept: set of dad, tom
        \\const:
        \\  demo = false
        \\== a
        \\[kept += dad]
        \\* { spot = piano and spot = stairs } Both.
        \\  -> end
        \\* { kept has dad and kept hasnt dad } Neither.
        \\  -> end
        \\* { demo } Only in the demo.
        \\  -> end
        \\* { kept has dad and kept has tom } Both kept.
        \\  -> end
        \\-> end
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
    try o.only(.warning, 5, 1, "`<-` goes back to a caller, but nothing calls `b` with `-> b ->`");
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
        \\[met = true]
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
        \\[persuaded = persuade(1, 12)]
        \\[rolled = persuade(1, 12)]
        \\[persuade(1, 12)]
        \\{ persuade(1, 12) = yes } Fine.
        \\{ persuaded = yes } Fine.
        \\[rolled = 3]
        \\-> end
    , .{});
    defer o.deinit();
    try o.has(.err, 8, 11, "`persuade`'s outcome is one of yes, no, and the fact keeping it is a number");
    try o.has(.err, 9, 2, "`persuade` has an outcome, which a fact keeps: `[fact = persuade(…)]`");
    try o.has(.err, 10, 3, "`persuade` is an action with an outcome: it runs as an effect whose outcome a fact keeps, `[fact = persuade(…)]`");
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
    try o.only(.err, 6, 34, "the game has no item_kind called `wolf_pelf`");
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
    o.files = files;
    files[0] = try syntax.parse(a, std.testing.allocator, &o.diags, 0, "harbour.river",
        \\module harbour
        \\facts:
        \\  met: bool
        \\== letter
        \\[met = true]
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

test "an int changes by an int; a set by one of its items" {
    var o = try checkOne(
        \\facts:
        \\  points: int
        \\  kept:   set of ruth, dad
        \\  met:    bool
        \\const:
        \\  penalty = 3
        \\  word = "no"
        \\== a
        \\[points += 2]
        \\[points -= penalty]
        \\[points += word]
        \\[kept += 2]
        \\[met += 1]
        \\{ points > 0 and kept has dad and met } -> end
        \\-> end
    , .{});
    defer o.deinit();
    try o.has(.err, 11, 12, "`+=` changes the int `points` by an int: this is text");
    try o.has(.err, 12, 10, "`+=` changes the set `kept` by an item: ruth, dad");
    try o.has(.err, 13, 2, "`+=` changes a set or an int; `met` is true or false");
    try std.testing.expectEqual(@as(usize, 3), o.diags.list.items.len);
}

test "a sum adds ints, never always overflows, and never sets a bounded fact past its bounds; what cannot meet never holds" {
    var o = try checkOne(
        \\facts:
        \\  a: int from 0 to 100
        \\  b: int from 0 to 100
        \\  h: int from 5 to 10
        \\  flag: bool
        \\const:
        \\  most = 9223372036854775807
        \\== s
        \\[h = a + 200]
        \\[h = 20 + 1]
        \\[a += flag]
        \\{ a + flag > 1 } A flag.
        \\{ most + 1 > 0 } Past.
        \\{ a + b } A sum.
        \\It is {a + b} and {flag + 1}.
        \\[b = a + b] [flag = true]
        \\* { a + b > 300 } Never.
        \\  -> end
        \\* { a + b >= 200 } At the top.
        \\  -> end
        \\* { a - b < 0 - 100 } Below.
        \\  -> end
    , .{});
    defer o.deinit();
    try o.has(.err, 9, 6, "this is 200 to 300, always past `h`'s bounds, 5 to 10");
    try o.has(.err, 10, 6, "21 is past `h`'s bounds, 5 to 10");
    try o.has(.err, 11, 7, "`+=` changes the int `a` by an int: this is true or false");
    try o.has(.err, 12, 7, "`+` takes ints: this is true or false");
    try o.has(.err, 13, 3, "this always passes what an int holds: it is 9223372036854775808 to 9223372036854775808");
    try o.has(.err, 14, 3, "a condition is true or false; this is a number");
    try o.has(.err, 15, 20, "`+` takes ints: this is true or false");
    try o.has(.warning, 17, 5, "this choice can never be offered: its condition can never hold");
    try o.has(.warning, 21, 5, "this choice can never be offered: its condition can never hold");
    try std.testing.expectEqual(@as(usize, 7), o.diags.errors());
    try std.testing.expectEqual(@as(usize, 9), o.diags.list.items.len);
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
    try o.only(.err, 7, 8, "a thing is said through a query the game answers, such as `{name(…)}`");
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
        \\= asked      when { day > 1 }
        \\  [stage]
        \\= late       when { since(asked, day) > 3 }
        \\  [stage] [after asked]
        \\= wrong      when { since(gone, day) > 3 and since(asked, life) > 0 }
        \\== a
        \\[life = go]
        \\{ since(asked, day) > 3 } -> end
        \\-> end
    , .{ .kinds = &.{quest} });
    defer o.deinit();
    try o.has(.err, 9, 27, "`gone` is not a part of `pelts`");
    try o.has(.err, 9, 59, "`life` is one of stay, go, where an int fact is wanted");
    try o.has(.err, 12, 3, "nothing is called `since`: no query or action");
    try std.testing.expectEqual(@as(usize, 3), o.diags.errors());
}

test "a package's pass reports inside the check, where the story is written" {
    const Stuck = struct {
        // a quest with no stage that ends it: what a quest package refuses and no schema can type
        fn run(_: ?*anyopaque, c: *check.Checker, story: *const check.Checked) error{OutOfMemory}!void {
            for (story.sections) |s| if (s.kind == .other and s.parts.len == 0) {
                try c.err(s.node.name.span, "the quest `{s}` has no stage, so it can never end", .{s.name});
            };
        }
    };
    var o = try checkOne(
        \\== pelts (quest)
        \\Hilde wants ten pelts.
        \\== hunt (quest)
        \\= asked
        \\  Ten pelts.
    , .{ .kinds = &.{.{ .name = "quest" }}, .passes = &.{.{ .run = Stuck.run }} });
    defer o.deinit();
    try o.only(.err, 1, 4, "the quest `pelts` has no stage, so it can never end");
}

/// A calendar's kind, as a time package declares one: each part's `place` brings a fact holding one of its `names`.
pub const calendar_kind: check.Kind = .{ .name = "calendar", .declare = Calendar.declare };

const Calendar = struct {
    fn declare(arena: std.mem.Allocator, s: *const syntax.ast.Section, _: []const syntax.ast.File) error{OutOfMemory}![]const check.Declared {
        var out: std.ArrayList(check.Declared) = .empty;
        for (s.subsections) |p| {
            const place = tagOf(p.tags, "place") orelse continue;
            const words = if (tagOf(p.tags, "names")) |n| n.values else &.{};
            const names = try arena.alloc(syntax.ast.Name, words.len);
            for (names, words) |*n, w| n.* = .{ .text = w, .span = place.key.span };
            try out.append(arena, .{ .scope = "time", .fact = .{ .span = place.span, .name = .{ .text = place.values[0], .span = place.key.span }, .type = .{ .one_of = names }, .game = true } });
        }
        return out.items;
    }

    fn tagOf(tags: []const syntax.ast.Tag, key: []const u8) ?*const syntax.ast.Tag {
        for (tags) |*t| if (std.mem.eql(u8, t.key.text, key) and t.values.len > 0) return t;
        return null;
    }
};

/// A quest's kind, as a quest package declares one: each stage a fact within the quest, true once it is reached.
pub const quest_kind: check.Kind = .{ .name = "quest", .declare = Quest.declare };

const Quest = struct {
    fn declare(arena: std.mem.Allocator, s: *const syntax.ast.Section, _: []const syntax.ast.File) error{OutOfMemory}![]const check.Declared {
        const out = try arena.alloc(check.Declared, s.subsections.len);
        for (out, s.subsections) |*d, p| d.* = .{ .scope = "quests", .fact = .{ .span = p.name.span, .name = p.name, .type = .boolean, .game = true }, .within = true };
        return out;
    }
};

test "a registered kind's sections declare facts, named and typed beside the story's own" {
    var o = try checkOne(
        \\facts:
        \\  day:     int   (game)
        \\  weekday: int   (game)
        \\== school (calendar)
        \\= slot
        \\  [place slot] [names morning, evening]
        \\= week
        \\  [place weekday] [names monday, sunday]
        \\== a
        \\{ slot = evening } Evening.
        \\{ slot = noon } Noon.
        \\-> end
    , .{ .kinds = &.{calendar_kind} });
    defer o.deinit();
    try o.has(.err, 8, 4, "`weekday` is declared twice: first at a.river:3:3, then by the calendar `school`");
    try o.has(.err, 11, 10, "`noon` is not one of morning, evening");
    try std.testing.expectEqual(@as(usize, 2), o.diags.errors());
    const slot = o.checked.?.facts[o.checked.?.fact("slot").?.raw()];
    try std.testing.expectEqualStrings("time", slot.scope.?);
    try std.testing.expect(slot.game);
    try std.testing.expectEqualStrings("school", o.checked.?.sections[slot.by.?.raw()].name);
}

test "what a section declares within it is `section.name` outside it, and `name` inside" {
    var o = try checkOne(
        \\facts:
        \\  day: int   (clock)
        \\== pelts (quest)
        \\= asked   when { day > 1 }
        \\= late    when { asked and day > 3 }
        \\== a
        \\{ pelts.late } Too late.
        \\{ asked } Asked.
        \\-> end
    , .{ .kinds = &.{quest_kind} });
    defer o.deinit();
    try o.only(.err, 8, 3, "nothing is called `asked`: no fact or constant");
    try std.testing.expect(o.checked.?.fact("pelts.asked") != null);
}

test "a section's own facts are named within it, and its roles never set by the story" {
    var o = try checkOne(
        \\facts:
        \\  met: bool   (game)
        \\  lost: ref of person   (role)
        \\== stranger (quest)
        \\facts (player):
        \\  asked: set of tom, danny
        \\  who: ref of person   (role)
        \\  met: bool
        \\= named   when { asked has tom and who = tom }
        \\== a
        \\{ stranger.asked has danny } Danny.
        \\[stranger.asked += tom]
        \\[stranger.who = tom]
        \\-> end
    , .{ .kinds = &.{quest_kind} });
    defer o.deinit();
    try o.has(.err, 3, 3, "`(role)` is a thing a section is given: declare `lost` in the section's own `facts:`");
    try o.has(.err, 8, 3, "`met` in `stranger` would hide `met`, declared at a.river:2:3, inside it: name one otherwise");
    try o.has(.err, 13, 2, "`stranger.who` is a role, given when its section starts: the story reads it and never sets it");
    try std.testing.expectEqual(@as(usize, 3), o.diags.errors());
    const asked = o.checked.?.facts[o.checked.?.fact("stranger.asked").?.raw()];
    try std.testing.expectEqualStrings("player", asked.scope.?);
    try std.testing.expect(o.checked.?.facts[o.checked.?.fact("stranger.who").?.raw()].role);
}

/// A quest's kind that keeps a quest tagged `repeat` per thing of its own name: one instance a thing.
pub const repeat_kind: check.Kind = .{ .name = "quest", .declare = Quest.declare, .per = Repeat.per };

const Repeat = struct {
    fn per(s: *const syntax.ast.Section) ?syntax.ast.Name {
        for (s.tags) |t| if (std.mem.eql(u8, t.key.text, "repeat")) return s.name;
        return null;
    }
};

test "a section kept per thing reads and writes its own for the one it is evaluated for" {
    var o = try checkOne(
        \\facts:
        \\  lead: ref of bounty   (game)
        \\== bounty (quest)
        \\  [repeat]
        \\facts:
        \\  target: ref of person   (role)
        \\  asked: set of tom, danny
        \\  kills(person): int
        \\= ask   when { asked has tom and target = tom and kills(tom) > 0 }
        \\  [asked += danny]
        \\  [asked(lead) -= tom]
        \\== a
        \\{ bounty.asked has tom } No.
        \\{ bounty.asked(lead) has tom and bounty.ask(lead) } Yes.
        \\-> end
    , .{ .kinds = &.{repeat_kind} });
    defer o.deinit();
    try o.has(.err, 8, 3, "`kills` is in `bounty`, which keeps it per bounty: it takes no key of its own");
    try o.has(.err, 13, 3, "`bounty.asked` is kept per bounty: read it for one, `bounty.asked(…)`");
    try std.testing.expectEqual(@as(usize, 3), o.diags.errors());
    const c = o.checked.?;
    const asked = c.facts[c.fact("bounty.asked").?.raw()];
    try std.testing.expectEqualStrings("bounty", c.kinds[asked.key.?.ref.raw()]);
    try std.testing.expect(c.facts[c.fact("bounty.ask").?.raw()].key != null);
}

test "a name a section declares within it never hides the story's own there" {
    var o = try checkOne(
        \\facts:
        \\  met: bool   (game)
        \\== stranger (quest)
        \\= met
        \\= named   when { met }
    , .{ .kinds = &.{quest_kind} });
    defer o.deinit();
    try o.only(.err, 4, 3, "`met` in `stranger` would hide `met`, declared at a.river:2:3, inside it: name one otherwise");
}

test "a package judges its own tags' values, and says what is wrong where the value is written" {
    const Stages = struct {
        // `after` names other stages of the quest it stands in
        fn after(c: *check.Checker, t: check.Schema.Tagged) error{OutOfMemory}!void {
            const s = c.section(t.section.?);
            for (t.tag.values, 0..) |v, i| {
                if (std.mem.eql(u8, s.parts[t.part.?].name, v)) try c.err(t.tag.at(i), "`{s}` comes after itself", .{v});
                for (s.parts) |p| {
                    if (std.mem.eql(u8, p.name, v)) break;
                } else try c.err(t.tag.at(i), "`{s}` is not a stage of `{s}`", .{ v, s.name });
            }
        }
    };
    const quest_tags: check.Schema = .{ .keys = &.{
        .{ .name = "after", .on = .{ .part = true }, .value = .{ .judge = Stages.after }, .count = .many },
    } };
    var o = try checkOne(
        \\== pelts (quest)
        \\= asked
        \\= late
        \\  [after asked, akked]
        \\= early
        \\  [after]
        \\= done
        \\  [after done]
    , .{ .kinds = &.{.{ .name = "quest", .schema = &quest_tags }} });
    defer o.deinit();
    try o.has(.err, 4, 17, "`akked` is not a stage of `pelts`");
    try o.has(.err, 6, 4, "`after` takes at least one value");
    try o.has(.err, 8, 10, "`done` comes after itself");
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
        \\  [honor += 1]
        \\= rich     when { gold() > 100 }
        \\  [honor += 1]
        \\= loose
        \\  [honor -= 1]
        \\= loud     when { honor < 0 }
        \\  Honor is low.
    , .{});
    defer o.deinit();
    try o.has(.err, 8, 3, "`since_changed` is kept by what watches conditions: a rule or a quest, not `a`");
    try o.has(.err, 9, 4, "`honor_rules` holds rules: they fire when their conditions become true, and nothing goes to them");
    try o.has(.err, 11, 40, "`day` is not a clock: since_changed counts on a fact declared `(clock)`");
    try o.has(.err, 13, 19, "`gold` is asked by a rule, which wakes only when what it reads changes: declare what it reads, `(reads …)`");
    try o.has(.err, 15, 3, "the rule `loose` needs its condition: `= loose when { … }`, its effects under it");
    try o.has(.err, 18, 3, "a rule's body is its effects, `[…]`: a rule says nothing and goes nowhere");
}

test "only a watched condition asks queries that must declare what they read" {
    var o = try checkOne(
        \\extern:
        \\  name(who: int) -> text
        \\  gold() -> int
        \\facts:
        \\  rich: bool
        \\== pelts (quest)
        \\= asked   when { gold() > 3 }
        \\  Pelts for {name(1)}.
        \\  [rich = gold() > 10]
    , .{ .kinds = &.{.{ .name = "quest" }} });
    defer o.deinit();
    try o.only(.err, 7, 18, "`gold` is asked by a watched condition, which wakes only when what it reads changes: declare what it reads, `(reads …)`");
}

test "a moment is seen only by rules and quests, and happened asks of moments alone" {
    var o = try checkOne(
        \\facts:
        \\  pulled:  one of a, b   (moment)
        \\  rang:    bool          (moment)
        \\  hour:    int           (game)
        \\  tick:    int           (clock) (moment)
        \\== a
        \\{ pulled = a } The lever moves.
        \\-> end
        \\== lever (rules)
        \\= any    when { happened(pulled) and happened(hour) }
        \\  [rang = true]
    , .{});
    defer o.deinit();
    try o.has(.err, 7, 3, "`pulled` is a moment, over once rules and quests have seen it: `a` would never see it");
    try o.has(.err, 10, 47, "`hour` is not a moment: `happened` asks of a fact declared `(moment)`");
    try o.has(.err, 5, 3, "`tick` is a clock or a moment: a clock lasts, and a moment is over at once");
    try std.testing.expectEqual(@as(usize, 3), o.diags.list.items.len);
}

test "a fact kept per thing is read and written for one key of its kind" {
    var o = try checkOne(
        \\facts:
        \\  opinion(person):  int
        \\  mood(one of calm, angry): bool
        \\  rank:  int
        \\  ticks(person): int   (clock)
        \\== a
        \\{ opinion > 3 } Liked.
        \\{ mood(calm) and opinion(3) > 1 } Calm.
        \\[opinion -= 5]
        \\[rank(margaret) = 2]
        \\[mood(angry) = true]
        \\-> end
    , .{});
    defer o.deinit();
    try o.has(.err, 5, 3, "`ticks` is kept per thing, so it cannot be a clock, a moment or text");
    try o.has(.err, 7, 3, "`opinion` is kept per person: read it for one, `opinion(…)`");
    try o.has(.err, 8, 26, "this is a number, where a person is wanted");
    try o.has(.err, 9, 2, "`opinion` is kept per person: write it for one, `opinion(…)`");
    try o.has(.err, 10, 2, "`rank` is a fact with one value: it takes no key");
}

test "a bounded int is set within its bounds, and a clock has none" {
    var o = try checkOne(
        \\const:
        \\  max_honor = 300
        \\facts:
        \\  honor: int from -100 to 100
        \\  day:   int from 0 to 9   (clock)
        \\== a
        \\[honor = 120]
        \\[honor = max_honor]
        \\[honor = -100]
        \\-> end
    , .{});
    defer o.deinit();
    try o.has(.err, 5, 3, "`day` is a clock, which only moves on: it has no bounds");
    try o.has(.err, 7, 10, "120 is past `honor`'s bounds, -100 to 100");
    try o.has(.err, 8, 10, "300 is past `honor`'s bounds, -100 to 100");
    try std.testing.expectEqual(@as(usize, 3), o.diags.list.items.len);
}

test "words chosen by a plural or a gender: known labels, none twice, other among them" {
    var o = try checkOne(
        \\cast:
        \\  marta  "Marta"
        \\    [gender female]
        \\facts:
        \\  pelts: int
        \\  name:  text
        \\== a
        \\{pelts as one: a pelt | few: pelts}.
        \\{marta as feminine: she | feminine: her | other: they}.
        \\{name as one: x | other: y}.
        \\-> end
    , .{});
    defer o.deinit();
    try o.has(.err, 3, 6, "a gender is one of masculine, feminine, neuter or other");
    try o.has(.err, 8, 11, "words chosen by a plural or a gender need `other`, which every language falls back to");
    try o.has(.err, 9, 27, "`feminine` is chosen twice here");
    try o.has(.err, 10, 2, "words are chosen by a number's plural or by a gender, a person's or a thing's: this is text");
}

test "weight belongs on a pool's candidates and migrate on rules, within the story's version" {
    var o = try checkOne(
        \\version: 2
        \\facts:
        \\  honor: int
        \\== a
        \\-> p ->
        \\-> end
        \\== p (pool)
        \\= one    when { true }
        \\  [weight 0]
        \\  One.
        \\= two    when { true }
        \\  [migrate 2]
        \\  Two.
        \\== fixes (rules)
        \\= ahead
        \\  [migrate 3]
        \\  [honor += 1]
        \\= heavy  when { true }
        \\  [weight 2]
        \\  [honor += 1]
    , .{});
    defer o.deinit();
    try o.has(.err, 9, 4, "`weight` takes one whole number above 0, at most 65535");
    try o.has(.err, 12, 4, "`migrate` is riverrun's, and belongs on a rule");
    try o.has(.err, 16, 4, "a migration to version 3 needs a story of that version: declare `version: 3`");
    try o.has(.err, 19, 4, "`weight` is riverrun's, and belongs on a pool's candidate");
}

test "a name is a tag or an action, never both, and the wrong form is refused naming the right one" {
    const schema: check.Schema = .{ .keys = &.{
        .{ .name = "picture", .on = .{ .line = true }, .value = .word },
        .{ .name = "cutscene", .on = .{ .section = true }, .value = .word },
    } };
    var o = try checkOne(
        \\extern:
        \\  show(name: ref of picture)
        \\  cutscene(name: ref of cutscene)
        \\== a
        \\[picture(door)]
        \\Go.
        \\  [show door]
        \\-> end
    , .{ .schema = &schema });
    defer o.deinit();
    try o.has(.err, 3, 3, "`cutscene` is an action and a tag the game knows: a name is one or the other");
    try o.has(.err, 5, 2, "`picture` is a tag, not an action: write `[picture …]`, without parentheses");
    try o.has(.err, 7, 4, "`show` is an action, not a tag: run it with `[show(…)]`");
    try std.testing.expectEqual(@as(usize, 3), o.diags.list.items.len);
}

test "an action named as a tag is refused with no schema too" {
    var o = try checkOne(
        \\extern:
        \\  show(name: ref of picture)
        \\== a
        \\Go.
        \\  [show door]
        \\-> end
    , .{});
    defer o.deinit();
    try o.only(.err, 5, 4, "`show` is an action, not a tag: run it with `[show(…)]`");
}

test "a delivery is a tag of the key the host names, typed by its schema, and refused where it names none" {
    const schema: check.Schema = .{ .keys = &.{
        .{ .name = "mood", .on = .{ .line = true }, .value = .{ .words = &.{ "laughing", "quiet" } } },
    } };
    const story =
        \\cast:
        \\  astro  "Astro"
        \\== a
        \\ASTRO (laughing): Fuck you.
        \\ASTRO (laughin): Not even close.
        \\-> end
    ;
    var typed = try checkOne(story, .{ .schema = &schema, .delivery = "mood" });
    defer typed.deinit();
    try typed.only(.err, 5, 8, "`mood` takes one of laughing, quiet: `laughin` is not one");
    var none = try checkOne(story, .{ .schema = &schema });
    defer none.deinit();
    try none.has(.err, 4, 7, "`(laughing)` is a delivery, and this game takes none: its vocabulary names no key for one (`Options.delivery`)");
    try none.has(.err, 5, 7, "`(laughin)` is a delivery, and this game takes none: its vocabulary names no key for one (`Options.delivery`)");
    try std.testing.expectEqual(@as(usize, 2), none.diags.list.items.len);
}
