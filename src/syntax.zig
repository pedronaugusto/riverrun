//! The syntax layer: `.river` text into a syntax tree that keeps every byte,
//! with every problem reported where it is, and the tree printed back as
//! text. It needs nothing else in riverrun, and nothing at run time needs it.

pub const source = @import("syntax/source.zig");
pub const ast = @import("syntax/ast.zig");
pub const parse = @import("syntax/parse.zig").parseFile;
/// A file's tree as text: byte for byte the file it was read from, when it read without a problem.
pub const print = @import("syntax/print.zig").print;

pub const Span = source.Span;
pub const Place = source.Place;
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
    _ = @import("syntax/print.zig");
    _ = @import("syntax/proof_test.zig");
    _ = @import("syntax/reader_test.zig");
}
