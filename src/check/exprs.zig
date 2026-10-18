//! Expressions, effects and text, typed. A name in an expression is a fact
//! or a constant, or, where the other side of a comparison or a parameter
//! says which enumeration is wanted, one of its values: `life = go`,
//! `kept has dad`, `lived(go)`. A query is asked with its arguments; `seen(x)`
//! reads the visit count of a section, a part or a label, a number that is
//! true in a condition once it is above zero. Every node is recorded with its
//! type and what it names.

const std = @import("std");
const syntax = @import("../syntax.zig");
const sym = @import("symbols.zig");
const Checker = @import("Checker.zig");

const ast = syntax.ast;
const Error = Checker.Error;

/// Where an expression is: the module its names are looked up in, and the
/// section and part whose labels and parts `seen` can name.
pub const Scope = struct {
    module: sym.ModuleId,
    section: sym.SectionId,
    part: ?u16,
};

/// A condition: true or false, or a visit count.
pub fn condition(c: *Checker, scope: Scope, e: *const ast.Expr) Error!void {
    const t = try infer(c, scope, e, .boolean) orelse return;
    if (t == .boolean) return;
    if (t == .int and isVisits(c, e)) return;
    try c.err(e.span, "a condition is true or false; this is {s}", .{try c.describe(t)});
}

/// An expression whose type must be `want`.
pub fn value(c: *Checker, scope: Scope, e: *const ast.Expr, want: sym.Type) Error!void {
    const t = try infer(c, scope, e, want) orelse return;
    if (t.eql(want)) return;
    try c.err(e.span, "this is {s}, where {s} is wanted", .{ try c.describe(t), try c.describe(want) });
}

/// Where an expression's words start: an operator's node is placed at the operator.
pub fn start(e: *const ast.Expr) syntax.Span {
    var at = e;
    while (at.kind == .binary) at = at.kind.binary.lhs;
    return at.span;
}

fn isVisits(c: *const Checker, e: *const ast.Expr) bool {
    const typed = c.exprs.get(e) orelse return false;
    const ref = typed.ref orelse return false;
    return ref == .visits;
}

fn record(c: *Checker, e: *const ast.Expr, t: sym.Type, ref: ?sym.Ref) Error!?sym.Type {
    try c.exprs.put(c.arena, e, .{ .type = t, .ref = ref });
    return t;
}

// The expression's type, or null once a problem in it is reported. `hint`
// is the type the context wants, which decides what a value's name means.
fn infer(c: *Checker, scope: Scope, e: *const ast.Expr, hint: ?sym.Type) Error!?sym.Type {
    switch (e.kind) {
        .int => |n| {
            // an enumeration may name a value with digits: `one of 1969, this_life`
            if (enumOf(hint)) |en| for (c.enums.items[en.raw()].values, 0..) |v, ix| {
                const as = std.fmt.parseInt(i64, v, 10) catch continue;
                if (as != n) continue;
                const index: u16 = @intCast(ix); // safe: an enumeration holds at most limits.values
                return record(c, e, .{ .one_of = en }, .{ .value = .{ .enumeration = en, .index = index } });
            };
            return record(c, e, .int, null);
        },
        .string => return record(c, e, .text, null),
        .boolean => return record(c, e, .boolean, null),
        .name => |n| return name(c, scope, e, n, hint),
        .call => |*call| return calls(c, scope, e, call),
        .not => |inner| {
            try condition(c, scope, inner);
            return record(c, e, .boolean, null);
        },
        .binary => |b| return binary(c, scope, e, b.op, b.lhs, b.rhs),
    }
}

fn enumOf(hint: ?sym.Type) ?sym.EnumId {
    const h = hint orelse return null;
    return if (h == .one_of) h.one_of else null;
}

fn name(c: *Checker, scope: Scope, e: *const ast.Expr, n: []const u8, hint: ?sym.Type) Error!?sym.Type {
    if (enumOf(hint)) |en| if (c.valueOf(en, n)) |ix| {
        return record(c, e, .{ .one_of = en }, .{ .value = .{ .enumeration = en, .index = ix } });
    };
    if (c.value_names.find(scope.module, n)) |named| switch (named) {
        .fact => |id| return record(c, e, c.facts.items[id.raw()].type, .{ .fact = id }),
        .constant => |id| return record(c, e, c.consts.items[id.raw()].type, .{ .constant = id }),
        .external => |id| {
            const what = if (c.externs.items[id.raw()].returns == null) "an action: it runs as an effect, `~ " else "a query: ask it as `";
            try c.err(e.span, "`{s}` is {s}{s}(…)`", .{ n, what, n });
            return null;
        },
    };
    if (enumOf(hint)) |en| {
        try c.err(e.span, "`{s}` is not one of {s}", .{ n, try c.valueList(en) });
    } else try c.err(e.span, "nothing is called `{s}`: no fact or constant", .{n});
    return null;
}

fn calls(c: *Checker, scope: Scope, e: *const ast.Expr, call: *const ast.Call) Error!?sym.Type {
    if (std.mem.eql(u8, call.name.text, "seen")) return seen(c, scope, e, call);
    const id = try externOf(c, scope, call) orelse return null;
    const ext = c.externs.items[id.raw()];
    const returns = ext.returns orelse {
        try c.err(e.span, "`{s}` is an action: it runs as an effect, `~ {s}(…)`, and gives no value", .{ ext.name, ext.name });
        return null;
    };
    try c.names.put(c.arena, &call.name, .{ .query = id });
    return record(c, e, returns, .{ .query = id });
}

/// The query or action a call names, its arguments checked against its parameters.
pub fn externOf(c: *Checker, scope: Scope, call: *const ast.Call) Error!?sym.ExternId {
    const named = c.value_names.find(scope.module, call.name.text) orelse {
        try c.err(call.name.span, "nothing is called `{s}`: no query or action", .{call.name.text});
        return null;
    };
    if (named != .external) {
        try c.err(call.name.span, "`{s}` is a fact or a constant, not a query or an action", .{call.name.text});
        return null;
    }
    const ext = c.externs.items[named.external.raw()];
    if (call.args.len != ext.params.len) {
        try c.err(call.name.span, "`{s}` takes {d} values, not {d}", .{ ext.name, ext.params.len, call.args.len });
        return null;
    }
    for (call.args, ext.params) |*arg, p| try value(c, scope, arg, p);
    return named.external;
}

fn seen(c: *Checker, scope: Scope, e: *const ast.Expr, call: *const ast.Call) Error!?sym.Type {
    if (call.args.len != 1 or call.args[0].kind != .name) {
        try c.err(e.span, "`seen` takes one name: a section, a part of this one, or a label", .{});
        return null;
    }
    const arg = &call.args[0];
    const visit = visitOf(c, scope, arg.kind.name) orelse {
        try c.err(arg.span, "`seen` counts visits to a section, a part or a label: nothing is called `{s}`", .{arg.kind.name});
        return null;
    };
    c.visits.items[visit.raw()].read = true;
    _ = try record(c, arg, .int, .{ .visits = visit });
    return record(c, e, .int, .{ .visits = visit });
}

// What `seen` can name, nearest first: a label here, a part of this section, a section.
fn visitOf(c: *const Checker, scope: Scope, n: []const u8) ?sym.VisitId {
    const s = &c.sections.items[scope.section.raw()];
    const here = if (scope.part) |p| s.parts[p].labels else s.labels;
    for (here) |l| if (std.mem.eql(u8, c.labels.items[l.raw()].name, n)) return c.labels.items[l.raw()].visit;
    for (s.parts) |p| if (std.mem.eql(u8, p.name, n)) return p.visit;
    const other = c.section_names.find(scope.module, n) orelse return null;
    return c.sections.items[other.raw()].visit;
}

fn binary(c: *Checker, scope: Scope, e: *const ast.Expr, op: ast.Expr.Op, lhs: *const ast.Expr, rhs: *const ast.Expr) Error!?sym.Type {
    switch (op) {
        .@"and", .@"or" => {
            try condition(c, scope, lhs);
            try condition(c, scope, rhs);
        },
        .eq, .ne => {
            // a value's name means nothing alone: type the other side first
            const swap = bare(c, scope, lhs) and !bare(c, scope, rhs);
            const first, const second = if (swap) .{ rhs, lhs } else .{ lhs, rhs };
            const a = try infer(c, scope, first, null) orelse return null;
            const b = try infer(c, scope, second, a) orelse return null;
            if (a == .set_of) {
                try c.err(e.span, "a set is asked with `has` and `hasnt`, not compared", .{});
                return null;
            }
            if (!a.eql(b)) {
                try c.err(e.span, "`{s}` compares like with like: {s} and {s}", .{ if (op == .eq) "=" else "!=", try c.describe(a), try c.describe(b) });
                return null;
            }
        },
        .has, .hasnt => {
            const a = try infer(c, scope, lhs, null) orelse return null;
            if (a != .set_of) {
                try c.err(lhs.span, "`{s}` asks a set; this is {s}", .{ @tagName(op), try c.describe(a) });
                return null;
            }
            try value(c, scope, rhs, .{ .one_of = a.set_of });
        },
    }
    return record(c, e, .boolean, null);
}

// A name or a number that means something only once the wanted type is known.
fn bare(c: *const Checker, scope: Scope, e: *const ast.Expr) bool {
    return switch (e.kind) {
        .int => true,
        .name => |n| c.value_names.find(scope.module, n) == null,
        else => false,
    };
}

// ---------------------------------------------------------------- effects and text

pub fn effect(c: *Checker, scope: Scope, eff: *const ast.Effect) Error!void {
    switch (eff.*) {
        .set => |*s| {
            const id = try settable(c, scope, &s.fact) orelse return;
            try value(c, scope, &s.value, c.facts.items[id.raw()].type);
        },
        .add => |*a| try item(c, scope, &a.fact, &a.item, "+="),
        .remove => |*r| try item(c, scope, &r.fact, &r.item, "-="),
        .call => |*call| {
            const id = try externOf(c, scope, call) orelse return;
            const ext = c.externs.items[id.raw()];
            if (ext.returns != null) return c.err(call.name.span, "`{s}` is a query: it answers in a condition, and an effect runs an action", .{ext.name});
            try c.names.put(c.arena, &call.name, .{ .action = id });
        },
    }
}

fn item(c: *Checker, scope: Scope, fact: *const ast.Name, it: *const ast.Name, op: []const u8) Error!void {
    const id = try settable(c, scope, fact) orelse return;
    const t = c.facts.items[id.raw()].type;
    if (t != .set_of) return c.err(fact.span, "`{s}` changes a set; `{s}` is {s}", .{ op, fact.text, try c.describe(t) });
    const ix = c.valueOf(t.set_of, it.text) orelse return c.err(it.span, "`{s}` is not in `{s}`: {s}", .{ it.text, fact.text, try c.valueList(t.set_of) });
    try c.names.put(c.arena, it, .{ .value = .{ .enumeration = t.set_of, .index = ix } });
}

// The fact an effect writes, if the story may write it.
fn settable(c: *Checker, scope: Scope, n: *const ast.Name) Error!?sym.FactId {
    const named = c.value_names.find(scope.module, n.text) orelse {
        try c.err(n.span, "nothing is called `{s}`: no fact", .{n.text});
        return null;
    };
    const id = switch (named) {
        .fact => |id| id,
        .constant => {
            try c.err(n.span, "`{s}` is a constant: it never changes", .{n.text});
            return null;
        },
        .external => {
            try c.err(n.span, "`{s}` is a query or an action, not a fact", .{n.text});
            return null;
        },
    };
    const f = &c.facts.items[id.raw()];
    if (f.game) {
        try c.err(n.span, "`{s}` is the game's, declared `(game)`: the story reads it and never sets it", .{n.text});
        return null;
    }
    f.set = true;
    try c.names.put(c.arena, n, .{ .fact = id });
    return id;
}

/// Text: what `{…}` says must be a fact or a constant that can be said, and words chosen by a condition are checked as both.
pub fn text(c: *Checker, scope: Scope, t: ast.Text) Error!void {
    for (t) |*piece| switch (piece.*) {
        .literal => {},
        .value => |*e| {
            if (e.kind != .name) return c.err(e.span, "`{{…}}` says a fact or a constant, by its name", .{});
            const typ = try infer(c, scope, e, null) orelse continue;
            if (typ == .set_of) try c.err(e.span, "`{s}` is a set, which cannot be said", .{e.kind.name});
        },
        .choose => |*ch| {
            try condition(c, scope, &ch.cond);
            try text(c, scope, ch.then);
            try text(c, scope, ch.otherwise);
        },
    };
}
