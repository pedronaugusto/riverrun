# riverrun

riverrun reads, checks and runs stories written in `.river` files.

- `riverrun`, the runtime: a compiled story told over the host's facts, on std and aegis alone.
- `riverrun-compiler`: the reader, the checker against a host's vocabulary, and the compiler. A game runs it at
  build time with `addStory`, which embeds the compiled story in a module.

A compiled story is graph data, specified in [docs/format.md](docs/format.md), so any engine's runtime can read
it. The design is [docs/design.md](docs/design.md).
