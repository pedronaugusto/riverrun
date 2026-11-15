# riverrun

riverrun reads, checks and runs stories written in `.river` files.

- `riverrun`, the runtime: a compiled story told over the host's facts, on std and aegis alone.
- `riverrun-compiler`: the reader, the checker against a host's vocabulary, and the compiler. A game runs it at
  build time with `addStory`, which embeds the compiled story in a module, with the packages its vocabulary
  registers (their kinds of section, tags, checks and passes) on one riverrun.
- `riverrun-tools` and the `riverrun` program, which the game's build makes with its vocabulary in it:
  `riverrun check` checks a story exactly as that build does, without building the game, `riverrun tag` gives
  every line and choice its id, and `riverrun play` plays it as the game would, in a terminal or from a script of
  inputs that writes a transcript.

A compiled story is graph data, specified in [docs/format.md](docs/format.md), so any engine's runtime can read
it. The design is [docs/design.md](docs/design.md). A writer starts with [the manual](docs/manual/README.md).

## Install

Requires Zig 0.17. Fetch with `zig fetch --save git+https://github.com/pedronaugusto/riverrun`. The runtime is the
`riverrun` module, on aegis alone. A game's build compiles its stories with `addStory`, which takes the dependency
as `riverrun.building(b)` asks for it, the `.river` files, and the Zig file that declares the game's vocabulary:

```zig
const riverrun = @import("riverrun");
const river = b.dependency("riverrun", riverrun.building(b));
const story = riverrun.addStory(b, river, .{
    .files = &.{b.path("story/main.river")},
    .vocabulary = b.path("src/vocabulary.zig"),
});
exe.root_module.addImport("story", story.module);
// zig-out/bin/riverrun, with the game's vocabulary: riverrun check story/*.river
b.installArtifact(story.program);
// zig build story: the story checked, the game not built
b.step("story", "Check the story").dependOn(&story.check.step);
```

The compiler fetches xenoglyph and strand, and the program ensign, lazily, only for a build that compiles a story.

## The program

```
riverrun check [--release] FILE…        check the story as the game's build does; exit 1 on an error
riverrun tag [--check] FILE…            give every line and choice its id, ^ and six letters and digits
riverrun play [options] FILE…           play the story as the game would
riverrun compile --graph P --words P FILE…   what addStory runs
```

`riverrun play` starts where the game starts the story (or `--from SECTION`), with what the game has done
(`--set 'spot = door'`, `--wait 27`, `--call 'start bounty target=wolf'`), and runs the story's rules and its
packages' runtimes as the game does. In a terminal a writer types a choice's number, an outcome when one is asked,
or `:facts`, `:set`, `:wait`, `:back`, `:restart`, `:quit`, `:help`, and the calls the game makes into its packages,
which each package offers and `:help` lists (cairn's `:start QUEST ROLE=THING…`). With `--script PATH`, `--input ROW`
or a script on standard input every row is given up front and the transcript is written to standard output; a
run-time error is placed at the effect or condition that met it; the exit status is 0 at the story's end, 3 waiting
for an input the script did not give, 4 stopped on a run-time error, 1 when the story does not check or a row
cannot be taken. `riverrun <command> --help` says the rest; the design's "The program" says it all.

## Scope

riverrun owns story: content, flow, facts and tags. It owns no time, rendering, input or mechanic, reads no file
while a story runs, and builds in no host's words: every scope, tag and fact name is the host's vocabulary. The
design names a C ABI; it is not built yet.

## Testing

`bay test` runs the unit suite: the reader, the checker and the compiler on stories and on a whole story read,
checked, compiled and told; the runtime on compiled stories; and the program, with the documentation's stories
checked by it, and played by it from a script, and every run the manual shows pinned. Properties hold the reader to
printing any bytes back, `riverrun tag` to adding ids and nothing else, the whole compiler to giving a story or
diagnostics for any text, never a crash, and play to a transcript and a named ending for any story and any script,
to telling what the walk tells, to going back and forward again as if never gone back, and to placing a run-time
error at the effect that met it; `bay fuzz` fuzzes them.

## Stability

riverrun is 0.x and tracks Zig 0.17.x. A breaking change comes only in a minor release
(0.1 to 0.2), with a CHANGELOG entry saying what changed and what to write instead; a
patch release never breaks.

## Licence

MIT. See [LICENSE](LICENSE).
