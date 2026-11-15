# 8. Pools

While the player waits at the landing, whoever is standing by says something now and then: the boy shouts for the
ferry, Otto complains about his feet. Who says what depends on who is there and how things stand, and nobody should
say the same thing twice running. Written as conditions, that is a tangle of `{ else }`; written as a pool, it is a
list.

```river
+ Look at the river.
  {seq: Black water, moving fast under the rain. | Still black. Still moving. | The river is not going anywhere, and nor, it seems, are you.}
  -> waiting ->
  -> ask
```

```river
// what someone standing by says while the player waits
== waiting (pool)
= boy             when { near has boy }
  A BOY: Ferry! Ferry!
= boy_in_rain     when { near has boy and rain = pouring }
  A BOY: It's hardly raining at all!
= otto            when { near has otto }
  OTTO: My feet have gone to sleep.
= otto_kind       when { near has otto and trust > 0 }
  OTTO: Come back from the edge, will you. You're making me nervous.
= nobody
  Nobody says anything. The rain says enough.
```

That is `stories/08/ferry.river`: one row added under `Look at the river.`, and the pool after the landing. Who is
standing by is the game's to know, so the story declares it among its facts: `near: set of otto, boy (game)`.

## A pool and its candidates

`== waiting (pool)` begins a section of the kind `pool`. Its parts are its candidates: each a name, `when` and a
condition, and the rows it says indented under it. A candidate with no `when` always holds.

`-> waiting ->` calls the pool, as a section is called ([chapter 5](05-scenes-and-flow.md)): of the candidates whose
conditions hold, the pool says one, and the story comes back to the row after the call. A pool is always called; a
pool where nothing holds says nothing.

## Which candidate

- **The most specific.** Of the candidates that hold, the pool takes those with the most comparisons joined by
  `and`. With the boy standing by in the pouring rain, `boy` and `boy_in_rain` both hold, and `boy_in_rain`, with
  two, is said. So the plain line comes first in the list and the particular one after it, and the particular one
  is said whenever it holds, with no `{ else }` anywhere.
- **The least recently said.** Among candidates as specific as each other, the pool says the one said longest
  ago, or never. With Otto and the boy both there, the rain easing and Otto in no mood, `boy` and `otto` take turns.
- **Then by the story's seed**, where nothing else decides, so every play of the same inputs says the same.

The pool remembers what it said in the story's own facts, so a saved game remembers it too.

## Weights

A candidate may carry `[weight n]`, a whole number, under its heading. A pool in which any candidate does draws
among its most specific candidates that hold, each as often as its weight says against the others' (a candidate
with no weight counts 1), and recency plays no part. The draw is made from the story's seed and how far the story
has gone, so it is the same every time for the same inputs. In `stories/08/inn.river`, at eight o'clock in the
taproom:

```river
= cards           when { room = taproom and hour = 20 }
  [weight 3]
  Otto is losing at cards to a drover, and smiling about it.
= rumour          when { room = taproom and hour = 20 }
  A DROVER: They say the far bank's flooded to the church door.
```

Otto is at cards three nights in four, and one night in four the drover tells the rumour instead. Use weights for a
line that should come up sometimes and not others, and the plain order for lines that should take turns.

## More than one

`(pool 2)` after a pool's name has it say up to two candidates, one after another: the most specific, then the next
by the same rules. Breakfast at the inn says two things:

```river
// two things said at breakfast
== at_breakfast (pool 2)
= otto_song       when { stood_a_drink }
  OTTO: You can't sing, but you can stand a drink. That'll do.
= ada_hurry
  ADA: Ten minutes. I'm not waiting.
= otto_head
  OTTO: My head.
```

## A night of rooms

The game, too, can ask a pool, at a moment of its own. This is the inn's night:

```river
// The game moves the player from room to room, two hours at a time, and at each move asks the pool for what
// happens in that room at that hour. When the night is over it goes on to `morning`.
== inn
  [rooms taproom, kitchen, stairs] [hours 20, 22, 0] [pool inn_night] [then morning]
```

```river
// the kitchen
= stew            when { room = kitchen and hour = 20 }
  THE COOK: There's the end of the stew, if you're not fussy.
= ada_eats        when { room = kitchen and hour = 22 }
  Ada eats standing up, by the back door, watching the rain.
  ADA: It'll ease by morning. It always does.
// the stairs
= creak           when { room = stairs }
  The stairs creak under somebody going up to bed.
// anywhere after midnight
= late            when { hour = 0 }
  Everyone who can sleep is asleep. The fire ticks.
= ada_asleep      when { room = taproom and hour = 0 }
  Ada is asleep in the corner with her boots on.
```

`rooms`, `hours`, `pool` and `then` are this game's tags ([chapter 7](07-the-games-vocabulary.md)): its night
mechanic moves the player from room to room and hour to hour, sets `room` and `hour`, both `(game)` facts, and at
each move asks `inn_night` for what happens there and then. A table of rooms by hours by what the player has done
is a list of candidates, and specificity settles which row of it is said: at midnight in the taproom, `ada_asleep`,
with two comparisons, and at midnight anywhere else `late`. `then` is a tag the game's vocabulary marks as
leading on: when `inn` is done, the game goes on to `morning`, so `inn` needs no `-> end`.

## What a play does with a pool

A pool the story calls, `-> waiting ->`, is said in a play as in the game. A pool the game asks is not: the night
mechanic is the game's, and a play runs only what riverrun runs. A tag that leads it does follow, as the game
would. So a play of the inn says the evening, goes on to `morning`, and has no night:

```console
$ riverrun play -i 1 inn.river
== inn
  [rooms taproom, kitchen, stairs] [hours 20, 22, 0] [pool inn_night] [then morning]
The Bell is full of people the rain has kept from crossing, and all of them are wet.
OTTO: A night here, then. I've slept in worse.
* 1 Buy Otto a drink.
* 2 Find a corner by the stairs.
> 1
[stood_a_drink = true]
OTTO: Now that's manners.
== morning
The rain has stopped. Down at the landing, Ada is bailing out the boat.
== at_breakfast
OTTO: You can't sing, but you can stand a drink. That'll do.
ADA: Ten minutes. I'm not waiting.
-> end
```

To hear what the night says in one room at one hour, start the play at the pool, with what the game would have set:

```console
$ riverrun play --from inn_night --set 'room = taproom' --set 'hour = 22' --set 'stood_a_drink = true' inn.river
> :set room = taproom
> :set hour = 22
> :set stood_a_drink = true
== inn_night
Somebody starts a song about the river, and Otto, a drink inside him, teaches you the words.
-> end
```

A play started at a pool says one of its candidates, or as many as its number, and ends.

## Playing the landing

`stories/08/ferry.play` has Otto and the boy both standing by, then neither:

```console
$ riverrun play --set 'rain = easing' --set 'near = otto, boy' --script ferry.play ferry.river
> :set rain = easing
> :set near = otto, boy
== landing
  [music rain_on_water] [picture landing_night]
Rain on the river, thinning.
A lantern on a post, and a boat tied up under it.
A BOY: Ferry! Last ferry over!
OTTO: She heard you the first time.
ADA (without looking up): Nearly. Give it a minute.
? crossings_left() = 0 (not set)
Otto hums to himself.
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 (closed) Offer her the one coin you have.
* 4 Look at the river.
* 5 Sit with Otto.
* 6 (closed) Pay, and get in.
  [marked]
* 7 Go home.
> 4
Black water, moving fast under the rain.
== waiting
OTTO: My feet have gone to sleep.
== landing
  [music rain_on_water] [picture landing_night]
Otto counts the buttons on his coat.
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 (closed) Offer her the one coin you have.
* 4 Look at the river.
* 5 Sit with Otto.
* 6 (closed) Pay, and get in.
  [marked]
* 7 Go home.
> 4
Still black. Still moving.
== waiting
A BOY: Ferry! Ferry!
== landing
  [music rain_on_water] [picture landing_night]
Otto looks at the sky.
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 (closed) Offer her the one coin you have.
* 4 Look at the river.
* 5 Sit with Otto.
* 6 (closed) Pay, and get in.
  [marked]
* 7 Go home.
> 5
You sit down beside him on the wet bench.
OTTO: You'll want this, over there.
  [pause 1.5]
  [trust += 1]
He puts a tin lantern in your hands.
[give(lantern)] [carrying += lantern]
Otto hums to himself.
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 (closed) Offer her the one coin you have.
* 4 Look at the river.
* 5 (closed) Pay, and get in.
  [marked]
* 6 Go home.
> 4
The river is not going anywhere, and nor, it seems, are you.
== waiting
OTTO: Come back from the edge, will you. You're making me nervous.
== landing
  [music rain_on_water] [picture landing_night]
Otto counts the buttons on his coat.
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 (closed) Offer her the one coin you have.
* 4 Look at the river.
* 5 (closed) Pay, and get in.
  [marked]
* 6 Go home.
> :set near = none
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 (closed) Offer her the one coin you have.
* 4 Look at the river.
* 5 (closed) Pay, and get in.
  [marked]
* 6 Go home.
> 4
The river is not going anywhere, and nor, it seems, are you.
== waiting
Nobody says anything. The rain says enough.
== landing
  [music rain_on_water] [picture landing_night]
Otto looks at the sky.
* 1 How much to cross?
* 2 (closed) I haven't got two coins.
* 3 (closed) Offer her the one coin you have.
* 4 Look at the river.
* 5 (closed) Pay, and get in.
  [marked]
* 6 Go home.
> 6
You turn up the lane, the way the boy went.
-> end
```

A call into a pool is printed as any call: the pool's heading, `== waiting`, what it said, and the heading of the
section the story comes back to. Otto and the boy take turns while neither is more specific than the other; once
Otto thinks well of the player, `otto_kind` is; and with nobody there, `nobody`, which always holds, is all that is
left. `:set near = none` empties the set.

## When the checker says no

This copy, `mistakes/08/ferry.river`, goes to the pool where it meant to call it, and asks Otto for more trust than
he can have:

```river refused
+ Look at the river.
  {seq: Black water, moving fast under the rain. | Still black. Still moving. | The river is not going anywhere, and nor, it seems, are you.}
  -> waiting
  -> ask
```

```river refused
= otto_kind       when { near has otto and trust > 3 }
  OTTO: Come back from the edge, will you. You're making me nervous.
```

```console
$ riverrun check ferry.river
ferry.river:60:6-60:13: error: `waiting` is a pool: call it, `-> waiting ->`, and it gives its lines and comes back
ferry.river:88:26-88:53: warning: the candidate `otto_kind` can never be picked: its condition can never hold
ferry.river:61:3-61:9: warning: nothing reaches this: the story always goes elsewhere before it
```

`trust` holds at most 3, so `trust > 3` never holds, and a candidate that can never be picked is a warning, as a
choice that can never be offered is. The last warning follows from the first: a story that goes to the pool and
not back never reaches `-> ask`. [Chapter 9](09-rules.md) has the story react to facts as they change.
