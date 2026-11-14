//! The six excerpts of design B as its proposal wrote them (`.wt/agents/river-syntax/PROPOSAL.md`, 5.1 to 5.6),
//! each read and checked against a vocabulary that declares the names it uses: a host's tags, a quest's kind, the
//! cast, the facts and the externs. Each reads with no diagnostic and checks with none but what is noted.

const std = @import("std");
const syntax = @import("../syntax.zig");
const check = @import("../check.zig");

const Schema = check.Schema;
const on_section: Schema.Places = .{ .section = true };
const on_line: Schema.Places = .{ .line = true };
const on_choice: Schema.Places = .{ .choice = true };
const on_part: Schema.Places = .{ .part = true };

/// `files` read and checked with `options`: no diagnostic but the warnings in `warnings`, in any order.
fn clean(files: []const []const u8, options: check.Options, warnings: []const []const u8) !void {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: syntax.Diagnostics = .{};
    defer diags.deinit(gpa);
    const trees = try arena.allocator().alloc(syntax.ast.File, files.len);
    for (files, trees, 0..) |text, *tree, i| tree.* = try syntax.parse(arena.allocator(), gpa, &diags, @intCast(i), try arena.allocator().print("f{d}.river", .{i}), text); // safe: a test's few files
    var checked = try check.run(gpa, &diags, trees, options);
    defer checked.deinit();
    var expected: usize = 0;
    for (diags.list.items) |d| {
        const known = d.severity == .warning and for (warnings) |w| {
            if (std.mem.eql(u8, w, d.message)) break true;
        } else false;
        if (known) {
            expected += 1;
            continue;
        }
        const at = trees[d.span.file].place(d.span);
        std.debug.print("{s}:{d}:{d}: {s}\n", .{ trees[d.span.file].path, at.line, at.col, d.message });
    }
    try std.testing.expectEqual(diags.list.items.len, expected);
    try std.testing.expectEqual(warnings.len, expected);
}

test "5.1 1969: a line's tags and effects under it, a section's under its heading, ids at the lines' ends" {
    const schema: Schema = .{ .keys = &.{
        .{ .name = "listen", .on = on_section },
        .{ .name = "card", .on = on_section },
        .{ .name = "count", .on = on_section, .value = .number },
        .{ .name = "beat", .on = on_section, .value = .number },
        .{ .name = "then", .on = on_section, .value = .section, .leads = true },
        .{ .name = "picture", .on = on_section, .value = .word, .count = .many },
        .{ .name = "at", .on = on_line, .value = .number },
        .{ .name = "heard", .on = on_line, .value = .{ .values_of = "spot" }, .count = .many },
        .{ .name = "pause", .on = on_line, .value = .number },
    } };
    try clean(&.{
        \\cast:
        \\  mum       "Mum"
        \\  dad       "Dad"
        \\  margaret  "Margaret"
        \\facts (player):
        \\  carried: set of play, gave, hands
        \\facts (life):
        \\  spot: one of stairs, piano, door, landing   (game)
        \\== kitchen_1985
        \\-> end
        ,
        \\== hide_1969
        \\  [listen] [count 20] [beat 1.35] [then found_1969]
        \\MUM: She was at the piano again today. She found middle C on her own. ^a81f0c
        \\  [at 2.5] [heard piano, door]
        \\DAD: Then lock it. ^b02e91
        \\  [at 6.5] [heard door]
        \\MUM: You could still play, Frank. ^k7f3a2
        \\  [at 9.5] [heard piano, door, landing]
        \\  [carried += play]
        \\DAD: Who'd listen? ^m2c9qd
        \\  [at 12.5] [heard piano]
        \\  [carried += play]
        \\MUM: You gave up the conservatory for us. You don't get to give her up too. ^p4w8e1
        \\  [at 16] [heard door]
        \\  [carried += gave]
        \\DAD: I'd do it again. ^r6t1y5
        \\  [at 21] [heard door, landing]
        \\MUM: She has your hands, you know. Look at them sometime. ^s9u3i7
        \\  [at 24] [heard landing]
        \\  [carried += hands]
        \\
        \\== found_1969
        \\  [card] [picture hide]
        \\{ spot = stairs }
        \\  Margaret finds her in four seconds.
        \\  MARGARET: You always hide there.
        \\{ spot = piano }
        \\  Margaret walks past the piano three times. The third time she stops, and listens, and walks on.
        \\{ spot = door }
        \\  The kitchen door opens. Dad looks down at her for a long time.
        \\  DAD: How long have you been there?
        \\  He doesn't wait for an answer.
        \\{ spot = landing }
        \\  Nobody finds her. She falls asleep on the landing with her cheek on the carpet.
        \\- In the morning the piano is locked.
        \\  [pause 0.5]
        \\-> kitchen_1985
    }, .{ .schema = &schema }, &.{});
}

test "5.2 1985: choices with their tags and effects under them, a gather named, quoted words in a tag" {
    const schema: Schema = .{ .keys = &.{
        .{ .name = "talk", .on = on_section },
        .{ .name = "fork", .on = on_section },
        .{ .name = "seam", .on = on_section },
        .{ .name = "picture", .on = .{ .section = true, .choice = true }, .value = .word, .count = .many },
        .{ .name = "pause", .on = on_line, .value = .number },
        .{ .name = "known", .on = on_choice, .value = .{ .values_of = "carried" } },
        .{ .name = "side", .on = on_choice, .value = .{ .values_of = "life" } },
        .{ .name = "line", .on = on_choice, .value = .text },
    } };
    try clean(&.{
        \\cast:
        \\  dad  "Dad"
        \\facts (player):
        \\  carried: set of play, gave, hands   (game)
        \\facts (life):
        \\  life: one of stay, go
        \\extern:
        \\  lived(one of stay, go) -> bool
        \\== day_1998
        \\-> end
        ,
        \\== kitchen_1985
        \\  [talk] [picture kitchen_1985]
        \\The scholarship letter has been on the fridge for a month. The last bus north leaves at 22:40. Her case has been packed since Sunday.
        \\Dad has been ill since the spring. He doesn't look up.
        \\  [pause 0.3]
        \\DAD: Go.
        \\- (ask)
        \\* Who'll run the shop?
        \\  DAD: I ran it before you could walk. I'll run it after you've gone.
        \\  -> ask
        \\* You're not well.
        \\  DAD: I'm not dead. Go.
        \\  -> ask
        \\* { carried has play } You could still play, Dad.
        \\  [known play]
        \\  DAD: Who'd listen?
        \\  The same two words. You were eight, behind the piano. He doesn't know you heard them.
        \\  -> ask
        \\* { carried has gave } You gave yours up.
        \\  [known gave]
        \\  He looks up for the first time.
        \\  DAD: And look what I got for it.
        \\  He means her. He means it.
        \\  -> ask
        \\* Pick up the case.
        \\  DAD: Go on. Go.
        \\  22:31. The bus stop is four minutes away.
        \\  -> fork_1985
        \\
        \\== fork_1985
        \\  [fork] [seam]
        \\* { not lived(go) } Get on
        \\  [side go] [picture fork_go] [line "the scholarship · the city · whoever she'd be"]
        \\  [life = go]
        \\  -> day_1998
        \\* { not lived(stay) } Stay
        \\  [side stay] [picture fork_stay] [line "her father · the shop · whoever she already is"]
        \\  [life = stay]
        \\  -> day_1998
    }, .{ .schema = &schema }, &.{});
}

test "5.3 deep branching: a call that comes back, a delivery, choices in a choice, a gather, a block and else" {
    const schema: Schema = .{ .keys = &.{
        .{ .name = "then", .on = on_section, .value = .section, .leads = true },
        .{ .name = "talk", .on = on_section },
        .{ .name = "picture", .on = on_section, .value = .word, .count = .many },
        .{ .name = "at", .on = on_choice, .value = .{ .words = &.{ "morning", "noon", "afternoon", "evening" } }, .count = .many },
        .{ .name = "who", .on = .{ .line = true, .choice = true }, .value = .text },
        .{ .name = "marked", .on = .{ .line = true, .choice = true } },
        .{ .name = "known", .on = on_choice, .value = .{ .values_of = "carried" } },
        .{ .name = "pause", .on = on_line, .value = .number },
        .{ .name = "delivery", .on = on_line, .value = .text },
    } };
    try clean(&.{
        \\cast:
        \\  dad  "Dad"
        \\facts (player):
        \\  carried: set of play, gave, hands   (game)
        \\facts (life):
        \\  life: one of stay, go   (game)
        \\  kept: set of dad, radio
        \\  said: set of gave
        \\const:
        \\  dies_at = "ten past nine"
        ,
        \\== day_1998
        \\  [then deathbed_1998]
        \\{ life = stay }
        \\  + { kept hasnt dad } Visit Dad at St Anne's
        \\    [at noon, afternoon] [who Dad] [marked]
        \\    St Anne's is a bus and a walk. She runs the walk.
        \\    [kept += dad]
        \\    -> deathbed_1998 ->
        \\    She takes the long way home, past the shop.
        \\
        \\== deathbed_1998
        \\  [talk] [picture deathbed_1998]
        \\He is very thin. He knows her straight away.
        \\DAD: { life = go: You came all this way. | You came. }
        \\- (ask)
        \\* How are you feeling?
        \\  DAD: Like a man in a bed.
        \\  -> ask
        \\* { carried has gave } You gave it up for me.
        \\  [known gave]
        \\  [said += gave]
        \\  DAD (quietly): I'd do it again.
        \\    [pause 0.2]
        \\  DAD: Don't you dare give yours up.
        \\  * { life = go } I didn't.
        \\    DAD: I know. I read about you. I cut it out.
        \\    { kept has radio }
        \\      DAD: I heard you on the wireless, too. A kitchen, you said.
        \\    { else }
        \\      He shows her where, in the drawer, the clipping is.
        \\  * { life = stay } I already did.
        \\    He closes his eyes for so long she thinks he's asleep.
        \\    DAD: Then you've got it to give back.
        \\  * Say nothing.
        \\    She holds his hand instead.
        \\  - He looks at the window for a while.
        \\  -> ask
        \\* Sleep, Dad. I'm here.
        \\  He sleeps. She stays.
        \\  Frank Marlowe died at {dies_at} that night, with the radio on and her hand on the blanket.
        \\    [pause 0.4]
        \\  <-
    }, .{ .schema = &schema, .delivery = "delivery" }, &.{});
}

const Quest = struct {
    const tags: Schema = .{ .keys = &.{
        .{ .name = "title", .on = on_section, .value = .text },
        .{ .name = "scope", .on = on_section, .value = .word },
        .{ .name = "stage", .on = on_part },
        .{ .name = "objective", .on = on_part },
        .{ .name = "outcome", .on = on_part },
        .{ .name = "active", .on = on_part, .value = .word },
        .{ .name = "after", .on = on_part, .value = .word, .count = .many },
    } };
    const kind: check.Kind = .{ .name = "quest", .schema = &tags, .declare = declare };

    // Each stage a fact the quest keeps, named within it, as a quest package declares them.
    fn declare(arena: std.mem.Allocator, s: *const syntax.ast.Section, _: []const syntax.ast.File) error{OutOfMemory}![]const check.Declared {
        const out = try arena.alloc(check.Declared, s.subsections.len);
        for (out, s.subsections) |*d, p| d.* = .{ .fact = .{ .span = p.name.span, .name = p.name, .type = .boolean, .game = true }, .within = true };
        return out;
    }
};

test "5.4 a quest: its tags under its heading and under each stage, a stage's effect, ids at the lines' ends" {
    try clean(&.{
        \\facts:
        \\  met:       bool   (game)
        \\  found:     set of letter, photo   (game)
        \\  the_hands: bool   (game)
        \\  carried:   set of play, gave, hands, his_name
        \\extern:
        \\  name(who: ref of person) -> text
        ,
        \\== the_stranger (quest)
        \\  [title "Who was he?"] [scope player]
        \\facts (player):
        \\  stranger: ref of person   (role)
        \\  asked: set of margaret, tom, danny
        \\
        \\= noticed      when { met }
        \\  [stage] [active spawn_stranger]
        \\  A man nobody knows stood at the foot of the coffin. ^q1a9
        \\= the_letter   when { found has letter }
        \\  [objective] [after noticed] [active pin_letter]
        \\  A letter signed "L.", from a city she never lived in. ^q1b2
        \\= named        when { the_letter and the_hands }
        \\  [outcome] [after the_letter]
        \\  [carried += his_name]
        \\  He was {name(stranger)}, her son, from a life she didn't live. ^q1d7
    }, .{ .kinds = &.{Quest.kind} }, &.{"nothing sets `the_stranger.asked`: declare it `(game)` if the game writes it"});
}

test "5.5 a courier: a cutscene as an effects step, an action's outcome, a block and else, a rule's effects" {
    const schema: Schema = .{ .keys = &.{
        .{ .name = "at", .on = on_section, .value = .text },
        .{ .name = "courier", .on = on_section },
    } };
    try clean(&.{
        \\cast:
        \\  margaret  "Margaret"
        \\extras: a courier
        \\facts:
        \\  letter: one of unsent, carried, read
        \\  paid:   bool
        \\  found:  set of letter, photo
        \\  turn:   int   (clock)
        \\extern:
        \\  cutscene(name: ref of cutscene)
        \\  give(what: ref of item_kind)
        \\  send(who: ref of person, why: ref of errand)
        \\  pay_fee(coins: int) -> bool   (action)
        ,
        \\// At day 12's evening tide comes due with this section's key; the game's courier walks to the player
        \\// and plays this when they meet.
        \\== courier_day12
        \\  [at day 12 evening] [courier]
        \\[cutscene(courier_at_the_gate)]
        \\A COURIER: Letter for you. Signed L. There's a fee on it, mind.
        \\* Pay the fee.
        \\  [paid = pay_fee(5)]
        \\  { paid }
        \\    A COURIER: Pleasure doing business.
        \\    [give(letter_from_l)]
        \\    [letter = carried]
        \\  { else }
        \\    You turn out your pockets. Lint, and a button.
        \\    A COURIER: Then it goes back to L.
        \\* Refuse it.
        \\  A COURIER: Suit yourself.
        \\- The courier is gone before the rain.
        \\-> end
        \\
        \\== letters (rules)
        \\= unopened   when { letter = carried and since_changed(letter, turn) >= 8 }
        \\  [send(margaret, asks_about_letter)]
        \\= opened     when { letter = read }
        \\  [found += letter]
    }, .{ .schema = &schema }, &.{});
}

test "5.6 Astro and Ruben: deliveries in parentheses, an action under a line, a cutscene between lines" {
    const schema: Schema = .{ .keys = &.{
        .{ .name = "talk", .on = on_section },
        .{ .name = "picture", .on = on_section, .value = .word, .count = .many },
        .{ .name = "delivery", .on = on_line, .value = .text },
    } };
    try clean(&.{
        \\cast:
        \\  astro  "Astro"
        \\  ruben  "Ruben"
        \\extern:
        \\  slap(who: ref of person, whom: ref of person)
        \\  cutscene(name: ref of cutscene)
        ,
        \\== the_slap
        \\  [talk] [picture bar_night]
        \\ASTRO: Fuck you.
        \\Astro slaps Ruben in the face, laughing manically.
        \\  [slap(astro, ruben)]
        \\RUBEN (stunned, quiet): Are you done?
        \\ASTRO (still laughing): Not even close.
        \\[cutscene(ruben_walks_out)]
        \\-> end
    }, .{ .schema = &schema, .delivery = "delivery" }, &.{});
}
