# Changelog

All notable changes are documented here, following Keep a Changelog 1.1.0.

## [Unreleased]

### Added

- The checker warns of narration that reads like a line: its first words a speaker's id, name or an extra's words,
  then a colon (`Ada: …`, `ADA:No space.`, `ADA : …`), naming the form a line takes; narration with a colon after
  other words is not warned of.
- The checker warns of a line that can say nothing (a `{once: …}` used up, words chosen with none) and carries
  effects: such a line is not delivered, and its effects are applied only when it says something.
- `Play.Event.outcome`: the outcome the game gave, written into its fact, told as `[fact = value]`.
- `ast.File.rowAt`, `Checker.row`: a statement's own row, where what is about it is placed.
- The manual, `docs/manual/`: its index and frame, and chapters 1 to 6 for a writer (a page of words, choices,
  facts and conditions, telling the game, scenes and flow, text that varies and its ids), each over a running story
  in `docs/manual/stories/`, its mistakes in `docs/manual/mistakes/`, and a play of it. Every story it shows is
  checked and prints nothing, every run it shows is pinned in the test step (`bay dev manual-test` alone), and
  `bay manual` builds the program its stories are written for.
- The manual's chapters 7 to 9 and 12 to 14: the game's vocabulary (for the writer, and for the programmer who
  wires the game: the vocabulary file, `extern:`, facts the game writes, facts kept per thing, `const:`, modules,
  counting, the build), pools, rules, what the checker proves (each kind of message, widths and limits, exit
  statuses, the loop an AI runs), worked scenes, and the reference card with the grammar; each over stories that
  check, with their mistakes and pinned plays. The manual's game knows its things, a night of rooms, and a width.
- The manual holds every block it shows: a ` ```zig ` block is rows of a Zig file the test step builds (the
  vocabulary, or a game's build compiled against riverrun's own, `docs/manual/stories/07/game/build.zig`, whose
  rows the README shows too), a ` ```text ` block rows of the design's grammar or of a pinned run's output, and a
  block of any other language fails the test. The grammar is in `docs/design.md`, the design of record, and the
  reference card's is held to it. The index links chapters 10 and 11, cairn's quests and tide's time.
- `addExcerptsTest` takes `sources` (Zig files a ` ```zig ` block shows rows of, as written or all less indented),
  `texts` (files a ` ```text ` block shows rows of, beside the runs' outputs) and `every` (every fenced block must
  be one it holds); `excerpts.withinIndented`, `Shown.sources`, `texts`, `every`. A document shows at least one
  block it holds, of any kind.
- `addShownRuns`: runs of the program a package's documents show (`ShownRun`: a folder, the arguments, the file
  holding what it prints, the exit status), each run with nothing on standard input and held to its file byte for
  byte and to its status. `addExcerptsTest` takes them (`runs`) and holds every ` ```console ` block, `$ riverrun …`
  and what it printed, to one of them whole, and every ` ```river refused ` block to a story a shown `riverrun check`
  refuses, and fails on a run no document shows; and stories shown before and after `riverrun tag` (`tagged`) to
  what `tag` writes. `excerpts.unshown` takes `Shown` (stories and runs); `excerpts.retagged`.
- `riverrun play` takes the calls a game makes into its packages as inputs: each package offers them as commands
  (`riverrun.Running.commands`: a name, what it applies to in the story, typed parameters, words for `:help`), which
  `:help` lists, a script's row is read against and refused in words, `:back` and a script give again, and
  `--call` gives before the story starts. `Play.commands`, `Input.command`.
- Every run-time error is placed where what met it is written: the effect being worked out or applied (the Nth of a
  run, under a line, in a rule, in a package's), the condition or value being evaluated (a rule's, a stage's), the
  choice, or the step. `story.At`; `compile.Where.effects`, `Where.terms`, `Where.of`; `run.Session.metAt` and
  `toldEffects`; `react.Rules.metAt` and `Fired.written`; `Watch.met`; `eval.Context.met`; `Running.Told.stopAt`,
  `News.written`.
- A query a package asks while it works out what happened is told under that news (`Event.news.asked`).
- A story that goes round without waiting is stopped where it goes round, with the sections it keeps coming back
  to; the bound is the story's own steps and 10,000 more, so a story that only goes on is never stopped.
- `riverrun play`: a story played as its game would play it, the writer in the game's place, in a terminal or from
  a script of inputs (`--script`, `--input`, standard input) that writes a plain, stable transcript and exits 0 at
  the story's end, 3 waiting for an input the script did not give, 4 on a run-time error, 1 when a row cannot be
  taken. It starts at the game's entry or `--from SECTION`, with `--set` and `--wait` for what the game has set;
  runs the story's rules and its packages' runtimes; answers each query with what the player set, else its type's
  first value, told where it is asked; waits for a choice or an action's outcome; applies a line's effects when the
  line is delivered; follows a section's tag that leads on; and places a run-time error at the step it is about. In
  play: `:facts`, `:set` (a fact, a fact kept per thing, a query's answer), `:wait`, `:back`, `:restart`, `:quit`,
  `:help`.
- `riverrun-tools`: `Play`, the one session the terminal, scripts and the editor drive (`next` gives what the game
  is given, `give` takes what it gives back, `back`, `restart`, `startWith`); `transcript`, the written form;
  `script`, rows read against a play. `walk.Loaded` answers queries through `answers`, starts a new game
  (`fresh`) and names things; `walk` gives each line's owed outcomes and reports each step (`Options.seen`).
- `riverrun.Running`, in `Package.running`: a package's runtime as a story is played without the game (`start`,
  `step`, `advance`, `bump`, `builtins`), saying what it did as news; `join` collects them into `Joined.running`.
- `compile.Compiled.where`: where each step and choice of the graph is written, for tools.
- `run.Session.offerAgain` (choices offered again as the facts now hold), `cursor` (where a flow goes on from: the
  step a named error is about) and `told` (the step last handed over); `facts.Effect.dupe` and `facts.dupeValue`.

- `riverrun`, the program a writer runs, its arguments read by ensign: `riverrun check` checks a story exactly as
  the game's build does (read, checked with the vocabulary's packages, compiled in memory, nothing written),
  `riverrun tag` writes ` ^id` at the end of every line and choice that has none and changes nothing else
  (`--check` reports them instead), and `riverrun compile` is what `addStory` runs. A game's build makes it with its
  vocabulary and packages in it, `addProgram`, which `addStory` uses and returns (`Story.program`), with
  `Story.check`, a step that checks the story's files; `addCheck` checks any files with a program. Every command
  prints a diagnostic as `path:line:col-line:col: severity: message` (the end just past the range), a file it
  cannot read as `path: error: …`, and what is about no file as `riverrun: error: …`; it exits 0 with no error, 1
  with one, 2 on a mistaken command line.
- Ids `riverrun tag` writes: a letter then five letters or digits from Crockford's base 32, lowercase, made from a
  hash of the line's section, part, place and words, hashed again until unused in the story's files: the same files
  always get the same ids, and a written id never changes.
- `riverrun-tools` (`tools(dep)`), the model every tool shows: `Manuscript` (a story's files, their trees and every
  diagnostic, read, checked and compiled as the build does), `report`, `tag`, `walk` (a compiled story loaded and
  told a bounded number of steps), `trial` (a story put through all of it, as the whole compiler's property does,
  with a package's own runtime run over it) and `excerpts`. `addExcerptsTest` holds every story a package's
  documents show to rows of the stories its tests check.
- The whole compiler's property: any text, one file or two, a story written to check or the proof with a file
  changed, through the reader, the checker with a package registered and the compiler, is a story told with every
  choice taken, or diagnostics placed in the files; fuzzed by the `fuzz` step.
- The documentation's stories are checked by `riverrun check` in the tests (`docs/examples/`).
- Integer `+` and `-` (docs/design.md, "Counting"): between int facts, constants, numbers, query answers, visit
  counts and int builtins, wherever an int stands: a comparison's sides, an effect's value and amount
  (`[trust += favour]`), a value a line says (`{owed - paid}`) or chooses its words by. They bind tighter than the
  comparisons and run left to right; parentheses group. `*`, `/` and `%` are refused naming the game as what
  computes formulas, a `-` before a name is refused, and so is a sum before an effect's `=`, `+=` or `-=`.
  `ast.Expr.Op.add` and `.sub`.
- A sum past what an i64 holds is `error.Overflow` at run time, evaluated with aegis's checked ints, never a wrap;
  the checker refuses one that always overflows.
- The checker works out each int expression's least and most (`check/interval.zig`): a bounded fact's bounds,
  a constant's and a number's value, anything an int holds otherwise, and a sum's from its sides. A comparison
  whose sides cannot meet folds to never or always, so `{ a + b > 300 }` over two ints bounded at 100 is reported as
  never offered; a set whose every possible value lies past the fact's bounds is refused.
- A watched comparison that reads one clock once, added or subtracted among anything else (`hour >= arrived + 3`),
  waits in the clock's heap where it next flips, worked out anew each time it is evaluated, so it moves when
  `arrived` changes; it wakes only at the instant its operator flips at. One that reads two clocks wakes when
  either moves.
- A speaker's delivery, the screenwriter's parenthetical: `DAD (quietly): I'd do it again.` It fills one tag of the
  line, of the key `check.Options.delivery` names, typed by the host's schema like any key: a closed list is
  checked, and a key typed as text puts the words in the string table beside the line. The line's text is still
  exactly what follows `:`. `ast.Line.delivery`; `check.Checked.tagsOf` gives a line's tags with it among them.
- The checker holds a name to one form: a tag whose key is an action (`[cutscene x]` for `[cutscene(x)]`), an
  effect that calls a key of the schema, and an extern action that is also a key of the host's or a registered
  kind's schema are refused, each naming the form meant.
- A control character in a row (a lone carriage return, NUL, any C0 or C1 control but a tab, DEL) is reported over
  its bytes; the row is kept as written, so the file still prints back.
- Every construct carries its range: each bracket (`Tag.span`, an effects step's `Stmt.span`), each brace and
  parenthetical (`Cond.cond_span`, `Cond.else_span`, `Choice.cond_span`, `Subsection.when_span`, `FlowIf.span`,
  `Section.kind_span`, `Facts.scope_span`, `Gather.label_span`, `Fact.marks`, `Extern.action_span`,
  `Extern.reads_span`, `Delivery.span`), a type where it is written (`Fact.type_span`, `Fact.key_span`,
  `Param.type_span`, `Extern.returns_span`), `Bounds.span`, an effect's (`Effect.span()`), `Flow.span` and
  `Call.span`. The spans property covers them: a field `x_span` is a node beside the others, and what `x` holds
  lies inside it.
- The reader keeps every byte. A file's tree holds its rows (`ast.File.rows`, `ast.Row`): each row's indentation,
  words, id, comment, the spaces before each and at its end, and its line ending (LF, CRLF, or none on a last row
  with no newline), and a UTF-8 byte-order mark the file begins with (`ast.File.bom`). `syntax.print` writes the
  tree as text: a file the reader takes prints back byte for byte, whatever is wrong in it.
- Every node of the tree carries the range it is written in: the file, the declarations and their entries
  (`Decl`, `CastEntry`, `Facts`, `Fact`, `Const`, `Extern`, `Param`, `Stamp`), sections and parts, tags, statements
  (from the first word to the end of the last thing under it), the pieces of text and a selection's branches, and
  expressions (an operator's from its left side to its right).
- Properties of the reader, run by the test step and fuzzed with the rest: any bytes print back from their tree, or
  are refused whole (not UTF-8, or past the size limit) and said to be; every node lies inside its parent and apart
  from its siblings, the root is the whole file and every diagnostic lies inside it; every name is exactly the range
  its word is written in. The proof story prints back byte for byte.

### Changed

- A `one of` fact always holds one of its values: it starts, and a reset puts it back, at its first listed value;
  `facts.Value.none` is gone, a snapshot and the JSON form always name the value, and a value a save names that the
  story no longer lists is lost to the first value and reported. A `one of` moment lists first the value meaning
  nothing happened. design.md "Where a value starts" says it once for every type.
- The cast note is the rest of the row after the quoted name: `ada "Ada" keeps the ferry`. A note after a dash
  (`—`, `–`, `-`) is refused, naming the row without it. Every story here and in the manual is rewritten so.
- The checker's reach is the runtime's: a choice point is passed where every choice there can be used up (a `*`
  whose body leads back to it) or closed, so "nothing reaches this" is said only where that cannot happen. A way past
  choices all used up by the scene's own flows can run off its end. A run-off is reported at the last row of each
  way that runs off, naming the scene or the part (was: on the scene's or part's name, once).
- A line whose words come out empty is not handed to the game, and its effects go with it (`run.Session.next`).
- The transcript tells a heading only where the place changes: `--from section.part` tells `== section` then
  `= part` once; a part of the section the flow is in tells `= part` alone (`Event.section.whole`). A query the
  flow asks is told under the heading of where it was asked (`Asked.where`, `Play.Place`).
- A thing the game names that the story does not is stood in for in `:set`, `--set`, a query's arguments and
  answers and an outcome, as in a package's command: `Input.set` and `Input.outcome` take `Arg`s, resolved when the
  input is taken.
- An extern's `one of` or `set of` parameter with a type among its values (`f(one of a, b, int)`) is refused,
  naming the form: two or more parameters are each named.
- Messages: `--set` on a clock and `:wait` on a fact name both forms (`:wait N` in a play, `--wait N` before it
  starts); `--from` with a pool's candidate says it is the pool's to pick; "more choices at once" is placed on the
  first choice's row; a fact an effect the reader refused would have written is not also warned of as one nothing
  sets (`ast.File.unread_writes`).
- The program writes standard output and standard error as streams through ensign's `stdout` and `stderr`, so
  output appended to a file (`>> log`) is appended and the two sharing a file follow each other. Pins ensign
  1e6ff3c (on ensign main 9689f8e) and shakedown 5dad84d, and with them the family move's aegis f52eabe and
  xenoglyph ab4d381.
- `Running.StandIn.name`: the name the play knows a thing by, so a package's news can say whom a role holds.
- `walk` fires the story's rules as a game does, so play and walk are held equal on stories with rules.
- `Play.Stop.at` (a `story.At`) replaces `Stop.step`; `Play.Options.steps` is null for the story's own bound.
- The checker's messages say "the game" where they said "the host": `` `x` is not a tag the game knows ``, `the game
  has no item_kind called …`, `past the game's 40`, `the game starts the story at …`, and the rest, as the program's
  help and the manual name it.
- A release's missing id is placed on the line's or the choice's own row, as `riverrun tag --check` places it, not
  over the rows under it, and says what needs one: ``a release needs an id on every line and choice, `^…` at the
  end of its row``.
- A line whose words or effects meet a named error leaves its flow at the line, so the error is placed there.
- `walk` gives the outcomes a line's effects owe (each its type's first value), where it stopped the section.
- `addStory` compiles with the `riverrun` program (`tools/riverrun.zig`, `riverrun compile`), which replaces
  `tools/compile.zig` and its hand-read arguments; its diagnostics take the program's form, with the range's end.
- A key stands once where it is, all its values in its one bracket: a second `[forks …]` on a section, or a
  `[delivery …]` beside `DAD (quietly):`, is refused naming the first. The proof's `wake` writes
  `[rooms front, kitchen, stairs]` for `[rooms] [rooms front, kitchen, stairs]`.
- Every name a story declares is a name: a fact's, a cast entry's id, an extern's and each value of a `one of` or
  `set of` are letters, digits and `_`, and a `one of` lists one value or more; each was taken as written.
- shakedown is pinned at main (ed5a873), whose fuzzer takes the `--build-arg` preflight's fuzz step gives.
- A bounded int starts, and its scope's reset puts it back, at the value in its range nearest 0 (`Value.start`,
  `Decl.start`, `FactDecl.start`), where it started at 0 even when 0 lay outside the range; a key of a bounded fact
  kept per thing reads so until set, and a snapshot leaves out a key that holds it. A fact's value always lies in its
  range. Nothing new is stored: the starting value is worked out from the kind and bounds.
- A chain of `and`, of `or` or of `+` and `-` holds at most 32 links, refused over the chain past that, and braces
  in words nest at most 8 deep, refused at the brace that opens past it (as deep as the string table's templates):
  a row of any length can no longer make the checker or the compiler recurse with it.
- **Breaking:** the compiled format is major 3 (docs/format.md): the terms `add` (25) and `sub` (26), which a
  major 2 reader could not step over. A story compiled before is refused by name and compiled again; snapshots are
  unchanged. A `-=` amount compiles to `0 amount sub`.
- An int's `+=` and `-=` take any int, where they took a number or a constant.
- **Breaking:** the story language is design B (docs/design.md, "The language"), and the reader reads it alone.
  `{ … }` the story asks, `[ … ]` the game is told, `( … )` qualifies, `->` is flow and nothing else:
  - tags are brackets on rows under what they describe, one tag a bracket: `# at 9.5 · heard door` at a line's end
    is `[at 9.5] [heard door]` on a row indented under the line; a section's under its heading, a part's under its
    heading, a cast entry's under the entry;
  - an effect is a bracket: `~ carried += play` is `[carried += play]`. Under a line, a choice or a part's heading
    the brackets first under it are its tags and its effects; anywhere else a row of brackets is a step of
    effects, and a tag there is refused;
  - a line's id is `^k7f3a2` at the end of its row, the tag `id` (`[id k7f3a2]` is refused);
  - a call is `-> name ->` (`->>` is gone), in a flow chosen by a condition too;
  - words chosen by a plural or a gender are `{n as one: … | other: …}` (`{n -> …}` is gone);
  - `extras:` and every list are separated by commas (`·` is gone);
  - `\[`, `\]`, `\^` and `\#` write the marks in words, beside `\{` and `\}`.
  Each mark of the first syntax is refused with the form that replaced it. `ast.Row.tags` and `before_tags` are
  `id` and `before_id`; `ast.Flow` is `{ span, kind }`; `Schema.Place.other` and `Schema.Places.other` are gone,
  since nothing but a line, a choice, a heading and a cast entry has tags.
- `syntax.Span` is a range of bytes, `{ file, start, end }`, not a line and a column. A line and a column are worked
  out when one is printed: `ast.File.place(span)` gives a `syntax.Place`, `{ line, col }`, and `Checker.place` a
  file's path with it. Every diagnostic, the reader's, the checker's and a package's, carries a range.
  `Span.none`, no place in the text, is placed at line 0, column 0.
- `ast.Decl` is `{ span, kind }`, its declarations under `kind` (`version` is the number alone); `ast.Piece` is
  `{ span, kind }`, its kinds under `kind`; `ast.Fact`, `ast.Tag`, `ast.Section` and `ast.Subsection` and the
  other nodes above take a `span`, which a package's `Kind.declare` gives the facts it makes.
- A statement written on a row after a condition (`{ met } Go.`) or a gather (`- (ask) * Run.`) has the row's id
  and the brackets under the row, as a part's one-line candidate has; the condition or the gather has none.
  `ast.Cond.on_row` says a condition and its statement share a row. What reaches the host is unchanged.
- The reader takes a file that begins with a UTF-8 byte-order mark, where it refused its first line.

### Fixed

- Scenes due in one move are each told in turn: one that ended the story with `-> end` dropped the others
  (`Play.stacked`). A key marked `interrupts` (`Schema.Key.interrupts`, tide's `at` and `every`) makes a section one
  the game runs into a flow, so its `<-` draws no warning.
- What the game did before the story starts is told before the first heading: a quest started by `--call` was told
  after the first scene's heading.
- A thing a command, a set or an outcome names is held to the vocabulary's list of its kind (`Play.Options.things`);
  stood in for only where the vocabulary lists none of that kind.
- A narration row may begin with a value: `{name(to)} has the parcel.` (`Checked.value_first`); a sum or a visit count
  there is a condition, as before.
- `:facts` lists every key a fact kept per thing holds, a stand-in's by its name and a package's own (a repeat
  quest's instance) by its kind and number.

- The checker crashed (`reached unreachable code`) on a choice written on a gather's row (`- * Go.`, `- (ask) *
  Run.`): it checks. Choices written together at one depth are one choice point, a gather's row's choice the first
  of them (`- (ask) * Run.` then `* Hide.` offer both); a choice on a condition's row stays that row's. The whole compiler's generator writes such
  rows.
- A line or a choice wider than the game allows is reported on its own row, and a line id used twice on the id
  itself, where both were placed over the statement and every row under it.
- An extern written with two unnamed parameters, `pay(int, int)`, is refused as more than one parameter, each to
  be named, where the reader said the pair was not a type.
- What the compiled format cannot hold is refused where it is written: a name that, joined with the names it is
  written within, passes 256 bytes, more facts, values, scopes, choices or speakers than the format holds. The
  builder's error used to escape the compiler with no place (`NameTooLong` for a 300-letter fact or section name, or
  a long line id that names its alternatives' state). Found by the whole compiler's property.
- A fact, an extern or an enumeration with an empty name (`  : int`, `  (int)`, `one of ,`) was read and checked,
  and the compiler then failed with `EmptyName` and no place. Found by the whole compiler's property.
- Two text tags of one key on one owner were given one line id, and the compiler failed with `DuplicateLineId`
  (now refused by the checker, above). Found by the whole compiler's property, over the proof.
- Resetting a scope that holds a bounded int whose range leaves out 0 trapped (`catch unreachable` on the set of 0);
  it is put back at its starting value, which always fits.
- `join` takes a vocabulary of any size: comparing every pair of a schema's keys ran past the compiler's default
  branch quota at a few dozen keys, and the vocabulary did not compile.
- A flow chosen by a condition with `|` before its `:` (`{ a | b: -> x }`) is refused, where it trapped.
- A list type that goes on under its fact (`set of a, b,` then `c` on the next row) places each name where it is
  written, where the names after the first row were placed by their offset on the first.
