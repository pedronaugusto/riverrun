//! Text into the string table and the graph: the words as a template with
//! numbered places, the string table's, and the slots that fill them, the
//! graph's. `{fact}` is a value slot, `{ cond: a | b }` a choice of two
//! branches, alternatives a slot of their arity whose state is a fact of
//! the reserved scope, named for the line and the slot so it survives a
//! recompiled story; a selection a plural or gender slot whose branches the
//! template labels by category, `{0?one:pelt|other:pelts}`, so a
//! translation labels its own language's.

const std = @import("std");
const syntax = @import("../syntax.zig");
const story = @import("riverrun").story;
const Compiler = @import("Compiler.zig");
const exprs = @import("exprs.zig");

const ast = syntax.ast;
const Error = Compiler.Error;

const Writing = struct {
    id: []const u8,
    template: std.ArrayList(u8) = .empty,
    slots: std.ArrayList(story.Slot) = .empty,
};

/// The text `t` of the line or choice whose id is `id`: its words in the string table, its slots in the graph.
pub fn text(c: *Compiler, id: []const u8, t: ast.Text) Error!story.TextId {
    var w: Writing = .{ .id = id };
    try pieces(c, &w, t);
    return c.b.text(try c.b.line(id, w.template.items), w.slots.items);
}

fn pieces(c: *Compiler, w: *Writing, t: ast.Text) Error!void {
    for (t) |*piece| switch (piece.kind) {
        .literal => |s| for (s) |ch| {
            if (ch == '\\' or ch == '{' or ch == '}' or ch == '|') try w.template.append(c.arena, '\\');
            try w.template.append(c.arena, ch);
        },
        .value => |*e| {
            const i = try slot(c, w, .{ .kind = .value, .expr = try exprs.value(c, e) });
            try w.template.print(c.arena, "{{{d}}}", .{i});
        },
        .choose => |*ch| {
            const i = try slot(c, w, .{ .kind = .choose, .expr = try exprs.condition(c, &ch.cond), .arity = 2 });
            try w.template.print(c.arena, "{{{d}:", .{i});
            try pieces(c, w, ch.then);
            try w.template.append(c.arena, '|');
            try pieces(c, w, ch.otherwise);
            try w.template.append(c.arena, '}');
        },
        .select => |*sel| {
            const typed = c.checked.exprs.get(&sel.operand) orelse unreachable; // unreachable: the checker typed it
            const s: story.Slot = if (typed.ref != null and typed.ref.? == .speaker)
                .{ .kind = .gender, .expr = try c.b.expr(&.{.of(.int, try c.b.int(c.cast[typed.ref.?.speaker.raw()].raw()))}) }
            else
                .{ .kind = if (typed.type == .int) .plural else .gender, .expr = try exprs.value(c, &sel.operand) };
            const i = try slot(c, w, s);
            try w.template.print(c.arena, "{{{d}?", .{i});
            for (sel.branches, 0..) |b, k| {
                if (k > 0) try w.template.append(c.arena, '|');
                try w.template.print(c.arena, "{s}:", .{b.label.text});
                try pieces(c, w, b.text);
            }
            try w.template.append(c.arena, '}');
        },
        .alternatives => |alt| {
            const state = try c.b.state(try c.arena.print("alt.{s}.{d}", .{ w.id, w.slots.items.len }));
            const arity = std.math.cast(u8, alt.options.len) orelse return error.TooManySlots;
            const i = try slot(c, w, .{ .kind = kindOf(alt.kind), .arity = arity, .state = state });
            try w.template.print(c.arena, "{{{d}:", .{i});
            for (alt.options, 0..) |o, k| {
                if (k > 0) try w.template.append(c.arena, '|');
                try pieces(c, w, o);
            }
            try w.template.append(c.arena, '}');
        },
    };
}

fn slot(c: *Compiler, w: *Writing, s: story.Slot) Error!usize {
    if (w.slots.items.len == story.max_slots) return error.TooManySlots;
    try w.slots.append(c.arena, s);
    return w.slots.items.len - 1;
}

fn kindOf(k: ast.Alternatives) story.SlotKind {
    return switch (k) {
        .seq => .sequence,
        .cycle => .cycle,
        .once => .once,
        .shuffle => .shuffle,
    };
}
