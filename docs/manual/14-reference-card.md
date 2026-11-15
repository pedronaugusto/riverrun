# 14. Reference card

Every mark of river on one page. Each row below is a row of one story, `stories/14/card.river` (with
`stories/14/fair.river`), which checks; the comment at the end of each row says what it shows.

## The marks

| Mark | What it does | Chapter |
|---|---|---|
| `NAME: words` | a line; words alone are narration | [1](01-a-page-of-words.md) |
| `NAME (how): words` | a line and its delivery | [4](04-telling-the-game.md) |
| `//` | a comment, to the end of the row | [1](01-a-page-of-words.md) |
| `==`, `=` | a section; a part of one | [1](01-a-page-of-words.md), [5](05-scenes-and-flow.md) |
| `*`, `+` | a choice offered once; a choice that stays | [2](02-choices.md) |
| `-`, `- (name)` | a gather; a gather with a label | [2](02-choices.md) |
| `->` | goes: `-> name`; `-> name ->` calls and comes back; `-> end` ends | [2](02-choices.md), [5](05-scenes-and-flow.md) |
| `<-` | back to where the section was called from | [5](05-scenes-and-flow.md) |
| `{ … }` | the story asks: a condition, a value, words chosen | [3](03-remembering.md), [6](06-text-that-varies.md) |
| `[ … ]` | the game is told: a tag or an effect | [4](04-telling-the-game.md) |
| `( … )` | qualifies what stands before it: a delivery, a scope, a section's kind, a fact's mark | [3](03-remembering.md), [4](04-telling-the-game.md), [8](08-pools.md) |
| `^id` | a line's or a choice's id | [6](06-text-that-varies.md) |
| `\` | the mark after it as a word: `\{`, `\}`, `\[`, `\]`, `\^`, `\#` | below |

## Declarations

```river
// Every mark of river, one row each where one row shows it: the story this manual's reference card is made from.
version: 2                                              // which version of the story this is

cast:
  ada    "Ada"    — keeps the ferry                     // an id, the name the game shows, a note
    [gender feminine]                                   // a cast entry's tag
  otto   "Otto"
    [gender masculine]
extras: a boy, a tollman                                // speakers with no name, once or twice

facts (player):                                         // facts in a scope the game names
  coins: int from 0 to 9   (game)                       // a bounded int, which the game writes
facts:
  rain: one of pouring, easing   (game)                 // one of a list
  carrying: set of lantern, needles                     // none, some or all of a list
  asked: bool                                           // true or false
  told: int                                             // a whole number
  name: text   (game)                                   // words the player typed, which the game keeps
  minute: int   (clock)                                 // an int only the game moves on
  bell: bool   (moment)                                 // what just happened, gone once rules have seen it
  owes(person): int from 0 to 9                         // a value for each person
  boat: one of tied, gone

const:
  fare = 2                                              // a value every run shares

extern:
  crossings_left() -> int                               // a query
  pay(int)                                              // an action
  talk_down(who: ref of person, coins: int) -> bool (action)   // an action with an outcome
  lamps(where: one of near, far) -> int   (reads lamps(where))  // a query a rule may ask
```

`facts (scope):` declares facts in a scope; `(game)`, `(clock)` and `(moment)` say who writes them
([chapter 3](03-remembering.md), [chapter 7](07-the-games-vocabulary.md)); `owes(person)` keeps a value for each
person. Under `extern:`, `->` gives the kind of a query's answer, `(action)` marks an action with an outcome, and
`(reads …)` says what a query reads, for rules and quests ([chapter 7](07-the-games-vocabulary.md)).

## A scene

```river
== landing                                              // a section
  [music rain_on_water]                                 // a section's tag
[boat = tied]                                           // an effect, done when the story comes to it
Rain on the river.                                      // narration
ADA: Two coins.                                         // a line
ADA (without looking up): Same as always.               // a line with its delivery
OTTO: She heard you.
  [pause 1.5]                                           // a line's tag
  [told += 1]                                           // a line's effect, done when the line is said
OTTO: Hm.
  [delivery "to himself, and nobody else"]              // a tag's words in quotes, commas and all
{ rain = pouring }                                      // rows said only when the condition holds
  Rain, hard enough to hiss.
{ else }                                                // and when it does not
  Rain, thinning.
{ asked } ADA: I told you.                              // one row, said only when the condition holds
ADA: {coins} coins, {name}.                             // a fact's value in the words
ADA: { rain = pouring: Not yet. | Soon. }               // words chosen by a condition
ADA: {coins as one: One coin. | other: {coins} coins.}  // words chosen by a number
ADA: Tell {otto as masculine: him | other: them}.       // words chosen by a gender
ADA: That's {fare - 1 + told} more.                     // a sum
OTTO: {seq: Wet. | Still wet. | Wetter.}                // each in turn, then the last
OTTO: {cycle: Hm. | Ha. | Ho.}                          // each in turn, round again
OTTO: Ferry{once: , at last}.                           // each in turn, then nothing
OTTO: {shuffle: Rain. | Wind. | Mud.}                   // in an order drawn afresh each time round
Ten \{ braces \}, a \[ bracket \], a \^ and a \#.       // the marks themselves, as words
```

## Choices, gathers and flow

```river
-> barks ->                                             // a call, which comes back
- (ask)                                                 // a gather with a label
* How much?                                             // a choice offered once
  [asked = true]                                        // a choice's effect, done when it is taken
  -> ask                                                // a jump
+ Look at the river.                                    // a choice that stays
  -> ask
* { coins >= fare and rain != pouring } Pay.            // a choice offered only when it holds
  [marked]                                              // a choice's tag
  [pay(fare)]                                           // an action
  -> crossing
* { not asked and seen(ask) > 2 } Offer one coin.       // not, and, the times a label was passed
  [asked = talk_down(ada, 1)]                           // an action whose outcome a fact keeps
  { asked: -> crossing | -> ask }                       // a flow chosen by a condition
* Go home.
  * Run.                                                // a choice under a choice
  * Walk.
  - You go.                                             // a gather: the branches above come together
  -> end                                                // the end of the story
```

## Parts, calls, pools and rules

```river
== crossing
-> midstream
= midstream                                             // a part of a section
  [picture fog]                                         // a part's tag
  { carrying has lantern or carrying hasnt needles } Light.   // has and hasnt
  [owes(otto) += 1] [carrying += lantern] [carrying -= needles]   // a value kept per thing; a set added to, taken from
  -> lamp ->
  -> fair.gate                                          // a section of another module

== lamp
The lamp swings at the prow.
{ crossings_left() > 0 and lamps(near) >= 1 } Lit.      // queries asked
<-                                                      // back to where the section was called from

== barks (pool 2)                                       // a pool, saying up to two
= boy          when { rain = pouring }                  // a candidate, said when it holds
  [weight 3]                                            // drawn three times as often
  A BOY: Ferry!
= anyone                                                // a candidate that always holds
  Nobody says anything.

== the_boat (rules)                                     // rules, which fire as the facts change
= gone         when { happened(bell) and since_changed(boat, minute) >= 10 }
  [boat = gone]                                         // a rule's effects
= kept         when { told > 0 }
  [migrate 2]                                           // a migration, run when a version-1 save loads
  [told = 0]
```

## A module

```river
module fair                                             // this file's names are `fair.…` to every other file
facts:
  sold: int

== gate
OTTO: That's the fair. Sold {sold} today.
[sold += 1]
-> end
```

The two files are one story, checked together:

```console
$ riverrun check card.river fair.river
```

## An id

`^` and six letters and digits at the end of a line's or a choice's row, written by `riverrun tag`
([chapter 6](06-text-that-varies.md)); from `stories/06/tagged/bank.river`:

```river
ADA: Mind how you go. ^cx3yhv
* Thank her. ^gfk8sk
```

## The program

| Command | What it does |
|---|---|
| `riverrun check [--release] FILE…` | checks the story as the game's build does, and prints every problem, or nothing; `--release` needs every id too |
| `riverrun tag [--check] FILE…` | writes an id at the end of every line and choice without one, and prints each file it changed; `--check` changes nothing and lists them |
| `riverrun play [options] FILE…` | plays the story, in the terminal, or from a script, writing a transcript |
| `riverrun compile --graph PATH --words PATH [--release] FILE…` | what the game's build runs: checks, then writes the compiled story |
| `riverrun COMMAND --help` | the command's options, with examples |

`riverrun play`'s options:

| Option | What it gives |
|---|---|
| `--from SECTION` | start at this section, not where the game starts |
| `--set 'FACT = VALUE'` | a fact the game has set at the start, or a query's answer: `--set 'crossings_left() = 1'` |
| `--wait N` | how far a clock has run at the start: `--wait 21` |
| `--call 'COMMAND …'` | a call the game made into a package before the start (quests and time) |
| `--script PATH` | the inputs, one to a row, `//` before a comment |
| `-i INPUT` | one input; give it again for each |

In a play, as input:

| Input | What it does |
|---|---|
| `N` | takes the choice numbered N |
| a value | the outcome an action waits for: `true`, `3`, a word of its list, a thing, `"words"` |
| `:set FACT = VALUE` | sets a fact; `+=` and `-=` add to a set or an int, or take from it |
| `:set FACT(KEY) = VALUE` | sets a fact kept per thing, for one thing |
| `:set QUERY(ARGS) = VALUE` | what the game answers a query with, from then on |
| `:wait N [CLOCK]` | moves a clock on N |
| `:facts [FACT…]` | the facts that moved since the start, or those named |
| `:back`, `:restart`, `:quit`, `:help` | back one input; from the start again; stop; list these |

A transcript's rows, each known by how it begins:

| Row | What it is |
|---|---|
| `== name`, `= name` | the story came to a section, a part |
| `NAME (how): words`, `words` | a line, narration; ` ^id` at the end where it has one |
| `  [ … ]` | indented under a heading, a line or a choice: its tags, then its effects |
| `[ … ]` | at the margin: effects the story came to on their own |
| `* N words`, `* N (closed) words` | a choice offered; a choice that cannot be taken |
| `? query(args) = value` | a query asked and its answer, `(not set)` where none was set |
| `? action(args) -> kind` | an outcome waited for |
| `! rule section.rule` | a rule fired, its effects under it; `!` also begins what a package says happened |
| `> input` | an input, as given |
| `-> end` | the end |
| `file:line:col-line:col: error: …` | an error at run time, or an input not taken |

A play's exit status is 0 at the end, 1 when the story does not check or an input is not taken, 2 for a mistaken
command line, 3 waiting for an input not given, and 4 stopped on an error at run time ([chapter
12](12-what-the-checker-proves.md)).

## Playing the card

```console
$ riverrun play --set 'name = "Pip"' --set 'coins = 2' --set 'rain = easing' --set 'crossings_left() = 1' --set 'lamps(near) = 1' -i 3 card.river fair.river
> :set name = "Pip"
> :set coins = 2
> :set rain = easing
> :set crossings_left() = 1
> :set lamps(near) = 1
== landing
  [music rain_on_water]
[boat = tied]
Rain on the river.
ADA: Two coins.
ADA (without looking up): Same as always.
OTTO: She heard you.
  [pause 1.5]
  [told += 1]
OTTO (to himself, and nobody else): Hm.
Rain, thinning.
ADA: 2 coins, Pip.
ADA: Soon.
ADA: 2 coins.
ADA: Tell him.
ADA: That's 2 more.
OTTO: Wet.
OTTO: Hm.
OTTO: Ferry, at last.
OTTO: Rain.
Ten { braces }, a [ bracket ], a ^ and a #.
== barks
Nobody says anything.
== landing
  [music rain_on_water]
* 1 How much?
* 2 Look at the river.
* 3 Pay.
  [marked]
* 4 (closed) Offer one coin.
* 5 Go home.
> 3
[pay(2)]
== crossing
= midstream
  [picture fog]
Light.
[owes(otto) += 1] [carrying += lantern] [carrying -= needles]
== lamp
The lamp swings at the prow.
? crossings_left() = 1
? lamps(near) = 1
Lit.
== fair.gate
OTTO: That's the fair. Sold 0 today.
[fair.sold += 1]
-> end
```

## The grammar

River's rows, as the reader reads them: the grammar of [docs/design.md](../design.md), the design of record, which
the test step holds this copy to, and every form in it a row of the card above. `NL` ends a row and `IND` is its
indentation, in spaces: what is indented deeper under a row belongs to it.

```text
file        = [ "module" name NL ] { row }
row         = IND ( declaration | heading | brackets | statement ) [ " ^" id ] [ comment ] NL
comment     = "//" { any }                     ; at the start of the words, or after a space

declaration = "version:" int
            | "cast:" NL { IND name quoted [ "—" words ] NL { IND brackets NL } }
            | "extras:" words { "," words }
            | "facts" [ "(" name ")" ] ":" NL { IND fact NL }
            | "const:" NL { IND name "=" value NL }
            | "extern:" NL { IND extern NL }
fact        = name [ "(" ( name | "one of" list ) ")" ] ":" type [ "(game)" | "(clock)" | "(moment)" ]
type        = "bool" | "int" [ "from" int "to" int ] | "text" | "one of" list | "set of" list | "ref of" name
list        = name { "," name }
extern      = name "(" [ params ] ")" [ "->" type ] [ "(action)" ] [ "(reads" name [ "(" list ")" ] ")" ]
params      = type | name ":" type { "," name ":" type }

heading     = "==" name [ "(" ( "pool" [ int ] | "rules" | name ) ")" ]
            | "=" name [ "when" "{" expr "}" ] [ statement ]
brackets    = "[" bracket "]" { "[" bracket "]" }
bracket     = name [ value { "," value } ]                    ; a tag
            | name [ "(" expr ")" ] ( "=" | "+=" | "-=" ) expr  ; an effect on a fact
            | name "(" [ expr { "," expr } ] ")"              ; an action
value       = word | number | quoted

statement   = [ "{" expr "}" ] ( line | flow )
            | ( "*" | "+" ) [ "{" expr "}" ] words
            | "-" [ "(" name ")" ] [ statement ]
            | "{" expr "}" | "{ else }"
line        = [ SPEAKER [ " (" words ")" ] ": " ] words
flow        = "->" ( name | name "." name | "end" ) [ "->" ] | "<-"
            | "{" expr ":" flow "|" flow "}"
words       = { text | escape | "{" expr "}" | "{" expr ":" words "|" words "}"
              | "{" ( "seq" | "cycle" | "once" | "shuffle" ) ":" words { "|" words } "}"
              | "{" expr "as" label ":" words { "|" label ":" words } "}" }
label       = "zero" | "one" | "two" | "few" | "many" | "masculine" | "feminine" | "neuter" | "other"
escape      = "\{" | "\}" | "\[" | "\]" | "\^" | "\#"

expr        = or
or          = and { "or" and }
and         = not { "and" not }
not         = "not" not | rel
rel         = sum [ ( "=" | "!=" | "<" | "<=" | ">" | ">=" | "has" | "hasnt" ) sum ]
sum         = atom { ( "+" | "-" ) atom }
atom        = name [ "(" [ expr { "," expr } ] ")" ] | int | quoted | "true" | "false" | "(" expr ")"
```

A speaker is capitals, digits, `_` and spaces, a cast entry's id or an extra in capitals; a name is letters, digits
and `_`, and a name another module declares is written after its module's, `fair.gate`; an id is letters, digits,
`_` and `-`. In a condition, `seen(name)` is how many times a section, a part or
a label has been passed, and in rules and quests, `since_changed(fact, clock)` and `happened(moment)` are there
too. Braces nest at most 8 deep in a line's words, and a chain of `and`, `or`, `+` or `-` holds at most 32 links.
