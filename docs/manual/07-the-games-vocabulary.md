# 7. The game's vocabulary

Ada has one crossing left tonight, and the player has one coin. How many crossings are left is the game's to know,
and whether Ada will take one coin instead of two is the game's to decide, by a roll, a check of the player's
standing, whatever the game does. The story asks for both by name.

```river
extern:
  crossings_left() -> int
  pay(int)
  give(ref of item)
  talk_down(who: ref of person, coins: int) -> bool (action)
```

```river
ADA (without looking up): { rain = pouring: I go when the rain eases. Not before. | Nearly. Give it a minute. }
{ crossings_left() = 1 } ADA: And that's the last crossing tonight.
```

```river
* { asked_price and coins = 1 } Offer her the one coin you have.
  [talked_down = talk_down(ada, 1)]
  { talked_down }
    ADA: One, then. Don't tell the boy.
    [pay(1)]
    -> crossing
  ADA: Two. I don't haggle in the rain.
  -> ask
```

That is `stories/07/ferry.river`: its `extern:`, a row added after Ada's first line, and a choice added after `I
haven't got two coins.` It also declares `talked_down: bool` among its facts.

The first half of this chapter is for the writer. The second, [for the programmer who wires the
game](#for-the-programmer-who-wires-the-game), is about the same words from the game's side.

## What the game does for a story

`extern:` lists what the game does when the story asks, one to a row. The shape of a row says which of three kinds
it is.

- `crossings_left() -> int` is a **query**: a question the game answers, with the kind of answer after `->`.
  Asking changes nothing, so the story asks a query wherever it reads a fact: in a condition, `{ crossings_left() =
  1 }`, or in a line's words, `{crossings_left()}`.
- `pay(int)` is an **action**, as in [chapter 4](04-telling-the-game.md): something the game does when the story
  tells it to, `[pay(1)]`. The story goes on at once.
- `talk_down(who: ref of person, coins: int) -> bool (action)` is an **action with an outcome**: the game does it,
  and says how it went. `(action)` marks it, and after `->` is the kind of outcome. The story waits for it.

What is in the parentheses is what each one is given. `who:` and `coins:` name the two things `talk_down` is given,
for whoever reads the row; `ref of person` is one of the game's people, named by an id. Which queries and actions
there are is the game's people's to say, and the story declares them so the checker can hold every use to them.

## An outcome

```river
  [talked_down = talk_down(ada, 1)]
```

This asks the game to try talking Ada down to one coin, and when the game says how it went, keeps the outcome in the
fact `talked_down`. The rows after it ask the fact as they would any other. An outcome is always kept so, in a fact
on the left of `=`; an action with none stands alone in its brackets, `[pay(1)]`.

The story never rolls a die or weighs a chance. A bargain, a fight, a lock picked: the game does it, by its own
rules, and the story is told the result and goes on from there.

## The game's things

`ada` in `talk_down(ada, 1)`, and `lantern` in `[give(lantern)]`, are ids of the game's things: a person, an item.
The game gives the checker every id it knows, so a name it does not know is a mistake (below). An id is letters,
digits and `_`, and the game's people say what they are.

## Playing it

In a play you are the game, so you give what it would: what a query answers, and an outcome when the story waits for
one. This is `stories/07/ferry.play`:

```console
$ riverrun play --set 'rain = easing' --set 'coins = 1' --set 'crossings_left() = 1' --script ferry.play ferry.river
> :set rain = easing
> :set coins = 1
> :set crossings_left() = 1
== landing
  [music rain_on_water] [picture landing_night]
Rain on the river, thinning.
A lantern on a post, and a boat tied up under it.
A BOY: Ferry! Last ferry over!
OTTO: She heard you the first time.
ADA (without looking up): Nearly. Give it a minute.
? crossings_left() = 1
ADA: And that's the last crossing tonight.
Otto hums to himself.
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 (closed) Offer her the one coin you have.
* 4 Look at the river.
* 5 Sit with Otto.
* 6 (closed) Pay, and get in.
  [marked]
* 7 Go home.
> 1
[asked_price = true]
ADA: Two coins. Same as always.
Otto counts the buttons on his coat.
* 1 I haven't got two coins.
* 2 Offer her the one coin you have.
* 3 Look at the river.
* 4 Sit with Otto.
* 5 (closed) Pay, and get in.
  [marked]
* 6 Go home.
> 2
? talk_down(ada, 1) -> true or false
> false
ADA: Two. I don't haggle in the rain.
Otto looks at the sky.
* 1 I haven't got two coins.
* 2 Look at the river.
* 3 Sit with Otto.
* 4 (closed) Pay, and get in.
  [marked]
* 5 Go home.
> :back
? talk_down(ada, 1) -> true or false
> true
ADA: One, then. Don't tell the boy.
[pay(1)]
== crossing
  [music oars]
The boat pushes off. Behind you the lantern on the post grows small.
== crossing
  [music oars]
= midstream
  [picture fog]
Halfway over, the fog comes down, and the far bank is gone.
== lamp
Ada's lantern swings at the prow, and lights nothing.
== crossing
  [music oars]
= midstream
  [picture fog]
OTTO: I can't see the bank.
ADA: You don't need to. I do.
* 1 Hold still.
* 2 Stand up to look.
> 1
== crossing
  [music oars]
= landfall
The keel scrapes on stones.
ADA: Out you get.
== far_bank
  [music fair_far_off] [picture far_bank]
Mud, a path, and up the hill the lights of the fair.
A cart goes by with its lamps unlit.
OTTO: Well. That's me.
ADA: Tell him the dogs up there bite.
-> end
```

**A query** is printed with its answer where the story asks it: `? crossings_left() = 1`. What a query answers is
the game's state, like a fact the game writes, so you set it the same way: `--set 'crossings_left() = 1'` before the
story starts, or `:set crossings_left() = 1` at any point in the play, and it answers so from then on. A query you
have not set answers with the first value of its kind (`0`, `false`, the first of a list) and is printed with `(not
set)` after it, so a play never goes one way on an answer you did not see.

**An outcome** is waited for: `? talk_down(ada, 1) -> true or false` says the story is waiting, and for what. The
next input is the outcome, as the game would give it: `true` or `false` here, a number for an int, one of the
words for a `one of`. In a terminal the play asks you then. The fact the outcome is kept in is not printed; `:facts`
shows it. `:back` takes back the last input, so `:back` then `true` has Ada take the coin after all: a script, too,
can try both ways.

## When the checker says no

This copy, `mistakes/07/ferry.river`, runs the action without keeping its outcome, and gives the player a lantern
the game has never heard of:

```river refused
* { asked_price and coins = 1 } Offer her the one coin you have.
  [talk_down(ada, 1)]
  { talked_down }
```

```river refused
  He puts a tin lantern in your hands.
  [give(lanturn)] [carrying += lantern]
```

```console
$ riverrun check ferry.river
ferry.river:50:4-50:13: error: `talk_down` has an outcome, which a fact keeps: `[fact = talk_down(…)]`
ferry.river:66:9-66:16: error: the game has no item called `lanturn`
ferry.river:16:3-16:14: warning: nothing sets `talked_down`: declare it `(game)` if the game writes it
```

The warning is the first error seen from the fact's side: with the outcome not kept, nothing sets `talked_down`.

## For the programmer who wires the game

A story and the game meet in two places: the game's vocabulary, a Zig file the game's build compiles in, and the
declarations at the top of the story, which say what the story reads and asks of the game. This part is about
both, and about how the game's build makes the `riverrun` program its writers run. A writer may read it to know
what can be declared; nothing in it changes how a story is written.

### The vocabulary

This is the manual's own, [stories/vocabulary.zig](stories/vocabulary.zig), whole:

```zig
//! The vocabulary of the game this manual's stories are written for: a small
//! game of a ferry crossing at night. A game's vocabulary says which tags its
//! stories may carry and where; this one has a few, so every example checks
//! as a game's story does. Your game has its own.

const riverrun = @import("riverrun-compiler");

const schema: riverrun.check.Schema = .{
    .keys = &.{
        // the music the game plays under a scene
        .{ .name = "music", .on = .{ .section = true }, .value = .word },
        // the picture the game shows behind a scene, or a part of one
        .{ .name = "picture", .on = .{ .section = true, .part = true }, .value = .word },
        // a sound the game plays as a line is said
        .{ .name = "sound", .on = .{ .line = true }, .value = .word },
        // how long the game holds a line before the next, in seconds
        .{ .name = "pause", .on = .{ .line = true }, .value = .number },
        // a choice the game shows with a mark beside it: one that matters
        .{ .name = "marked", .on = .{ .choice = true } },
        // how a line is said, `ADA (quietly):`: words for the actor and the translator
        .{ .name = "delivery", .on = .{ .line = true }, .value = .text },
        // a night the game plays room by room: the rooms the player may be in, the hours it moves them through, the
        // pool it asks what happens in each room at each hour, and the scene it goes on to when the night is over
        .{ .name = "rooms", .on = .{ .section = true }, .value = .{ .values_of = "room" }, .count = .many },
        .{ .name = "hours", .on = .{ .section = true }, .value = .number, .count = .many },
        .{ .name = "pool", .on = .{ .section = true }, .value = .section },
        .{ .name = "then", .on = .{ .section = true }, .value = .section, .leads = true },
    },
};

// the game's things a story names by id, `[give(lantern)]`: each kind with every id the game knows
const things: []const riverrun.check.Things = &.{
    .{ .kind = "item", .ids = &.{ "lantern", "needles", "thread", "buttons" } },
    .{ .kind = "person", .ids = &.{ "ada", "otto", "miller" } },
};

// the game's subtitles hold 100 columns, and its choices 40
const width: riverrun.check.Width = .{ .line = 100, .choice = 40 };

pub const options: riverrun.check.Options = .{ .schema = &schema, .delivery = "delivery", .things = things, .width = width };
```

It is Zig, not a data file, because a package's kinds and checks are functions: quests and time, chapters 10 and
11 in [the index](README.md), are packages. It declares `pub const options`, a `riverrun.check.Options`:

- `schema`: the tags, each key with where it may stand (`.on`: a cast entry, a section, a part, a line, a choice),
  its value (`.none` for a mark, `.number`, `.word`, `.text`, `.words` for a fixed list, `.values_of` a fact's
  values, `.section` a section of the story) and how many (`.count`: `.one`, `.many`, or `.any` for a key that is
  also a mark). A key on a section whose value is a section may be `.leads`: when the section ends, the game goes on
  to the one it names ([chapter 8](08-pools.md) has one).
- `delivery`: the key a speaker's delivery fills, `ADA (without looking up):`. Without one, a delivery is refused.
- `things`: the ids of the game's things, by kind. A kind not listed takes any id, so a game without a list of its
  things still builds.
- `entries`: the sections the game starts the story at. Without them, every section nothing goes to is one.
- `width`: the most columns a line's words and a choice's may take, and how many a value said in them counts for;
  the checker holds every line and choice to it ([chapter 12](12-what-the-checker-proves.md)).

A vocabulary that registers packages adds `pub const packages`, each package's `riverrun.Package`, and the game's
own checks of the whole story go in `pub const passes`.

### The story's declarations

The fair on the far bank is a story of two files, `stories/07/fair/fair.river` and `stories/07/fair/stall.river`,
which between them declare what this part is about:

```river
cast:
  otto     "Otto"         — a pedlar, at his stall
  miller   "Mrs Miller"   — from the mill, who buys on the slate

facts:
  hour: int   (clock)                // the fair's clock: the game moves it on
  owes(person): int from 0 to 20     // what each person owes Otto

const:
  closing = 22

extern:
  price(of: ref of item) -> int
  sell(what: ref of item, to: ref of person)
```

**`extern:`** is the game's side of the story's actions and queries, each by name. A **query** is pure: the story
may ask it at any time and as often as it likes, so asking must change nothing in the game. An **action** runs when the story reaches it, and an **action with an outcome**, `-> type (action)`, stops the
story until the game gives the outcome. A parameter is a type, or a name and a type: one parameter may stand alone,
`pay(int)`, and two or more are each named, `sell(what: ref of item, to: ref of person)`. The game binds each extern
by its name when it loads the compiled story; one left unbound, or bound with another signature, fails the load and
names it. A query that a rule or a quest asks, which wake only when what they read changes, declares what it reads
after it, `(reads stock(kind))`, so they are woken when its answer may have moved ([chapter 9](09-rules.md)).

**`ref of item`** is one of the game's things, which the story names by a stable id (`needles`) and the game
resolves to its own handle once, when it loads the story. `things` in the vocabulary is the list the checker holds
the ids to.

**Facts the game writes.** `(game)`, as in [chapter 3](03-remembering.md): the game sets it and the story only
reads it. `(clock)`: an int that only the game moves, and only on, never back: `hour` here, which the fair's lines
read as `{ hour >= closing }`. `(moment)`: something that just happened (a bell rung, a lever pulled), held until
the story's rules and quests have seen it and then gone, never saved; only they read one ([chapter 9](09-rules.md)).
A fact the story declares and nothing sets is a warning that names it.

**Scopes.** The game stores facts by scope, `facts (player):`, and may save or reset each alone. riverrun keeps
them apart and knows none of their names; facts with no scope are kept in a scope of their own, `default`.

**Facts kept per thing.** `owes(person): int from 0 to 20` holds a value for each person: read `owes(miller)`,
written `[owes(miller) += price(needles)]`. Its key is a thing's id, a fact holding one, or, for a fact kept per
value of a list, `mood(one of calm, angry): bool`, a value. It holds a value only for the keys set, each starting
where the fact does, so a fact kept for a few thousand people costs what the few set cost; and a rule that reads
`owes(miller)` wakes when Mrs Miller's value moves and no other's. It is never a clock, a moment or text.

**`const:`** is a value every run shares, written once: `closing = 22`. A constant is a value as written, never a
sum.

```river
module stall
facts:
  sold: int from 0 to 99   // what Otto has sold tonight
```

**Modules.** A file that begins `module stall` keeps its names to itself. Inside it, `sold` is its own fact and
`open` its own section; to every other file they are `stall.sold` and `stall.open`:

```river
-> stall.open ->
OTTO: {stall.sold as one: One sale | other: {stall.sold} sales} tonight. Could be worse.
```

A name with no module before it is looked for in the file's own module first, then among the names of the files
that have none. The cast, the extras and every fact are seen by every file. Many writers, and many hundreds of
files, each in a module of its own, never clash. A story is all its files at once, checked together:

```console
$ riverrun check fair.river stall.river
```

Nothing printed: nothing is wrong. Given `fair.river` alone, the checker would say `stall.open` and `stall.sold`
are not there.

**Counting.** A story adds and subtracts whole numbers: `{ hour >= closing - 1 }`, `[owes(miller) +=
price(needles)]`, `{stall.sold}`. A sum stands wherever an int does: either side of a comparison, the right of an
effect, a value a line says or chooses its words by, and what a query that takes an int is given. `+` and `-` bind
tighter than the comparisons and go left to right; parentheses group. Ints are 64 bits, and a sum that would pass
them stops the story with a named error, `Overflow`; a bounded fact that a change would carry past its end stops at
the end. What a story does not do is a formula: `*`, `/` and `%` are refused, and a price with its discount, a rate,
a percentage is the game's, asked for by name through a query. So is anything that loops. A `-` before a name is
refused too (`0 - x` says it), and so is a sum on the left of an effect's `=`: an effect writes one fact.

This copy of the stall, `mistakes/07/fair/stall.river`, works out a debt by multiplying and sells to a person the
game does not know:

```river refused
{ owes(miller) > price(needles) * 3 } OTTO: That's three cards you owe me for, Mrs Miller.
```

```river refused
  [owes(miller) += price(needles)]
  [sell(needles, millar)]
```

```console
$ riverrun check fair.river stall.river
stall.river:7:33-7:34: error: `*` multiplies, and a formula is the game's: a story adds and subtracts, and asks the game by name, through a query in `extern:`
stall.river:11:18-11:24: error: the game has no person called `millar`
```

### The build

A game's build compiles its story with `addStory`, which reads, checks and compiles the files with the game's
vocabulary and embeds the result in a module the game imports. It makes the `riverrun` program on the way, with the
same vocabulary in it, and hands it back to install, so the writers' `riverrun check` checks exactly what the build
does. These are the middle rows of [a game's build](stories/07/game/build.zig), the game's own `build` function,
as riverrun's README shows them:

```zig
const riverrun = @import("riverrun");
const river = b.dependency("riverrun", riverrun.building(b));
const story = riverrun.addStory(b, river, .{
    .files = &.{b.path("story/main.river")},
    .vocabulary = b.path("src/vocabulary.zig"),
});
exe.root_module.addImport("story", story.module);
// zig-out/bin/riverrun, with the game's vocabulary: riverrun check story/*.river
b.installArtifact(story.program);
// zig build story: the story checked, the game not built
b.step("story", "Check the story").dependOn(&story.check.step);
```

- `riverrun.building(b)` asks for riverrun built for the machine doing the building, where the compiler and the
  program run. Every package whose compiler side the vocabulary imports is asked the same way, and handed to
  `addStory` in `.packages` by the name the vocabulary imports it by.
- `story.module` embeds the compiled story, `graph` and `words`, the string table; the game loads them with the
  runtime, the `riverrun` module, built for the game's own target.
- `story.program` is the `riverrun` program; `story.check` is a step that runs `riverrun check` over the story's
  files. `.release = true` builds a release, which needs every id ([chapter 6](06-text-that-varies.md)).

A build that wants the program without compiling a story calls `riverrun.addProgram(b, river, .{ .vocabulary, .packages
})`, and `riverrun.addCheck(b, program, files, .{ .release })` makes a step that checks any files with it. This
manual's program is made that way, in riverrun's own `build.zig`: `addProgram` with
`stories/vocabulary.zig`, which `bay manual` installs.

### Playing the fair

```console
$ riverrun play --set 'owes(miller) = 3' --set 'price(needles) = 2' --wait 21 -i 1 fair.river stall.river
> :set owes(miller) = 3
> :set price(needles) = 2
> :wait 21
== fair
  [music fair_far_off]
Lamps on poles, mud underfoot, and somebody's pig loose among the stalls.
OTTO: Last hour. Then I'm for my bed.
== stall.open
OTTO: Needles, thread, buttons!
OTTO: And you still owe me 3, Mrs Miller.
MILLER: A card of needles. Put it on the slate.
* 1 Let her owe it.
* 2 Tell her it's money tonight.
> 1
? price(needles) = 2
[owes(miller) += 2] [sell(needles, miller)] [stall.sold += 1]
== fair
  [music fair_far_off]
OTTO: One sale tonight. Could be worse.
-> end
```

`:set owes(miller) = 3` sets one key of a fact kept per thing; `--wait 21`, or `:wait 21` in the play, moves the
game's clock on by 21, the one way a clock moves. A section of a module is printed with its module, `==
stall.open`. An effect is printed with its values worked out, `[owes(miller) += 2]`, and a play applies those on
facts and prints the actions, as in [chapter 4](04-telling-the-game.md). [Chapter 8](08-pools.md) lets the story
choose among lines.
