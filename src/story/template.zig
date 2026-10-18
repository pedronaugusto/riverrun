//! A line's text as the string table holds it: the whole line, with a place
//! for each slot, so a translation can move the slots and choose its own
//! words in each branch, as ICU's message format lets translators do.
//!
//!     template = { literal | escape | slot }
//!     escape   = "\" ( "{" | "}" | "|" | "\" )
//!     slot     = "{" index [ ":" template { "|" template }
//!                          | "?" label ":" template { "|" label ":" template } ] "}"
//!     label    = lowercase letters
//!
//! `{0}` writes slot 0's value; `{1:You came all this way.|You came.}` writes
//! the branch slot 1 chooses. A plural's or a gender's branches are labelled
//! by category, `{2?one:pelt|other:pelts}`, and each language's table labels
//! its own: a translation into Polish adds `few` and `many`. Every labelled
//! slot has `other`, which a category it lacks falls back to. A bare `|` is
//! literal outside a slot's branches.

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
    /// A plural's or a gender's branches unlabelled, a category not its kind's or named twice, or no `other`.
    BadCategory,
};

/// The categories a plural's branches are labelled by: CLDR's.
pub const plural_categories = [_][]const u8{ "zero", "one", "two", "few", "many", "other" };
/// The categories a gender's branches are labelled by.
pub const gender_categories = [_][]const u8{ "masculine", "feminine", "neuter", "other" };

/// Whether a slot of this kind has labelled branches, and which labels it takes.
pub fn categoriesOf(kind: format.SlotKind) ?[]const []const u8 {
    return switch (kind) {
        .plural => &plural_categories,
        .gender => &gender_categories,
        else => null,
    };
}

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
        var labels: [plural_categories.len + gender_categories.len][]const u8 = undefined;
        var labelled = false;
        if (p.t[p.i] == ':' or p.t[p.i] == '?') {
            labelled = p.t[p.i] == '?';
            while (true) {
                p.i += 1;
                if (labelled) {
                    if (branches == labels.len) return error.BadCategory;
                    labels[branches] = try p.label();
                }
                try p.run(depth + 1, true);
                branches += 1;
                if (p.t[p.i] == '}') break;
            }
        } else if (p.t[p.i] != '}') return error.BadTemplate;
        p.i += 1;
        const shapes = p.shapes orelse return;
        if (index >= shapes.len) return error.SlotOutOfRange;
        const shape = shapes[index];
        if (categoriesOf(shape.kind)) |allowed| return categories(labels[0..branches], labelled, allowed);
        if (labelled) return error.SlotMisused;
        if ((shape.kind == .value) != (branches == 0)) return error.SlotMisused;
        if (branches != 0 and branches != shape.arity) return error.WrongBranches;
    }

    // A branch's label up to its `:`.
    fn label(p: *Parser) Error![]const u8 {
        const start = p.i;
        while (p.i < p.t.len and std.ascii.isLower(p.t[p.i])) p.i += 1;
        if (p.i == start or p.i == p.t.len or p.t[p.i] != ':') return error.BadTemplate;
        defer p.i += 1;
        return p.t[start..p.i];
    }
};

// Labels each one of a kind's categories, none twice, `other` among them.
fn categories(labels: []const []const u8, labelled: bool, allowed: []const []const u8) Error!void {
    if (!labelled) return error.BadCategory;
    var other = false;
    for (labels, 0..) |l, i| {
        if (!within(allowed, l)) return error.BadCategory;
        for (labels[0..i]) |before| if (std.mem.eql(u8, before, l)) return error.BadCategory;
        other = other or std.mem.eql(u8, l, "other");
    }
    if (!other) return error.BadCategory;
}

fn within(list: []const []const u8, word: []const u8) bool {
    for (list) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

/// Writes a validated template, asking `resolver` for what each slot holds:
/// `resolver.value(slot, writer) std.Io.Writer.Error!void` writes a value,
/// `resolver.branch(slot) ?u8` says which branch to write, or null for none
/// (alternatives used up), and `resolver.category(slot) []const u8` which
/// labelled branch, `other` if the slot labels none by that name.
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
    if (t[i.*] == '?') return renderLabelled(t, i, resolver, w, emit, index);
    const chosen: ?u8 = if (emit) resolver.branch(index) else null;
    var b: u8 = 0;
    while (t[i.*] != '}') : (b += 1) {
        i.* += 1;
        try renderRun(t, i, resolver, w, true, emit and chosen == b);
    }
    i.* += 1;
}

// A plural's or a gender's branches: the one labelled the slot's category, else `other`.
fn renderLabelled(t: []const u8, i: *usize, resolver: anytype, w: *std.Io.Writer, emit: bool, index: u8) std.Io.Writer.Error!void {
    const want: []const u8 = if (emit) resolver.category(index) else "";
    const start = i.*;
    var has_want = false;
    while (t[i.*] != '}') {
        i.* += 1;
        const l = labelAt(t, i);
        has_want = has_want or std.mem.eql(u8, l, want);
        try renderRun(t, i, resolver, w, true, false);
    }
    const chosen = if (has_want) want else "other";
    i.* = start;
    while (t[i.*] != '}') {
        i.* += 1;
        const l = labelAt(t, i);
        try renderRun(t, i, resolver, w, true, emit and std.mem.eql(u8, l, chosen));
    }
    i.* += 1;
}

fn labelAt(t: []const u8, i: *usize) []const u8 {
    const start = i.*;
    while (t[i.*] != ':') i.* += 1;
    defer i.* += 1;
    return t[start..i.*];
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
        pub fn category(_: @This(), _: u8) []const u8 {
            return "few";
        }
    };
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(t, Resolver{}, &w);
    try std.testing.expectEqualStrings("Frank died at <0>. You came. {sic}", w.buffered());
}

test "a plural's branches are labelled by category, and a missing one falls back to other" {
    const shapes = [_]Shape{.{ .kind = .plural, .arity = 0 }};
    // Polish: one, few, many, other
    const t = "{0?one:wilk|few:wilki|many:wilków|other:wilka}";
    try validate(t, &shapes);
    try std.testing.expectError(error.BadCategory, validate("{0?one:wilk|few:wilki}", &shapes));
    try std.testing.expectError(error.BadCategory, validate("{0?one:a|one:b|other:c}", &shapes));
    try std.testing.expectError(error.BadCategory, validate("{0?feminine:a|other:b}", &shapes));
    try std.testing.expectError(error.BadCategory, validate("{0:a|b}", &shapes));
    const Resolver = struct {
        cat: []const u8,
        pub fn value(_: @This(), _: u8, _: *std.Io.Writer) std.Io.Writer.Error!void {}
        pub fn branch(_: @This(), _: u8) ?u8 {
            return null;
        }
        pub fn category(r: @This(), _: u8) []const u8 {
            return r.cat;
        }
    };
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(t, Resolver{ .cat = "few" }, &w);
    try std.testing.expectEqualStrings("wilki", w.buffered());
    w = .fixed(&buf);
    try render("{0?one:pelt|other:pelts}", Resolver{ .cat = "few" }, &w);
    try std.testing.expectEqualStrings("pelts", w.buffered());
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
                pub fn category(_: @This(), slot: u8) []const u8 {
                    return if (slot % 2 == 0) "one" else "few";
                }
            };
            var buf: [1024]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            try render(bytes, Resolver{}, &w);
        }
    }.one, .{});
}
