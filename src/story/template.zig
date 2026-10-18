//! A line's text as the string table holds it: the whole line, with a place
//! for each slot, so a translation can move the slots and choose its own
//! words in each branch, as ICU's message format lets translators do.
//!
//!     template = { literal | escape | slot }
//!     escape   = "\" ( "{" | "}" | "|" | "\" )
//!     slot     = "{" index [ ":" template { "|" template } ] "}"
//!
//! `{0}` writes slot 0's value; `{1:You came all this way.|You came.}` writes
//! the branch slot 1 chooses. A bare `|` is literal outside a slot's branches.

const std = @import("std");
const format = @import("format.zig");

/// How deep branches nest within branches.
pub const max_depth = 8;

pub const Error = error{
    /// A brace, a bar or an escape out of place.
    BadTemplate,
    NestsTooDeep,
    SlotOutOfRange,
    /// A value slot given branches, or a slot with branches given none.
    SlotMisused,
    /// Branches that are not the slot's count.
    WrongBranches,
};

/// What the graph says a text's slot is, for checking a template against it.
pub const Shape = struct { kind: format.SlotKind, arity: u8 };

/// Checks `t`'s syntax, and, given `shapes`, that each slot it names is used as the graph declares it.
pub fn validate(t: []const u8, shapes: ?[]const Shape) Error!void {
    var p: Parser = .{ .t = t, .shapes = shapes };
    try p.run(0, false);
    if (p.i != t.len) return error.BadTemplate;
}

const Parser = struct {
    t: []const u8,
    shapes: ?[]const Shape,
    i: usize = 0,

    // Up to the end, or within a branch, to the `|` or `}` that ends it.
    fn run(p: *Parser, depth: usize, in_branch: bool) Error!void {
        while (p.i < p.t.len) {
            switch (p.t[p.i]) {
                '\\' => {
                    if (p.i + 1 == p.t.len or std.mem.findScalar(u8, "{}|\\", p.t[p.i + 1]) == null) return error.BadTemplate;
                    p.i += 2;
                },
                '{' => try p.slot(depth),
                '}' => if (in_branch) return else return error.BadTemplate,
                '|' => if (in_branch) return else {
                    p.i += 1;
                },
                else => p.i += 1,
            }
        }
        if (in_branch) return error.BadTemplate;
    }

    fn slot(p: *Parser, depth: usize) Error!void {
        if (depth == max_depth) return error.NestsTooDeep;
        p.i += 1;
        const start = p.i;
        while (p.i < p.t.len and std.ascii.isDigit(p.t[p.i])) p.i += 1;
        if (p.i == start or p.i - start > 2 or p.i == p.t.len) return error.BadTemplate;
        const index = std.fmt.parseInt(u8, p.t[start..p.i], 10) catch return error.BadTemplate;
        if (index >= format.max_slots) return error.SlotOutOfRange;
        var branches: usize = 0;
        if (p.t[p.i] == ':') {
            while (true) {
                p.i += 1;
                try p.run(depth + 1, true);
                branches += 1;
                if (p.t[p.i] == '}') break;
            }
        } else if (p.t[p.i] != '}') return error.BadTemplate;
        p.i += 1;
        const shapes = p.shapes orelse return;
        if (index >= shapes.len) return error.SlotOutOfRange;
        const shape = shapes[index];
        if ((shape.kind == .value) != (branches == 0)) return error.SlotMisused;
        if (branches != 0 and branches != shape.arity) return error.WrongBranches;
    }
};

/// Writes a validated template, asking `resolver` for what each slot holds:
/// `resolver.value(slot, writer) std.Io.Writer.Error!void` writes a value, and
/// `resolver.branch(slot) ?u8` says which branch to write, or null for none
/// (alternatives used up).
pub fn render(t: []const u8, resolver: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var i: usize = 0;
    try renderRun(t, &i, resolver, w, false, true);
}

fn renderRun(t: []const u8, i: *usize, resolver: anytype, w: *std.Io.Writer, in_branch: bool, emit: bool) std.Io.Writer.Error!void {
    while (i.* < t.len) {
        const c = t[i.*];
        switch (c) {
            '\\' => {
                if (emit) try w.writeByte(t[i.* + 1]);
                i.* += 2;
            },
            '{' => try renderSlot(t, i, resolver, w, emit),
            '}' => return,
            '|' => if (in_branch) return else {
                if (emit) try w.writeByte('|');
                i.* += 1;
            },
            else => {
                if (emit) try w.writeByte(c);
                i.* += 1;
            },
        }
    }
}

fn renderSlot(t: []const u8, i: *usize, resolver: anytype, w: *std.Io.Writer, emit: bool) std.Io.Writer.Error!void {
    i.* += 1;
    const start = i.*;
    while (std.ascii.isDigit(t[i.*])) i.* += 1;
    const index = std.fmt.parseInt(u8, t[start..i.*], 10) catch unreachable; // unreachable: validated
    if (t[i.*] == '}') {
        i.* += 1;
        if (emit) try resolver.value(index, w);
        return;
    }
    const chosen: ?u8 = if (emit) resolver.branch(index) else null;
    var b: u8 = 0;
    while (t[i.*] != '}') : (b += 1) {
        i.* += 1;
        try renderRun(t, i, resolver, w, true, emit and chosen == b);
    }
    i.* += 1;
}

test "a template holds values and branches, and checks against its slots" {
    const shapes = [_]Shape{ .{ .kind = .value, .arity = 0 }, .{ .kind = .choose, .arity = 2 } };
    const t = "Frank died at {0}. {1:You came all this way.|You came.} \\{sic\\}";
    try validate(t, &shapes);
    try std.testing.expectError(error.WrongBranches, validate("{1:a|b|c}", &shapes));
    try std.testing.expectError(error.SlotMisused, validate("{0:a|b}", &shapes));
    try std.testing.expectError(error.SlotOutOfRange, validate("{2}", &shapes));
    try std.testing.expectError(error.BadTemplate, validate("{1:a|b", null));
    try std.testing.expectError(error.BadTemplate, validate("a}", null));
    const Resolver = struct {
        pub fn value(_: @This(), slot: u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("<{d}>", .{slot});
        }
        pub fn branch(_: @This(), _: u8) ?u8 {
            return 1;
        }
    };
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(t, Resolver{}, &w);
    try std.testing.expectEqualStrings("Frank died at <0>. You came. {sic}", w.buffered());
}

test "any bytes are a template or refused, never crash" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [256]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];
            validate(bytes, null) catch return;
            const Resolver = struct {
                pub fn value(_: @This(), _: u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
                    try w.writeByte('v');
                }
                pub fn branch(_: @This(), slot: u8) ?u8 {
                    return slot % 3;
                }
            };
            var buf: [1024]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            try render(bytes, Resolver{}, &w);
        }
    }.one, .{});
}
