//! Text against the host's width: the terminal columns a line or a choice
//! takes, measured by grapheme cluster as xenoglyph counts them, so a wide
//! character is two and an accent none.

const std = @import("std");
const xenoglyph = @import("xenoglyph");
const syntax = @import("../syntax.zig");
const Checker = @import("Checker.zig");

const ast = syntax.ast;

/// The columns `text` takes at its widest. A `{value}` counts `value` columns
/// (none when null), and words chosen by a condition count as the wider.
pub fn measure(text: ast.Text, value: ?u32) usize {
    var n: usize = 0;
    for (text) |piece| n += switch (piece) {
        .literal => |s| xenoglyph.width.string(s, .{}).raw(),
        .value => value orelse 0,
        .choose => |ch| @max(measure(ch.then, value), measure(ch.otherwise, value)),
    };
    return n;
}

/// Reports `text` when it is wider than `limit`; `what` names it: "line", "choice".
pub fn check(c: *Checker, span: syntax.Span, text: ast.Text, limit: ?u32, what: []const u8) Checker.Error!void {
    const most = limit orelse return;
    const n = measure(text, c.options.width.value);
    if (n > most) try c.err(span, "the {s} is {d} columns wide, past the host's {d}", .{ what, n, most });
}

test "width counts columns, not bytes" {
    const text: ast.Text = &.{ .{ .literal = "café " }, .{ .value = .{ .span = .none, .kind = .{ .name = "dies_at" } } }, .{ .literal = " 日本" } };
    try std.testing.expectEqual(@as(usize, 10), measure(text, null));
    try std.testing.expectEqual(@as(usize, 18), measure(text, 8));
}
