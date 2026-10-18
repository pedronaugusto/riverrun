//! riverrun's compiler: `.river` files read (`syntax`), checked against a
//! host's vocabulary (`check`) and compiled into the format the runtime
//! tells (`compile`), and the JSON forms tools read (`json`). A game runs it
//! at build time through `addStory`; nothing at run time needs it. It stands
//! on the `riverrun` module, the runtime, and adds what only building needs.

pub const syntax = @import("syntax.zig");
pub const check = @import("check.zig");
pub const compile = @import("compile.zig");
pub const json = @import("json.zig");

test {
    _ = syntax;
    _ = check;
    _ = compile;
    _ = json;
}
