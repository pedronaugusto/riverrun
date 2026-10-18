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
const template = @import("riverrun").story.template;

const ast = syntax.ast;
const Error = Checker.Error;

/// Where an expression is: the module its names are looked up in, and the
/// section and part whose labels and parts `seen` can name.
pub const Scope = struct {
    module: sym.ModuleId,
    section: sym.SectionId,
    part: ?u16,
    /// A condition watched as facts change, a rule's or a registered kind's part's `when`: what it asks it asks of
    /// queries that declare what they read.
    watched: bool = false,
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

// A name as `scope` sees it in the expression namespace: what its section declares within it first (`stage` for
// `quest.stage`), then its module's names and the root's.
fn lookup(c: *const Checker, scope: Scope, n: []const u8) ?sym.Named {
    const s = &c.sections.items[scope.section.raw()];
    if (s.declares) {
        var buf: [256]u8 = undefined;
        if (std.mem.print(&buf, "{s}.{s}", .{ s.name, n })) |own| {
            if (c.value_names.map.get(.{ .module = s.module, .name = own })) |v| return v;
        } else |_| {} // a name too long for the buffer is longer than any the section declares
    }
    return c.valueNamed(scope.module, n);
}

// Whether `id` is a fact the section `scope` is in declares within it.
fn isOwn(c: *const Checker, scope: Scope, id: sym.FactId) bool {
    const by = c.facts.items[id.raw()].by orelse return false;
    return by.eql(scope.section) and c.sections.items[scope.section.raw()].declares;
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
    // where a thing of a kind is wanted, a name the story does not declare is one of the host's, by its id
    if (hint != null and hint.? == .ref and lookup(c, scope, n) == null) {
        const kind = hint.?.ref;
        if (!c.knowsThing(kind, n)) {
            try c.err(e.span, "the host has no {s} called `{s}`", .{ c.kinds.items[kind.raw()], n });
            return null;
        }
        return record(c, e, hint.?, .{ .thing = .{ .kind = kind, .id = n } });
    }
    if (lookup(c, scope, n)) |named| switch (named) {
        .fact => |id| {
            const f = c.facts.items[id.raw()];
            if (f.role and isOwn(c, scope, id)) return record(c, e, f.type, .{ .role = id });
            if (f.key) |k| {
                if (isOwn(c, scope, id) and c.sections.items[scope.section.raw()].per != null) return record(c, e, f.type, .{ .own = id });
                try c.err(e.span, "`{s}` is kept per {s}: read it for one, `{s}(…)`", .{ n, try keyWord(c, k), n });
                return null;
            }
            if (c.facts.items[id.raw()].moment and !reacts(c, scope)) {
                try c.err(e.span, "`{s}` is a moment, over once rules and quests have seen it: `{s}` would never see it", .{ n, c.sections.items[scope.section.raw()].name });
                return null;
            }
            return record(c, e, c.facts.items[id.raw()].type, .{ .fact = id });
        },
        .constant => |id| return record(c, e, c.consts.items[id.raw()].type, .{ .constant = id }),
        .external => |id| {
            const what = if (!c.externs.items[id.raw()].asks()) "an action: it runs as an effect, `~ " else "a query: ask it as `";
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
    if (std.mem.eql(u8, call.name.text, "since_changed")) return sinceChanged(c, scope, e, call);
    if (std.mem.eql(u8, call.name.text, "happened")) return happened(c, scope, e, call);
    if (lookup(c, scope, call.name.text)) |named| if (named == .fact) return keyedRead(c, scope, e, call, named.fact);
    if (c.kindOfSection(scope.section)) |kind| if (kind.builtin(call.name.text)) |b| return builtin(c, scope, e, call, kind, b);
    const id = try externOf(c, scope, call) orelse return null;
    const ext = c.externs.items[id.raw()];
    if (scope.watched and ext.asks() and ext.reads == null) {
        const by = if (c.sections.items[scope.section.raw()].kind == .rules) "a rule" else "a watched condition";
        try c.err(call.name.span, "`{s}` is asked by {s}, which wakes only when what it reads changes: declare what it reads, `(reads …)`", .{ ext.name, by });
        return null;
    }
    if (ext.action) {
        try c.err(e.span, "`{s}` is an action with an outcome: it runs as an effect whose outcome a fact keeps, `~ fact = {s}(…)`", .{ ext.name, ext.name });
        return null;
    }
    const returns = ext.returns orelse {
        try c.err(e.span, "`{s}` is an action: it runs as an effect, `~ {s}(…)`, and gives no value", .{ ext.name, ext.name });
        return null;
    };
    try c.names.put(c.arena, &call.name, .{ .query = id });
    return record(c, e, returns, .{ .query = id });
}

/// The query or action a call names, its arguments checked against its parameters.
pub fn externOf(c: *Checker, scope: Scope, call: *const ast.Call) Error!?sym.ExternId {
    const named = lookup(c, scope, call.name.text) orelse {
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

// Whether conditions here are watched rather than asked: a rule's, or a registered kind's (a quest's).
fn reacts(c: *const Checker, scope: Scope) bool {
    return switch (c.sections.items[scope.section.raw()].kind) {
        .rules, .other => true,
        .scene, .pool => false,
    };
}

// `since_changed(fact, clock)`: how far a clock has moved since the fact last changed, which only what watches
// conditions keeps.
fn sinceChanged(c: *Checker, scope: Scope, e: *const ast.Expr, call: *const ast.Call) Error!?sym.Type {
    if (!reacts(c, scope)) {
        try c.err(e.span, "`since_changed` is kept by what watches conditions: a rule or a quest, not `{s}`", .{c.sections.items[scope.section.raw()].name});
        return null;
    }
    if (call.args.len != 2 or call.args[0].kind != .name or call.args[1].kind != .name) {
        try c.err(e.span, "`since_changed` takes a fact and a clock: `since_changed(levers, seconds)`", .{});
        return null;
    }
    const fact = try factArg(c, scope, &call.args[0]) orelse return null;
    const clock = try factArg(c, scope, &call.args[1]) orelse return null;
    if (c.facts.items[fact.raw()].key != null) {
        try c.err(call.args[0].span, "`{s}` is kept per thing: since_changed watches a fact with one value", .{call.args[0].kind.name});
        return null;
    }
    if (!c.facts.items[clock.raw()].clock) {
        try c.err(call.args[1].span, "`{s}` is not a clock: since_changed counts on a fact declared `(clock)`", .{call.args[1].kind.name});
        return null;
    }
    return record(c, e, .int, .{ .since_changed = .{ .fact = fact, .clock = clock } });
}

// `happened(moment)`: whether a moment holds something this step, its value aside.
fn happened(c: *Checker, scope: Scope, e: *const ast.Expr, call: *const ast.Call) Error!?sym.Type {
    if (!reacts(c, scope)) {
        try c.err(e.span, "`happened` is seen by what watches conditions: a rule or a quest, not `{s}`", .{c.sections.items[scope.section.raw()].name});
        return null;
    }
    if (call.args.len != 1 or call.args[0].kind != .name) {
        try c.err(e.span, "`happened` takes a moment: `happened(pulled)`", .{});
        return null;
    }
    const m = try factArg(c, scope, &call.args[0]) orelse return null;
    if (!c.facts.items[m.raw()].moment) {
        try c.err(call.args[0].span, "`{s}` is not a moment: `happened` asks of a fact declared `(moment)`", .{call.args[0].kind.name});
        return null;
    }
    return record(c, e, .boolean, .{ .happened = m });
}

// `opinion(margaret)`: a fact kept per thing, read for one key of its key's type.
fn keyedRead(c: *Checker, scope: Scope, e: *const ast.Expr, call: *const ast.Call, id: sym.FactId) Error!?sym.Type {
    const f = c.facts.items[id.raw()];
    const key = f.key orelse {
        try c.err(e.span, "`{s}` is a fact with one value: it takes no key", .{f.name});
        return null;
    };
    if (call.args.len != 1) {
        try c.err(e.span, "`{s}` is read for one {s}: `{s}(…)`", .{ f.name, try keyWord(c, key), f.name });
        return null;
    }
    try value(c, scope, &call.args[0], key);
    try c.names.put(c.arena, &call.name, .{ .fact = id });
    return record(c, e, f.type, .{ .keyed = id });
}

// What a fact is kept per, as a writer says it: "person", "one of calm, angry".
fn keyWord(c: *const Checker, t: sym.Type) Error![]const u8 {
    return if (t == .ref) c.kinds.items[t.ref.raw()] else c.describe(t);
}

// The key an effect writes a fact kept per thing for, checked against the fact; false when the effect does not fit.
fn keyFits(c: *Checker, scope: Scope, fact: *const ast.Name, key: ?*const ast.Expr, id: sym.FactId) Error!bool {
    const f = c.facts.items[id.raw()];
    if (f.key) |k| {
        const given = key orelse {
            // a fact of the section kept per thing, written for the thing the section is evaluated for
            if (isOwn(c, scope, id) and c.sections.items[scope.section.raw()].per != null) {
                try c.names.put(c.arena, fact, .{ .own = id });
                return true;
            }
            try c.err(fact.span, "`{s}` is kept per {s}: write it for one, `{s}(…)`", .{ f.name, try keyWord(c, k), f.name });
            return false;
        };
        try value(c, scope, given, k);
        return true;
    }
    if (key != null) {
        try c.err(fact.span, "`{s}` is a fact with one value: it takes no key", .{f.name});
        return false;
    }
    return true;
}

// The number a value is when it is one written, or an int constant: what a bound can be checked against now.
fn constantInt(c: *const Checker, scope: Scope, e: *const ast.Expr) ?i64 {
    switch (e.kind) {
        .int => |n| return n,
        .name => |n| {
            const named = lookup(c, scope, n) orelse return null;
            if (named != .constant) return null;
            const k = c.consts.items[named.constant.raw()].value;
            return if (k == .int) k.int else null;
        },
        else => return null,
    }
}

fn factArg(c: *Checker, scope: Scope, arg: *const ast.Expr) Error!?sym.FactId {
    const named = lookup(c, scope, arg.kind.name) orelse {
        try c.err(arg.span, "nothing is called `{s}`: no fact", .{arg.kind.name});
        return null;
    };
    if (named != .fact) {
        try c.err(arg.span, "`{s}` is not a fact", .{arg.kind.name});
        return null;
    }
    return named.fact;
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

// A builtin of the section's registered kind: its arguments name things of the story, never values.
fn builtin(c: *Checker, scope: Scope, e: *const ast.Expr, call: *const ast.Call, kind: *const Checker.Kind, index: u16) Error!?sym.Type {
    const b = kind.builtins[index];
    if (call.args.len != b.params.len) {
        try c.err(call.name.span, "`{s}` takes {d} names, not {d}", .{ b.name, b.params.len, call.args.len });
        return null;
    }
    const args = try c.arena.alloc(sym.BuiltinArg, b.params.len);
    for (call.args, b.params, args) |*arg, want, *out| {
        if (arg.kind != .name) {
            try c.err(arg.span, "`{s}` takes names: {s}", .{ b.name, argName(want) });
            return null;
        }
        out.* = try builtinArg(c, scope, arg, want) orelse return null;
    }
    const k: u16 = @intCast(kind - c.options.kinds.ptr); // safe: a kind of the options, which are few
    const t: sym.Type = switch (b.returns) {
        .boolean => .boolean,
        .int => .int,
    };
    try c.names.put(c.arena, &call.name, .{ .builtin = .{ .kind = k, .builtin = index, .args = args } });
    return record(c, e, t, .{ .builtin = .{ .kind = k, .builtin = index, .args = args } });
}

fn argName(a: Checker.Builtin.Arg) []const u8 {
    return switch (a) {
        .part => "a part of this section",
        .section => "a section",
        .int_fact => "an int fact",
        .fact => "a fact",
    };
}

fn builtinArg(c: *Checker, scope: Scope, arg: *const ast.Expr, want: Checker.Builtin.Arg) Error!?sym.BuiltinArg {
    const n = arg.kind.name;
    switch (want) {
        .part => {
            const s = &c.sections.items[scope.section.raw()];
            for (s.parts, 0..) |p, i| if (std.mem.eql(u8, p.name, n)) {
                const ref: sym.PartRef = .{ .section = scope.section, .index = @intCast(i) }; // safe: parts were numbered in u16
                _ = try record(c, arg, .int, .{ .target = .{ .part = ref } });
                return .{ .part = ref };
            };
            try c.err(arg.span, "`{s}` is not a part of `{s}`", .{ n, s.name });
        },
        .section => if (c.sectionNamed(scope.module, n)) |id| {
            _ = try record(c, arg, .int, .{ .target = .{ .section = id } });
            return .{ .section = id };
        } else try c.err(arg.span, "nothing is called `{s}`: no section", .{n}),
        .int_fact, .fact => if (lookup(c, scope, n)) |named| if (named == .fact) {
            const t = c.facts.items[named.fact.raw()].type;
            if (want == .int_fact and t != .int) {
                try c.err(arg.span, "`{s}` is {s}, where an int fact is wanted", .{ n, try c.describe(t) });
                return null;
            }
            _ = try record(c, arg, t, .{ .fact = named.fact });
            return .{ .fact = named.fact };
        },
        // a name that is not a fact
    }
    if (want == .int_fact or want == .fact) try c.err(arg.span, "nothing is called `{s}`: no fact", .{n});
    return null;
}

// What `seen` can name, nearest first: a label here, a part of this section, a section.
fn visitOf(c: *const Checker, scope: Scope, n: []const u8) ?sym.VisitId {
    const s = &c.sections.items[scope.section.raw()];
    const here = if (scope.part) |p| s.parts[p].labels else s.labels;
    for (here) |l| if (std.mem.eql(u8, c.labels.items[l.raw()].name, n)) return c.labels.items[l.raw()].visit;
    for (s.parts) |p| if (std.mem.eql(u8, p.name, n)) return p.visit;
    const other = c.sectionNamed(scope.module, n) orelse return null;
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
        .lt, .le, .gt, .ge => {
            try value(c, scope, lhs, .int);
            try value(c, scope, rhs, .int);
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
        .name => |n| lookup(c, scope, n) == null,
        else => false,
    };
}

// ---------------------------------------------------------------- effects and text

pub fn effect(c: *Checker, scope: Scope, eff: *const ast.Effect) Error!void {
    switch (eff.*) {
        .set => |*s| {
            const id = try settable(c, scope, &s.fact) orelse return;
            if (!try keyFits(c, scope, &s.fact, s.key, id)) return;
            if (try outcome(c, scope, &s.value, id)) {
                if (s.key != null) try c.err(s.value.span, "an outcome is kept in a fact with one value", .{});
                return;
            }
            if (c.facts.items[id.raw()].bounds) |b| if (constantInt(c, scope, &s.value)) |n| if (n < b.min or n > b.max) {
                try c.err(s.value.span, "{d} is past `{s}`'s bounds, {d} to {d}", .{ n, s.fact.text, b.min, b.max });
            };
            try value(c, scope, &s.value, c.facts.items[id.raw()].type);
        },
        .add => |*a| try change(c, scope, a, "+="),
        .remove => |*r| try change(c, scope, r, "-="),
        .call => |*call| {
            const id = try externOf(c, scope, call) orelse return;
            const ext = c.externs.items[id.raw()];
            if (ext.action) return c.err(call.name.span, "`{s}` has an outcome, which a fact keeps: `~ fact = {s}(…)`", .{ ext.name, ext.name });
            if (ext.returns != null) return c.err(call.name.span, "`{s}` is a query: it answers in a condition, and an effect runs an action", .{ext.name});
            try c.names.put(c.arena, &call.name, .{ .action = id });
        },
    }
}

// `~ fact = action(…)`: an action whose outcome the host decides, kept in `fact`. False when the value is no such call.
fn outcome(c: *Checker, scope: Scope, v: *const ast.Expr, fact: sym.FactId) Error!bool {
    if (v.kind != .call) return false;
    const named = lookup(c, scope, v.kind.call.name.text) orelse return false;
    if (named != .external or !c.externs.items[named.external.raw()].action) return false;
    const id = try externOf(c, scope, &v.kind.call) orelse return true;
    const ext = c.externs.items[id.raw()];
    const want = c.facts.items[fact.raw()].type;
    if (!ext.returns.?.eql(want)) {
        try c.err(v.span, "`{s}`'s outcome is {s}, and the fact keeping it is {s}", .{ ext.name, try c.describe(ext.returns.?), try c.describe(want) });
    }
    try c.names.put(c.arena, &v.kind.call.name, .{ .action = id });
    _ = try record(c, v, ext.returns.?, .{ .action = id });
    return true;
}

// `+=` and `-=`: a set gains or loses an item; an int moves by a number or an int constant.
fn change(c: *Checker, scope: Scope, ch: *const ast.Change, op: []const u8) Error!void {
    const id = try settable(c, scope, &ch.fact) orelse return;
    if (!try keyFits(c, scope, &ch.fact, ch.key, id)) return;
    const t = c.facts.items[id.raw()].type;
    const amount = &ch.amount;
    switch (t) {
        .set_of => |en| {
            if (amount.kind != .name) return c.err(amount.span, "`{s}` changes the set `{s}` by an item: {s}", .{ op, ch.fact.text, try c.valueList(en) });
            const it = amount.kind.name;
            const ix = c.valueOf(en, it) orelse return c.err(amount.span, "`{s}` is not in `{s}`: {s}", .{ it, ch.fact.text, try c.valueList(en) });
            _ = try record(c, amount, .{ .one_of = en }, .{ .value = .{ .enumeration = en, .index = ix } });
        },
        .int => {
            if (amount.kind == .int) {
                _ = try record(c, amount, .int, null);
                return;
            }
            const named = lookup(c, scope, amount.kind.name);
            if (named != null and named.? == .constant and c.consts.items[named.?.constant.raw()].type == .int) {
                _ = try record(c, amount, .int, .{ .constant = named.?.constant });
                return;
            }
            try c.err(amount.span, "`{s}` changes the int `{s}` by a number or an int constant, and `{s}` is neither", .{ op, ch.fact.text, amount.kind.name });
        },
        else => try c.err(ch.fact.span, "`{s}` changes a set or an int; `{s}` is {s}", .{ op, ch.fact.text, try c.describe(t) }),
    }
}

// The fact an effect writes, if the story may write it.
fn settable(c: *Checker, scope: Scope, n: *const ast.Name) Error!?sym.FactId {
    const named = lookup(c, scope, n.text) orelse {
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
    if (f.role) {
        try c.err(n.span, "`{s}` is a role, given when its section starts: the story reads it and never sets it", .{n.text});
        return null;
    }
    if (f.game) {
        try c.err(n.span, "`{s}` is the game's, declared `(game)`: the story reads it and never sets it", .{n.text});
        return null;
    }
    f.set = true;
    try c.names.put(c.arena, n, .{ .fact = id });
    return id;
}

/// Text: what `{…}` says must be a fact, a constant or a query's answer that can be said; words chosen by a
/// condition are checked as both, and every option of alternatives.
pub fn text(c: *Checker, scope: Scope, t: ast.Text) Error!void {
    for (t) |*piece| switch (piece.*) {
        .literal => {},
        .value => |*e| {
            if (e.kind != .name and e.kind != .call) return c.err(e.span, "`{{…}}` says a fact, a constant or a query's answer", .{});
            const typ = try infer(c, scope, e, null) orelse continue;
            if (typ == .set_of) try c.err(e.span, "a set cannot be said", .{});
            if (typ == .ref) try c.err(e.span, "a thing is said through a query the host answers, such as `{{name(…)}}`", .{});
        },
        .choose => |*ch| {
            try condition(c, scope, &ch.cond);
            try text(c, scope, ch.then);
            try text(c, scope, ch.otherwise);
        },
        .alternatives => |alt| for (alt.options) |o| try text(c, scope, o),
        .select => |*sel| {
            if (try selection(c, scope, &sel.operand)) |categories| try labels(c, sel.branches, categories);
            for (sel.branches) |b| try text(c, scope, b.text);
        },
    };
}

/// Plural categories, by which a number's words are chosen.
pub const plural_categories = template.plural_categories;
/// Genders, by which a person's or a thing's words are chosen.
pub const gender_categories = template.gender_categories;

// What a selection chooses by: a number's plural, or the gender of a cast member (named by its id) or of a thing.
fn selection(c: *Checker, scope: Scope, operand: *const ast.Expr) Error!?[]const []const u8 {
    if (operand.kind == .name and lookup(c, scope, operand.kind.name) == null) {
        if (c.speaker_names.find(scope.module, try c.lower(operand.kind.name))) |id| {
            _ = try record(c, operand, .int, .{ .speaker = id });
            return &gender_categories;
        }
    }
    const t = try infer(c, scope, operand, null) orelse return null;
    return switch (t) {
        .int => &plural_categories,
        .ref => &gender_categories,
        else => blk: {
            try c.err(operand.span, "words are chosen by a number's plural or by a gender, a person's or a thing's: this is {s}", .{try c.describe(t)});
            break :blk null;
        },
    };
}

fn labels(c: *Checker, branches: []const ast.Branch, allowed: []const []const u8) Error!void {
    var other = false;
    for (branches, 0..) |b, i| {
        const l = b.label.text;
        other = other or std.mem.eql(u8, l, "other");
        if (!within(allowed, l)) try c.err(b.label.span, "`{s}` is not one of {s}", .{ l, try std.mem.join(c.arena, ", ", allowed) });
        for (branches[0..i]) |before| if (std.mem.eql(u8, before.label.text, l)) {
            try c.err(b.label.span, "`{s}` is chosen twice here", .{l});
        };
    }
    if (!other and branches.len > 0) try c.err(branches[0].label.span, "words chosen by a plural or a gender need `other`, which every language falls back to", .{});
}

fn within(list: []const []const u8, word: []const u8) bool {
    for (list) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}
