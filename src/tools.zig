//! riverrun's tools: the model every tool shows, and what the `riverrun`
//! program does with it. A story is held as its writer has it, each file's
//! text read to the tree that keeps every byte, with everything the reader,
//! the checker and the compiler said about it (`Manuscript`); its
//! diagnostics are written in one form a person, an editor and an AI read
//! alike (`report`); its lines and choices are given the ids translations
//! and voices key on (`tag`); a compiled story is told a bounded number of
//! steps (`walk`), and a story put through all of it as the whole compiler's
//! property does (`trial`); and a package's documented stories are held to
//! its checked ones (`excerpts`). The program is a thin front of this module, so the
//! editor to come calls the same code. It stands on the compiler and the
//! runtime and adds nothing they lack.

pub const Manuscript = @import("tools/Manuscript.zig");
pub const report = @import("tools/report.zig");
pub const tag = @import("tools/tag.zig");
pub const walk = @import("tools/walk.zig");
pub const trial = @import("tools/trial.zig");
pub const excerpts = @import("tools/excerpts.zig");

test {
    _ = Manuscript;
    _ = report;
    _ = tag;
    _ = walk;
    _ = trial;
    _ = excerpts;
    _ = @import("tools/tag_test.zig");
    _ = @import("tools/whole_test.zig");
}
