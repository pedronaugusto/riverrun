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

A `.river` file is plain UTF-8 a writer reads top to bottom, indented by spaces. Words stand bare; what is for the
game falls into three delimiters, each with one meaning: `{ … }` the story asks, `[ … ]` the game is told, `( … )`
qualifies what stands before it. `->` is flow and nothing else, and the structure is Ink's weave on indentation.

```
cast:
  mum   "Mum"
  dad   "Dad"     — Frank, her father
facts (player):
  carried: set of play, gave, hands
facts (life):
  spot: one of stairs, piano, door, landing   (game)

== hide_1969
  [listen] [count 20]
MUM: You could still play, Frank. ^k7f3a2
  [at 9.5] [heard piano, door, landing]
  [carried += play]
DAD (quietly): Who'd listen? ^m2c9qd
  [at 12.5] [heard piano]

== kitchen_1985
DAD: Go.
- (ask)
* Who'll run the shop?
  DAD: I ran it before you could walk.
* { carried has play } You could still play, Dad.
  [known play]
  DAD: Who'd listen?
  -> ask
* Pick up the case.
  -> fork_1985
```

### Rows

A file is rows. A row's words are what follows its indentation, up to its comment; a row is one of these, by how
its words begin:

- **a declaration** at indentation zero: `version:`, `cast:`, `extras:`, `facts:` or `facts (scope):`, `const:`,
  `extern:`, and `module name` on the first row;
- **a heading:** `== name` a section, `= name` a part of one;
- **a row of brackets,** words that begin with `[`: direction for the game (below);
- **a statement:** a line, a choice (`*`, `+`), a gather (`-`), a condition (`{ … }`, `{ else }`) or a flow (`->`,
  `<-`).

Indentation is spaces. What is indented under a row, deeper than it, belongs to it. `//` after a space, or at the
start of the words, begins a comment, which runs to the row's end; inside a bracket's quotes it is words. A row's
line ending is LF or CRLF. A control character in a row (a carriage return on its own, a NUL, any C0 or C1 control
but a tab, or DEL) is an error over that byte; the row is kept as it is written.

### Declarations

Seen by every file of the story:

- `cast:` ids with a display name, a note after `—`, and tags in brackets on rows indented under the entry:
  ```
  cast:
    marta  "Marta"  — the merchant
      [gender feminine]
  ```
  `extras:` people who speak once and need no name, separated by commas: `extras: a student, the youngest`. A
  speaker that is neither is an error. A cast entry takes tags, never effects.
- `facts (scope):` typed facts in a scope the host names; `(game)` marks a fact only the host writes,
  `(clock)` an int it only advances, and `(moment)` what happened (a lever pulled, a shot heard), held until rules
  and quests have seen it and never saved. Only they read a moment; `happened(m)` asks whether one happened at
  all, its value aside.
- `ref of kind` is a type for one of the host's things (a person, an item kind, a place), named in the story by
  its stable id (`wolf_pelt`) and checked against the host's manifest.
- **A fact kept per thing,** `opinion(person): int` or `mood(one of calm, angry): bool`, holds a value for each
  thing of a kind, or each value of an enumeration: read `opinion(marta) < 0`, written `[opinion(wife) -= 50]`,
  its key a thing's id, a ref fact or a value. It is stored sparsely, a value only for the keys set, each with its
  own stamp, so a rule reading `killed(hank)` wakes when hank's value moves and no other's. It is never a clock, a
  moment or text.
- `const:` fixed points every run shares (`dies_at = "ten past nine"`).
- `extern:` the host's vocabulary. `name(params) -> type` is a **query**, pure and callable anywhere; `name(params)`
  is an **action**, run when its line is reached; `name(params) -> type (action)` is an action with an **outcome**
  the host decides (a roll, a check, a fight). Parameters may be named (`kind: ref of item_kind, n: int`); a
  query declares the stamp of what it reads, keyed by its parameters, `(reads stock(kind))`, so whatever
  evaluates it can be woken when that changes.
- A list, of a type's values, an extern's parameters, a stamp's keys or `extras:`, is separated by commas.
- **Modules.** A file may begin `module name`; what it declares is `name.x` to other modules, and an unqualified
  name resolves in its own module first, then the root; in a section whose kind declares names within it, the
  section's own come before both. *Protects:* hundreds of files and many writers without clashes.
- **A story's version,** `version: 3`, which migration rules count from.

### Sections and parts

`== name`, with nested `= name`. A section may have a kind in parentheses after its name: `(pool)`, `(pool N)`,
`(rules)`, or a kind a package registers with the compiler, such as a quest package's `(quest)`. Its tags stand
in brackets on rows indented under its heading:

```
== the_stranger (quest)
  [title "Who was he?"] [scope player]
facts (player):
  asked: set of margaret, tom, danny

= noticed      when { met }
  [stage] [active spawn_stranger]
  A man nobody knows stood at the foot of the coffin. ^q1a9
```

Under its heading a section may declare facts of its own, `facts:` or `facts (scope):`, named within it: `asked`
inside, `the_stranger.asked` to the rest of the story. Among them `(role)` marks one of the things the section is
about, given to it when it starts (a quest's stranger), which the story reads and never sets. A registered kind
may keep its sections per thing (`Kind.per`: a quest that runs many times, one instance a thing): every fact such a
section declares within it is kept per that kind of thing, and read and written inside it for the one it is
evaluated for, so `asked` there is this instance's, and `bounty.asked(lead)` names another's.

A part's body is indented under its heading. A part may be written on one row, `= ruth  when { kept has ruth }  She
sat up with whoever was ill.`, and then what is indented under that row belongs to its statement.

### Lines

`SPEAKER: text`, or narration with no speaker. A speaker is capitals, digits, `_` and spaces before `:`, and may
carry a **delivery** in parentheses, the screenwriter's parenthetical: `DAD (quietly): I'd do it again.` The
line's text is exactly what follows `:`, never assembled from pieces at run time; it holds:

- `{fact}`, a value;
- `{ condition: these words | those words }`, words chosen by a condition;
- `{seq: a | b | c}`, `{cycle: …}`, `{once: …}` and `{shuffle: …}`, alternatives, each keeping its own state in the
  `story` scope (a shuffle needs more than a count);
- `{pelts as one: a pelt | other: {pelts} pelts}`, words chosen by a number's plural category, and
  `{marta as feminine: she | other: they}` by a gender: a cast member's, from its `[gender …]` tag, or a thing's,
  which the host answers. The labels are CLDR's (`zero`, `one`, `two`, `few`, `many`, `other`) or the genders
  (`masculine`, `feminine`, `neuter`, `other`), each language's string table labels its own, and `other`, which
  every language falls back to, is required.

`\{`, `\}`, `\[`, `\]`, `\^` and `\#` write the mark itself, so a narration row that begins with a bracket is
written `\[`, words that end in `^word` are written `\^word`, and a `#` alone among words is written `\#`.

**A line's id** is `^` and the id at the end of its row, after one space or more: `MUM: You could still play,
Frank. ^k7f3a2`. Letters, digits, `_` and `-`. It is riverrun's reserved `id` tag, which `riverrun tag` writes and
nobody types; a choice takes one the same way. An id anywhere else is an error.

**The delivery** fills one tag of the line: of the key the host's `Options.delivery` names, typed by the host's
schema like any key. A closed list (`(laughing)`, `(whisper)`) is checked, so a typo fails the build, and the game
animates or voices it; a key typed as text puts the words (`(laughing manically)`) in the string table beside the
line, for actors, captioners and translators. The words in the parentheses are the tag's one value, commas and all.
A delivery where the host names no key is an error.

### Brackets: what the game is told

`[ … ]` holds one thing for the game: a **tag** or an **effect**. Brackets stand on rows of their own, several to a
row, and a row of brackets holds brackets and nothing else (a comment aside):

- **a tag,** `[key]` or `[key value, value]`: a key and its values, separated by commas. A quoted value is words,
  and holds `,`, `]` and `//` as words: `[line "the scholarship · the city"]`.
- **an effect:** `[fact = value]`, `[set += item]`, `[set -= item]`, `[int += n]` and `[int -= n]` (a number or an
  int constant, never an expression: approval, bonds, reputation), `[action(args)]` and `[fact = action(args)]`. In
  brackets `=`, `+=` and `-=` tell; in braces `=` asks. `=` means "equals" in both, and the delimiter says whether
  it is asked or told.

What a bracket is, the reader decides by its form: a name followed by `(`, or by `=`, `+=` or `-=`, is an effect;
any other name is a tag's key. So `[cutscene x]` is a tag and `[cutscene(x)]` an action. The host's vocabulary
declares each name one or the other, never both: an extern action whose name is a key of the host's schema, or of
a registered kind's, is an error at the extern; a tag whose key is an action's name, and an effect that calls a
key's name, are errors naming the form that was meant.

**Whose a bracket is.** The rows of brackets indented directly under a row, before anything else under it, belong
to that row:

- under a **section's heading,** its tags. An effect there is an error: a section's effects are steps, written at
  its level.
- under a **part's heading,** its tags, and its effects are the part's first step (a rule's body is its effects).
- under a **line,** its tags, and its effects, which happen when the host delivers the line: a host that does not
  deliver it does not apply them, so a memory overheard in hide and seek is carried only if the line is heard.
  Nothing but brackets stands under a line. A statement written on the row of a condition or a gather
  (`{ met } Go.`, `- In the morning.`) is the row's, and the brackets under the row are its.
- under a **choice,** its tags, and its effects, which are its first step once it is chosen.
- under a **cast entry,** its tags; an effect there is an error.

Anywhere else, at a section's level, inside a condition's block, under a choice after a line, a row of brackets
is an **effects step,** its effects in order, and a tag there is an error: indent it under the line, the choice or
the heading it describes. Nothing is indented under a row of brackets.

```
== courier_day12
  [at day 12 evening] [courier]
[cutscene(courier_at_the_gate)]
A COURIER: Letter for you. Signed L. There's a fee on it, mind.
* Pay the fee.
  [paid = pay_fee(5)]
  { paid }
    A COURIER: Pleasure doing business.
    [give(letter_from_l)]
    [letter = carried]
```

`id` is riverrun's: a line's id, written `^id`, never `[id …]`; so are `gender` on a cast entry, `weight` on a
pool's candidate and `migrate` on a rule. Every other key is the host's or a package's, typed by its schema; a key
the schema marks `leads` carries the flow on into the host's mechanic; a value it types as text (a quest's
`[title "…"]`) is words a player reads, which go into the string table under an id made of where the tag stands,
so a translation carries them and a typo fixed keeps them; and a value it leaves to a judge is held to the story by
the package that defines the key (`[every week]` names one of a calendar's units).

### Choices, gathers and conditions

- **Choices:** `*` is offered once, `+` stays; `{ condition }` before the text gates one. A gated choice is still
  returned, marked closed, so a host can show it locked. A gather `-` joins the branches; `- (label)` names it.
  Nesting is by indentation alone.
- **Conditions:** `{ condition } line` for one line; `{ condition }` above an indented block, with `{ else }` after
  it. Inline conditions are for words, blocks for whole lines.
- **Expressions:** `=`, `!=`, `<`, `<=`, `>`, `>=` on ints, `has` and `hasnt` on sets, `and`, `or`, `not`, queries,
  `seen(name)`, the visits of a section, part or label (an int; true when above zero), and in rules
  `since_changed(fact, clock)`. No arithmetic and nothing that loops: the host computes, through its queries.

### Flow

`-> name` jumps (a section, a part or a label), `-> name ->` calls it and comes back to the row after, `<-`
returns, `-> end` ends, and `{ condition: -> a | -> b }` goes one way or the other, each way a jump, a call or a
return.

### Pools and rules

- **Pools:** a `(pool)` section's candidates are parts with `when { condition }`. riverrun picks the most specific
  candidate that holds (the most comparisons joined by `and`), the least recently seen among equals, with a seed
  that lives in the facts. `(pool N)` gives up to N. A candidate may carry `[weight n]`, riverrun's own: a pool
  where any does draws among its most specific matching candidates by weight (1 for one with none), from the seed
  and the turn, recency set aside, so "the merchant mentions the rumour three times in ten" is the writer's and a
  replay draws the same.
- **Rules:** a `(rules)` section's parts are rules, each `= name when { condition }` with its effects in brackets
  under it and nothing else. A rule fires when its condition becomes true: false when last evaluated, true now; it
  does not fire again until its condition has been false and become true again. Each time a rules section is
  evaluated it fires at most one rule, the first in the order written whose condition just became true; the others
  that became true with it wait to become true again. Nothing goes to a rules section and nothing reaches it by
  flow: what its rules read reaches it. A puzzle with an order, honor that drifts back, a reaction to a crime, a
  threshold a faction acts on: rules over facts, and a state machine is an enumeration fact and the rules that move
  it. A rule tagged `[migrate n]` is a migration: it runs once, when a save from a version before `n` is first
  restored under a story of version `n` or later, for a change of meaning healing cannot derive (two facts merged,
  a scale rescaled); it needs no condition, and is never watched.
  `since_changed(fact, clock)` reads how far a `(clock)` fact has moved since `fact` last changed, and
  `happened(moment)` whether a moment happened, in rules and in what a package watches; a condition reading a fact
  kept per thing by a key written as a constant is filed under that key alone; a query a watched condition asks
  (a rule's, a quest's stage's) must declare its stamp, so the condition wakes when its answer may change, while
  one asked in words or effects is asked when they are said.

### One way to write each thing

The reader reads this syntax and no other. Where it costs nothing, a mark of riverrun's earlier syntax is an error
that names the form that replaced it: `~ x` (write `[x]`), `# key` after a line's words (write `[key]` under the
line, or `\#` for the mark), `->> x` (write `-> x ->`), `{n -> one: …}` (write `{n as one: …}`), `·` between tags
or names (a bracket each, or commas), `[id x]` (write `^x` at the line's end).

Built: the reader and the checker, all of the above.

## Conversations

A conversation with several speakers needs no construct of its own:

- **Interjections** are calls into a pool: `-> barks ->` after a line, whose candidates are conditioned on who is
  present (a `(game)` fact). A pool where nothing holds says nothing.
- **Interruptions** are the host's: it calls a section into a running flow, which says it and returns to the line
  after the one being delivered, or ends with `-> end`.
- **Flows:** several cursors over the same facts, for conversations held at once.
- **Checks with outcomes:** `[persuaded = persuade(margaret, 12)]` stops the flow at an action; the host decides the
  outcome, sets the fact, and the story branches on it. riverrun never rolls.

## Facts

- **Bounded ints,** `honor: int from -100 to 100`: a change stops at the nearer end, a set past the bounds is
  refused (by the checker where the value is a number or a constant, by the store at run time), and a save restored
  under tighter bounds holds its value at the nearer end and reports it. Honor, karma, approval, reputation.
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
- **A change notifies only what reads it:** a subscriber names facts and learns which changed. A store marks each
  change, a fact kept per thing with its key, in a log of its latest marks, so what reads many facts follows the
  marks rather than asking each one, and asks every stamp only once it has fallen behind the log. A quest system
  stands on this.
- **A snapshot** of a scope is versioned bytes with the story's hash. Restored under another version, facts are
  matched by name and the dropped and new ones are reported; a readable JSON form goes through strand.

## The compiler

It runs at build time. A game's build calls `riverrun.addStory(b, dep, .{ .files, .vocabulary, .packages,
.release })`, `dep` being riverrun asked by `riverrun.building(b)` (below), and imports the module it returns,
which embeds the graph and the string table. The vocabulary is a Zig file of the host's: `pub const options` (its
tag schema, its widths and things), `pub const packages`, each package's `riverrun.Package` (its kinds, the tags it
adds anywhere, its check and its compile pass), and `pub const passes` for the host's own. `riverrun.join` joins
each package in after the host's, and two kinds of one name or one key twice where both may stand fail to compile,
so nothing a package adds shadows another silently. It is Zig, not data, because a registered kind carries
functions; the compiler is built for the machine doing the building, with the vocabulary compiled in, and prints
every diagnostic as `file:line:col: severity: message`.

1. **Read** each file: a hand-written recursive-descent parser into a tree that keeps every byte (each row's
   indentation, words, id, comment, spaces and line ending, so the tree prints the file back byte for byte), every
   node and diagnostic carrying the range of bytes it is about; the compiler, the checker and the tools read that
   one tree. A fuzz target for each parser, and properties that the tree prints back and its ranges nest.
2. **Resolve** against one index of every file's declarations: speakers, facts, constants, externs, sections, labels
   and modules.
3. **Check**, reporting every error, not the first:
   - types;
   - every section reachable from where the host starts the story (its `entries`) and from every section of a
     registered kind, which its package runs and no vocabulary lists, a section a tag names counting as an edge;
   - no path that runs off a scene without `-> end`, a return, a jump or a tag that leads on;
   - no choice whose condition can never hold, where that is decidable;
   - `(game)` facts never set by the story, and a story fact nothing sets;
   - tags against the host's schema, so a typo fails with a file and a line;
   - text width against the host's limit, measured by xenoglyph;
   - line ids unique; a release build refuses a line without one.
4. **Emit** the compiled format, and a JSON dump through strand for tools.

The compiler enters every declaration in an index first (facts, types, externs, the cast, visit counts, sections),
then compiles each file's sections against it alone, then runs each package's pass, then links: the builder writes
the graph, reads it back and validates it, and writes the string table for its hash. A file's steps depend only on
the index and its own tree, so a cache keyed by both can keep a file's steps between builds; that cache is not built
yet, and every build compiles every file. Facts declared without a scope are kept in riverrun's scope `default`.
**Line ids:** `riverrun tag` writes an id, `^id`, at the end of every line that has none; a development build
derives missing ones (`~` and a hash of the section, the part, the position, the speaker and the words).
*Protects:* translations, recorded voices and model characters keyed on a line and surviving a typo fix.

Built: all of it, `addStory` included.

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

### What packages add

A package is one `riverrun.Package` in a vocabulary's `packages`, and one mechanism: functions of its own that
riverrun calls at fixed points of its work, with its own state, each reporting through riverrun's diagnostics. It
registers kinds of section (`(quest)`), each with a tag schema its sections are held to before the host's, and
builtins their conditions may call (`since(stage, fact) -> int`), whose arguments name things of the story, never
values. The compiled story carries each builtin call for the package to answer, and a
named, versioned **block** the package owns beside the graph. A query's stamp and a `(clock)` fact are carried too,
so a package can wake a condition only when what it reads moves.

A kind's sections may bring facts into the story (`Kind.declare`): read from the section's own text, and the
story's where a section draws on others (a quest on the shared rules it inherits), before any name is resolved, each is a `facts (scope):` entry as the reader would have made it (`check.Declared`), entered in
the index after the story's own declarations, so it is typed, scoped, read by conditions, compiled and saved in
snapshots like any other, and a name declared twice is reported with both places. A calendar keeps `weekday` and
`slot`, which the story then reads and never declares; a quest's stages are declared within it, `the_stranger.named`
to the rest of the story and `named` inside the quest, so two quests' stages never meet, and a stage that would hide
a name the story declares is refused.

A key's value may be judged rather than typed (`Schema.Value.judge`), the key a kind's or one a package adds
anywhere: the package is handed each such tag where it stands (its section and part, its place and the tags beside
it) with the checker, and reports what is wrong where the value is written (`Tag.at`, each value's place), as
`.values_of` and `.section` are riverrun's own judgements. An instant of a calendar, a schedule's unit, a reference to a quest's stage: what a word or a fixed
list cannot say. A tag whose count is wrong is reported for that and never judged.

A package reports through riverrun's diagnostics, never beside them. Its checks are a pass of the checker's
(`check.Options.passes`), run inside `check.run` once riverrun's are done, over the checked story: what no schema can
type (a calendar that does not hold together, a quest that can get stuck) is reported with `Checker.err` where it is
written, and printed `file:line:col` as riverrun's own. Its compile pass reports the same way (`Compiler.err`), and
the story is refused; a pass that fails without saying why is reported by its name. *Protects:* no check a tool must
remember to run, and no build that fails without a place.

**A package's build.** A package with a compiler side offers it in its `build.zig` as `pub fn compiler(dep:
*std.Build.Dependency) ?*std.Build.Module`: the module of that instance of the package, made on the first ask and
kept in the instance, on the riverrun its own build depends on; null until lazy dependencies are fetched, as
`riverrun.compiler(dep)` is. Its build asks riverrun, and every other dependency, with `.{ .target, .optimize }`
and nothing more. A story's build asks riverrun and each such package by `riverrun.building(b)`, the machine doing
the building at ReleaseSafe, and hands each compiler side to `addStory` by the name its vocabulary imports:

```zig
const river = b.dependency("riverrun", riverrun.building(b));
const tide_side = tide.compiler(b.dependency("tide", riverrun.building(b))) orelse return;
const story = riverrun.addStory(b, river, .{ .files = &.{b.path("episodes/ep1/story.river")},
    .vocabulary = b.path("src/vocabulary.zig"), .packages = &.{.{ .name = "tide-compiler", .module = tide_side }} });
exe.root_module.addImport("story", story.module);
exe.root_module.addImport("tide", b.dependency("tide", .{ .target = target, .optimize = optimize }).module("tide"));
```

Zig keeps one instance of a package for one set of arguments, so asked alike they are one: the compiler, the
vocabulary and every package's compiler side hold one riverrun, and the game, its runtime side and each package's
runtime hold another, for the game's target. Two in one compilation would be two kinds of every type, so `addStory`
refuses, by its name, a package whose compiler side stands on another riverrun. A package that builds on packages
(a game's package on tide and cairn) asks them by the same arguments from its own `compiler`, and gets the same instances.
*Protects:* one riverrun in each program by construction, and packages any engine's build can register.

## The runtime

A small data-oriented Zig **executor** walks the graph. There is no virtual machine.

```
Story.init(bytes) · Strings.init(bytes) · Host.bind(story, impls)
Session.init(gpa, story, strings, store, host, options)
start(flow, section) · next(flow) → line | choices | effects | action | end · held(flow) → line
choose(flow, i) · outcome(flow, value) · interrupt(flow, section) · stop(flow)
saveCursors() → bytes · restoreCursors(bytes) → report      (facts: snapshot and restore per scope)
```

- **`next` walks until it has something for the host**: branches, gathers, jumps, calls and pools are walked
  through. A line comes with its own effects, and says where it is written: its section, and its part where it is in
  one, however the flow came to it, so a host that chooses a mechanic by a section's tags needs no index of its own;
  choices come open or closed, a once-only choice gone after it is taken, and when none is open the flow goes past
  them; an effects step on its own comes as `effects`.
- **The host is bound by name at load.** The story's externs carry names and signatures; a Zig host binds a struct
  of functions, reflected by field name into a table indexed by extern id, and a host in another language binds a
  function pointer and its data per name through `Binder`. Every extern must be bound with its signature, or the
  bind fails naming what is unbound or mismatched; at run time a call is an array index.
- **Calls carry their context:** the flow that asked, whose facts each scope holds (`setOwner`: a player, a
  region), so a query on a server knows whose inventory it counts, and the thing a section kept per thing is
  evaluated for (a quest's instance). An evaluation may be given its section's roles, which its terms then read. An emitted action carries the same context.
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
- **A flow is saved at any step the host is shown,** a line in its hand among them. The line `next` last handed over
  is held by its flow until the next step, a start, a stop or an interruption, and saved with the cursors with what
  its slots held. Restored, the flow holds it again: `held` hands it over again, worded as it was, its effects worked
  out from the facts restored, and `next` goes on after it as it would have. So a host saves where its player is, a
  line half typed or a count's next line waiting, and going back resumes there rather than at the line before. Why
  `held` and not `next` handing it again: `next` keeps one meaning, the step after the one in hand, so a host that
  saved after acting on its line never sees it twice, and one that holds a line asks for it. Why the slots and not
  the words or the facts: saying a line moves its alternatives on, and the host's writes since (the line's own
  effects among them) would word it otherwise, while the slots reword it in any translation. Only an outcome owed
  refuses a save.
- **A language's rules are the host's:** the plural category of a number in the string table's locale, and a
  thing's gender, given as `Language` in a session's options; without them plurals are English's and every thing's
  gender is `other`. riverrun ships no CLDR tables: a host brings its locales' plural rules.
- **Deterministic:** no clock, no I/O, no randomness outside the seed in `story`. Each flow keeps one arena, reset at
  every step, so a step allocates nothing once the arena has grown; what a step hands over is valid until that
  flow's next step.
- **Every bound is a named error:** call depth 64 (calls, interruptions and pools together), choices at a point 32,
  candidates given at once 8, outcomes owed by one step 8, facts 65,535, flows 16, and a step walking 100,000 nodes
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

## Reacting to facts

What happens when facts change, rather than when a flow is told, is the `react` layer's.

- **`Watch` evaluates a condition only when what it reads may have changed.** A condition is filed under every
  fact it reads, under the stamp of every query it asks (by the query's keyed arguments where they are constants in
  the condition, else by the stamp's family), and, where it compares a `(clock)` fact, a `since_changed` or a
  builtin whose answer moves with a clock (`Builtin.moves`, cairn's `since` over a day) with a number, under the
  clock's value where that comparison can next flip, in a heap per clock. A condition may be watched for a thing
  (`this`, a quest's instance) and given roles, constants to it, so `alive(giver)` is filed under its giver's key
  alone; one removed is taken out of all it was filed under, and its id is the next one's. A step takes what
  changed (the store's stamps, the stamps the host bumped, the clocks' moves) and evaluates what was filed there,
  in the order the conditions were added, each once: a clock ticking wakes only the comparisons whose moment came,
  and one moving back, a restored moment, wakes every comparison with it.
- **A moment is over once every condition marked has seen it:** at the end of a step that leaves nothing marked, each
  moment goes back to its initial value, so what read it falls at the next step and can rise again at the next
  moment. With a budget, moments wait for the rest.
- **A step reports what it evaluated and what each holds now;** a client keeps what each held before, as rules keep
  it in the facts, so the report survives a save. Nothing allocates in a step once the conditions are added; a
  budget evaluates that many and leaves the rest first in line, so it changes when, never what.
- **`Rules` fires a story's rules sections over a `Watch`.** What each rule last held is kept in the reserved scope
  (`rule.<section>.<rule>`), so a restored save fires nothing twice; a rule true when the story first starts fires
  at the first step. A step is one round and returns the rules that fired with their effects, emitted; the host
  applies them and steps again, and `settle` does the rounds for a host that applies at once, bounded by a named
  error, `NoFixedPoint`, after 64.
- **A package's own conditions** (cairn's quests) are added to a `Watch` for the thing each is evaluated for, with
  its roles and the facts its builtins read, and given the package's meaning on top: one evaluator for every
  reaction.

```
Watch.init(gpa, story, store, host, owners, options) · add(terms, user, for) → cond · remove(cond)
bump(family, keyed) · step() → evaluated · holds(cond) · markAll()
Rules.init(gpa, story, store, host, owners, options) · step() → fired · settle(user, apply) → rounds
start() · migrate() → fired
```

- **Migrations:** the version a save was taken under is a fact of the reserved scope. `start` marks a new game of
  the story's version; `migrate`, after a restore, fires each migration to a version past the save's and no later
  than the story's, in order, whose condition holds, then marks the save of the story's version, so each runs once.

Built.

## The code, by layer

Each layer is a folder beside its root file, and imports only those before it:

```
syntax    files → a syntax tree that keeps every byte, with ranges, and back       built
facts     types, scopes, the store interface, the default store, snapshots      needs nothing · built
check     resolve and check the tree against a host's schema → a checked story  syntax · built
story     the compiled format: builder, writer, validated reader               facts · built
compile   a checked story → the format, file by file, then linked              check, story · built
run       the executor over the format and a store                             story, facts · built
react     conditions watched as facts change, and rules fired over them        run, story, facts · built
ffi       the C ABI over run                                                   run
tools     the program, on ensign                                               all
```

The layers are two modules. `riverrun`, the runtime, is `facts`, `story`, `run` and `react` on std and aegis alone;
`riverrun-compiler` is `syntax`, `check`, `compile` and the JSON forms, standing on the runtime and adding
xenoglyph (for widths) and strand (for JSON), both lazy dependencies. A game that only tells stories imports
`riverrun` and never fetches the compiler's dependencies; its build runs the compiler through `addStory`, and a tool
asks for it with `riverrun.compiler(dep)`. *Protects:* a small runtime, and compile-time work that stays at build time.

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
