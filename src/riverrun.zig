//! riverrun's runtime: stories compiled from `.river` files, told over the
//! host's facts. `facts` (typed state in scopes, behind a store), `story`
//! (the compiled format, read in place), `run` (the executor) and `react`
//! (rules, and conditions watched as facts change), each importing only
//! those before it, on std and aegis alone. The compiler is
//! the `riverrun-compiler` module, which a game runs at build time.

pub const facts = @import("facts.zig");
pub const story = @import("story.zig");
pub const run = @import("run.zig");
pub const react = @import("react.zig");

test {
    _ = facts;
    _ = story;
    _ = run;
    _ = react;
}
