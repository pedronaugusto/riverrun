# Changelog

All notable changes are documented here, following Keep a Changelog 1.1.0.

## [Unreleased]

### Added

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

- Resetting a scope that holds a bounded int whose range leaves out 0 trapped (`catch unreachable` on the set of 0);
  it is put back at its starting value, which always fits.
- `join` takes a vocabulary of any size: comparing every pair of a schema's keys ran past the compiler's default
  branch quota at a few dozen keys, and the vocabulary did not compile.
- A flow chosen by a condition with `|` before its `:` (`{ a | b: -> x }`) is refused, where it trapped.
- A list type that goes on under its fact (`set of a, b,` then `c` on the next row) places each name where it is
  written, where the names after the first row were placed by their offset on the first.
