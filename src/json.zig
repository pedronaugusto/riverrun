//! The JSON forms, through strand: a scope's facts readably, and a compiled
//! story as a tool reads it. Tools' and tests', so the runtime never needs
//! strand.

pub const facts = @import("json/facts.zig");
pub const story = @import("json/story.zig");

test {
    _ = facts;
    _ = story;
}
