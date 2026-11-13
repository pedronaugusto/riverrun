# riverrun

riverrun reads, checks and runs stories written in `.river` files.

- `riverrun`, the runtime: a compiled story told over the host's facts, on std and aegis alone.
- `riverrun-compiler`: the reader, the checker against a host's vocabulary, and the compiler. A game runs it at
  build time with `addStory`, which embeds the compiled story in a module, with the packages its vocabulary
  registers (their kinds of section, tags, checks and passes) on one riverrun.

A compiled story is graph data, specified in [docs/format.md](docs/format.md), so any engine's runtime can read
it. The design is [docs/design.md](docs/design.md).

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
```

The compiler fetches xenoglyph and strand, lazily, only for a build that compiles a story.

## Scope

riverrun owns story: content, flow, facts and tags. It owns no time, rendering, input or mechanic, reads no file
while a story runs, and builds in no host's words: every scope, tag and fact name is the host's vocabulary. The
design names a C ABI and a command line program; neither is built yet.

## Testing

`bay test` runs the unit suite: the reader, the checker and the compiler on stories and on a whole story read,
checked, compiled and told; and the runtime on compiled stories.

## Stability

riverrun is 0.x and tracks Zig 0.17.x. A breaking change comes only in a minor release
(0.1 to 0.2), with a CHANGELOG entry saying what changed and what to write instead; a
patch release never breaks.

## Licence

MIT. See [LICENSE](LICENSE).
