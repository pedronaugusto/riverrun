# 6. Text that varies, and travels

A player who looks at the river three times should not read the same words three times, and a player with one coin
should not read `1 coins`. This chapter is about the words inside a line that change: from one time to the next,
with a number, with who is spoken of. Then about what lets a line travel, into another language or an actor's voice:
its id.

## Words that change each time

```river
- (ask)
Otto {cycle: hums to himself | counts the buttons on his coat | looks at the sky}.
```

```river
+ Look at the river.
  {seq: Black water, moving fast under the rain. | Still black. Still moving. | The river is not going anywhere, and nor, it seems, are you.}
  -> ask
```

Braces that begin with a word and a colon hold alternatives, separated by `|`. Each time the line is said, one of
them is, and which depends on the word:

- `{seq: a | b | c}` says each in turn, then the last from then on.
- `{cycle: a | b | c}` says each in turn, then starts again from the first.
- `{once: a | b | c}` says each in turn, then nothing.
- `{shuffle: a | b | c}` says them in an order drawn afresh each time round, each once before any again.

The story remembers where each one is, so a story saved and loaded goes on where it was. A shuffle's order comes from
a seed the story keeps, so a play, and a replay, of the same inputs says the same.

`once` is for words a line says the first time only. On a line of its own, once used up, it leaves the line with no
words, and a line with no words is not said at all: the game is never handed it, and the effects under it are not
applied (the checker warns where they would be lost so). Inside a line's words, as here, the rest of the line
stands without it:

```river
= midstream
  [picture fog]
  Halfway over, the fog comes down{once: , and the far bank is gone}.
```

## Numbers

```river
* { asked_price and coins < 2 } I haven't got two coins.
  You count what you have: {coins as one: one coin | other: {coins} coins}.
```

`{coins as one: one coin | other: {coins} coins}` chooses words by the number: `one coin` for 1, and `{coins}
coins`, the number and the word, for anything else. The labels are the ones every language's plurals are named by:
`zero`, `one`, `two`, `few`, `many` and `other`. English needs `one` and `other`; other languages need more, and
`other`, which every language falls back to, must always be there. Any number stands before `as`: a fact, a sum,
what the game answers.

## Who is spoken of

```river
cast:
  ada    "Ada"    keeps the ferry
    [gender feminine]
  otto   "Otto"   a pedlar, going over for the fair
    [gender masculine]
```

```river
ADA: Tell {otto as masculine: him | feminine: her | other: them} the dogs up there bite.
```

`{otto as masculine: him | feminine: her | other: them}` chooses words by Otto's gender, which `[gender masculine]`
under his cast entry gives: a tag of riverrun's own, which every game takes on a cast entry. The labels are `masculine`, `feminine`, `neuter` and `other`, and `other` must be there.
Change the tag and every line written so follows. A person or a thing the game holds has the gender the game gives
it; [chapter 7](07-the-games-vocabulary.md) has facts that hold one.

## Playing them

```console
$ riverrun play --set 'rain = easing' --set 'coins = 1' -i 3 -i 3 -i 1 -i 1 -i 4 ferry.river
> :set rain = easing
> :set coins = 1
== landing
  [music rain_on_water] [picture landing_night]
Rain on the river, thinning.
A lantern on a post, and a boat tied up under it.
A BOY: Ferry! Last ferry over!
OTTO: She heard you the first time.
ADA (without looking up): Nearly. Give it a minute.
Otto hums to himself.
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 Look at the river.
* 4 Sit with Otto.
* 5 (closed) Pay, and get in.
  [marked]
* 6 Go home.
> 3
Black water, moving fast under the rain.
Otto counts the buttons on his coat.
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 Look at the river.
* 4 Sit with Otto.
* 5 (closed) Pay, and get in.
  [marked]
* 6 Go home.
> 3
Still black. Still moving.
Otto looks at the sky.
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 Look at the river.
* 4 Sit with Otto.
* 5 (closed) Pay, and get in.
  [marked]
* 6 Go home.
> 1
[asked_price = true]
ADA: Two coins. Same as always.
Otto hums to himself.
* 1 I haven't got two coins.
* 2 Look at the river.
* 3 Sit with Otto.
* 4 (closed) Pay, and get in.
  [marked]
* 5 Go home.
> 1
You count what you have: one coin.
ADA: Then you'd better find some more.
You look at Otto.
OTTO: Don't look at me.
  [trust -= 1]
Otto counts the buttons on his coat.
* 1 Look at the river.
* 2 Sit with Otto.
* 3 (closed) Pay, and get in.
  [marked]
* 4 Go home.
> 4
You turn up the lane, the way the boy went.
-> end
```

And across the river, standing up once, with Otto's good opinion:

```console
$ riverrun play --from crossing --set 'trust = 1' -i 2 -i 1 ferry.river
> :set trust = 1
== crossing
  [music oars]
The boat pushes off. Behind you the lantern on the post grows small.
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
> 2
The boat tips. Ada says something you are glad not to have heard.
Halfway over, the fog comes down.
== lamp
Ada's lantern swings at the prow, and lights nothing.
== crossing
  [music oars]
= midstream
  [picture fog]
OTTO: I can't see the bank.
ADA: You don't need to. I do.
* 1 Hold still.
> 1
= landfall
The keel scrapes on stones.
ADA: Out you get.
== far_bank
  [music fair_far_off] [picture far_bank]
Mud, a path, and up the hill the lights of the fair.
A dog barks somewhere up the hill.
OTTO: Well. That's me.
OTTO: Keep the lantern.
ADA: Tell him the dogs up there bite.
-> end
```

## A line is said whole

A line's words are everything after its colon, and the game is given the line whole: a sentence with its varying
words in their places. When the story is built, each line goes into a table of its own, the string table, with a
numbered place for each value and each choice of words. A translator writes the whole line again in their language,
in the order their language puts it, with their language's words for one and for many and for each gender, and the
game says the translated line in its place.

So write each sentence as one line, with what varies inside its braces. Two rows are two lines, to the game, the
translator and the actor: a sentence begun on one row and finished on the next cannot be put into another language
in one piece. There is no way to build a line from pieces as the story runs, and that is why.

## Ids

To the string table, to recorded voices, and to a saved game, a line is known by its id: `^` and six letters and
digits at the end of its row. This is the far bank on its own, `stories/06/bank.river`, as written:

```river
== far_bank
Mud, a path, and up the hill the lights of the fair.
ADA: Mind how you go.
* Thank her.
  ADA: Thank the river.
  -> end
* Go up the hill.
  -> end
```

It has no ids yet, and `riverrun tag --check` lists every line and choice without one:

```console
$ riverrun tag --check bank.river
bank.river:6:1-6:53: error: this has no id: `riverrun tag` writes one
bank.river:7:1-7:22: error: this has no id: `riverrun tag` writes one
bank.river:8:1-8:13: error: this has no id: `riverrun tag` writes one
bank.river:9:3-9:24: error: this has no id: `riverrun tag` writes one
bank.river:11:1-11:18: error: this has no id: `riverrun tag` writes one
```

`riverrun tag bank.river` writes them into the file, and prints its name, `bank.river`, for each file it changed. Now
it reads (this is `stories/06/tagged/bank.river`):

```river
== far_bank
Mud, a path, and up the hill the lights of the fair. ^c6q1h6
ADA: Mind how you go. ^cx3yhv
* Thank her. ^gfk8sk
  ADA: Thank the river. ^f2v39v
  -> end
* Go up the hill. ^gwbxy7
  -> end
```

`riverrun tag` adds ` ^id` at the end of each line and choice that has none, before a comment if the row has one,
and changes nothing else in the file. Run it as often as you like: a line that has its id keeps it, and a second run
changes nothing. Give it all the story's files at once, `riverrun tag story/*.river`, so no id is given twice.

An id is the line's for good. Change the line's words, move it to another section, rename the section: the id stays,
and the translation, the recording and the save that know the line by it still find it. So never write or change an
id by hand, and when you copy a row to make a new line, delete the copied id and let `riverrun tag` give the new line
its own; the checker refuses an id used twice.

Until a line has its id, it plays all the same: the story is given a stand-in id for it, made from where the line is
and what it says, which changes when either does. A release of the game needs every id written, and `riverrun check
--release` checks a story as a release is built, printing nothing when every line has its id:

```console
$ riverrun check --release bank.river
```

A play prints each id at the end of its line or choice:

```console
$ riverrun play -i 1 bank.river
== far_bank
Mud, a path, and up the hill the lights of the fair. ^c6q1h6
ADA: Mind how you go. ^cx3yhv
* 1 Thank her. ^gfk8sk
* 2 Go up the hill. ^gwbxy7
> 1
ADA: Thank the river. ^f2v39v
-> end
```

[Chapter 7](07-the-games-vocabulary.md) is about the game's side of a story: what it keeps, what it answers, and what
it does when it is asked.
