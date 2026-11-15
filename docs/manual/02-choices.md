# 2. Choices

The player waits at the landing with the others, and now the player chooses what to do while they wait.

```river
== landing
Rain on the river. A lantern on a post, and a boat tied up under it.
A BOY: Ferry! Last ferry over!
OTTO: She heard you the first time.
ADA: I go when the rain eases. Not before.
- (ask)
* How much to cross?
  ADA: Two coins. Same as always.
  -> ask
* When will it ease?
  ADA: When it's ready.
  OTTO: She means never.
  -> ask
+ Look at the river.
  Black water, moving fast under the rain.
  -> ask
* Sit with Otto.
  You sit down beside him on the wet bench.
  * Ask what he sells.
    OTTO: Needles, thread, buttons. Nothing anyone needs until they need it.
  * Say nothing.
    Otto hums something under his breath.
  - The rain goes on.
  -> end
* Go home.
  You turn up the lane, the way the boy went.
  -> end
```

That is the landing of `stories/02/ferry.river`; the cast and the extras above it are [chapter 1](01-a-page-of-words.md)'s.

## A choice

```river
* How much to cross?
  ADA: Two coins. Same as always.
  -> ask
```

`*` begins a choice: the words after it are what the player picks, and the rows indented under it are what happens
when they do. Choices written one after another are offered together, and the game shows them in that order.

A `*` choice is offered once: taken, it is gone the next time the player comes back to it. A `+` choice stays, and is
offered every time:

```river
+ Look at the river.
  Black water, moving fast under the rain.
  -> ask
```

Use `+` for what a player may do as often as they like, and `*` for what is said once.

## Choices under a choice

```river
* Sit with Otto.
  You sit down beside him on the wet bench.
  * Ask what he sells.
    OTTO: Needles, thread, buttons. Nothing anyone needs until they need it.
  * Say nothing.
    Otto hums something under his breath.
  - The rain goes on.
  -> end
```

What is indented under a row, deeper than it, belongs to it, and the indent is all that says so. So the two choices
under `Sit with Otto.` are offered only once the player has sat down, and the rows under each belong to it in turn.
This manual indents by two spaces. Indentation is spaces: the checker refuses a tab.

## Gathers

`- The rain goes on.` is a gather: where the branches above it come back together. Whichever of the two the player
takes, the story goes on at the gather, says its words, and goes on to the row after it. A gather may carry words, as
this one does, or stand alone as `-` on its row.

`- (ask)` is a gather with a name, a label. It joins nothing here; it marks a place to come back to.

## Going somewhere

`->` goes somewhere. `-> ask`, the last row under three of the choices, goes back to the label `ask`, so the player
is offered the choices again: the ones that stay, and the ones not yet taken. That is how a story goes round, and
there is no other way to repeat: a conversation the player leaves when they choose is a label, its choices, and
`-> ask` at the end of each that goes back to it.

`-> end` ends the story, as in chapter 1. Every choice here ends one way or the other, so every way through the
section ends.

Keep one way out of a loop that the player can always take, a `+` choice or a `*` choice that goes elsewhere, as
`Go home.` does here. When every choice offered has been taken and none stays, the story goes on past them, to the
row after the last choice.

## Playing choices

A play stops at each set of choices and numbers them. In a terminal you type the number. To give the choices up front,
give each with `-i`, in order:

```console
$ riverrun play -i 1 -i 2 -i 2 -i 3 -i 2 ferry.river
== landing
Rain on the river. A lantern on a post, and a boat tied up under it.
A BOY: Ferry! Last ferry over!
OTTO: She heard you the first time.
ADA: I go when the rain eases. Not before.
* 1 How much to cross?
* 2 When will it ease?
* 3 Look at the river.
* 4 Sit with Otto.
* 5 Go home.
> 1
ADA: Two coins. Same as always.
* 1 When will it ease?
* 2 Look at the river.
* 3 Sit with Otto.
* 4 Go home.
> 2
Black water, moving fast under the rain.
* 1 When will it ease?
* 2 Look at the river.
* 3 Sit with Otto.
* 4 Go home.
> 2
Black water, moving fast under the rain.
* 1 When will it ease?
* 2 Look at the river.
* 3 Sit with Otto.
* 4 Go home.
> 3
You sit down beside him on the wet bench.
* 1 Ask what he sells.
* 2 Say nothing.
> 2
Otto hums something under his breath.
The rain goes on.
-> end
```

`* 1` is a choice offered, with the number to take it by; `> 1` is the input given. A play numbers the choices
as they are offered, so `How much to cross?`, taken once, is gone and the rest move up; `Look at the river.` is
offered each time. The play prints every choice with `*`, the ones written `+` too.

A play given its inputs this way prints the transcript, the rows above, and stops at the end, with the exit status
0. A play that runs out of inputs while the story is waiting for a choice stops there, with 3, and says so.

## When the checker says no

`-> aks` goes to a label nobody wrote (`mistakes/02/ferry.river`):

```river refused
* When will it ease?
  ADA: When it's ready.
  OTTO: She means never.
  -> aks
```

```console
$ riverrun check ferry.river
ferry.river:19:6-19:9: error: nothing is called `aks`: no section, part of this one, or label here
```

The name after `->` is `end`, a label of the section it is written in, or a section ([chapter
5](05-scenes-and-flow.md) adds parts). [Chapter 3](03-remembering.md) makes the story remember what the player chose.
