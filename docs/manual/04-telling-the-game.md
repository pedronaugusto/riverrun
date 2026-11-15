# 4. Telling the game

A story says more than its words. When Otto speaks the game may play a sound, hold the line a moment, and change
what he thinks of the player; when the player pays, the game takes two coins. Everything the game is told stands in
square brackets, on rows of their own, under what it belongs to.

```river
== landing
  [music rain_on_water] [picture landing_night]
{ rain = pouring }
  Rain on the river, hard enough to hiss.
    [sound rain_heavy]
{ else }
  Rain on the river, thinning.
A lantern on a post, and a boat tied up under it.
A BOY: Ferry! Last ferry over!
OTTO: She heard you the first time.
ADA (without looking up): { rain = pouring: I go when the rain eases. Not before. | Nearly. Give it a minute. }
- (ask)
* How much to cross?
  [asked_price = true]
  ADA: Two coins. Same as always.
  -> ask
* { asked_price and coins < 2 } I haven't got two coins.
  You count what you have: {coins} coins.
  ADA: Then you'd better find some more.
  You look at Otto.
  OTTO: Don't look at me.
    [trust -= 1]
  -> ask
+ Look at the river.
  Black water, moving fast under the rain.
  -> ask
* Sit with Otto.
  You sit down beside him on the wet bench.
  OTTO: You'll want this, over there.
    [pause 1.5]
    [trust += 1]
  He puts a tin lantern in your hands.
  [give(lantern)] [carrying += lantern]
  -> ask
* { coins >= 2 and rain != pouring } Pay, and get in.
  [marked]
  [pay(2)]
  { not asked_price } ADA: Two coins, first.
  ADA: Mind the step.
  -> end
* Go home.
  You turn up the lane, the way the boy went.
  -> end
```

That is the landing of `stories/04/ferry.river`. A bracket holds one thing for the game, a tag or an effect.

## Tags

```river
== landing
  [music rain_on_water] [picture landing_night]
```

A tag is a word the game knows, its key, and the values that go with it: `[music rain_on_water]` tells the game to
play the music it calls `rain_on_water` under this section. Some keys take no value (`[marked]`), some one, and
some several, separated by commas.

Which keys there are, where each may stand, and what values each takes, is the game's to say: they are the game's
vocabulary, and the checker holds every tag to it. This manual's game knows six: `music` and `picture` on a section,
`picture` on a part ([chapter 5](05-scenes-and-flow.md)), `sound` and `pause` on a line, `marked` on a choice, and
`delivery` (below). Your game has its own, and its people say what they are.

A quoted value is words, and may hold commas: `[caption "Hollin, at night"]`, in a game with a `caption` key.

## What a bracket belongs to

The rows of brackets indented under a row, before anything else under it, belong to that row. Several brackets
may stand on one row, and a row of brackets holds nothing else.

- Under a **section's heading**, `== landing`, they are its tags.
- Under a **line**, its tags and its effects. The effects happen when the game delivers the line, so a line the
  game skips changes nothing. Nothing but brackets stands under a line.
- Under a **choice**, its tags and its effects. The effects happen first, once the choice is taken.
- Anywhere else, on a row of their own among the story's rows, they are **effects**, done when the story comes to
  them. A tag there is a mistake (below): indent it under what it describes.

So in the landing, `[sound rain_heavy]` is the rain line's, `[trust += 1]` is Otto's line's and happens when he says
it, `[marked]` and `[pay(2)]` are the choice's, and `[give(lantern)] [carrying += lantern]` is a row of effects of
its own, done after `He puts a tin lantern in your hands.`

## Effects: changing facts

`[asked_price = true]`, in chapter 3, sets a fact. Two more change one:

- `[trust += 1]` adds to an int, and `[trust -= 1]` takes from it. A fact declared `int from -3 to 3` stops at its
  end: at 3, `+= 1` leaves it at 3.
- `[carrying += lantern]` puts a word into a set, and `[carrying -= lantern]` takes it out.

A set is declared `set of …`, as `carrying` is:

```river
facts (player):
  coins: int from 0 to 9   (game)
  carrying: set of lantern, needles
facts:
  rain: one of pouring, easing, stopped   (game)
  asked_price: bool
  trust: int from -3 to 3   // what Otto makes of you
```

and asked about with `has` and `hasnt`: `{ carrying has lantern }`, `{ carrying hasnt needles }`.

In brackets, `=` sets; in braces, `=` asks whether two things are equal. The brackets say which.

## Effects: the game's actions

```river
extern:
  pay(int)
  give(ref of item)
```

An action is something only the game can do: take two coins from the purse, put a lantern in the player's hands.
`[pay(2)]` asks the game to do it, a name and its arguments in parentheses. The game's actions are declared under
`extern:`, each with the kinds of value it takes; `ref of item` is one of the game's things, named by its id,
`lantern`. [Chapter 7](07-the-games-vocabulary.md) says more of what `extern:` declares; the game's people say which
actions there are.

`coins` is the game's, so the story does not set it: it asks the game to `pay(2)`, and the game takes them. The story
does keep `carrying` itself, beside the lantern the game gives, so it can ask about the lantern later.

A tag and an action differ by the parentheses: `[sound rain_light]` is a tag, `[pay(2)]` an action. A name followed
by `(`, `=`, `+=` or `-=` is an effect; any other name is a tag's key.

## Delivery

```river
ADA (without looking up): { rain = pouring: I go when the rain eases. Not before. | Nearly. Give it a minute. }
```

Words in parentheses after a speaker, before the colon, say how the line is delivered, as a script's parenthetical
does. They are not part of what Ada says. The game takes them as one of the line's tags: in this manual's game, words
for the actor, the captioner and the translator. Another game may take only a list it knows, `(whispering)`,
`(laughing)`, and animate or voice each. A game that takes none refuses a delivery.

## Playing it

A play prints a section's tags under its heading, a line's tags and effects under the line, a choice's tags under
the choice, and effects that stand on their own at the margin, as the story writes them:

```console
$ riverrun play --set 'rain = easing' --script ferry.play ferry.river
> :set rain = easing
== landing
  [music rain_on_water] [picture landing_night]
Rain on the river, thinning.
A lantern on a post, and a boat tied up under it.
A BOY: Ferry! Last ferry over!
OTTO: She heard you the first time.
ADA (without looking up): Nearly. Give it a minute.
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 Look at the river.
* 4 Sit with Otto.
* 5 (closed) Pay, and get in.
  [marked]
* 6 Go home.
> 4
You sit down beside him on the wet bench.
OTTO: You'll want this, over there.
  [pause 1.5]
  [trust += 1]
He puts a tin lantern in your hands.
[give(lantern)] [carrying += lantern]
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 Look at the river.
* 4 (closed) Pay, and get in.
  [marked]
* 5 Go home.
> :facts
  carrying = lantern
  rain = easing
  trust = 1
> :set coins = 3
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 Look at the river.
* 4 Pay, and get in.
  [marked]
* 5 Go home.
> 4
[pay(2)]
ADA: Two coins, first.
ADA: Mind the step.
-> end
```

The play applies the effects on facts as the game would, which `:facts` shows: `trust` is 1 and the lantern is in
`carrying`. An action it only prints: `[pay(2)]` takes no coins, since the purse is the game's, so after paying,
`coins` is still what you set it to.

## When the checker says no

This copy, `mistakes/04/ferry.river`, leaves a tag at the margin, misspells one, and writes an action as a tag:

```river refused
A lantern on a post, and a boat tied up under it.
[sound rain_light]
A BOY: Ferry! Last ferry over!
```

```river refused
  OTTO: You'll want this, over there.
    [pase 1.5]
    [trust += 1]
```

```river refused
* { coins >= 2 and rain != pouring } Pay, and get in.
  [marked]
  [pay 2]
```

```console
$ riverrun check ferry.river
ferry.river:27:1-27:19: error: `[sound]` is a tag, and a tag belongs to what it describes: indent it under that line, choice or heading
ferry.river:49:6-49:10: error: `pase` is not a tag the game knows
ferry.river:56:4-56:7: error: `pay` is an action, not a tag: run it with `[pay(…)]`
```

Indented under the line, `[sound rain_light]` would be the lantern line's sound. [Chapter 5](05-scenes-and-flow.md)
takes the player across the river.
