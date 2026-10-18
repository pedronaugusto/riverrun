//! Flow: where `->`, `->>` and `<-` go, and whether the story holds
//! together as a graph.
//!
//! - A target is, nearest first, `end`, a label of the body it is in, a part
//!   of its section, or a section. A pool is called, never gone to, and its
//!   candidates are the pool's to pick.
//! - No scene runs off its end: every way through it ends in `-> end`, `<-`
//!   or a flow elsewhere, unless a tag that leads hands its end to the host.
//!   A scene with parts and no body of its own opens with its first part.
//!   A pool's candidate ends by going back to whoever asked the pool. A kind
//!   the host registers is the host's to run.
//! - A choice point goes on past its choices if any choice's body does; when
//!   every open choice has been taken, that is the runtime's to report.
//! - Every section is reached from where the story starts: the host's
//!   entries, or else every section nothing else leads to. Tags typed as
//!   sections are edges, so a section only a mechanic leads to is reached.

const std = @import("std");
const syntax = @import("../syntax.zig");
const sym = @import("symbols.zig");
const Checker = @import("Checker.zig");
const exprs = @import("exprs.zig");

const ast = syntax.ast;
const Error = Checker.Error;

/// Resolves a flow written at `span` in `scope`.
pub fn resolve(c: *Checker, scope: exprs.Scope, f: *const ast.Flow, span: syntax.Span) Error!void {
    switch (f.*) {
        .ret => {
            const first = try c.returns.getOrPut(c.arena, scope.section);
            if (!first.found_existing) first.value_ptr.* = span;
        },
        .jump => |*n| try go(c, scope, n, .jump),
        .call => |*n| try go(c, scope, n, .call),
    }
}

fn go(c: *Checker, scope: exprs.Scope, n: *const ast.Name, how: enum { jump, call }) Error!void {
    const t = find(c, scope, n.text) orelse {
        return c.err(n.span, "nothing is called `{s}`: no section, part of this one, or label here", .{n.text});
    };
    switch (t) {
        .end => if (how == .call) return c.err(n.span, "`end` is gone to, `-> end`; it cannot be called", .{}),
        .label => if (how == .call) return c.err(n.span, "`{s}` is a label: go to it with `->`; `->>` calls a section", .{n.text}),
        .part => |p| {
            const s = c.section(p.section);
            if (s.kind == .pool) return c.err(n.span, "`{s}` is a candidate of the pool `{s}`, which picks it", .{ n.text, s.name });
            s.parts[p.index].reached = true;
        },
        .section => |id| {
            const s = c.section(id);
            if (how == .jump and s.kind == .pool) return c.err(n.span, "`{s}` is a pool: call it, `->> {s}`, and it gives its lines and comes back", .{ n.text, n.text });
            if (how == .call) s.called = true;
            try c.edge(scope.section, id, if (how == .call) .call else .jump);
        },
    }
    try c.names.put(c.arena, n, .{ .target = t });
}

fn find(c: *const Checker, scope: exprs.Scope, name: []const u8) ?sym.Target {
    if (std.mem.eql(u8, name, "end")) return .end;
    const s = &c.sections.items[scope.section.raw()];
    const here = if (scope.part) |p| s.parts[p].labels else s.labels;
    for (here) |l| if (std.mem.eql(u8, c.labels.items[l.raw()].name, name)) return .{ .label = l };
    for (s.parts, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) {
        return .{ .part = .{ .section = scope.section, .index = @intCast(i) } }; // safe: parts were numbered in u16
    };
    const other = c.section_names.find(scope.module, name) orelse return null;
    return .{ .section = other };
}

// ---------------------------------------------------------------- the graph

/// Run once every flow is resolved and every tag checked.
pub fn run(c: *Checker) Error!void {
    for (0..c.sections.items.len) |i| try ends(c, sym.idOf(sym.SectionId, i));
    try reach(c);
    var it = c.returns.iterator();
    while (it.next()) |r| {
        const s = c.section(r.key_ptr.*);
        if (!s.called) try c.warn(r.value_ptr.*, "`<-` goes back to a caller, but nothing calls `{s}` with `->>`", .{s.name});
    }
    for (c.sections.items) |s| if (s.kind == .scene) for (s.parts) |p| {
        if (!p.reached) try c.warn(p.node.name.span, "nothing goes to the part `{s}` of `{s}`", .{ p.name, s.name });
    };
}

fn ends(c: *Checker, id: sym.SectionId) Error!void {
    const s = c.section(id);
    const node = s.node;
    switch (s.kind) {
        .scene => {
            if (node.body.len == 0 and s.parts.len > 0) {
                s.parts[0].reached = true;
            } else if (!try gone(c, node.body) and !s.leads) {
                try c.err(node.name.span, "the scene `{s}` can run off its end: end it with `-> end`, `<-` or a flow elsewhere", .{s.name});
            }
            for (s.parts) |p| if (!try gone(c, p.node.body)) {
                try c.err(p.node.name.span, "the part `{s}` can run off its end: end it with `-> end`, `<-` or a flow elsewhere", .{p.name});
            };
        },
        .pool, .other => {
            _ = try gone(c, node.body);
            for (s.parts) |p| _ = try gone(c, p.node.body);
        },
    }
}

/// Whether every way through `body` goes elsewhere before its end. What
/// follows a statement that always goes elsewhere is reported unreached,
/// unless a label lets flow back in.
fn gone(c: *Checker, body: []const ast.Stmt) Error!bool {
    var away = false;
    var i: usize = 0;
    while (i < body.len) {
        const s = &body[i];
        if (away) {
            const labelled = s.kind == .gather and s.kind.gather.label != null;
            if (!labelled) {
                try c.warn(s.span, "nothing reaches this: the story always goes elsewhere before it", .{});
                return true;
            }
        }
        if (s.kind == .choice) {
            // a choice point: the choices written together
            away = true;
            while (i < body.len and body[i].kind == .choice) : (i += 1) {
                if (!try gone(c, body[i].kind.choice.body)) away = false;
            }
            continue;
        }
        away = try stmtGone(c, s);
        i += 1;
    }
    return away;
}

fn stmtGone(c: *Checker, s: *const ast.Stmt) Error!bool {
    return switch (s.kind) {
        .line, .effect => false,
        .cond => |k| {
            _ = try gone(c, k.body);
            return false;
        },
        .gather => |g| if (g.then) |then| stmtGone(c, then) else false,
        .flow => |f| f != .call,
        .flow_if => |f| f.then != .call and f.otherwise != .call,
        .choice => unreachable, // a choice point is read whole by `gone`
    };
}

fn reach(c: *Checker) Error!void {
    const n = c.sections.items.len;
    if (n == 0) return;
    var reached = try std.DynamicBitSetUnmanaged.initEmpty(c.arena, n);
    var queue: std.ArrayList(sym.SectionId) = .empty;
    if (c.options.entries.len > 0) {
        for (c.options.entries) |name| {
            const id = c.section_names.find(sym.root, name) orelse {
                try c.err(.none, "the host starts the story at `{s}`, and the story has no such section", .{name});
                continue;
            };
            try c.entries.append(c.arena, id);
        }
    } else {
        var led = try std.DynamicBitSetUnmanaged.initEmpty(c.arena, n);
        for (c.edges.items) |e| if (!e.from.eql(e.to)) led.set(e.to.raw());
        for (0..n) |i| if (!led.isSet(i)) try c.entries.append(c.arena, sym.idOf(sym.SectionId, i));
    }
    for (c.entries.items) |id| if (!reached.isSet(id.raw())) {
        reached.set(id.raw());
        try queue.append(c.arena, id);
    };
    const edges = try c.arena.dupe(sym.Edge, c.edges.items);
    std.mem.sort(sym.Edge, edges, {}, struct {
        fn less(_: void, a: sym.Edge, b: sym.Edge) bool {
            return a.from.raw() < b.from.raw();
        }
    }.less);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const from = queue.items[head];
        var k = lowerBound(edges, from);
        while (k < edges.len and edges[k].from.eql(from)) : (k += 1) {
            const to = edges[k].to;
            if (reached.isSet(to.raw())) continue;
            reached.set(to.raw());
            try queue.append(c.arena, to);
        }
    }
    for (c.sections.items, 0..) |s, i| if (!reached.isSet(i)) {
        try c.err(s.node.name.span, "nothing reaches `{s}` from where the story starts", .{s.name});
    };
}

fn lowerBound(edges: []const sym.Edge, from: sym.SectionId) usize {
    var lo: usize = 0;
    var hi = edges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (edges[mid].from.raw() < from.raw()) lo = mid + 1 else hi = mid;
    }
    return lo;
}
