# riverrun's design

riverrun runs stories written in `.river` files: what is said, by whom, on what condition, what a choice changes and
where the story goes next. A host engine reaches it through Zig or a C ABI. This page is the design it is built to;
what is built is marked so.

## What it owns

riverrun owns **story**: content, flow, facts and tags. It owns no time, rendering, input, file at run time or
mechanic, and it knows no host's words: no scope, tag or fact name is built in. A host's mechanics (timed listening,
a day of slots, rooms by hours) and its presentation are its own. The two meet through **tags**, which riverrun
carries and a host's schema types. *Protects:* one narrative system for every engine, and no engine's ideas inside
it.

## The language

A `.river` file is plain UTF-8 a writer reads top to bottom, indented by spaces:

```
cast:
  mum   "Mum"
  dad   "Dad"     — Frank, her father
facts (player):
  carried: set of play, gave, hands
facts (life):
  spot: one of stairs, piano, door, landing   (game)

== hide_1969                                 # listen · count 20
MUM: You could still play, Frank.            # id k7f3a2 · at 9.5 · heard piano, door, landing
  ~ carried += play
DAD: Who'd listen?                           # id m2c9qd · at 12.5 · heard piano

== kitchen_1985
DAD: Go.
- (ask)
* Who'll run the shop?
  DAD: I ran it before you could walk.
* { carried has play } You could still play, Dad.
  DAD: Who'd listen?
  -> ask
* Pick up the case.
  -> fork_1985
```

- **Declarations**, seen by every file of the story:
  - `cast:` ids with a display name, a note after `—` and tags; `extras:` people who speak once and need no name. A
    speaker that is neither is an error.
  - `facts (scope):` typed facts in a scope the host names; `(game)` marks a fact only the host writes, and
    `(clock)` an int it only advances.
  - `ref of kind` is a type for one of the host's things (a person, an item kind, a place), named in the story by
    its stable id (`wolf_pelt`) and checked against the host's manifest.
  - `const:` fixed points every run shares (`dies_at = "ten past nine"`).
  - `extern:` the host's vocabulary. `name(params) -> type` is a **query**, pure and callable anywhere; `name(params)`
    is an **action**, run when its line is reached; `name(params) -> type (action)` is an action with an **outcome**
    the host decides (a roll, a check, a fight). Parameters may be named (`kind: ref of item_kind, n: int`); a
    query declares the stamp of what it reads, keyed by its parameters, `(reads stock(kind))`, so whatever
    evaluates it can be woken when that changes.
- **Modules.** A file may begin `module name`; what it declares is `name.x` to other modules, and an unqualified
  name resolves in its own module first, then the root. *Protects:* hundreds of files and many writers without clashes.
- **Sections:** `== name`, with nested `= name`. A section may have a kind: `(pool)`, `(pool N)`, or a kind a
  package registers with the compiler, such as a quest package's `(quest)`.
- **Lines:** `SPEAKER: text`, or narration with no speaker. The text is the whole line, never assembled from pieces at
  run time; it holds:
  - `{fact}`, a value;
  - `{ condition: these words | those words }`, words chosen by a condition;
  - `{seq: a | b | c}`, `{cycle: …}`, `{once: …}` and `{shuffle: …}`, alternatives, each keeping its own state in
    the `story` scope (a shuffle needs more than a count).
- **A line's own effects** are indented under it and happen when the host delivers the line. A host that does not
  deliver it does not apply them: a memory overheard in hide and seek is carried only if the line is heard.
- **Choices:** `*` is offered once, `+` stays; `{ condition }` before the text gates one. A gated choice is still
  returned, marked closed, so a host can show it locked. A gather `-` joins the branches; `- (label)` names it.
  Nesting is by indentation alone.
- **Conditions:** `{ condition } line` for one line; `{ condition }` above an indented block, with `{ else }` after
  it. Inline conditions are for words, blocks for whole lines.
- **Expressions:** `=`, `!=`, `<`, `<=`, `>`, `>=` on ints, `has` and `hasnt` on sets, `and`, `or`, `not`, queries,
  and `seen(name)`, the visits of a section, part or label (an int; true when above zero). No arithmetic and nothing
  that loops: the host computes, through its queries.
- **Effects:** `~ fact = value`, `~ set += item`, `~ set -= item`, `~ int += n` and `~ int -= n` (a number or an int
  constant, never an expression: approval, bonds, reputation), `~ action(args)` and `~ fact = action(args)`.
- **Flow:** `-> name` jumps (a section, a part or a label), `->> name` calls and `<-` returns, `-> end` ends, and
  `{ condition } -> name` jumps on a condition.
- **Pools:** a `(pool)` section's candidates are parts with `when { condition }`. riverrun picks the most specific
  candidate that holds (the most comparisons joined by `and`), the least recently seen among equals, with a seed
  that lives in the facts. `(pool N)` gives up to N.
- **Tags:** `# key value · key value` at the end of a line, a choice or a heading. `id` is riverrun's: a line's
  stable id. Every other key is the host's, typed by its schema; a key the schema marks `leads` carries the flow on
  into the host's mechanic.
- **Comments:** `//`.

Built: the reader and the checker, all of the above.

## Conversations

A conversation with several speakers needs no construct of its own:

- **Interjections** are calls into a pool: `->> barks` after a line, whose candidates are conditioned on who is
  present (a `(game)` fact). A pool where nothing holds says nothing.
- **Interruptions** are the host's: it calls a section into a running flow, which says it and returns to the line
  after the one being delivered, or ends with `-> end`.
- **Flows:** several cursors over the same facts, for conversations held at once.
- **Checks with outcomes:** `~ persuaded = persuade(margaret, 12)` stops the flow at an action; the host decides the
  outcome, sets the fact, and the story branches on it. riverrun never rolls.

## Facts

- **Types:** `bool`, `int`, `one of …`, `set of …`, text (only for names the player types), and `ref of kind`,
  the host's handle for one of its things. A story names things by stable text ids, resolved to handles once at
  load; a snapshot saves a named thing by its id, so a host may renumber its handles, and any other ref by its
  handle, which must then be lasting.
- **Scopes** are named by the story and stored by the host; riverrun keeps them apart. A game that replays lives
  might save `life` per life and keep `player` across them; riverrun knows neither name.
- **The reserved scope `story`** holds what riverrun itself counts: visits, alternatives, pools' memory and the seed.
  The host saves it like any other.
- **An interface:** riverrun reads and writes facts by id and type through a store the host gives it. The default
  store is in memory; an engine can back facts with its own world state, so they save, replicate and journal as its
  other state does.
- **A change notifies only what reads it:** a subscriber names facts and learns which changed. A quest system stands
  on this.
- **A snapshot** of a scope is versioned bytes with the story's hash. Restored under another version, facts are
  matched by name and the dropped and new ones are reported; a readable JSON form goes through strand.

## The compiler

It runs at build time. A game's build calls `riverrun.addStory(b, dep, .{ .files, .schema, .mode })` and embeds the
result.

1. **Read** each file: a hand-written recursive-descent parser with positions, and a fuzz target for each parser.
2. **Resolve** against one index of every file's declarations: speakers, facts, constants, externs, sections, labels
   and modules.
3. **Check**, reporting every error, not the first:
   - types;
   - every section reachable, a section a tag names counting as an edge;
   - no path that runs off a scene without `-> end`, a return, a jump or a tag that leads on;
   - no choice whose condition can never hold, where that is decidable;
   - `(game)` facts never set by the story, and a story fact nothing sets;
   - tags against the host's schema, so a typo fails with a file and a line;
   - text width against the host's limit, measured by xenoglyph;
   - line ids unique; a release build refuses a line without one.
4. **Emit** the compiled format, and a JSON dump through strand for tools.

A file is checked against the index and compiled on its own, then linked, so a change recompiles one file.
**Line ids:** `riverrun tag` writes an `id` into every line that has none; a development build derives missing ones
(`~` and a hash of the section, the part, the position, the speaker and the words). *Protects:* translations,
recorded voices and model characters keyed on a line and surviving a typo fix.

Built: read, resolve and check. The format, its builder and its reader are built; compiling into it is next.

## The compiled format

**Graph data**, not bytecode: sections as nodes, lines, choices, gathers and pool candidates as their entries, jumps
and calls as edges, and conditions and effects as small postfix arrays over fact, constant and extern ids. Arrays of
structs of plain integers, little-endian, with a header carrying the version and the story's hash. The **string
table** is a file of its own keyed by line id, so a translation replaces it whole without touching the graph. It
holds each line whole, as a template with numbered places for its values and chosen words (`{0}`, `{1:a|b}`), so a
translator can reorder a sentence. Externs carry an action flag, since an action may return an outcome. A
reader validates every index before use and never trusts the bytes. `docs/format.md` specifies it, so another
engine's runtime can read it without this library.

Why a graph and not a bytecode VM: a player reads a line for seconds, so speed decides nothing. A graph is what tools
draw, so the compiled story is the graph they read rather than one rebuilt from instructions; a save names a section
and a line id, which survive edits, where an instruction offset moves with any edit; and reachability and dead ends
are exact over fixed node kinds. The cost is expressiveness: riverrun has no functions, loops or text assembled at
run time, and procedural text comes from the host's queries.

## The runtime

A small data-oriented Zig **executor** walks the graph. There is no virtual machine.

```
Story.init(bytes) · Strings.init(bytes) · Host.bind(story, impls)
Session.init(gpa, story, strings, store, host, options)
start(flow, section) · next(flow) → line | choices | effects | action | end
choose(flow, i) · outcome(flow, value) · interrupt(flow, section) · stop(flow)
saveCursors() → bytes · restoreCursors(bytes) → report      (facts: snapshot and restore per scope)
```

- **`next` walks until it has something for the host**: branches, gathers, jumps, calls and pools are walked
  through. A line comes with its own effects; choices come open or closed, a once-only choice gone after it is taken,
  and when none is open the flow goes past them; an effects step on its own comes as `effects`.
- **The host is bound by name at load.** The story's externs carry names and signatures; a Zig host binds a struct
  of functions, reflected by field name into a table indexed by extern id, and a host in another language binds a
  function pointer and its data per name through `Binder`. Every extern must be bound with its signature, or the
  bind fails naming what is unbound or mismatched; at run time a call is an array index.
- **Calls carry their context:** the flow that asked, and whose facts each scope holds (`setOwner`: a player, a
  region), so a query on a server knows whose inventory it counts. An emitted action carries the same context.
- **Things the host owns are resolved once.** A story names them by stable text ids of a kind (`wolf_pelt`, a
  `ref of item_kind`); the host resolves each to its own 64-bit handle at load, refusing an id it does not know, and
  the evaluator only ever sees handles.
- **Effects are emitted, never applied.** The host applies them: at once, or as commands at its own tick boundary,
  so its journal, replay, undo and network authority cover the story too. The executor writes only its own
  bookkeeping, in the reserved `story` scope: visits, alternatives, pools' memory and the turn.
- **Conditions are a formula evaluator,** a tight loop over a postfix array: it cannot loop, branch the story or call
  what the host did not declare.
- **Queries** may be evaluated at any time; **actions** only when their step is reached, and nothing looks ahead. An
  action with an outcome is handed over on its own (`action`, which the bound host can `perform`), and its flow
  waits until the host gives `outcome`,
  which the session writes into the result fact. Actions with outcomes in a line's effects hold the flow the same way,
  in order.
- **Pools** give the most specific candidates that hold, then the least recently given, then an order the seed and
  the turn decide, so equals take turns; `(pool N)` gives N, one after another.
- **A section runs out** when a step has no next: a call or an interruption goes back to where it began, a pool to
  its next candidate; with nothing to go back to, the flow ends. `<-` runs a section out at once.
- **Interruptions** run a section as a call and come back to the step after the one being delivered, or to the
  choices being offered, which are offered again.
- **Cursors are saved by name:** each step by its section, its place in that section and its line id. Restored under
  a recompiled story, a step that moved is found by its line id and one that is gone ends its flow, as the report
  says.
- **Deterministic:** no clock, no I/O, no randomness outside the seed in `story`. Each flow keeps one arena, reset at
  every step, so a step allocates nothing once the arena has grown; what a step hands over is valid until that
  flow's next step.
- **Every bound is a named error:** call depth 64 (calls, interruptions and pools together), choices at a point 32,
  candidates given at once 8, outcomes owed by one step 8, facts 4,096, flows 16, and a step walking 100,000 nodes
  without saying anything (`NoProgress`, a loop of jumps).

Built.

## Reach

- **The core is Zig,** with the caller's allocator and no globals, I/O or clock; it builds freestanding, so it runs
  in WebAssembly as well as in a game.
- **A C ABI,** `ffi/riverrun.h`: opaque handles, the caller's allocator, facts and the host's queries and actions by
  callbacks, and a version handshake at load. That reaches C and C++, Rust, C#, GDExtension, Unreal and Swift.
- **The `riverrun` program:** `check`, `tag`, `dump`, `explore` (walks every branch on a deterministic clock and
  proves every section and choice reachable, no dead end and no line that can never be said) and `compile`. Hosts
  reload `.river` files live through lookout.

## The code, by layer

Each layer is a folder beside its root file, and imports only those before it:

```
syntax    files → syntax tree, with positions                                   built
facts     types, scopes, the store interface, the default store, snapshots      needs nothing · built
check     resolve and check the tree against a host's schema → a checked story  syntax · built
story     the compiled format: builder, writer, validated reader               facts · built
compile   a checked story → the format, file by file, then linked              check, story
run       the executor over the format and a store                             story, facts · built
ffi       the C ABI over run                                                   run
tools     the program, on ensign                                               all
```

A game that only plays links `story`, `facts` and `run`, never `syntax` or `check`. *Protects:* a small runtime, and
compile-time work that stays at build time.

## Napkin math

- **A two-hour story** is about 50,000 words: some 5,000 lines in 600 sections, about 800 KB compiled, half of it
  the string table (the proof's 30 KB of source is about 65 KB). A step reads a few entries.
- **A snapshot** is facts plus visits, a few kilobytes.

## Decided from the proof

`src/syntax/testdata/proof/` is a whole game's story, about 490 lines, written before the code to test the language.
Writing it decided:

- **A day of slots reads as story.** Each act is a sticky choice offered until it is kept, with tags the host's
  mechanic reads; no data file beside the story.
- **Pools carry a night of rooms.** A table of rooms by hours by what was kept became 30 candidates, and specificity
  settles "this line if she came, that one if not" with no chains of `else`.
- **A tag can name a section**, typed so by the host's schema, and counts as an edge.
- **Changing which life is played is the host's:** it is an action, not a fact the story sets.
