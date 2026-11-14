//! What an int expression can be: its least and its most, worked out from
//! what the checker typed. A number and an int constant are themselves; a
//! bounded fact is its bounds, which it holds from the start (it starts at
//! the value in its range nearest 0, as a fact kept per thing does for every
//! key not set); any other int is anything an int holds; a sum adds its sides' least and most, and a
//! difference takes the other side's most from its least and its least from
//! its most. Every value the expression gives at run time lies between the
//! two, the store holding each bounded fact inside its bounds, so what is
//! decided from them holds for every run: the checker's folding over ints,
//! which decides less where ints are unbounded and never decides wrongly.
//!
//! The least and most are i128, which no sum the reader takes can leave: an
//! expression has fewer operands than its words have bytes, each within 64
//! bits. So a sum that would leave an int's 64 bits is seen, not wrapped.

const std = @import("std");
const syntax = @import("../syntax.zig");
const Checker = @import("Checker.zig");

const ast = syntax.ast;

pub const Interval = struct {
    least: i128,
    most: i128,

    /// Anything an int holds.
    pub const int: Interval = .{ .least = std.math.minInt(i64), .most = std.math.maxInt(i64) };

    pub fn one(n: i64) Interval {
        return .{ .least = n, .most = n };
    }

    /// Whether every value lies past what an int holds: evaluating it always overflows.
    pub fn past(i: Interval) bool {
        return i.most < int.least or i.least > int.most;
    }

    /// The single value it can be, if it is one an int holds.
    pub fn only(i: Interval) ?i64 {
        if (i.least != i.most or i.past()) return null;
        return @intCast(i.least); // safe: not past an int's bounds
    }

    fn sum(a: Interval, b: Interval) Interval {
        return .{ .least = a.least + b.least, .most = a.most + b.most };
    }

    fn difference(a: Interval, b: Interval) Interval {
        return .{ .least = a.least - b.most, .most = a.most - b.least };
    }
};

/// The least and the most `e` can be, or null where it is no int the checker typed.
pub fn of(c: *const Checker, e: *const ast.Expr) ?Interval {
    const typed = c.exprs.get(e) orelse return null;
    if (typed.type != .int) return null;
    switch (e.kind) {
        .binary => |b| {
            const x = of(c, b.lhs) orelse return null;
            const y = of(c, b.rhs) orelse return null;
            return switch (b.op) {
                .add => x.sum(y),
                .sub => x.difference(y),
                else => null,
            };
        },
        .int => |n| if (typed.ref == null) return .one(n),
        else => {},
    }
    const ref = typed.ref orelse return .int;
    return switch (ref) {
        .constant => |id| switch (c.consts.items[id.raw()].value) {
            .int => |n| .one(n),
            else => null,
        },
        // a bounded fact holds its bounds from the start
        .fact, .own, .keyed => |id| if (c.facts.items[id.raw()].bounds) |bounds| .{
            .least = bounds.min,
            .most = bounds.max,
        } else .int,
        else => .int,
    };
}

test "a sum's least and most come from its sides', past an int's bounds where they lie" {
    const max = std.math.maxInt(i64);
    const a: Interval = .{ .least = -5, .most = 10 };
    const b: Interval = .{ .least = 0, .most = 3 };
    try std.testing.expectEqual(Interval{ .least = -5, .most = 13 }, a.sum(b));
    try std.testing.expectEqual(Interval{ .least = -8, .most = 10 }, a.difference(b));
    try std.testing.expect(!Interval.int.sum(.one(1)).past());
    try std.testing.expect(Interval.one(max).sum(.one(1)).past());
    try std.testing.expect(Interval.int.difference(.int).only() == null);
    try std.testing.expectEqual(@as(?i64, 7), Interval.one(7).only());
}
