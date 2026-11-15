# 13. Worked scenes

Four scenes, each a whole story beside this chapter in `stories/13/`, each played. Each puts together what the
chapters before it teach, and says why it is written the way it is.

## A conversation with interjections

Otto tells a story at supper, and whoever else is at the table puts in a word after each thing he says.

```river
// Supper at the Bell: Otto tells how he lost his cart, and whoever is at the table puts in a word.
cast:
  ada    "Ada"    — keeps the ferry
  otto   "Otto"   — a pedlar, going over for the fair
extras: a boy

facts:
  at_table: set of ada, boy   (game)   // who else is sitting with you
  heard: set of cart, horse, wife      // what Otto has told

== supper
  [music fair_far_off]
Otto has a bowl of stew and an audience, which is all he ever wants.
OTTO: I had a cart once. A good one, green wheels.
-> puts_in ->
- (ask)
* What happened to it?
  [heard += cart]
  OTTO: Lost it at cards, to a man with one eye and two aces.
  -> puts_in ->
  -> ask
* { heard has cart } And the horse?
  [heard += horse]
  OTTO: The horse came back on her own. She never liked him either.
  -> puts_in ->
  -> ask
* { heard has horse } Who's "she"?
  [heard += wife]
  OTTO: The horse. Who else would I mean?
  -> puts_in ->
  -> ask
+ Eat your stew.
  You eat. It is better than it looks.
  -> end

// Someone at the table puts in a word after Otto speaks; nobody, if nobody is there.
== puts_in (pool)
= ada             when { at_table has ada }
  ADA: Here we go.
= ada_cards       when { at_table has ada and heard has cart }
  ADA: Two aces. It was three, last time.
= ada_wife        when { at_table has ada and heard has wife }
  ADA (to you): He was married. Ask him about Bremen sometime. Not tonight.
= boy             when { at_table has boy }
  A BOY: Did it have a bell? A cart should have a bell.
= boy_horse       when { at_table has boy and heard has horse }
  A BOY: What was she called?
```

**Why a pool.** Who puts in a word depends on who is at the table, which is the game's to know (`at_table`, a
`(game)` fact), and on what Otto has told so far, which is the story's (`heard`). A pool after each of Otto's lines,
`-> puts_in ->`, picks the most specific candidate that holds ([chapter 8](08-pools.md)): Ada's general sigh, `Here
we go.`, until something she has a remark about comes up, and then the remark. With Ada and the boy both at the
table, two equally specific remarks take turns. With nobody at the table, nothing holds, and the pool says nothing:
Otto talks to himself. The interjections are written once, in one place, and the conversation's rows stay a
conversation.

**Why the questions are closed.** `And the horse?` is offered once the cart has come up, through `{ heard has cart
}`. Until then it is closed, and the game may show it locked or leave it out. `Eat your stew.` is `+`, so the way out
is always there.

```console
$ riverrun play --set 'at_table = ada, boy' -i 1 -i 1 -i 1 -i 1 supper.river
> :set at_table = ada, boy
== supper
  [music fair_far_off]
Otto has a bowl of stew and an audience, which is all he ever wants.
OTTO: I had a cart once. A good one, green wheels.
== puts_in
A BOY: Did it have a bell? A cart should have a bell.
== supper
  [music fair_far_off]
* 1 What happened to it?
* 2 (closed) And the horse?
* 3 (closed) Who's "she"?
* 4 Eat your stew.
> 1
[heard += cart]
OTTO: Lost it at cards, to a man with one eye and two aces.
== puts_in
ADA: Two aces. It was three, last time.
== supper
  [music fair_far_off]
* 1 And the horse?
* 2 (closed) Who's "she"?
* 3 Eat your stew.
> 1
[heard += horse]
OTTO: The horse came back on her own. She never liked him either.
== puts_in
A BOY: What was she called?
== supper
  [music fair_far_off]
* 1 Who's "she"?
* 2 Eat your stew.
> 1
[heard += wife]
OTTO: The horse. Who else would I mean?
== puts_in
ADA (to you): He was married. Ask him about Bremen sometime. Not tonight.
== supper
  [music fair_far_off]
* 1 Eat your stew.
> 1
You eat. It is better than it looks.
-> end
```

## A day of slots

Three hours at the fair before the last ferry home, and five things that want them.

```river
// A day at the fair: three hours before the last ferry home, and five things that want them.
cast:
  ada    "Ada"    — keeps the ferry
  otto   "Otto"   — a pedlar, at his stall

facts (player):
  coins: int from 0 to 9   (game)
facts:
  hours: int from 0 to 3              // the hours spent so far
  done: set of stall, horses, ribbon, fortune, river

extern:
  pay(int)

== fair_day
  [music fair_far_off]
Three hours before the last ferry home, and more to do than three hours hold.
- (hour)
{ hours = 3 }
  -> last_ferry
The church clock says {hours + 10} o'clock.
* { hours = 0 } Help Otto set out his stall.
  You hang his ribbons in rows, and he lets you keep a blue one.
  [done += stall] [hours += 1]
  -> hour
* Watch the horses being sold.
  A grey mare goes for more than the man selling her expected. He looks sorry about it.
  [done += horses] [hours += 1]
  -> hour
* { coins >= 1 and done hasnt stall } Buy a ribbon.
  [pay(1)]
  You buy a red one, from a stall that is not Otto's.
  [done += ribbon] [hours += 1]
  -> hour
* { coins >= 2 } Have your fortune told.
  [pay(2)]
  The woman tells you that you will cross water. You have, twice.
  [done += fortune] [hours += 1]
  -> hour
* Sit by the river for an hour.
  The ferry goes over and comes back. Ada does not wave. Then she does.
  [done += river] [hours += 1]
  -> hour

== last_ferry
ADA: Last one. In you get.
{ done has stall } You have a blue ribbon from Otto in your pocket.
{ done has ribbon } You have a ribbon you paid for, which is not the same.
{ done hasnt river } You never did sit by the river. Next fair.
-> end
```

**Why a counter, and a label.** Each thing done takes an hour, `[hours += 1]`, and goes back to `- (hour)`, where
the first thing the story asks is whether the hours are spent. So the day ends after three things, whichever three,
and the label is the one place that says so. `{hours + 10}` works out the time from it.

**Why `*`.** Each thing is done once, so each is a choice offered once. Some are offered only at some hours or to
some players: setting out the stall only at the start, `{ hours = 0 }`; a ribbon only to a player with a coin who
has not been given one, `{ coins >= 1 and done hasnt stall }`. A closed choice still shows, so the player sees what
they have missed.

**Why the evening reads the day.** `last_ferry` asks `done` for what was and was not done, so what the player chose
is what the evening remembers.

A game can run a day like this itself, with a mechanic of its own that offers acts by the hour and goes on when the
hours run out, read from tags of the game's own; such a mechanic is the game's, and a play
does not run it ([chapter 8](08-pools.md) says the same of a pool the game asks). Written as above, the day is the
story's own, and plays as it is.

```console
$ riverrun play --set 'coins = 2' -i 2 -i 2 -i 3 day.river
> :set coins = 2
== fair_day
  [music fair_far_off]
Three hours before the last ferry home, and more to do than three hours hold.
The church clock says 10 o'clock.
* 1 Help Otto set out his stall.
* 2 Watch the horses being sold.
* 3 Buy a ribbon.
* 4 Have your fortune told.
* 5 Sit by the river for an hour.
> 2
A grey mare goes for more than the man selling her expected. He looks sorry about it.
[done += horses] [hours += 1]
The church clock says 11 o'clock.
* 1 (closed) Help Otto set out his stall.
* 2 Buy a ribbon.
* 3 Have your fortune told.
* 4 Sit by the river for an hour.
> 2
[pay(1)]
You buy a red one, from a stall that is not Otto's.
[done += ribbon] [hours += 1]
The church clock says 12 o'clock.
* 1 (closed) Help Otto set out his stall.
* 2 Have your fortune told.
* 3 Sit by the river for an hour.
> 3
The ferry goes over and comes back. Ada does not wave. Then she does.
[done += river] [hours += 1]
== last_ferry
ADA: Last one. In you get.
You have a ribbon you paid for, which is not the same.
-> end
```

## A confession, branching deep

Halfway back across the river, Otto owns up that the lantern was never his to give.

```river
// Halfway back across the river, Otto says the lantern was never his to give.
cast:
  ada    "Ada"    — keeps the ferry
  otto   "Otto"   — a pedlar, coming home from the fair

facts:
  knows: set of thief, owner, sorry   // what Otto has owned up to

== confession
  [music oars]
OTTO (low, so Ada won't hear): That lantern. It wasn't mine to give you.
* Whose was it, then?
  [knows += thief]
  OTTO: I took it off a hook at the Bell. The night we waited.
  * Take it back, then.
    OTTO: Can't. They'd know it was me.
    * They'd know anyway.
      [knows += sorry]
      OTTO: ...Aye. They would.
    * Then I'll take it back.
      [knows += owner]
      OTTO: You'd do that? It was Ada's husband's, they say. Hung there since he drowned.
  * Keep your voice down.
    OTTO: Aye. Aye.
  - He looks at the lantern in your lap, and then at the water.
* Say nothing.
  You say nothing. Otto takes that for an answer, and is wrong.
- ADA: You two are quiet.
{ knows has owner or knows has sorry }
  You hold up the lantern. Ada looks at it for a long time.
  ADA: Where did you get that?
  -> owned_up
OTTO: Tired, is all.
-> end

== owned_up
* { knows has owner } I'm taking it back to the Bell.
  ADA: Keep it. He'd want it used.
  -> end
* { knows has sorry } Otto took it. He's sorry.
  ADA: He's always sorry. Otto, sit where I can see you.
  -> end
* Otto gave it me.
  ADA: Did he.
  -> end
```

**Why indentation, and gathers.** The conversation goes three choices deep, and each depth is two spaces further
in. Each set of choices is followed by a gather at its own depth: `- He looks at the lantern…` joins the two answers
to `Whose was it, then?`, whichever was taken, and `- ADA: You two are quiet.` joins that with `Say nothing.` So
every way through comes back to one place, and the scene goes on from there, rather than four copies of the ending.

**Why a set.** What Otto has owned up to is kept in `knows`, one word for each thing, and the ending asks it rather
than asking which way the player came. Two different ways set `owner` and `sorry`, and the end sorts them out:
`{ knows has owner or knows has sorry }` brings the lantern out, and `owned_up` offers what the player can say for
what they know.

```console
$ riverrun play -i 1 -i 1 -i 1 -i 2 confession.river
== confession
  [music oars]
OTTO (low, so Ada won't hear): That lantern. It wasn't mine to give you.
* 1 Whose was it, then?
* 2 Say nothing.
> 1
[knows += thief]
OTTO: I took it off a hook at the Bell. The night we waited.
* 1 Take it back, then.
* 2 Keep your voice down.
> 1
OTTO: Can't. They'd know it was me.
* 1 They'd know anyway.
* 2 Then I'll take it back.
> 1
[knows += sorry]
OTTO: ...Aye. They would.
He looks at the lantern in your lap, and then at the water.
ADA: You two are quiet.
You hold up the lantern. Ada looks at it for a long time.
ADA: Where did you get that?
== owned_up
* 1 (closed) I'm taking it back to the Bell.
* 2 Otto took it. He's sorry.
* 3 Otto gave it me.
> 2
ADA: He's always sorry. Otto, sit where I can see you.
-> end
```

And the shortest way, saying nothing:

```console
$ riverrun play -i 2 confession.river
== confession
  [music oars]
OTTO (low, so Ada won't hear): That lantern. It wasn't mine to give you.
* 1 Whose was it, then?
* 2 Say nothing.
> 2
You say nothing. Otto takes that for an answer, and is wrong.
ADA: You two are quiet.
OTTO: Tired, is all.
-> end
```

## An event, an outcome and a rule

A storm breaks over the landing, the river rises, and the boat must be hauled out before the water comes over.

```river
// The night the river came up: a storm the game sends, a rule that keeps time, and a rope that may not hold.
cast:
  ada    "Ada"    — keeps the ferry
  otto   "Otto"   — a pedlar, sheltering at the landing

facts:
  minute: int   (clock)                  // the game's clock
  thunder: bool   (moment)               // the game's storm breaks
  water: one of low, rising, over
  hauled: bool

extern:
  haul(with: ref of person) -> bool (action)   // can the player and this person haul the boat clear?

== storm
  [music rain_on_water]
[water = low]
Rain on the landing roof, and Ada's boat pulling at its rope.
- (now)
{ water = over }
  The river comes over the landing and takes the boat with it, rope and all.
  ADA: Well. That's that.
  -> end
{ water = rising } ADA: It's coming up! Help me get her out of the water!
+ { water = rising } Haul the boat up the slip, with Otto.
  [hauled = haul(otto)]
  { hauled }
    The keel grinds up the stones, out of the river's reach.
    ADA: There. She'll do.
    -> end
  The rope burns through your hands, and the boat slides back.
  -> now
+ Wait under the shelter.
  You wait. The rain hammers on the roof.
  -> now

// The river, which pays no attention to anyone.
== river (rules)
= storm_breaks   when { water = low and happened(thunder) }
  [water = rising]
= comes_over     when { water = rising and since_changed(water, minute) >= 15 }
  [water = over]
```

**Why a moment and a rule.** The storm is the game's: it breaks when the game says, and the game says so with the
moment `thunder` ([chapter 9](09-rules.md)). The rule `storm_breaks` hears it and starts the river rising, whatever
the player is doing at the time, and `comes_over` brings the water over the landing a quarter of an hour of the
game's clock later. The scene itself only asks `water` each time round, at `- (now)`.

**Why an outcome.** Whether the player and Otto can haul the boat clear is the game's to decide ([chapter
7](07-the-games-vocabulary.md)): `[hauled = haul(otto)]` stops the story until the game says, and the story goes on
from the answer. The haul is `+`, so a failed haul can be tried again, as long as the water is rising.

**Why the water is set first.** `water` holds none of its values until something sets it ([chapter
3](03-remembering.md)), and the rules ask for `low`, so the scene's first row sets it.

This is `stories/13/storm.play`, in which the rope slips and the river wins:

```console
$ riverrun play --script storm.play storm.river
== storm
  [music rain_on_water]
[water = low]
Rain on the landing roof, and Ada's boat pulling at its rope.
* 1 (closed) Haul the boat up the slip, with Otto.
* 2 Wait under the shelter.
> :set thunder = true
! rule river.storm_breaks
  [water = rising]
* 1 Haul the boat up the slip, with Otto.
* 2 Wait under the shelter.
> 2
You wait. The rain hammers on the roof.
ADA: It's coming up! Help me get her out of the water!
* 1 Haul the boat up the slip, with Otto.
* 2 Wait under the shelter.
> 1
? haul(otto) -> true or false
> false
The rope burns through your hands, and the boat slides back.
ADA: It's coming up! Help me get her out of the water!
* 1 Haul the boat up the slip, with Otto.
* 2 Wait under the shelter.
> :wait 15
! rule river.comes_over
  [water = over]
* 1 (closed) Haul the boat up the slip, with Otto.
* 2 Wait under the shelter.
> 2
You wait. The rain hammers on the roof.
The river comes over the landing and takes the boat with it, rope and all.
ADA: Well. That's that.
-> end
```

And with the game saying the haul holds:

```console
$ riverrun play -i ':set thunder = true' -i 1 -i true storm.river
== storm
  [music rain_on_water]
[water = low]
Rain on the landing roof, and Ada's boat pulling at its rope.
* 1 (closed) Haul the boat up the slip, with Otto.
* 2 Wait under the shelter.
> :set thunder = true
! rule river.storm_breaks
  [water = rising]
* 1 Haul the boat up the slip, with Otto.
* 2 Wait under the shelter.
> 1
? haul(otto) -> true or false
> true
The keel grinds up the stones, out of the river's reach.
ADA: There. She'll do.
-> end
```

[Chapter 14](14-reference-card.md) puts every mark on one page.
