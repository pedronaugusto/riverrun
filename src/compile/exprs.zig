//! Expressions into terms: what the checker typed and resolved, written in
//! postfix for the format's evaluator. A name becomes the fact, the value,
//! the visit count or the thing it named; a constant its value; a query its
//! arguments then the call; a builtin its call record. A visit count where a
//! condition stands is true once it is above zero.

const std = @import("std");
const syntax = @import("../syntax.zig");
const check = @import("../check.zig");
const story = @import("riverrun").story;
const Compiler = @import("Compiler.zig");

const sym = check.symbols;
const ast = syntax.ast;
const Term = story.Term;
const Error = Compiler.Error;

pub const Terms = std.ArrayList(Term);

/// A condition's terms, in the builder.
pub fn condition(c: *Compiler, e: *const ast.Expr) Error!story.Range {
    var out: Terms = .empty;
    try cond(c, &out, e);
    return c.b.expr(out.items);
}

/// A value's terms, in the builder.
pub fn value(c: *Compiler, e: *const ast.Expr) Error!story.Range {
    var out: Terms = .empty;
    try val(c, &out, e);
    return c.b.expr(out.items);
}

/// A key's terms, then a value's: what writing a fact kept per thing takes.
pub fn pair(c: *Compiler, key: *const ast.Expr, v: *const ast.Expr) Error!story.Range {
    var out: Terms = .empty;
    try val(c, &out, key);
    try val(c, &out, v);
    return c.b.expr(out.items);
}

/// A value's terms appended to `out`, for an effect that builds its own.
pub fn into(c: *Compiler, out: *Terms, e: *const ast.Expr) Error!void {
    try val(c, out, e);
}

/// A call's arguments, each a value, in order.
pub fn arguments(c: *Compiler, args: []const ast.Expr) Error!story.Range {
    var out: Terms = .empty;
    for (args) |*a| try val(c, &out, a);
    return c.b.expr(out.items);
}

fn typed(c: *const Compiler, e: *const ast.Expr) sym.Typed {
    return c.checked.exprs.get(e) orelse unreachable; // unreachable: the checker typed every expression it passed
}

fn cond(c: *Compiler, out: *Terms, e: *const ast.Expr) Error!void {
    try val(c, out, e);
    // a visit count stands for whether it was ever reached
    if (typed(c, e).type == .int) try out.appendSlice(c.arena, &.{ .of(.int, try c.b.int(0)), .of(.gt, 0) });
}

fn val(c: *Compiler, out: *Terms, e: *const ast.Expr) Error!void {
    switch (e.kind) {
        .name, .int => try named(c, out, e),
        .string => |s| try out.append(c.arena, .of(.text, try c.b.literal(s))),
        .boolean => |b| try out.append(c.arena, .of(if (b) .true else .false, 0)),
        .call => |*call| try calls(c, out, e, call),
        .not => |inner| {
            try cond(c, out, inner);
            try out.append(c.arena, .of(.not, 0));
        },
        .binary => |b| {
            const both_conditions = b.op == .@"and" or b.op == .@"or";
            if (both_conditions) {
                try cond(c, out, b.lhs);
                try cond(c, out, b.rhs);
            } else {
                try val(c, out, b.lhs);
                try val(c, out, b.rhs);
            }
            try out.append(c.arena, .of(op(b.op), 0));
        },
    }
}

fn op(o: ast.Expr.Op) Term.Op {
    return switch (o) {
        inline else => |t| @field(Term.Op, @tagName(t)),
    };
}

// A name, or a number that may name a value of an enumeration: what the checker said it is.
fn named(c: *Compiler, out: *Terms, e: *const ast.Expr) Error!void {
    const t = typed(c, e);
    const ref = t.ref orelse {
        std.debug.assert(e.kind == .int);
        return out.append(c.arena, .of(.int, try c.b.int(e.kind.int)));
    };
    try out.append(c.arena, switch (ref) {
        .fact => |id| .of(.fact, c.fact(id).raw()),
        .constant => |id| return constant(c, out, c.checked.consts[id.raw()].value),
        .value => |v| Term.item(c.enums[v.enumeration.raw()].raw(), @intCast(v.index)), // safe: an enumeration holds at most 256 values
        .visits => |id| .of(.fact, c.visits[id.raw()].raw()),
        .thing => |th| .of(.thing, try c.b.thing(c.kinds[th.kind.raw()], th.id)),
        else => unreachable, // unreachable: a name in an expression is a fact, a constant, a value, a visit count or a thing
    });
}

pub fn constant(c: *Compiler, out: *Terms, k: sym.Constant) Error!void {
    try out.append(c.arena, switch (k) {
        .boolean => |b| .of(if (b) .true else .false, 0),
        .int => |n| .of(.int, try c.b.int(n)),
        .text => |s| .of(.text, try c.b.literal(s)),
    });
}

fn calls(c: *Compiler, out: *Terms, e: *const ast.Expr, call: *const ast.Call) Error!void {
    const ref = typed(c, e).ref orelse unreachable; // unreachable: a call the checker passed names something
    switch (ref) {
        .visits => |id| try out.append(c.arena, .of(.fact, c.visits[id.raw()].raw())),
        .query => |id| {
            for (call.args) |*a| try val(c, out, a);
            try out.append(c.arena, .of(.query, c.externs[id.raw()].raw()));
        },
        .builtin => |b| try out.append(c.arena, .of(.builtin, try builtin(c, b))),
        .happened => |m| try out.append(c.arena, .of(.happened, c.fact(m).raw())),
        .keyed => |f| {
            try val(c, out, &call.args[0]);
            try out.append(c.arena, .of(.keyed, c.fact(f).raw()));
        },
        .since_changed => |w| try out.append(c.arena, .of(.since_changed, try c.b.sinceChanged(c.fact(w.fact), c.fact(w.clock)))),
        else => unreachable, // unreachable: a call in an expression is `seen`, `since_changed`, `happened`, a fact kept per thing, a query or a builtin
    }
}

// A builtin's call record: what each argument names, as the format says. A part is the section it compiles to.
fn builtin(c: *Compiler, b: sym.BuiltinRef) Error!u24 {
    const kind = c.checked.registered[b.kind];
    const def = kind.builtins[b.builtin];
    const args = try c.arena.alloc(u32, b.args.len);
    for (b.args, args) |a, *out| out.* = switch (a) {
        .part => |p| (c.part(p) orelse unreachable).raw(), // unreachable: a builtin's parts are a registered kind's, which compile to sections
        .section => |id| c.section(id).raw(),
        .fact => |id| c.fact(id).raw(),
    };
    return c.b.builtinCall(kind.name, def.name, args, switch (def.returns) {
        .boolean => .boolean,
        .int => .int,
    });
}
