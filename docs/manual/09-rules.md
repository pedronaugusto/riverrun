# 9. Rules

Ada does not wait for the player. When the rain eases she is ready to go; when the boy rings the bell on the post
she casts off; ten minutes after that she is gone, whether the player got in or not. None of that happens because
the player chose something. It happens because the facts changed, and a story says so with rules.

```river
// What moves the boat on, whatever the player is doing.
== the_boat (rules)
= ready          when { boat = tied and rain != pouring }
  [boat = ready]
= rained_off     when { boat = ready and rain = pouring }
  [boat = tied]
= cast_off       when { boat = ready and happened(bell) }
  [boat = leaving]
= gone           when { boat = leaving and since_changed(boat, minute) >= 10 }
  [boat = gone]
```

That is from `stories/09/ferry.river`. Its facts have three more rows:

```river
  minute: int   (clock)      // the game's clock: it moves on a minute at a time
  bell: bool   (moment)      // the boy rings the bell on the post
  boat: one of tied, ready, leaving, gone
```

## A rule

`== the_boat (rules)` begins a section of the kind `rules`. Each of its parts is a rule: a name, `when` and a
condition, and under it the effects that happen when it fires, in brackets. A rule says nothing and goes nowhere:
its effects are all it has.

Nothing goes to a rules section, and the story never reaches it by `->`. Its rules are looked at whenever a fact
they read changes, whatever the story is doing at the time: the player choosing, a line being said, the game moving
its clock.

**A rule fires when its condition becomes true:** false when last looked at, and true now. A condition that stays
true does not fire the rule again; it must become false, and then true again. So `ready` fires once when the rain
eases, and again only if the rain has come back in between (which `rained_off` watches for) and eased again.

**One rule each time.** Each time a rules section is looked at, it fires at most one rule: the first, in the order
written, whose condition has just become true. Another that became true at the same moment does not fire, and waits
to become true again. Put rules that should all happen in sections of their own, and rules where one should win
in one section, the one that should win first.

The rules' effects are the game's to apply, as a line's are. Once applied, they are new facts, and the rules are
looked at again.

## A state machine

`boat` is a list of states, and the rules move it from one to the next: tied, ready, leaving, gone. Each rule asks
which state the boat is in and what has happened, and sets the next. A puzzle with an order (levers pulled one,
then three, then two), a guard who grows suspicious and calms down, a feud between two families: each is a fact of
states and the rules that move it.

A `one of` fact holds none of its values until something sets it ([chapter 3](03-remembering.md)), so the landing
puts the boat in its first state as the story starts:

```river
== landing
  [music rain_on_water] [picture landing_night]
[boat = tied]
```

The landing reads the state like any fact:

```river
- (ask)
{ boat = gone }
  The ferry is out on the water, without you. Ada does not look back.
  -> end
{ boat = leaving } ADA: That's the bell. In or out?
```

## Time, and what just happened

`since_changed(boat, minute)` is how far the clock `minute` has moved since `boat` last changed. `minute` is a
`(clock)` fact ([chapter 7](07-the-games-vocabulary.md)): an int the game moves on and never back. So `gone`
becomes true ten minutes after the boat started leaving, and fires then; the rules are looked at as the clock moves,
when the moment comes, and not every minute before it.

```river
// Otto does not stay cross: a point of trust back every quarter of an hour.
== otto_mood (rules)
= forgives       when { trust < 0 and since_changed(trust, minute) >= 15 }
  [trust += 1]
```

`forgives` gives back one point of trust a quarter of an hour after it was lost. Giving it back changes `trust`, so
`since_changed` starts again from nothing, the condition is false, and if trust is still below 0, it becomes true,
and fires, a quarter of an hour later. A rule that undoes itself a step at a time is how a mood, a reputation,
a guard's suspicion drifts back.

`happened(bell)` is true when the moment `bell` has just happened. `bell` is a `(moment)` fact: the game sets it when
the boy rings the bell, and it holds only until every rule that reads it has seen it, then goes back to nothing. A
moment is never saved. Only rules, and quests ([chapter 10](https://github.com/pedronaugusto/cairn/blob/main/docs/manual/10-quests.md)), read one: a moment is over before a line
could ask about it.

`since_changed` and `happened` are for rules and quests alone, since only they are looked at as the facts change.

## Migrations

A story changes after it has shipped, and players have saved games of the version before. A saved game is matched
to the new story by its facts' names: a fact added starts where it starts, and one dropped is dropped. A change of
meaning, two facts made one or a scale changed, cannot be worked out that way, and a migration says it:

```river
// Saves from the first version kept no `carrying`: Otto had given the lantern if he thought well of the player.
= lantern_kept   when { trust > 0 }
  [migrate 2]
  [carrying += lantern]
```

```river
// The landing at Hollin, at night: a ferry, and two people waiting for it.
version: 2
```

`version: 2` at the top of the story says which version it is. A rule with `[migrate 2]` is a migration to version
2: it fires once, when a game saved under an earlier version is loaded under version 2 or later, if its condition
holds, and never in a game begun under version 2. A migration may leave out `when` and its condition, and then
always fires. It is never looked at again.

A play starts a new game, so a play never runs a migration.

## Playing it

A play runs the rules as the game does, and prints each rule that fires with `!` and its section, and its effects
under it. `:wait 15` moves the clock on, the one way time passes in a play; `:set bell = true` is the game setting
the moment. This is `stories/09/ferry.play`:

```console
$ riverrun play --set 'rain = pouring' --script ferry.play ferry.river
> :set rain = pouring
== landing
  [music rain_on_water] [picture landing_night]
[boat = tied]
Rain on the river, hard enough to hiss.
  [sound rain_heavy]
A lantern on a post, and a boat tied up under it.
A BOY: Ferry! Last ferry over!
OTTO: She heard you the first time.
ADA (without looking up): I go when the rain eases. Not before.
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
> 1
[asked_price = true]
ADA: Two coins. Same as always.
Otto counts the buttons on his coat.
* 1 I haven't got two coins.
* 2 (closed) Offer her the one coin you have.
* 3 Look at the river.
* 4 Sit with Otto.
* 5 (closed) Pay, and get in.
  [marked]
* 6 Go home.
> 1
You count what you have: 0 coins.
ADA: Then you'd better find some more.
You look at Otto.
OTTO: Don't look at me.
  [trust -= 1]
Otto looks at the sky.
* 1 (closed) Offer her the one coin you have.
* 2 Look at the river.
* 3 Sit with Otto.
* 4 (closed) Pay, and get in.
  [marked]
* 5 Go home.
> :wait 15
! rule otto_mood.forgives
  [trust += 1]
* 1 (closed) Offer her the one coin you have.
* 2 Look at the river.
* 3 Sit with Otto.
* 4 (closed) Pay, and get in.
  [marked]
* 5 Go home.
> :set rain = easing
! rule the_boat.ready
  [boat = ready]
* 1 (closed) Offer her the one coin you have.
* 2 Look at the river.
* 3 Sit with Otto.
* 4 (closed) Pay, and get in.
  [marked]
* 5 Go home.
> :set bell = true
! rule the_boat.cast_off
  [boat = leaving]
* 1 (closed) Offer her the one coin you have.
* 2 Look at the river.
* 3 Sit with Otto.
* 4 (closed) Pay, and get in.
  [marked]
* 5 Go home.
> 2
Black water, moving fast under the rain.
== waiting
Nobody says anything. The rain says enough.
== landing
  [music rain_on_water] [picture landing_night]
ADA: That's the bell. In or out?
Otto hums to himself.
* 1 (closed) Offer her the one coin you have.
* 2 Look at the river.
* 3 Sit with Otto.
* 4 (closed) Pay, and get in.
  [marked]
* 5 Go home.
> :wait 10
! rule the_boat.gone
  [boat = gone]
* 1 (closed) Offer her the one coin you have.
* 2 Look at the river.
* 3 Sit with Otto.
* 4 (closed) Pay, and get in.
  [marked]
* 5 Go home.
> 2
Still black. Still moving.
== waiting
Nobody says anything. The rain says enough.
== landing
  [music rain_on_water] [picture landing_night]
The ferry is out on the water, without you. Ada does not look back.
-> end
```

The rules fire between the player's inputs, as the facts they read change, and the story finds out when it next
asks: `ADA: That's the bell.` is said the next time round the landing, and so is the boat being gone. With no
coins, the player could not have got in; with two, `:set coins = 2` and `Pay, and get in.` while the boat is ready
or leaving takes them over.

## When the checker says no

This copy, `mistakes/09/ferry.river`, has the landing ask whether the bell has rung, has a rule speak, and counts
time on a fact that is not a clock:

```river refused
{ happened(bell) } ADA: That's the bell. In or out?
```

```river refused
= cast_off       when { boat = ready and happened(bell) }
  [boat = leaving]
  ADA: That's the bell. In or out?
= gone           when { boat = leaving and since_changed(boat, rain) >= 10 }
```

```console
$ riverrun check ferry.river
ferry.river:47:3-47:17: error: `happened` is seen by what watches conditions: a rule or a quest, not `landing`
ferry.river:98:3-98:35: error: a rule's body is its effects, `[…]`: a rule says nothing and goes nowhere
ferry.river:99:64-99:68: error: `rain` is not a clock: since_changed counts on a fact declared `(clock)`
```

A rule that should be heard sets a fact, and the story says the line where it asks about the fact, as the landing
does with `boat`. [Chapter 10](https://github.com/pedronaugusto/cairn/blob/main/docs/manual/10-quests.md), cairn's, is about quests; [chapter 12](12-what-the-checker-proves.md) is
about everything the checker says.
