//! Flow: where `->`, `-> name ->` and `<-` go, and whether the story holds
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
//! - A choice point goes on past its choices where any choice's body does,
//!   and, as the runtime does, where every choice there can be used up or
//!   closed: a once-only choice whose body can lead the flow back to it, a
//!   choice whose condition the checker cannot show always holds. A sticky
//!   choice always open keeps the flow at its point. What follows is reached
//!   either way. A way past choices all used up by the section's own flows
//!   coming back (`-> ask`) can run off; one past choices closed, or used up
//!   only by way of another section or a caller, is not counted as running
//!   off: whether every condition can be false at once, or the flow comes
//!   back from elsewhere with a choice taken, is the game's to say.
//! - A way that runs off is reported at its last row, one error to a row,
//!   naming the scene or the part it runs off.
//! - Every section is reached from where the story starts: the host's
//!   entries, or else every section nothing else leads to, and every section
//!   of a registered kind, which its package runs. A rules section is reached
//!   by what its rules react to, and nothing goes to it. Tags typed as
//!   sections are edges, so a section only a mechanic leads to is reached.

const std = @import("std");
const syntax = @import("../syntax.zig");
const sym = @import("symbols.zig");
const Checker = @import("Checker.zig");
const exprs = @import("exprs.zig");
const verdict = @import("never.zig").verdict;

const ast = syntax.ast;
const Error = Checker.Error;

/// Resolves a flow written in `scope`.
pub fn resolve(c: *Checker, scope: exprs.Scope, f: *const ast.Flow) Error!void {
    switch (f.kind) {
        .ret => {
            const first = try c.returns.getOrPut(c.arena, scope.section);
            if (!first.found_existing) first.value_ptr.* = f.span;
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
        .label => if (how == .call) return c.err(n.span, "`{s}` is a label: go to it with `-> {s}`; `-> name ->` calls a section", .{ n.text, n.text }),
        .part => |p| {
            const s = c.section(p.section);
            if (s.kind == .pool) return c.err(n.span, "`{s}` is a candidate of the pool `{s}`, which picks it", .{ n.text, s.name });
            if (s.kind == .rules) return c.err(n.span, "`{s}` is a rule of `{s}`: it fires when its condition becomes true, and nothing goes to it", .{ n.text, s.name });
            s.parts[p.index].reached = true;
        },
        .section => |id| {
            const s = c.section(id);
            if (how == .jump and s.kind == .pool) return c.err(n.span, "`{s}` is a pool: call it, `-> {s} ->`, and it gives its lines and comes back", .{ n.text, n.text });
            if (s.kind == .rules) return c.err(n.span, "`{s}` holds rules: they fire when their conditions become true, and nothing goes to them", .{n.text});
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
    const other = c.sectionNamed(scope.module, name) orelse return null;
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
        if (!s.called) try c.warn(r.value_ptr.*, "`<-` goes back to a caller, but nothing calls `{s}` with `-> {s} ->`", .{ s.name, s.name });
    }
    for (c.sections.items) |s| if (s.kind == .scene) for (s.parts) |p| {
        if (!p.reached) try c.warn(p.node.name.span, "nothing goes to the part `{s}` of `{s}`", .{ p.name, s.name });
    };
}

fn ends(c: *Checker, id: sym.SectionId) Error!void {
    const s = c.section(id);
    // first every way the flow can take, to know where each choice point can be come back to; then the ways again,
    // each point passed where its choices can be used up, reporting what runs off and what nothing reaches
    var g: Graph = try .init(c, id);
    for ([_]bool{ true, false }) |first| {
        g.first = first;
        const node = s.node;
        switch (s.kind) {
            .scene => {
                if (node.body.len == 0 and s.parts.len > 0) {
                    s.parts[0].reached = true;
                } else {
                    const off = try g.walked(0, node.body, c.row(node.name.span));
                    if (!first and !s.leads) for (off) |at| {
                        try c.err(at, "the scene `{s}` can run off its end after this row: end it with `-> end`, `<-` or a flow elsewhere", .{s.name});
                    };
                }
                for (s.parts, 1..) |p, i| {
                    const off = try g.walked(i, p.node.body, c.row(p.node.name.span));
                    if (!first) for (off) |at| {
                        try c.err(at, "the part `{s}` can run off its end after this row: end it with `-> end`, `<-` or a flow elsewhere", .{p.name});
                    };
                }
            },
            .pool, .rules, .other => {
                _ = try g.walked(0, node.body, c.row(node.name.span));
                for (s.parts, 1..) |p, i| _ = try g.walked(i, p.node.body, c.row(p.node.name.span));
            },
        }
    }
}

/// A section's places a flow comes in at, its entries: its body (0), each part (1 to n), each label (after the
/// parts); where the flow can go from each, and which entries each choice point can be reached from.
const Graph = struct {
    c: *Checker,
    section: sym.SectionId,
    /// The first walk, which only gathers the edges and what reaches each point, every point passed that can be.
    first: bool = true,
    count: usize,
    labels: []const sym.LabelId,
    /// Where the flow goes from each entry; `far` where it goes by way of another section or a caller.
    edges: std.ArrayList(struct { from: usize, to: usize, far: bool }) = .empty,
    reach: std.AutoHashMapUnmanaged(*const ast.Stmt, std.DynamicBitSetUnmanaged) = .empty,

    fn init(c: *Checker, id: sym.SectionId) Error!Graph {
        const s = c.section(id);
        var labels: std.ArrayList(sym.LabelId) = .empty;
        try labels.appendSlice(c.arena, s.labels);
        for (s.parts) |p| try labels.appendSlice(c.arena, p.labels);
        return .{ .c = c, .section = id, .count = 1 + s.parts.len + labels.items.len, .labels = labels.items };
    }

    fn entryOfLabel(g: *const Graph, l: sym.LabelId) usize {
        for (g.labels, 0..) |x, i| if (x.eql(l)) return 1 + g.c.section(g.section).parts.len + i;
        return 0;
    }

    const Entry = struct { at: usize, far: bool };

    // Where a flow written in this section comes in, if it comes in here at all: by this section's own flows, or
    // `far`, by way of another section that leads back here or of a caller that may call it again.
    fn entryOf(g: *const Graph, f: *const ast.Flow) ?Entry {
        const c = g.c;
        return switch (f.kind) {
            // a caller may call the section again, and it starts from its body
            .ret => if (c.section(g.section).called) .{ .at = 0, .far = true } else null,
            .jump, .call => |*n| switch (c.names.get(n) orelse return null) {
                .target => |t| switch (t) {
                    .end => null,
                    .label => |l| .{ .at = g.entryOfLabel(l), .far = false },
                    .part => |p| if (p.section.eql(g.section)) .{ .at = 1 + @as(usize, p.index), .far = false } else null,
                    .section => |to| if (to.eql(g.section)) .{ .at = 0, .far = false } else if (leadsTo(c, to, g.section)) .{ .at = 0, .far = true } else null,
                },
                else => null,
            },
        };
    }

    // The label a gather declares, among this section's.
    fn labelAt(g: *const Graph, s: *const ast.Stmt) ?sym.LabelId {
        for (g.labels) |l| if (g.c.labels.items[l.raw()].stmt == s) return l;
        return null;
    }

    // The entries the flows written in `s` and under it come in at; by this section's own flows alone when `local`.
    fn targetsOf(g: *const Graph, s: *const ast.Stmt, local: bool, out: *std.DynamicBitSetUnmanaged) void {
        switch (s.kind) {
            .line, .effect => {},
            .flow => |*f| g.target(f, local, out),
            .flow_if => |*f| {
                g.target(&f.then, local, out);
                g.target(&f.otherwise, local, out);
            },
            .cond => |k| for ([_][]const ast.Stmt{ k.body, k.otherwise }) |list| for (list) |*x| g.targetsOf(x, local, out),
            .gather => |gather| if (gather.then) |t| g.targetsOf(t, local, out),
            .choice => |ch| for (ch.body) |*x| g.targetsOf(x, local, out),
        }
    }

    fn target(g: *const Graph, f: *const ast.Flow, local: bool, out: *std.DynamicBitSetUnmanaged) void {
        if (f.kind == .call) return;
        const e = g.entryOf(f) orelse return;
        if (!(local and e.far)) out.set(e.at);
    }

    fn walked(g: *Graph, entry: usize, body: []const ast.Stmt, head: syntax.Span) Error![]const syntax.Span {
        var w: Ways = try .init(g);
        try w.add(head);
        w.from.set(entry);
        try w.body(body);
        return w.ends.items;
    }

    // Whether the entries in `targets` lead, by the section's flows (its own alone when `local`), to an entry
    // `point` is reached from.
    fn leadsBack(g: *const Graph, targets: *const std.DynamicBitSetUnmanaged, point: *const ast.Stmt, local: bool) Error!bool {
        const from = g.reach.get(point) orelse return false;
        var seen = try targets.clone(g.c.arena);
        var grew = true;
        while (grew) {
            grew = false;
            for (g.edges.items) |e| if (!(local and e.far) and seen.isSet(e.from) and !seen.isSet(e.to)) {
                seen.set(e.to);
                grew = true;
            };
        }
        var it = from.iterator(.{});
        while (it.next()) |i| if (seen.isSet(i)) return true;
        return false;
    }
};

/// The ways the flow comes to a point of a body, each by the last row it came from, and the entries it can have
/// come in at.
const Ways = struct {
    g: *Graph,
    ends: std.ArrayList(syntax.Span) = .empty,
    from: std.DynamicBitSetUnmanaged,
    /// The flow may also come here past a choice point whose choices were closed, by no way the run-off check
    /// counts: whether every choice there can be closed at once is the game's facts' to say.
    quiet: bool = false,
    /// Set once something no way reaches has been reported in this walk, so it is reported once.
    unreached: bool = false,

    fn init(g: *Graph) Error!Ways {
        return .{ .g = g, .from = try .initEmpty(g.c.arena, g.count) };
    }

    fn add(w: *Ways, at: syntax.Span) Error!void {
        for (w.ends.items) |e| if (e.file == at.file and e.start == at.start and e.end == at.end) return;
        try w.ends.append(w.g.c.arena, at);
    }

    fn only(w: *Ways, at: syntax.Span) Error!void {
        w.ends.clearRetainingCapacity();
        w.quiet = false;
        try w.add(at);
    }

    fn away(w: *Ways) void {
        w.ends.clearRetainingCapacity();
        w.quiet = false;
        w.from.unsetAll();
    }

    fn reached(w: *const Ways) bool {
        return w.ends.items.len > 0 or w.quiet;
    }

    // Another set of ways joined into these.
    fn join(w: *Ways, other: *const Ways) Error!void {
        for (other.ends.items) |e| try w.add(e);
        w.quiet = w.quiet or other.quiet;
        w.from.setUnion(other.from);
        w.unreached = w.unreached or other.unreached;
    }

    fn branch(w: *const Ways, at: syntax.Span) Error!Ways {
        var b: Ways = try .init(w.g);
        b.from.setUnion(w.from);
        try b.add(at);
        return b;
    }

    fn body(w: *Ways, stmts: []const ast.Stmt) Error!void {
        var i: usize = 0;
        while (i < stmts.len) {
            const s = &stmts[i];
            if (s.kind == .gather) if (s.kind.gather.label) |_| {
                // a label lets flow back in
                if (w.g.labelAt(s)) |l| w.from.set(w.g.entryOfLabel(l));
                if (!w.reached()) try w.add(w.g.c.row(s.span));
            };
            if (!w.reached()) {
                if (!w.unreached and !w.g.first) try w.g.c.warn(s.span, "nothing reaches this: the story always goes elsewhere before it", .{});
                w.unreached = true;
                return;
            }
            // a choice point: the choices written together at one depth, the first of them on a gather's row or not
            const gathered: ?*const ast.Stmt = if (s.kind == .gather) if (s.kind.gather.then) |t| (if (t.kind == .choice) t else null) else null else null;
            if (s.kind == .choice or gathered != null) {
                if (gathered != null) try w.only(w.g.c.row(s.span));
                var j = i + @intFromBool(gathered != null);
                while (j < stmts.len and stmts[j].kind == .choice) j += 1;
                const first = i + @intFromBool(gathered != null);
                const list = try w.g.c.arena.alloc(*const ast.Stmt, j - first + @intFromBool(gathered != null));
                if (gathered) |g| list[0] = g;
                for (list[@intFromBool(gathered != null)..], stmts[first..j]) |*out, *x| out.* = x;
                try w.point(list);
                i = j;
                continue;
            }
            try w.stmt(s);
            i += 1;
        }
    }

    fn flow(w: *Ways, f: *const ast.Flow) Error!void {
        if (w.g.first) if (w.g.entryOf(f)) |to| {
            var it = w.from.iterator(.{});
            while (it.next()) |e| try w.g.edges.append(w.g.c.arena, .{ .from = e, .to = to.at, .far = to.far });
        };
    }

    fn stmt(w: *Ways, s: *const ast.Stmt) Error!void {
        const c = w.g.c;
        switch (s.kind) {
            .line, .effect => try w.only(c.row(s.span)),
            .flow => |*f| {
                try w.flow(f);
                if (f.kind == .call) try w.only(c.row(s.span)) else w.away();
            },
            .flow_if => |*f| {
                try w.flow(&f.then);
                try w.flow(&f.otherwise);
                if (f.then.kind == .call or f.otherwise.kind == .call) try w.only(c.row(s.span)) else w.away();
            },
            .cond => |k| {
                // gated, the block may not run; with `{ else }`, one of the two always does
                const at = c.row(s.span);
                var then = try w.branch(at);
                try then.body(k.body);
                if (k.otherwise.len == 0) {
                    try w.only(at);
                } else {
                    var otherwise = try w.branch(if (k.else_span) |e| c.row(e) else at);
                    try otherwise.body(k.otherwise);
                    w.away();
                    try w.join(&otherwise);
                }
                try w.join(&then);
            },
            .gather => |g| {
                try w.only(c.row(s.span));
                // a statement on the gather's row, a choice among them (`- (ask) * Run.`), comes after it
                if (g.then) |then| try w.stmt(then);
            },
            .choice => try w.point(&.{s}),
        }
    }

    // A choice point: each choice's body runs from its row, and the flow goes past the point, from its last
    // choice's row, when every choice there can be used up or closed, as the runtime goes past choices when none is
    // open.
    fn point(w: *Ways, choices: []const *const ast.Stmt) Error!void {
        const g = w.g;
        const c = g.c;
        const key = choices[0];
        if (g.first) {
            const got = try g.reach.getOrPut(c.arena, key);
            if (!got.found_existing) got.value_ptr.* = try .initEmpty(c.arena, g.count);
            got.value_ptr.setUnion(w.from);
        }
        var after: Ways = try .init(g);
        var used = true;
        var passes = true;
        for (choices) |s| {
            const ch = &s.kind.choice;
            var way = try w.branch(c.row(s.span));
            way.ends.clearRetainingCapacity();
            try way.add(c.row(s.span));
            try way.body(ch.body);
            try after.join(&way);
            // used up by the section's own flows coming back, a way the run-off check counts; by another section or
            // a caller, a way the flow may come, which only what is reached counts
            const near = !ch.sticky and try w.comesBack(ch.body, key, true);
            const far = !ch.sticky and (near or try w.comesBack(ch.body, key, false));
            used = used and near;
            passes = passes and (far or closable(c, ch));
        }
        // used up, the point is passed by a way of the story's own; closed, by the game's facts
        if (used) try after.add(c.row(choices[choices.len - 1].span)) else if (passes) after.quiet = true;
        if (passes) after.from.setUnion(w.from);
        w.away();
        try w.join(&after);
    }

    // Whether, once a choice is taken, the flow can come to its point again, so a choice taken once can be used up:
    // its body goes somewhere the section's flows (its own alone when `local`) lead back from to where the point is
    // reached. On the first walk every once-only choice is taken to come back, which only gathers more ways.
    fn comesBack(w: *const Ways, stmts: []const ast.Stmt, here: *const ast.Stmt, local: bool) Error!bool {
        const g = w.g;
        if (g.first) return true;
        var targets: std.DynamicBitSetUnmanaged = try .initEmpty(g.c.arena, g.count);
        for (stmts) |*s| g.targetsOf(s, local, &targets);
        if (targets.count() == 0) return false;
        return g.leadsBack(&targets, here, local);
    }
};

// A choice that can be closed: one with a condition the checker cannot show always holds.
fn closable(c: *const Checker, ch: *const ast.Choice) bool {
    const k = ch.cond orelse return false;
    return verdict(c, &k) != .yes;
}

// Whether the flow can go from section `from` to section `to` by the story's flows and the tags that lead.
fn leadsTo(c: *Checker, from: sym.SectionId, to: sym.SectionId) bool {
    if (from.eql(to)) return true;
    const n = c.sections.items.len;
    var seen = std.DynamicBitSetUnmanaged.initEmpty(c.arena, n) catch return true;
    var queue: std.ArrayList(sym.SectionId) = .empty;
    queue.append(c.arena, from) catch return true;
    seen.set(from.raw());
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const at = queue.items[head];
        for (c.edges.items) |e| if (e.from.eql(at) and !seen.isSet(e.to.raw())) {
            if (e.to.eql(to)) return true;
            seen.set(e.to.raw());
            queue.append(c.arena, e.to) catch return true;
        };
    }
    return false;
}

fn reach(c: *Checker) Error!void {
    const n = c.sections.items.len;
    if (n == 0) return;
    var reached = try std.DynamicBitSetUnmanaged.initEmpty(c.arena, n);
    var queue: std.ArrayList(sym.SectionId) = .empty;
    if (c.options.entries.len > 0) {
        for (c.options.entries) |name| {
            const id = c.sectionNamed(sym.root, name) orelse {
                try c.err(.none, "the game starts the story at `{s}`, and the story has no such section", .{name});
                continue;
            };
            if (c.sections.items[id.raw()].kind != .other) try c.entries.append(c.arena, id);
        }
    } else {
        var led = try std.DynamicBitSetUnmanaged.initEmpty(c.arena, n);
        for (c.edges.items) |e| if (!e.from.eql(e.to)) led.set(e.to.raw());
        for (0..n) |i| {
            const kind = c.sections.items[i].kind;
            if (!led.isSet(i) and kind != .rules and kind != .other) try c.entries.append(c.arena, sym.idOf(sym.SectionId, i));
        }
    }
    // a registered kind's section is run by its package (a calendar, a quest), so it is an entry by its kind
    for (c.sections.items, 0..) |s, i| if (s.kind == .other) try c.entries.append(c.arena, sym.idOf(sym.SectionId, i));
    // rules are reached by what they react to, never by a flow
    for (c.sections.items, 0..) |s, i| if (s.kind == .rules) {
        reached.set(i);
        try queue.append(c.arena, sym.idOf(sym.SectionId, i));
    };
    for (c.entries.items) |id| if (!reached.isSet(id.raw())) {
        reached.set(id.raw());
        try queue.append(c.arena, id);
    };
    const edges = try c.arena.dupe(sym.Edge, c.edges.items);
    std.mem.sort(sym.Edge, edges, {}, struct {
        fn less(_: void, a: sym.Edge, b: sym.Edge) bool {
            return a.from.compare(b.from) == .lt;
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
        if (edges[mid].from.compare(from) == .lt) lo = mid + 1 else hi = mid;
    }
    return lo;
}
