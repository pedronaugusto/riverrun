# 1. A page of words

A river story is a text file the game reads, row by row. Here is a whole one: a ferry landing at night, and two
people waiting for the ferry to go.

```river
// The landing at Hollin, at night: a ferry, and two people waiting for it.
cast:
  ada    "Ada"    — keeps the ferry
  otto   "Otto"   — a pedlar, going over for the fair
extras: a boy

== landing
Rain on the river. A lantern on a post, and a boat tied up under it.
A BOY: Ferry! Last ferry over!
OTTO: She heard you the first time.   // the boy shouts it at every boat
ADA: I go when the rain eases. Not before.
The boy runs off up the lane. Otto sits down on his pack.
OTTO: Then we wait.
-> end
```

It is `stories/01/ferry.river`, beside this chapter. Play it:

```console
$ riverrun play ferry.river
== landing
Rain on the river. A lantern on a post, and a boat tied up under it.
A BOY: Ferry! Last ferry over!
OTTO: She heard you the first time.
ADA: I go when the rain eases. Not before.
The boy runs off up the lane. Otto sits down on his pack.
OTTO: Then we wait.
-> end
```

`riverrun` is the program a writer runs. Your game's build makes it with the game's vocabulary in it, the tags and
actions the game knows, so it reads a story exactly as the game does; ask whoever builds the game where it puts it. This manual's stories are written
for a small game of the manual's own, and its `riverrun` is built in riverrun's folder with `bay manual`, which puts
it in `zig-out/bin/`. Every command in this manual is run in the folder of the story it names.

In a terminal, `riverrun play` prints the same rows in colour, with a line on how to use it above them, and after
`-> end` it waits for you to type `:quit`. The rest of this chapter goes through the story row by row.

## Lines

```river
OTTO: Then we wait.
```

A line is a speaker, a colon, and what they say. The speaker is written in capitals, the colon follows straight
after it, then a space, then the words. The words are exactly what follows the colon, and the game shows them as
written.

A row is a line only in that shape. `Otto: Then we wait.` and `OTTO:Then we wait.` are narration (below), name and
all, and the checker does not say so. In a terminal a play prints a speaker in bold, so a line that has lost its
speaker shows.

## Narration

```river
Rain on the river. A lantern on a post, and a boat tied up under it.
```

A row of words with no speaker is narration: what the player reads, or a narrator says, as the game decides.

## The cast

```river
cast:
  ada    "Ada"    — keeps the ferry
  otto   "Otto"   — a pedlar, going over for the fair
```

Everyone who speaks more than once is in the cast. Each entry is a row indented under `cast:`: an id, the name the
game shows in quotes, and after a dash, `—`, a note for whoever reads the story. The id is what a line names in
capitals: `ada` is spoken for by `ADA:`. An id is letters, digits and `_`, so `old_tom` would speak as `OLD_TOM:`.
The note is for writers, translators and actors, and the game never shows it. It may be left out, and so may the
spaces that line the entries up; the dash before a note is the long one, `—`, not a hyphen.

## Extras

```river
extras: a boy
```

An extra speaks once or twice and needs no name: a boy, a guard, the youngest. List them on one row after
`extras:`, separated by commas, and write each as a speaker in capitals, `A BOY:`. A speaker who is neither in the
cast nor among the extras is a mistake, and the checker says so (below).

## Comments

```river
OTTO: She heard you the first time.   // the boy shouts it at every boat
```

`//` begins a comment, which runs to the end of its row: notes to yourself and to whoever works on the story next.
A comment is on a row of its own, or after a space at the end of one, as here. The game never sees it, and a play
does not print it.

## A section, and its end

```river
== landing
```

`== landing` begins a section, and every line of a story belongs to one. A section is a scene, a place the game can
start the story and the story can go to; its name, `landing`, is letters, digits and `_`. This story has one, and
the play starts there: `== landing` is the first row it prints.

```river
-> end
```

`-> end` ends the story. Every way through a section ends somewhere, and until [chapter 2](02-choices.md) there is
only one way through, so a section's last row is `-> end`. [Chapter 5](05-scenes-and-flow.md) has the other ways a
section can end.

## When the checker says no

`riverrun play` checks the story before it plays it, and `riverrun check` checks it and does nothing else. This copy
of the story, `mistakes/01/ferry.river`, misspells Ada and has lost its last row, `-> end`:

```river refused
A BOY: Ferry! Last ferry over!
OTTO: She heard you the first time.   // the boy shouts it at every boat
ADDA: I go when the rain eases. Not before.
The boy runs off up the lane. Otto sits down on his pack.
OTTO: Then we wait.
```

```console
$ riverrun check ferry.river
ferry.river:11:1-11:5: error: `ADDA` is not a speaker: speakers come from `cast:` and `extras:`
ferry.river:7:4-7:11: error: the scene `landing` can run off its end: end it with `-> end`, `<-` or a flow elsewhere
```

Each mistake is one row: the file, where the mistake starts and where it ends as line and column (`11:1-11:5` is
line 11, from the first column to just past the fifth, which is `ADDA`), whether it is an error or a warning, and
what is wrong. The checker reports every mistake it finds, not only the first. A story with an error is not played,
and the game's build refuses it; a warning is something to look at, and the story still plays. When nothing is
wrong `riverrun check` prints nothing.

Put the two rows right and play it again. [Chapter 2](02-choices.md) gives the player something to choose.
