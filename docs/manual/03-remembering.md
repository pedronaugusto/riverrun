# 3. Remembering: facts and conditions

Ada will not go while it pours, and she wants two coins. Whether it pours and what the player has are the game's to
know; that the player asked the price is the story's. Both are facts, and the story says different things as they
change.

```river
facts (player):
  coins: int from 0 to 9   (game)
facts:
  rain: one of pouring, easing, stopped   (game)
  asked_price: bool

== landing
{ rain = pouring }
  Rain on the river, hard enough to hiss.
{ else }
  Rain on the river, thinning.
A lantern on a post, and a boat tied up under it.
A BOY: Ferry! Last ferry over!
OTTO: She heard you the first time.
ADA: { rain = pouring: I go when the rain eases. Not before. | Nearly. Give it a minute. }
- (ask)
* How much to cross?
  [asked_price = true]
  ADA: Two coins. Same as always.
  -> ask
* { asked_price and coins < 2 } I haven't got two coins.
  You count what you have: {coins} coins.
  ADA: Then you'd better find some more.
  -> ask
+ Look at the river.
  Black water, moving fast under the rain.
  -> ask
* { coins >= 2 and rain != pouring } Pay, and get in.
  { not asked_price } ADA: Two coins, first.
  ADA: Mind the step.
  -> end
* Go home.
  You turn up the lane, the way the boy went.
  -> end
```

That is `stories/03/ferry.river` from its facts on; the cast above them is as before.

## Facts

```river
facts:
  rain: one of pouring, easing, stopped   (game)
  asked_price: bool
```

A fact is something the story remembers. `facts:` declares them, one to a row indented under it: a name, a colon,
and what kind of value it holds.

- `bool`: true or false. It starts false.
- `int`: a whole number. `int from 0 to 9` holds only those, and starts at the one nearest 0.
- `one of pouring, easing, stopped`: one of the words listed, separated by commas. It holds none of them until
  something sets it, so `{ rain = pouring }` is false at first; a fact the game writes, the game sets before the
  story asks.
- `set of …`: none, some or all of the words listed. [Chapter 4](04-telling-the-game.md) puts things in one.

A fact's name, and each word of a list, is letters, digits and `_`. Every file of a story sees every fact it
declares.

`(game)` after a fact says the game writes it and the story only reads it. Here the game knows the weather and how
much the player carries; the story asks, and never sets either. A fact without `(game)` is the story's own.

```river
facts (player):
  coins: int from 0 to 9   (game)
```

The word in parentheses after `facts` is a scope: a set of facts the game keeps together. The game decides what a
scope is for, here what goes with the player from one night to the next, and it may save or reset one without the
others. The story names the scopes and the game's people say which to use; facts declared with no scope are kept
together in one of their own.

## Setting a fact

```river
* How much to cross?
  [asked_price = true]
```

`[asked_price = true]` sets the fact when the choice is taken. A fact in square brackets is set; in braces, below,
it is asked about. [Chapter 4](04-telling-the-game.md) says all that brackets do.

## Conditions

A condition asks something of the facts, in braces, and is true or false:

- `rain = pouring`, `rain != pouring`: equal, or not equal;
- `coins < 2`, `coins <= 2`, `coins > 2`, `coins >= 2`, between numbers;
- `asked_price` alone, true when the fact is;
- `and`, `or` and `not` to join them: `{ asked_price and coins < 2 }`.

A condition stands in three places.

**Above rows.** `{ rain = pouring }` with rows indented under it says them only when it holds. `{ else }` after
them, at the same indent, has the rows said when it does not:

```river
{ rain = pouring }
  Rain on the river, hard enough to hiss.
{ else }
  Rain on the river, thinning.
```

**Before one row.** `{ not asked_price } ADA: Two coins, first.` says that line only when the player has not asked
the price. Write the condition and the row on one row when it gates the one; indent rows under it when it gates more.

**Before a choice.** `* { coins >= 2 and rain != pouring } Pay, and get in.` is offered only when the condition
holds. When it does not, the choice is still there, closed: the game can show it locked, so the player sees that
there is a way across and that something stands in it.

## Words that change

```river
ADA: { rain = pouring: I go when the rain eases. Not before. | Nearly. Give it a minute. }
```

Inside a line's words, `{ condition: these words | those words }` says the first words when the condition holds and
the second when it does not. Use it for words in a line; use a condition above rows for whole lines, as `{ rain =
pouring }` does, so a reader of the story sees which lines are said when.

```river
  You count what you have: {coins} coins.
```

`{coins}` says what the fact holds now, as words: `0`, `3`, `easing`. With one coin this row reads `1 coins`;
[chapter 6](06-text-that-varies.md) has the words for one and for many.

## Playing with facts

The game sets its facts before the story starts, and changes them while it runs. In a play, you are the game. `--set`
sets a fact before the story starts, and `:set` sets one at any point in the play, as a row of input. `:facts` prints
every fact that holds something other than the value it starts at.

With many inputs, a script is easier than `-i`: a file of inputs, one to a row, exactly as you would type them, with
`//` before a comment. This is `stories/03/ferry.play`:

```console
$ riverrun play --set 'rain = easing' --script ferry.play ferry.river
> :set rain = easing
== landing
Rain on the river, thinning.
A lantern on a post, and a boat tied up under it.
A BOY: Ferry! Last ferry over!
OTTO: She heard you the first time.
ADA: Nearly. Give it a minute.
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 Look at the river.
* 4 (closed) Pay, and get in.
* 5 Go home.
> 1
[asked_price = true]
ADA: Two coins. Same as always.
* 1 I haven't got two coins.
* 2 Look at the river.
* 3 (closed) Pay, and get in.
* 4 Go home.
> 1
You count what you have: 0 coins.
ADA: Then you'd better find some more.
* 1 Look at the river.
* 2 (closed) Pay, and get in.
* 3 Go home.
> :facts
  rain = easing
  asked_price = true
> :set coins = 3
* 1 Look at the river.
* 2 Pay, and get in.
* 3 Go home.
> 2
ADA: Mind the step.
-> end
```

The script's rows are the `>` rows after the first, each as given, its comments left out; the first, `:set rain =
easing`, is the `--set`. Quote what `--set` takes, as here, when it holds spaces. A closed choice is printed `(closed)`
and cannot be taken. A fact set while choices wait has them offered again as they now hold: `:set coins = 3` opens
`Pay, and get in.` The game's facts are yours to set this way, and so are the story's, to try a branch without playing
up to it.

## When the checker says no

The checker knows each fact's kind, who writes it, and what values it can hold. This copy,
`mistakes/03/ferry.river`, has the story pay itself, asks about a weather the story never declared, and offers a
choice no player will see:

```river refused
* How much to cross?
  [asked_price = true]
  [coins = 2]
```

```river refused
* { coins >= 2 and rain != snowing } Pay, and get in.
  { not asked_price } ADA: Two coins, first.
  ADA: Mind the step.
  -> end
* { coins > 9 } Pay double, and go now.
  ADA: No.
  -> ask
```

```console
$ riverrun check ferry.river
ferry.river:25:4-25:9: error: `coins` is the game's, declared `(game)`: the story reads it and never sets it
ferry.river:35:28-35:35: error: `snowing` is not one of pouring, easing, stopped
ferry.river:39:5-39:14: warning: this choice can never be offered: its condition can never hold
```

`coins` holds at most 9, so `coins > 9` never holds, and the checker can tell. A warning does not stop a play, but a
choice no one is offered is a mistake to put right. [Chapter 4](04-telling-the-game.md) tells the game what has
happened.
