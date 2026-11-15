# 5. Scenes and flow

The player pays and gets in, and the story leaves the landing for the river. A story of more than one place is
several sections, and `->` goes from one to the next.

```river
* { coins >= 2 and rain != pouring } Pay, and get in.
  [marked]
  [pay(2)]
  { not asked_price } ADA: Two coins, first.
  ADA: Mind the step.
  -> crossing
* Go home.
  You turn up the lane, the way the boy went.
  -> end

== crossing
  [music oars]
The boat pushes off. Behind you the lantern on the post grows small.
-> midstream

= midstream
  [picture fog]
  Halfway over, the fog comes down.
  -> lamp ->
  OTTO: I can't see the bank.
  ADA: You don't need to. I do.
  * Hold still.
    -> landfall
  * Stand up to look.
    The boat tips. Ada says something you are glad not to have heard.
    -> midstream

= landfall
  The keel scrapes on stones.
  ADA: Out you get.
  -> far_bank

== lamp
{ carrying has lantern }
  You hold up Otto's lantern. It makes a small room of light in the fog.
  <-
Ada's lantern swings at the prow, and lights nothing.
<-

== far_bank
  [music fair_far_off] [picture far_bank]
Mud, a path, and up the hill the lights of the fair.
OTTO: Well. That's me.
{ trust > 0 } OTTO: Keep the lantern.
-> end
```

That is `stories/05/ferry.river` from the landing's last two choices on.

## Sections

`== crossing` begins a section, and the section runs to the next `==`. `-> crossing` goes there: the story leaves
the landing and goes on at the first row of `crossing`. A section is a place the story goes to, and a scene of the
game: the game may play other music, show another picture, for each, as its tags here say.

The game starts the story where its own vocabulary says, or else at the first section nothing goes to with `->`:
here, `landing`.

## Parts

```river
= midstream
  [picture fog]
  Halfway over, the fog comes down.
```

`= midstream` begins a part of the section it is in: a beat of a scene, with a name to go to. Its rows are indented
under its heading, and its tags stand on the first rows, as a section's do. Once a section has parts, every row
after the first part belongs to one.

A part is gone to by its name from within its section: `-> midstream`, `-> landfall`. From another section, go to
the section. A label, `- (ask)`, belongs to the section or the part it is written in, and is gone to from there.

## Going and coming back

`-> lamp ->` goes to `lamp`, and comes back. The story says what `lamp` says, and at `<-` returns to the row after
the one it left from, `OTTO: I can't see the bank.` Use it for what several places say alike: here, whether the
player has a lantern to hold up, in the fog, wherever the fog comes down.

```river
== lamp
{ carrying has lantern }
  You hold up Otto's lantern. It makes a small room of light in the fog.
  <-
Ada's lantern swings at the prow, and lights nothing.
<-
```

`<-` goes back to where the section was called from. A section reached by a call ends with `<-`; one reached by
`-> name` goes on somewhere with `->`. `-> end`, anywhere, ends the whole story, from inside a call too.

## Where a section must end

Every way through a section ends: with `-> end`, with `<-`, or by going somewhere with `->`. The checker follows
every way, through every choice and every condition, and a way that runs off the bottom of a section or a part is
an error, since the story would not know where to go.

A part does not go on into the next part: `midstream` ends with its choices, and each goes somewhere.

## Trying a scene

`--from` starts the play at a section, where the game would start the story elsewhere. `--set` gives the facts the
player would have by then: here, the lantern from Otto, and his good opinion.

```console
$ riverrun play --from crossing --set 'carrying = lantern' --set 'trust = 1' -i 2 -i 1 ferry.river
> :set carrying = lantern
> :set trust = 1
== crossing
  [music oars]
The boat pushes off. Behind you the lantern on the post grows small.
== crossing
  [music oars]
= midstream
  [picture fog]
Halfway over, the fog comes down.
== lamp
You hold up Otto's lantern. It makes a small room of light in the fog.
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
You hold up Otto's lantern. It makes a small room of light in the fog.
== crossing
  [music oars]
= midstream
  [picture fog]
OTTO: I can't see the bank.
ADA: You don't need to. I do.
* 1 Hold still.
> 1
== crossing
  [music oars]
= landfall
The keel scrapes on stones.
ADA: Out you get.
== far_bank
  [music fair_far_off] [picture far_bank]
Mud, a path, and up the hill the lights of the fair.
OTTO: Well. That's me.
OTTO: Keep the lantern.
-> end
```

A play prints a section's heading, with its tags, each time the story comes to it, and `= part` under it for a
part: back from `lamp` it prints `== crossing` and `= midstream` again, where the story goes on. Going back to
`midstream` after standing up, the story does not print the heading again until it has been elsewhere.

In a terminal, `:back` takes back the last input and `:restart` starts again, to try the other way.

## When the checker says no

This copy, `mistakes/05/ferry.river`, has lost the row that takes the player back after standing up:

```river refused
  * Hold still.
    -> landfall
  * Stand up to look.
    The boat tips. Ada says something you are glad not to have heard.

= landfall
```

```console
$ riverrun check ferry.river
ferry.river:68:3-68:12: error: the part `midstream` can run off its end: end it with `-> end`, `<-` or a flow elsewhere
```

The error is placed on the part's name, since it is the part that has a way out with nowhere to go; the way is the
choice above whose rows stop.

And this one, `mistakes/05/jump/ferry.river`, goes to `lamp` with `-> lamp` where it meant to call it:

```river
= midstream
  [picture fog]
  Halfway over, the fog comes down.
  -> lamp
  OTTO: I can't see the bank.
```

```console
$ riverrun check ferry.river
ferry.river:72:3-72:30: warning: nothing reaches this: the story always goes elsewhere before it
ferry.river:88:3-88:5: warning: `<-` goes back to a caller, but nothing calls `lamp` with `-> lamp ->`
```

Two warnings, and the story still plays, but the fog scene would end in the lamp. `-> lamp` goes and does not come
back, so nothing after it is said; and `lamp`'s `<-` has no one to go back to. [Chapter 6](06-text-that-varies.md)
makes the lines vary from one time to the next.
