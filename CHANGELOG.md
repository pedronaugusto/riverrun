# Changelog

All notable changes are documented here, following Keep a Changelog 1.1.0.

## [Unreleased]

### Added

- The reader keeps every byte. A file's tree holds its rows (`ast.File.rows`, `ast.Row`): each row's indentation,
  words, tags, comment, the spaces before each and at its end, and its line ending (LF, CRLF, or none on a last row
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

- `syntax.Span` is a range of bytes, `{ file, start, end }`, not a line and a column. A line and a column are worked
  out when one is printed: `ast.File.place(span)` gives a `syntax.Place`, `{ line, col }`, and `Checker.place` a
  file's path with it. Every diagnostic, the reader's, the checker's and a package's, carries a range.
  `Span.none`, no place in the text, is placed at line 0, column 0.
- `ast.Decl` is `{ span, kind }`, its declarations under `kind` (`version` is the number alone); `ast.Piece` is
  `{ span, kind }`, its kinds under `kind`; `ast.Fact`, `ast.Tag`, `ast.Section` and `ast.Subsection` and the
  other nodes above take a `span`, which a package's `Kind.declare` gives the facts it makes.
- A statement written on a row after a condition (`{ met } Go.`) or a gather (`- (ask) * Run.`) has the row's tags
  itself, as a part's one-line candidate has; the condition or the gather has none. `ast.Cond.on_row` says a
  condition and its statement share a row. What reaches the host is unchanged.
- The reader takes a file that begins with a UTF-8 byte-order mark, where it refused its first line.

### Fixed

- A flow chosen by a condition with `|` before its `:` (`{ a | b: -> x }`) is refused, where it trapped.
- A list type that goes on under its fact (`set of a, b,` then `c` on the next row) places each name where it is
  written, where the names after the first row were placed by their offset on the first.
