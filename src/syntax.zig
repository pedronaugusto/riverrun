//! The syntax layer: `.river` text into a syntax tree, with every problem
//! reported where it is. It needs nothing else in riverrun, and nothing at
//! run time needs it.

pub const source = @import("syntax/source.zig");
pub const ast = @import("syntax/ast.zig");
pub const parse = @import("syntax/parse.zig").parseFile;

pub const Span = source.Span;
pub const FileId = source.FileId;
pub const Diagnostics = source.Diagnostics;
/// The largest file the reader takes.
pub const max_file = @import("syntax/lines.zig").max_bytes;

test {
    _ = source;
    _ = ast;
    _ = @import("syntax/lines.zig");
    _ = @import("syntax/expr.zig");
    _ = @import("syntax/text.zig");
    _ = @import("syntax/parse.zig");
    _ = @import("syntax/proof_test.zig");
    _ = @import("syntax/reader_test.zig");
}
