//! riverrun: stories written in `.river` files, read, checked and run.
//!
//! Layers, each importing only those before it: `syntax` (text into a tree),
//! then `facts`, `check`, `story`, `compile` and `run`. Nothing at run time
//! imports `syntax`, `check` or `compile`.

pub const syntax = @import("syntax.zig");
pub const facts = @import("facts.zig");
pub const check = @import("check.zig");
pub const story = @import("story.zig");
pub const compile = @import("compile.zig");
pub const run = @import("run.zig");

test {
    _ = syntax;
    _ = facts;
    _ = check;
    _ = story;
    _ = compile;
    _ = run;
}
