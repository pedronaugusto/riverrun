//! A file's tree printed as text: its byte-order mark, then each row's
//! indentation, words, tags and comment, each after the spaces before it,
//! the spaces at its end and its line ending. A file the reader read without
//! a problem prints back byte for byte; a tool that edits the rows prints the
//! file it means.

const std = @import("std");
const ast = @import("ast.zig");
const source = @import("source.zig");

pub fn print(w: *std.Io.Writer, file: *const ast.File) std.Io.Writer.Error!void {
    if (file.bom) try w.writeAll(source.byte_order_mark);
    for (file.rows) |row| try printRow(w, row);
}

pub fn printRow(w: *std.Io.Writer, row: ast.Row) std.Io.Writer.Error!void {
    try w.splatByteAll(' ', row.indent);
    try w.writeAll(row.text);
    try w.splatByteAll(' ', row.before_tags);
    try w.writeAll(row.tags);
    try w.splatByteAll(' ', row.before_comment);
    try w.writeAll(row.comment);
    try w.splatByteAll(' ', row.trailing);
    try w.writeAll(row.ending.bytes());
}
