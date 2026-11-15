# The river manual

river is the language a game's story is written in: who says what, on what condition, what a choice changes, and
where the story goes next. This manual teaches it to a writer, in the order a writer needs it. It starts with a page
of words and a play of it, and every chapter ends with something you can run.

1. [A page of words](01-a-page-of-words.md): lines, narration, the cast, extras, comments, a section and its end.
2. [Choices](02-choices.md): `*` and `+`, choices under choices, gathers and labels, `->`.
3. [Remembering: facts and conditions](03-remembering.md): facts, scopes, conditions on rows and choices, words
   chosen by a condition, `--set`, `:set` and `:facts`.
4. [Telling the game](04-telling-the-game.md): tags, what a bracket belongs to, changing facts, the game's actions,
   a line's delivery.
5. [Scenes and flow](05-scenes-and-flow.md): sections and parts, going and coming back, where a section must end,
   `--from`.
6. [Text that varies, and travels](06-text-that-varies.md): alternatives, plurals and genders, why a line is said
   whole, ids and `riverrun tag`.
7. [The game's vocabulary](07-the-games-vocabulary.md): queries, actions and actions with outcomes, the game's
   things, and in a play what a query answers and an outcome given; then, for the programmer who wires the game,
   the vocabulary file, `extern:`, facts the game writes, facts kept per thing, `const:`, modules, counting, and the
   game's build.
8. [Pools](08-pools.md): candidates, the most specific, the least recently said, weights, `(pool N)`; barks, and a
   night of rooms the game plays.
9. [Rules](09-rules.md): firing on becoming true, one at a time, a state machine, `since_changed` and `happened`,
   migrations.
10. [Quests](https://github.com/pedronaugusto/cairn/blob/main/docs/manual/10-quests.md), in cairn's documentation,
    the package that runs them: stages and what moves a quest on, roles, quests the game starts and quests that
    repeat, what every quest shares, and a quest's news in a play.
11. [Time](https://github.com/pedronaugusto/tide/blob/main/docs/manual/11-time.md), in tide's documentation, the
    package that keeps a game's time: a clock, a calendar and the facts it keeps, scenes that come due, and time
    moved on in a play.
12. [What the checker proves](12-what-the-checker-proves.md): reading a diagnostic, what each kind of message
    means and what to do, widths and limits, how far the checker can tell, exit statuses, and the loop an AI runs.
13. [Worked scenes](13-worked-scenes.md): a conversation with interjections, a day of slots, a confession branching
    deep, a storm with an outcome and rules.
14. [Reference card](14-reference-card.md): every mark on one page, the program's commands and a transcript's
    rows, and the grammar.

The stories the chapters show are under [stories](stories/), each beside its chapter's number, with the inputs a
play is given and what it printed; the mistakes they show are under [mistakes](mistakes/). The language's design of
record is [docs/design.md](../design.md).

## How this manual is kept

For whoever writes its next chapter. The manual is Markdown that reads on GitHub, and nothing in it is typed from
memory: every story it shows checks, every run it shows is what the program printed, every block of it is held to
the file it shows, and the test step holds them so (`bay dev manual-test` runs those tests alone; `bay manual`
builds the program the stories are written for).

**Where it lives.** Chapters 1 to 9 and 12 to 14 are here, one file each, named by number and title
(`01-a-page-of-words.md`). Chapter 10 is cairn's `docs/manual/10-quests.md` and chapter 11 tide's
`docs/manual/11-time.md`, each written in this frame with its package's own stories, vocabulary and test step, and
linked from this index by its URL. Every chapter is listed in `manual.documents` in its repository's `build.zig`.

**The game.** The stories are written for one small game, whose vocabulary is
[stories/vocabulary.zig](stories/vocabulary.zig): its tags (`music`, `picture`, `sound`, `pause`, `marked`,
`delivery`, and a night of rooms' `rooms`, `hours`, `pool` and `then`), the delivery's key, the ids of its things
and the width of its lines and choices. A chapter that needs another tag adds it there, with a comment saying what
the game does with it. Chapters 10 and 11 write for the same game with their package added, each in a vocabulary of
its own in its repository (`docs/manual/stories/vocabulary.zig`), shown whole in the chapter.

**The running story.** The ferry at Hollin: Ada, who keeps it; Otto, a pedlar; a boy; the player, who wants to
cross at night. Chapter 1 is its landing; each chapter after grows it by what it teaches (choices, facts, tags and
actions, the crossing and the far bank, words that vary), so a reader meets the same people and places throughout.
`stories/NN/ferry.river` is the whole story as it stands at chapter NN, and the next chapter starts from a copy of
it. A chapter whose subject needs another shape (a pool, a rule set, a day of slots) writes a short story of its own
beside it, as chapter 6's `bank.river`. Chapter 10 goes back to the fair on the far bank, where Otto has an errand
and the player's purse goes in the crowd; chapter 11 keeps the landing by the clock.

**Stories.** Every ` ```river ` block is consecutive rows of a story in `stories/`, copied exactly, indentation and
all, with no row left out or standing for others. Every story there is listed in `manual.stories` and is checked
in the test step, which requires it to print nothing: no error and no warning. A row indented in the story is
indented in the block.

**Runs.** A ` ```console ` block is one run of the program: its first row `$ riverrun …`, exactly as a writer
types it in the story's folder, and under it everything the run prints to standard output, whole. Each run is a row
of `manual.runs` in `build.zig`: the folder, the arguments, the file beside the story that holds what it printed
(`ferry.transcript` for a play, `ferry.diagnostics` for a check), and its exit status. The test step runs each with
nothing on standard input and holds its output to that file byte for byte and its status to the one written; the
excerpts test holds each console block to the run of that command whose output it shows, whole, and fails on a run
that no chapter shows. To pin a new run, run it in the folder, `riverrun … > ferry.transcript`, read the output, and
add the row. A play's inputs are `-i` arguments when they are few, and a script, `ferry.play`, when they are more
or need comments. Every chapter ends with a play of its story.

**Mistakes.** Where a chapter teaches a rule the checker holds, it shows a copy of its story with the mistake in it,
under `mistakes/NN/` (`mistakes/NN/NAME/` for a second), and the run of `riverrun check` on it. Its rows are shown in
a ` ```river refused ` block, which the excerpts test holds to a story some pinned `riverrun check` refuses. A
mistake the checker only warns about checks, so its rows go in a ` ```river ` block, and its pinned run has the
status 0. The prose names the file, so a reader can open it.

**Zig.** A ` ```zig ` block is consecutive rows of a Zig file the test step builds, and the prose names the file:
the vocabulary, which the program is made with, or the game's build, `stories/07/game/build.zig`, which the test
step compiles against riverrun's own build and never runs. Rows from inside a function may be shown at the margin,
all less indented by the same number of spaces. The excerpts test holds each block to its file, so changing the file
fails the block until it is changed too; the README's build is held to the same file.

**Text.** A ` ```text ` block is consecutive rows of a text the repository keeps, the grammar of
[docs/design.md](../design.md), or of what a pinned run printed: chapter 14's grammar is the design's, and chapter
12 quotes a row of a diagnostic.

Every fenced block of a chapter is one of these kinds, and the excerpts test fails on a block of any other language,
or of none, so nothing is shown that the test step does not hold.

**Ids.** A story shown before and after `riverrun tag` is a pair in `manual.tagged`, and the excerpts test holds the
second to what `riverrun tag` writes into the first. `riverrun tag` is not run by the test step, since it writes
into the file it is given.

**Conventions.**

- A chapter teaches one thing, in the order a writer meets it, and stops. It opens with the case, a story or a
  scene, before any rule. What belongs to a later chapter is named and linked, never explained early.
- A new mark: what it means in a sentence, then a block that shows it, then its rule.
- The words for things are `docs/design.md`'s, used the same way everywhere: a line, narration, a speaker, the
  cast, an extra, a section (a scene, where the checker says so) and a part, a label, a choice, a gather, a fact, a
  scope, a condition, a tag and its key, an effect, an action, a query, a delivery, an id, a play and its
  transcript. The program's user is the writer; the program is `riverrun`; the host is the game.
- Commands and their output are console blocks, never paraphrased; a path is relative to the story's folder, as the
  program prints it.
- Spelling as `docs/design.md`'s, British.
- A reference to another chapter is a link to it.
