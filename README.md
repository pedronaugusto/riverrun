# riverrun

riverrun reads, checks and runs stories written in `.river` files.

- `riverrun`, the runtime: a compiled story told over the host's facts, on std and aegis alone.
- `riverrun-compiler`: the reader, the checker against a host's vocabulary, and the compiler. A game runs it at
  build time with `addStory`, which embeds the compiled story in a module, with the packages its vocabulary
  registers (their kinds of section, tags, checks and passes) on one riverrun.

A compiled story is graph data, specified in [docs/format.md](docs/format.md), so any engine's runtime can read
it. The design is [docs/design.md](docs/design.md).

## Stability

riverrun is 0.x and tracks Zig 0.17.x. A breaking change comes only in a minor release
(0.1 to 0.2), with a CHANGELOG entry saying what changed and what to write instead; a
patch release never breaks.
