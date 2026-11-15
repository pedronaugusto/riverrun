# 12. What the checker proves

An AI asked for the toll gate on the far bank, a penny to pass up to the fair, wrote this first, and checked it:

```river refused
== toll
  [music fair_far_off]
A gate across the path, and a man in a box beside it with a lamp, a ledger, a dog and a great deal of patience.
TOLMAN: A penny to pass. Fair night, no exceptions.
- (ask)
* { coins > 1 } Pay the penny.
  [pay 1]
  A TOLLMAN: Mind the mud.
  -> fair
* { trust > 3 } Ask Otto to speak for you.
  OTTO: This one's with me, Walter.
  [vouched = true]
  -> fair
```

```console
$ riverrun check toll.river
toll.river:17:1-17:112: error: the line is 111 columns wide, past the game's 100
toll.river:18:1-18:7: error: `TOLMAN` is not a speaker: speakers come from `cast:` and `extras:`
toll.river:21:4-21:7: error: `pay` is an action, not a tag: run it with `[pay(…)]`
toll.river:24:5-24:14: warning: this choice can never be offered: its condition can never hold
```

That is `mistakes/12/toll.river`. Four problems, each on a row of its own, and each says what to write instead. This
chapter is about reading them, what the checker can know and what it cannot, and the loop a writer, or an AI,
runs to get from a first draft to a story that plays as meant.

## Reading a diagnostic

```
toll.river:18:1-18:7: error: `TOLMAN` is not a speaker: speakers come from `cast:` and `extras:`
```

- `toll.river`: the file, as it was given to the program.
- `18:1-18:7`: where the problem starts and where it ends, each as line and column, counting from 1. The end is
  just past the last character, so `18:1-18:7` is the six letters of `TOLMAN`. A range whose two ends are the same,
  `12:5-12:5`, is a place to insert something.
- `error` or `warning`. A story with an error is not played, and the game's build refuses it. A warning is
  something to look at, and the story still plays and builds.
- the message: what is wrong, and where it can, what to write instead.

The checker reports every problem it finds, not only the first, one to a row, in one form whatever the command:
a person reads it, an editor jumps to it, and an AI can take it apart at the colons. A problem with a whole file has
its path alone before `error:` (a file that is not there); one with no file at all, such as the game's vocabulary
naming a start that is not in the story, begins `riverrun:`. Past 1,024 problems, the last row says how many more
were found. When nothing is wrong, `riverrun check` prints nothing.

## What a story that checks has

When `riverrun check` prints nothing, the checker has proved, of every file given together:

- every name is declared: each speaker in the cast or the extras, each fact, label, section, part, query and
  action, each of the game's things in the game's list;
- every value is of its kind: a `one of` is one of its words, a bounded int within its bounds where the checker can
  tell, an action's outcome is kept in a fact, a sum is between ints and never a formula;
- every tag is one the game's vocabulary knows, where it may stand, with values it takes;
- the story never sets a fact the game writes;
- every way through every section ends: in `-> end`, `<-`, a jump, or a tag that leads on;
- every section is reached from where the game starts the story;
- no choice or pool candidate is written that can never be offered or picked, where that can be told;
- every line and choice fits the game's width, and the story fits what a compiled story holds;
- no line id is used twice, and under `--release`, every line and choice has one;
- and whatever the game's packages check (quests that can get stuck, a calendar that does not hold together).

What the build refuses, the checker refuses: `riverrun check` compiles the story too, writing nothing, so a story
that checks builds.

It does not prove that the story says what you meant. A choice closed when it should be open, a line said in the
wrong order, a scene that is dull: that is what a play is for (below).

## The kinds of message

**A name.** ``nothing is called `aks`: no section, part of this one, or label here`` ([chapter 2](02-choices.md)),
`` `TOLMAN` is not a speaker ``, ``the game has no item called `lanturn` `` ([chapter
7](07-the-games-vocabulary.md)). A typo, or a declaration missing: put the name right, or declare it where the
message says names come from.

**A kind of value.** `` `snowing` is not one of pouring, easing, stopped ``, `` `coins` is the game's, declared
`(game)`: the story reads it and never sets it `` ([chapter 3](03-remembering.md)), `` `*` multiplies, and a
formula is the game's `` ([chapter 7](07-the-games-vocabulary.md)). The message names the kind wanted: write a
value of it, or ask the game through a query.

**A tag or an effect.** `` `pase` is not a tag the game knows ``, `` `[sound]` is a tag, and a tag belongs to
what it describes ``, `` `pay` is an action, not a tag: run it with `[pay(…)]` `` ([chapter
4](04-telling-the-game.md)). Which tags there are is the game's vocabulary; what a bracket belongs to is where it
is indented.

**Where a way ends.** ``the part `midstream` can run off its end: end it with `-> end`, `<-` or a flow elsewhere``
([chapter 5](05-scenes-and-flow.md)) is an error: some way through, a choice's rows or a condition's, stops with
nowhere to go. It is placed on the section's or the part's name; follow each choice and condition in it to the way
whose last row is not a flow. ``nothing reaches this: the story always goes elsewhere before it`` is a warning on a
row that can never be said, because every way before it has gone somewhere else: often a `->` written where `->
name ->` was meant. ``nothing reaches `x` from where the story starts`` is an error on a section no way leads to.
Without a list of starts in the game's vocabulary, every section nothing goes to is a start, so this names a
section that only such unreached sections go to.

**Never.** ``this choice can never be offered: its condition can never hold`` and ``the candidate `x` can never be
picked`` ([chapter 8](08-pools.md)) are warnings: the condition asks for something no story can have. Above,
`trust > 3` asks more of a fact that holds at most 3. The checker knows each fact's kind and each int's least and
most: a number is itself, a bounded fact its bounds, a sum the least and most of its sides added. From those it can
tell that `trust > 3` never holds, nor `rain = pouring and rain = easing`. What it cannot tell, it does not say: a
query's answer, an int with no bounds, how facts move as the story runs. It never says never of a condition that
can hold.

**A fact nobody sets.** ``nothing sets `x`: declare it `(game)` if the game writes it`` is a warning on a fact no
effect in the story writes: either the game writes it, and it is declared so, or a row that sets it is missing.

**Widths and limits.** ``the line is 111 columns wide, past the game's 100``: the game's vocabulary says how wide a
line and a choice may be, a subtitle's or a button's room, and the checker measures each as a player would see it,
the wider words where they are chosen. Shorten it, or make two lines of it. A compiled story holds at most 32
choices offered at once, braces nested 8 deep in a line's words, 32 links in one chain of `and`, `or`, `+` or `-`,
and a name, with the names it is written within, of 256 bytes. Each is named where it is met. This stall, written out
from a list of Otto's wares, `mistakes/12/limits/stall.river`, offers 33:

```river refused
== stall
OTTO: What'll it be?
- (wares)
* The needles.
  -> wares
* The thread.
  -> wares
```

```console
$ riverrun check stall.river
stall.river:8:1-9:11: error: this offers more choices at once than a compiled story holds (32)
```

A player cannot read 33 choices either: offer the kinds of ware first, and the wares of each kind under it.

**Ids.** `the line id `x` is used twice` is an error in any build: a copied row kept its id ([chapter
6](06-text-that-varies.md)). A release needs an id on every line and choice, and `riverrun check --release`, or
`riverrun tag --check`, says where one is missing. In a game's checks before a release:

```console
$ riverrun check --release toll.river
toll.river:17:1-17:79: error: a release needs an id on every line and choice, `^…` at the end of its row: `riverrun tag` writes them
toll.river:18:1-18:55: error: a release needs an id on every line and choice, `^…` at the end of its row: `riverrun tag` writes them
toll.river:20:1-20:32: error: a release needs an id on every line and choice, `^…` at the end of its row: `riverrun tag` writes them
toll.river:22:3-22:27: error: a release needs an id on every line and choice, `^…` at the end of its row: `riverrun tag` writes them
toll.river:24:1-24:43: error: a release needs an id on every line and choice, `^…` at the end of its row: `riverrun tag` writes them
toll.river:25:3-25:36: error: a release needs an id on every line and choice, `^…` at the end of its row: `riverrun tag` writes them
toll.river:28:1-28:29: error: a release needs an id on every line and choice, `^…` at the end of its row: `riverrun tag` writes them
toll.river:29:3-29:51: error: a release needs an id on every line and choice, `^…` at the end of its row: `riverrun tag` writes them
toll.river:31:1-31:28: error: a release needs an id on every line and choice, `^…` at the end of its row: `riverrun tag` writes them
toll.river:35:1-35:39: error: a release needs an id on every line and choice, `^…` at the end of its row: `riverrun tag` writes them
toll.river:36:13-36:92: error: a release needs an id on every line and choice, `^…` at the end of its row: `riverrun tag` writes them
```

`riverrun tag toll.river` writes them all, and the same check then prints nothing.

## How far the checker can tell

The checker reads the story; it does not play it. Where a way goes depends on facts only a play has, it follows
every way that could be taken, and where it cannot know, it takes it that the story can go on. So a story that
checks can still go wrong as it plays. This one, `stories/12/round/toll.river`, has the tollman ask again after
each answer:

```river
- (ask)
* { coins >= 1 } Pay the penny.
  [pay(1)]
  A TOLLMAN: Mind the mud.
  -> fair
* { trust > 0 } Ask Otto to speak for you.
  OTTO: This one's with me, Walter.
  [vouched = true]
  -> fair
* Ask what the fair is like.
  A TOLLMAN: Loud. Muddy. Worth a penny, some say.
-> ask
```

It checks, and prints nothing: a way through it ends at `-> fair` and goes on there. But a player with no coin and
no friend in Otto, once they have asked about the fair, has no choice open. The story goes on past the choices, to
`-> ask`, and round again, with nothing to wait for:

```console
$ riverrun play -i 3 toll.river
== toll
  [music fair_far_off]
A gate across the path, and a man in a box beside it with a lamp and a ledger.
A TOLLMAN: A penny to pass. Fair night, no exceptions.
* 1 (closed) Pay the penny.
* 2 (closed) Ask Otto to speak for you.
* 3 Ask what the fair is like.
> 3
A TOLLMAN: Loud. Muddy. Worth a penny, some say.
toll.river:19:1-19:8: error: the story walked 100,000 steps and said nothing: jumps in a loop (NoProgress)
```

The play stops, with the status 4, names what went wrong, and places it where the loop comes round: `- (ask)`.
The checker cannot tell that every choice will be closed or gone at once, since that depends on the facts as they
stand; keep a way out that is always open ([chapter 2](02-choices.md)), as `Go back down to the boat.` was. A loop that says something every time round is stopped the same way, once
it has gone round 10,000 times more than the story has steps, naming the sections it keeps coming back to
(`Endless`).

## Exit statuses

Every command says how it went by its exit status, which a script, a build or an AI reads without reading the
output:

| status | `check` | `tag` | `play` |
|---|---|---|---|
| 0 | no error (warnings allowed) | done; under `--check`, every line has its id | the story came to its end |
| 1 | an error, or a file that cannot be read | a file the reader refuses, or that cannot be written; under `--check`, a line without an id | the story does not check, or an input could not be taken |
| 2 | the command line is mistaken | the command line is mistaken | the command line is mistaken |
| 3 | | | the story waits for an input the script did not give |
| 4 | | | the story stopped on an error at run time |

A mistaken command line is answered on standard error with the usage (`riverrun: unknown command 'chek'; did you
mean 'check'?`). A play that waits says on standard error what it waits for. `riverrun compile` exits as `check`
does.

## The loop

A story is written by going round: write, check, play from a script, read the transcript, fix. An AI writing a story
goes round the same way, and every step of it is a command with an output to read and a status to act on.

**Write** the scene, and **check** it: `riverrun check` with every file of the story. Until it prints nothing, put
right what each row says, at the place it gives. The first draft above, put right row by row, is
`stories/12/draft/toll.river`:

```console
$ riverrun check toll.river
```

**Play it from a script**: a file of inputs, `toll.play`, one to a row as a player types them, with `//` before a
comment, and `--set` for what the game would have set. Write the script for what the scene is meant to do: here, a
player with one coin asks about the fair, then pays.

```console
$ riverrun play --set 'coins = 1' --script toll.play toll.river
> :set coins = 1
== toll
  [music fair_far_off]
A gate across the path, and a man in a box beside it with a lamp and a ledger.
A TOLLMAN: A penny to pass. Fair night, no exceptions.
* 1 (closed) Pay the penny.
* 2 (closed) Ask Otto to speak for you.
* 3 Ask what the fair is like.
* 4 Go back down to the boat.
> 3
A TOLLMAN: Loud. Muddy. Worth a penny, some say.
* 1 (closed) Pay the penny.
* 2 (closed) Ask Otto to speak for you.
* 3 Ask what the fair is like.
* 4 Go back down to the boat.
> 1
toll.play:3:1-3:2: error: choice 1 is closed: its condition does not hold
```

**Read the transcript.** The exit status is 1, and the last row says why, placed at the script's row: the player
could not pay. The rows above say more: `Pay the penny.` was closed from the start, with one coin set. Its condition
is `coins > 1`, two coins or more, where a penny is one: `coins >= 1`.

**Fix**, and go round again, from the check. `stories/12/toll.river` has the fix, and the same script plays to the
end, with the status 0:

```console
$ riverrun play --set 'coins = 1' --script toll.play toll.river
> :set coins = 1
== toll
  [music fair_far_off]
A gate across the path, and a man in a box beside it with a lamp and a ledger.
A TOLLMAN: A penny to pass. Fair night, no exceptions.
* 1 Pay the penny.
* 2 (closed) Ask Otto to speak for you.
* 3 Ask what the fair is like.
* 4 Go back down to the boat.
> 3
A TOLLMAN: Loud. Muddy. Worth a penny, some say.
* 1 Pay the penny.
* 2 (closed) Ask Otto to speak for you.
* 3 Ask what the fair is like.
* 4 Go back down to the boat.
> 1
[pay(1)]
A TOLLMAN: Mind the mud.
== fair
Up the hill, the lights and the noise.
-> end
```

A transcript is plain text, and the same script and story always print the same bytes: it holds no time, no
address, nothing that changes from one run to the next. So once a scene plays as meant, its script and transcript
can go in the game's tests, held to each other as this manual holds its own, and a later change that alters the
scene shows as a difference. Each row of a transcript says what it is by how it begins; [chapter
14](14-reference-card.md) lists them all.

Keep one script for each way through a scene that matters: here, paying, Otto speaking up (`--set 'trust = 1'`), and
turning back. A script tries a way in less time than it takes to play it by hand, and the transcript shows
everything the game would be told, which a play in a terminal shows only in passing. [Chapter 13](13-worked-scenes.md)
works whole scenes through.
