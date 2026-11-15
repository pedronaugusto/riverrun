//! Statements into steps. A body is compiled from its last statement to its
//! first, each step pointing at the one after it, so every edge is known
//! when its step is made: `next` is where the flow goes after a statement,
//! and null hands the flow back (a section that runs out returns). Choices
//! written together are one choices step, each body going on to what follows
//! them; a condition is a branch; a labelled gather is the step reserved for
//! its label, so a jump to it from anywhere is the step itself.

const std = @import("std");
const syntax = @import("../syntax.zig");
const check = @import("../check.zig");
const story = @import("riverrun").story;
const Compiler = @import("Compiler.zig");
const exprs = @import("exprs.zig");
const text = @import("text.zig");

const sym = check.symbols;
const ast = syntax.ast;
const Error = Compiler.Error;
const Next = ?story.NodeId;

/// The first step of `stmts`, which go on to `next`; `next` itself when there are none.
pub fn chain(c: *Compiler, stmts: []const ast.Stmt, next: Next) Error!Next {
    var after = next;
    var i = stmts.len;
    while (i > 0) {
        i -= 1;
        const kind = std.meta.activeTag(stmts[i].kind);
        if (kind == .choice or kind == .effect) {
            // a run of choices is one point; a run of effects one step
            var j = i;
            while (j > 0 and std.meta.activeTag(stmts[j - 1].kind) == kind) j -= 1;
            after = if (kind == .choice) try choices(c, stmts[j .. i + 1], after) else try effectRun(c, stmts[j .. i + 1], after);
            i = j;
            continue;
        }
        after = try stmt(c, &stmts[i], after);
    }
    return after;
}

fn stmt(c: *Compiler, s: *const ast.Stmt, after: Next) Error!Next {
    c.at = s.span;
    switch (s.kind) {
        .line => |*l| return try line(c, s, l, after),
        .cond => |*k| {
            const then = if (k.on_row) try stmt(c, &k.body[0], after) else try chain(c, k.body, after);
            const otherwise = if (k.otherwise.len > 0) try chain(c, k.otherwise, after) else after;
            return try c.node(.{ .step = .{ .branch = .{ .cond = try exprs.condition(c, &k.cond), .then = then, .otherwise = otherwise } } });
        },
        .gather => |*g| {
            const then = if (g.then) |t| try stmt(c, t, after) else after;
            if (g.label == null) return then;
            const l = labelOf(c, s);
            const id = c.labels[l.raw()];
            try c.define(id, .{ .step = .{ .gather = .{ .visits = c.visits[c.checked.labels[l.raw()].visit.raw()].?, .next = then } } });
            return id;
        },
        .effect => return try effectRun(c, s[0..1], after),
        .flow => |*f| return try flow(c, f, after),
        .flow_if => |*f| return try c.node(.{ .step = .{ .branch = .{
            .cond = try exprs.condition(c, &f.cond),
            .then = try flow(c, &f.then, after),
            .otherwise = try flow(c, &f.otherwise, after),
        } } }),
        .choice => return try choices(c, s[0..1], after),
    }
}

fn line(c: *Compiler, s: *const ast.Stmt, l: *const ast.Line, after: Next) Error!Next {
    const speaker: ?story.CastId = if (l.speaker) |*who| switch (c.checked.names.get(who) orelse unreachable) { // unreachable: the checker resolved every speaker
        .speaker => |id| c.cast[id.raw()],
        else => unreachable, // unreachable: a speaker names a speaker
    } else null;
    const effects = try effectList(c, l.effects);
    return try c.node(.{ .tags = try c.tags(c.checked.tagsOf(s), c.lineId(s)), .step = .{ .line = .{ .text = try text.text(c, c.lineId(s), l.text), .speaker = speaker, .effects = effects, .next = after } } });
}

fn choices(c: *Compiler, stmts: []const ast.Stmt, after: Next) Error!story.NodeId {
    const list = try c.arena.alloc(story.Choice, stmts.len);
    const spans = try c.arena.alloc(syntax.Span, stmts.len);
    for (stmts, list, spans) |*s, *out, *span| {
        span.* = s.span;
        const ch = &s.kind.choice;
        const id = c.lineId(s);
        const target = try chain(c, ch.body, after) orelse try c.back();
        c.at = s.span;
        out.* = .{
            .text = try text.text(c, id, ch.text),
            .cond = if (ch.cond) |*k| try exprs.condition(c, k) else .empty,
            .sticky = ch.sticky,
            .visits = try c.b.visits(try c.arena.print("*{s}", .{id})),
            .tags = try c.tags(c.checked.tagsOf(s), id),
            .target = target,
        };
    }
    c.at = stmts[0].span;
    return c.node(.{ .step = .{ .choices = .{ .choices = try c.choiceList(list, spans), .next = after } } });
}

fn effectRun(c: *Compiler, stmts: []const ast.Stmt, after: Next) Error!story.NodeId {
    c.at = stmts[0].span.join(stmts[stmts.len - 1].span);
    return c.node(.{ .step = .{ .effects = .{ .effects = try effectList(c, stmts), .next = after } } });
}

fn effectList(c: *Compiler, stmts: []const ast.Stmt) Error!story.Range {
    if (stmts.len == 0) return .empty;
    const list = try c.arena.alloc(story.Effect, stmts.len);
    const spans = try c.arena.alloc(syntax.Span, stmts.len);
    // each effect compiled where it is written, and the step it is of where that is
    const at = c.at;
    defer c.at = at;
    for (stmts, list, spans) |*s, *out, *span| {
        c.at = s.span;
        span.* = s.span;
        out.* = try effect(c, &s.kind.effect);
    }
    return c.effectList(list, spans);
}

fn effect(c: *Compiler, e: *const ast.Effect) Error!story.Effect {
    switch (e.*) {
        .set => |*x| {
            const fact = factNamed(c, &x.fact);
            if (x.value.kind == .call) if (c.checked.names.get(&x.value.kind.call.name)) |r| if (r == .action) {
                // a check with an outcome: the host performs it and writes the result into the fact
                return .{ .call = .{ .action = c.externs[r.action.raw()], .args = try exprs.arguments(c, x.value.kind.call.args), .result = fact } };
            };
            // a fact kept per thing: its key's terms, then the value's
            if (x.key) |key| return .{ .set = .{ .fact = fact, .value = try exprs.pair(c, key, &x.value) } };
            if (own(c, &x.fact)) |id| {
                var terms: exprs.Terms = .empty;
                try terms.append(c.arena, exprs.this(c, id));
                try exprs.into(c, &terms, &x.value);
                return .{ .set = .{ .fact = fact, .value = try c.expr(terms.items) } };
            }
            return .{ .set = .{ .fact = fact, .value = try exprs.value(c, &x.value) } };
        },
        .add, .remove => |*x| return change(c, x, e.* == .remove),
        .call => |*call| {
            const r = c.checked.names.get(&call.name) orelse unreachable; // unreachable: the checker resolved every action
            return .{ .call = .{ .action = c.externs[r.action.raw()], .args = try exprs.arguments(c, call.args) } };
        },
    }
}

// `+=` and `-=`: a set's item, or an int's amount, taken from 0 for `-=`.
fn change(c: *Compiler, x: *const ast.Change, minus: bool) Error!story.Effect {
    const fact = factNamed(c, &x.fact);
    const typed = c.checked.exprs.get(&x.amount) orelse unreachable; // unreachable: the checker typed the amount
    if (typed.type == .one_of) {
        const item: u8 = @intCast(typed.ref.?.value.index); // safe: an enumeration holds at most 256 values
        const key: story.Range = if (x.key) |k| try exprs.value(c, k) else if (own(c, &x.fact)) |id| try c.expr(&.{exprs.this(c, id)}) else .empty;
        return if (minus) .{ .remove = .{ .fact = fact, .item = item, .key = key } } else .{ .add = .{ .fact = fact, .item = item, .key = key } };
    }
    var terms: exprs.Terms = .empty;
    if (x.key) |k| try exprs.into(c, &terms, k) else if (own(c, &x.fact)) |id| try terms.append(c.arena, exprs.this(c, id));
    if (minus) try terms.append(c.arena, .of(.int, try c.b.int(0)));
    try exprs.into(c, &terms, &x.amount);
    if (minus) try terms.append(c.arena, .of(.sub, 0));
    return .{ .change = .{ .fact = fact, .by = try c.expr(terms.items) } };
}

fn factNamed(c: *const Compiler, n: *const ast.Name) story.FactId {
    const r = c.checked.names.get(n) orelse unreachable; // unreachable: the checker resolved every fact an effect writes
    return c.fact(if (r == .own) r.own else r.fact);
}

// The section's own fact an effect writes for the thing the section is evaluated for, if it writes one so.
fn own(c: *const Compiler, n: *const ast.Name) ?sym.FactId {
    const r = c.checked.names.get(n) orelse return null;
    return if (r == .own) r.own else null;
}

// Where a flow goes: a step that goes there, or the step itself for a label.
fn flow(c: *Compiler, f: *const ast.Flow, after: Next) Error!Next {
    switch (f.kind) {
        .ret => return try c.node(.{ .step = .ret }),
        .jump => |*n| return switch (targetOf(c, n)) {
            .end => try c.node(.{ .step = .end }),
            .section => |id| try c.node(.{ .step = .{ .jump = c.section(id) } }),
            .part => |p| try c.node(.{ .step = .{ .jump = c.part(p).? } }),
            .label => |id| c.labels[id.raw()],
        },
        .call => |*n| {
            const to = switch (targetOf(c, n)) {
                .section => |id| c.section(id),
                .part => |p| c.part(p).?,
                .end, .label => unreachable, // unreachable: the checker refuses calling `end` or a label
            };
            return try c.node(.{ .step = .{ .call = .{ .section = to, .next = after } } });
        },
    }
}

fn targetOf(c: *const Compiler, n: *const ast.Name) sym.Target {
    const r = c.checked.names.get(n) orelse unreachable; // unreachable: the checker resolved every flow's target
    return r.target;
}

// The label a gather declares, found by the statement the checker numbered it with.
fn labelOf(c: *const Compiler, s: *const ast.Stmt) sym.LabelId {
    for (c.checked.labels, 0..) |l, i| if (l.stmt == s) return sym.idOf(sym.LabelId, i);
    unreachable; // unreachable: every labelled gather was numbered by the checker
}
