//! Everything a reader checks before it trusts a story: every index in its
//! table, every name in the names, every kind a kind, and every condition,
//! value and argument list typed for its place. A story that passes cannot
//! make the executor read out of bounds or meet a value of the wrong kind.

const std = @import("std");
const facts = @import("../facts.zig");
const format = @import("format.zig");
const tables = @import("tables.zig");

const Graph = tables.Graph;
const Error = tables.Error;
const Range = format.Range;
const Term = format.Term;
const none = format.none;
const none16 = format.none16;

pub fn all(g: *const Graph) Error!void {
    if (!std.unicode.utf8ValidateSlice(g.raw(.names))) return error.BadName;
    try declarations(g);
    try externs(g);
    try reserved(g);
    try sections(g);
    try nodes(g);
    try choices(g);
    try texts(g);
    try effects(g);
    try tagTables(g);
    try extensions(g);
    try watches(g);
}

// What `since_changed` reads: a fact, a clock, and an int of the reserved scope that keeps the clock's value.
fn watches(g: *const Graph) Error!void {
    const reserved_scope = g.get(.meta, 0).reserved_scope;
    for (0..g.len(.changes)) |i| {
        const c = g.get(.changes, @intCast(i)); // safe: below a u32 count
        if (c.pad != 0) return error.BadNode;
        try index(g, .facts, c.fact);
        if (keyed(g.get(.facts, c.fact))) return error.BadKind;
        try intFact(g, c.clock);
        if (g.get(.facts, c.clock).role != @backingInt(facts.Role.clock)) return error.BadKind;
        try intFact(g, c.at);
        const at = g.get(.facts, c.at);
        if (at.scope != reserved_scope or at.role != @backingInt(facts.Role.state)) return error.BadReserved;
    }
}

fn extensions(g: *const Graph) Error!void {
    for (0..g.len(.builtins)) |i| {
        const b = g.get(.builtins, @intCast(i)); // safe: below a u32 count
        try nonEmptyName(g, b.kind);
        try nonEmptyName(g, b.name);
        try range(g, .builtin_args, b.args);
        if (b.returns != @backingInt(facts.Kind.boolean) and b.returns != @backingInt(facts.Kind.int)) return error.BadKind;
        if (b.pad[0] | b.pad[1] | b.pad[2] != 0) return error.BadNode;
    }
    for (0..g.len(.blocks)) |i| {
        const b = g.get(.blocks, @intCast(i)); // safe: below a u32 count
        try nonEmptyName(g, b.name);
        try range(g, .block_bytes, b.bytes);
        if (b.pad != 0) return error.BadNode;
        for (0..i) |k| {
            const before = g.get(.blocks, @intCast(k)); // safe: below a u32 count
            if (std.mem.eql(u8, g.raw(.names)[before.name.offset..][0..before.name.len], g.raw(.names)[b.name.offset..][0..b.name.len])) return error.BadName;
        }
    }
}

fn name(g: *const Graph, s: format.Str) Error!void {
    if (!tables.validName(g.raw(.names), s)) return error.BadName;
}

fn nonEmptyName(g: *const Graph, s: format.Str) Error!void {
    if (s.len == 0) return error.BadName;
    try name(g, s);
}

fn range(g: *const Graph, comptime table: format.Table, r: Range) Error!void {
    if (r.end() > g.len(table)) return error.OutOfRange;
}

fn index(g: *const Graph, comptime table: format.Table, i: u32) Error!void {
    if (i >= g.len(table)) return error.OutOfRange;
}

fn optionalNode(g: *const Graph, i: u32) Error!void {
    if (i != none) try index(g, .nodes, i);
}

fn kind(raw: u8) Error!facts.Kind {
    return std.enums.fromInt(facts.Kind, raw) orelse error.BadKind;
}

fn listed(k: facts.Kind) bool {
    return k == .one_of or k == .set_of;
}

fn enumLen(g: *const Graph, e: u16) u32 {
    return g.get(.enums, e).len;
}

// An enumeration where the kind needs one, a kind of things for a ref, bounds or none for an int, and none
// where none of these is.
fn enumeration(g: *const Graph, k: facts.Kind, e: u16) Error!void {
    if (k == .ref) return index(g, .kinds, e);
    if (!listed(k)) {
        if (e != none16) return error.BadKind;
        return;
    }
    try index(g, .enums, e);
}

fn intFact(g: *const Graph, f: u16) Error!void {
    try index(g, .facts, f);
    const d = g.get(.facts, f);
    if (d.kind != @backingInt(facts.Kind.int) or keyed(d)) return error.BadKind;
}

fn keyed(f: format.Fact) bool {
    return f.key_kind != format.no_kind;
}

fn keyTy(f: format.Fact) Ty {
    return .{ .kind = f.key_kind, .enumeration = f.key_type };
}

fn optionalIntFact(g: *const Graph, f: u16) Error!void {
    if (f != none16) try intFact(g, f);
}

fn declarations(g: *const Graph) Error!void {
    if (g.len(.scopes) > facts.max_scopes) return error.TooManyScopes;
    for (0..g.len(.scopes)) |i| try nonEmptyName(g, g.get(.scopes, @intCast(i))); // safe: below a u32 count
    for (0..g.len(.items)) |i| try nonEmptyName(g, g.get(.items, @intCast(i))); // safe: below a u32 count
    for (0..g.len(.literals)) |i| try name(g, g.get(.literals, @intCast(i))); // safe: below a u32 count
    if (g.len(.enums) >= none16) return error.OutOfRange;
    for (0..g.len(.enums)) |i| {
        const r = g.get(.enums, @intCast(i)); // safe: below a u32 count
        try range(g, .items, r);
        if (r.len == 0) return error.BadKind;
        if (r.len > facts.max_items) return error.TooManyItems;
    }
    if (g.len(.kinds) >= none16) return error.OutOfRange;
    for (0..g.len(.kinds)) |i| try nonEmptyName(g, g.get(.kinds, @intCast(i))); // safe: below a u32 count
    for (0..g.len(.things)) |i| {
        const t = g.get(.things, @intCast(i)); // safe: below a u32 count
        try nonEmptyName(g, t.id);
        try index(g, .kinds, t.kind);
        if (t.pad != 0) return error.BadNode;
    }
    if (g.len(.facts) > facts.max_facts) return error.TooManyFacts;
    for (0..g.len(.facts)) |i| {
        const f = g.get(.facts, @intCast(i)); // safe: below a u32 count
        try nonEmptyName(g, f.name);
        try index(g, .scopes, f.scope);
        const role = std.enums.fromInt(facts.Role, f.role) orelse return error.BadKind;
        const k = try kind(f.kind);
        if (role == .clock and k != .int) return error.BadKind;
        if (k == .int and f.enumeration != none16) {
            // a bounded int: its least no more than its most, and never a clock or the executor's own
            try index(g, .bounds, f.enumeration);
            const b = g.get(.bounds, f.enumeration);
            if (b.min > b.max or role == .clock or role == .visits or role == .state) return error.BadKind;
        } else try enumeration(g, k, f.enumeration);
        if (f.key_kind == format.no_kind) {
            if (f.key_type != none16) return error.BadKind;
        } else {
            const key = try kind(f.key_kind);
            if (key != .one_of and key != .ref) return error.BadKind;
            if (k == .text or role == .clock or role == .moment or role == .visits or role == .state) return error.BadKind;
            try enumeration(g, key, f.key_type);
        }
    }
    if (g.len(.cast) >= none16) return error.OutOfRange;
    for (0..g.len(.cast)) |i| {
        const c = g.get(.cast, @intCast(i)); // safe: below a u32 count
        try name(g, c.name);
        try range(g, .tags, c.tags);
        if (c.display == 0 or c.extra > 1) return error.BadKind;
        if ((c.extra == 1) != (c.name.len == 0)) return error.BadName;
    }
}

fn externs(g: *const Graph) Error!void {
    for (0..g.len(.params)) |i| {
        const p = g.get(.params, @intCast(i)); // safe: below a u32 count
        try enumeration(g, try kind(p.kind), p.enumeration);
    }
    if (g.len(.externs) >= none16) return error.OutOfRange;
    for (0..g.len(.externs)) |i| {
        const e = g.get(.externs, @intCast(i)); // safe: below a u32 count
        try nonEmptyName(g, e.name);
        try range(g, .params, e.params);
        if (e.action > 1) return error.BadKind;
        if (e.params.len > format.max_params) return error.BadKind;
        try name(g, e.stamp);
        // a stamp is a query's, and keys only parameters it has
        if (e.stamp.len == 0) {
            if (e.keys != 0) return error.BadKind;
        } else {
            if (e.action != 0) return error.BadKind;
            if (e.params.len < 32 and e.keys >> @intCast(e.params.len) != 0) return error.BadKind;
        }
        if (e.returns == format.no_kind) {
            if (e.action == 0) return error.BadKind; // a query answers
            if (e.enumeration != none16) return error.BadKind;
        } else try enumeration(g, try kind(e.returns), e.enumeration);
    }
}

fn reserved(g: *const Graph) Error!void {
    if (g.len(.meta) != 1) return error.MissingTable;
    const m = g.get(.meta, 0);
    try index(g, .scopes, m.reserved_scope);
    const scope = g.get(.scopes, m.reserved_scope);
    if (!std.mem.eql(u8, g.raw(.names)[scope.offset..][0..scope.len], facts.reserved_scope)) return error.BadReserved;
    for ([_]u16{ m.seed, m.turn }) |f| {
        try intFact(g, f);
        const d = g.get(.facts, f);
        if (d.scope != m.reserved_scope or d.role != @backingInt(facts.Role.state)) return error.BadReserved;
    }
}

fn sections(g: *const Graph) Error!void {
    if (g.len(.sections) >= none) return error.OutOfRange;
    for (0..g.len(.sections)) |i| {
        const s = g.get(.sections, @intCast(i)); // safe: below a u32 count
        try nonEmptyName(g, s.name);
        try name(g, s.kind_name);
        try range(g, .tags, s.tags);
        try optionalNode(g, s.entry);
        try intFact(g, s.visits);
        switch (std.enums.fromInt(format.SectionKind, s.kind) orelse return error.BadKind) {
            .pool => {
                if (s.pick == 0) return error.BadNode;
                try range(g, .candidates, s.candidates);
            },
            // a rules section's candidates are its rules, each fired on its own; it gives none at once
            .rules => {
                if (s.pick != 1 or s.entry != none) return error.BadNode;
                try range(g, .candidates, s.candidates);
            },
            .scene, .other => if (s.candidates.len != 0 or s.entry == none) return error.BadNode,
        }
    }
    for (0..g.len(.candidates)) |i| {
        const c = g.get(.candidates, @intCast(i)); // safe: below a u32 count
        try nonEmptyName(g, c.name);
        if (c.when.len > 0) try expr(g, c.when, .condition);
        try range(g, .tags, c.tags);
        try index(g, .nodes, c.entry);
        try intFact(g, c.visits);
        try intFact(g, c.seen);
    }
}

fn nodes(g: *const Graph) Error!void {
    if (g.len(.nodes) >= none) return error.OutOfRange;
    for (0..g.len(.nodes)) |i| {
        const n = g.get(.nodes, @intCast(i)); // safe: below a u32 count
        try range(g, .tags, n.tags);
        try optionalNode(g, n.next);
        const k = std.enums.fromInt(format.NodeKind, n.kind) orelse return error.BadKind;
        if (k != .line and n.speaker != none16) return error.BadNode;
        // Fields a kind does not use hold nothing, so one story has one encoding.
        const unused: u32 = switch (k) {
            .line => n.d,
            .choices, .effects => n.c | n.d,
            .branch => 0,
            .gather, .jump, .call => n.b | n.c | n.d,
            .ret, .end => n.a | n.b | n.c | n.d,
        };
        if (unused != 0) return error.BadNode;
        switch (k) {
            .line => {
                try index(g, .texts, n.a);
                try range(g, .effects, .{ .start = n.b, .len = n.c });
                if (n.speaker != none16) try index(g, .cast, n.speaker);
            },
            .choices => {
                try range(g, .choices, .{ .start = n.a, .len = n.b });
                if (n.b == 0) return error.BadNode;
                if (n.b > format.max_choices) return error.TooManyChoices;
            },
            .branch => {
                if (n.b == 0 or n.next != none) return error.BadNode;
                try expr(g, .{ .start = n.a, .len = n.b }, .condition);
                try optionalNode(g, n.c);
                try optionalNode(g, n.d);
            },
            .gather => {
                if (n.a > none16) return error.BadNode;
                try optionalIntFact(g, @intCast(n.a)); // safe: checked to fit a u16
            },
            .effects => {
                if (n.b == 0) return error.BadNode;
                try range(g, .effects, .{ .start = n.a, .len = n.b });
            },
            .jump, .call => {
                try index(g, .sections, n.a);
                if (k == .jump and n.next != none) return error.BadNode;
            },
            .ret, .end => if (n.next != none) return error.BadNode,
        }
    }
}

fn choices(g: *const Graph) Error!void {
    for (0..g.len(.choices)) |i| {
        const c = g.get(.choices, @intCast(i)); // safe: below a u32 count
        try index(g, .texts, c.text);
        if (c.cond.len > 0) try expr(g, c.cond, .condition);
        try range(g, .tags, c.tags);
        try index(g, .nodes, c.target);
        try intFact(g, c.visits);
        if (c.sticky > 1) return error.BadKind;
    }
}

fn texts(g: *const Graph) Error!void {
    for (0..g.len(.texts)) |i| {
        const t = g.get(.texts, @intCast(i)); // safe: below a u32 count
        if (t.line == 0) return error.OutOfRange;
        try range(g, .slots, t.slots);
        if (t.slots.len > format.max_slots) return error.TooManySlots;
    }
    for (0..g.len(.slots)) |i| {
        const s = g.get(.slots, @intCast(i)); // safe: below a u32 count
        switch (std.enums.fromInt(format.SlotKind, s.kind) orelse return error.BadKind) {
            .value => {
                if (s.arity != 0 or s.state != none16) return error.BadNode;
                try expr(g, s.expr, .value);
            },
            .choose => {
                if (s.arity != 2 or s.state != none16) return error.BadNode;
                try expr(g, s.expr, .condition);
            },
            .plural, .gender => {
                if (s.arity != 0 or s.state != none16) return error.BadNode;
                try expr(g, s.expr, if (s.kind == @backingInt(format.SlotKind.plural)) .{ .of = .int } else .gender);
            },
            .sequence, .cycle, .once, .shuffle => {
                if (s.arity == 0 or s.expr.len != 0) return error.BadNode;
                if (s.arity > format.max_slots) return error.TooManySlots;
                try intFact(g, s.state);
            },
        }
    }
}

fn effects(g: *const Graph) Error!void {
    for (0..g.len(.effects)) |i| {
        const e = g.get(.effects, @intCast(i)); // safe: below a u32 count
        const k = std.enums.fromInt(format.EffectKind, e.kind) orelse return error.BadKind;
        // Fields a kind does not use hold nothing, so one story has one encoding.
        if (k != .call) try index(g, .facts, e.fact);
        // a fact kept per thing is written with its key, which its terms leave first
        const per = k != .call and keyed(g.get(.facts, e.fact));
        const canonical = switch (k) {
            .set, .change => e.item == 0 and e.action == none16 and e.result == none16,
            .add, .remove => (per or (e.expr.len == 0 and e.expr.start == 0)) and e.action == none16 and e.result == none16,
            .call => e.fact == none16 and e.item == 0,
        };
        if (!canonical) return error.BadNode;
        switch (k) {
            .set => {
                const f = g.get(.facts, e.fact);
                try expr(g, e.expr, if (per) .{ .keyed = .{ .key = keyTy(f), .value = tyOfFact(f) } } else .{ .of = tyOfFact(f) });
            },
            .change => {
                const f = g.get(.facts, e.fact);
                if (f.kind != @backingInt(facts.Kind.int)) return error.BadKind;
                try expr(g, e.expr, if (per) .{ .keyed = .{ .key = keyTy(f), .value = .int } } else .{ .of = .int });
            },
            .add, .remove => {
                const f = g.get(.facts, e.fact);
                if (f.kind != @backingInt(facts.Kind.set_of)) return error.BadKind;
                if (e.item >= enumLen(g, f.enumeration)) return error.OutOfRange;
                if (per) try expr(g, e.expr, .{ .keyed = .{ .key = keyTy(f), .value = null } });
            },
            .call => {
                try index(g, .externs, e.action);
                const x = g.get(.externs, e.action);
                if (x.action != 1) return error.BadKind;
                try expr(g, e.expr, .{ .args = x.params });
                if (e.result != none16) {
                    try index(g, .facts, e.result);
                    if (x.returns == format.no_kind) return error.BadKind;
                    if (!tyOfFact(g.get(.facts, e.result)).eql(.{ .kind = x.returns, .enumeration = x.enumeration })) return error.BadKind;
                }
            },
        }
    }
}

fn tagTables(g: *const Graph) Error!void {
    for (0..g.len(.tags)) |i| {
        const t = g.get(.tags, @intCast(i)); // safe: below a u32 count
        try nonEmptyName(g, t.key);
        try range(g, .tag_values, t.values);
    }
    for (0..g.len(.tag_values)) |i| {
        const v = g.get(.tag_values, @intCast(i)); // safe: below a u32 count
        try name(g, v.text);
        if (v.section != none) try index(g, .sections, v.section);
        if (v.pad != 0) return error.BadNode;
    }
}

// ---------------------------------------------------------------- expressions

// The type of a value on the stack: its kind, and its enumeration where it has one.
const Ty = struct {
    kind: u8,
    enumeration: u16,

    const boolean: Ty = .{ .kind = @backingInt(facts.Kind.boolean), .enumeration = none16 };
    const int: Ty = .{ .kind = @backingInt(facts.Kind.int), .enumeration = none16 };

    fn eql(a: Ty, b: Ty) bool {
        return a.kind == b.kind and a.enumeration == b.enumeration;
    }
};

// A fact's value's type: a bounded int's `enumeration` names its bounds, which are no part of its type.
fn tyOfFact(f: format.Fact) Ty {
    if (f.kind == @backingInt(facts.Kind.int)) return .int;
    return .{ .kind = f.kind, .enumeration = f.enumeration };
}

const Want = union(enum) {
    condition,
    value,
    of: Ty,
    /// A key, then a value of this type unless null: what writing a fact kept per thing takes.
    keyed: struct { key: Ty, value: ?Ty },
    /// What a gender is asked of: a cast member, by its index (an int), or a thing (a ref).
    gender,
    /// The values of these parameters, in order.
    args: Range,
};

/// Checks that the terms of `r` evaluate to what `want` needs.
fn expr(g: *const Graph, r: Range, want: Want) Error!void {
    try range(g, .terms, r);
    var stack: [format.max_stack]Ty = undefined;
    var n: usize = 0;
    for (0..r.len) |k| {
        const word = g.get(.terms, r.start + @as(u32, @intCast(k))); // safe: below a u32 length
        const op = std.enums.fromInt(Term.Op, @as(u8, @truncate(word))) orelse return error.BadExpression; // safe: the low byte is the op
        const arg: u24 = @intCast(word >> 8); // safe: the high 24 bits
        if (n == format.max_stack) return error.BadExpression;
        switch (op) {
            .fact => {
                try index(g, .facts, arg);
                if (keyed(g.get(.facts, arg))) return error.BadExpression;
                stack[n] = tyOfFact(g.get(.facts, arg));
                n += 1;
            },
            .keyed => {
                try index(g, .facts, arg);
                const f = g.get(.facts, arg);
                if (!keyed(f) or n < 1 or !stack[n - 1].eql(keyTy(f))) return error.BadExpression;
                stack[n - 1] = tyOfFact(f);
            },
            .int => {
                try index(g, .ints, arg);
                stack[n] = .int;
                n += 1;
            },
            .text => {
                try index(g, .literals, arg);
                stack[n] = .{ .kind = @backingInt(facts.Kind.text), .enumeration = none16 };
                n += 1;
            },
            .item => {
                const t: Term = .{ .op = .item, .arg = arg };
                try index(g, .enums, t.itemEnum());
                if (t.itemIndex() >= enumLen(g, t.itemEnum())) return error.OutOfRange;
                stack[n] = .{ .kind = @backingInt(facts.Kind.one_of), .enumeration = t.itemEnum() };
                n += 1;
            },
            .true, .false => {
                stack[n] = .boolean;
                n += 1;
            },
            .builtin => {
                try index(g, .builtins, arg);
                stack[n] = .{ .kind = g.get(.builtins, arg).returns, .enumeration = none16 };
                n += 1;
            },
            .happened => {
                try index(g, .facts, arg);
                if (g.get(.facts, arg).role != @backingInt(facts.Role.moment)) return error.BadExpression;
                stack[n] = .boolean;
                n += 1;
            },
            .since_changed => {
                try index(g, .changes, arg);
                stack[n] = .int;
                n += 1;
            },
            .thing => {
                try index(g, .things, arg);
                stack[n] = .{ .kind = @backingInt(facts.Kind.ref), .enumeration = g.get(.things, arg).kind };
                n += 1;
            },
            .not => {
                if (n < 1 or !stack[n - 1].eql(.boolean)) return error.BadExpression;
            },
            .eq, .ne, .lt, .le, .gt, .ge, .has, .hasnt, .@"and", .@"or" => {
                if (n < 2) return error.BadExpression;
                const a = stack[n - 2];
                const b = stack[n - 1];
                const fits = switch (op) {
                    .eq, .ne => a.eql(b),
                    .lt, .le, .gt, .ge => a.eql(.int) and b.eql(.int),
                    .has, .hasnt => a.kind == @backingInt(facts.Kind.set_of) and b.kind == @backingInt(facts.Kind.one_of) and a.enumeration == b.enumeration,
                    else => a.eql(.boolean) and b.eql(.boolean),
                };
                if (!fits) return error.BadExpression;
                n -= 1;
                stack[n - 1] = .boolean;
            },
            .query => n = try query(g, arg, stack[0..], n),
        }
    }
    const fits = switch (want) {
        .condition => n == 1 and stack[0].eql(.boolean),
        .value => n == 1,
        .of => |ty| n == 1 and stack[0].eql(ty),
        .args => |params| n == params.len and paramsFit(g, params, stack[0..n]),
        .gender => n == 1 and (stack[0].eql(.int) or stack[0].kind == @backingInt(facts.Kind.ref)),
        .keyed => |kv| if (kv.value) |v| (n == 2 and stack[0].eql(kv.key) and stack[1].eql(v)) else (n == 1 and stack[0].eql(kv.key)),
    };
    if (!fits) return error.BadExpression;
}

// A query's arguments off the stack, its answer on: the stack's new depth.
fn query(g: *const Graph, arg: u24, stack: []Ty, n: usize) Error!usize {
    if (arg >= g.len(.externs)) return error.OutOfRange;
    const x = g.get(.externs, @intCast(arg)); // safe: checked against the table
    if (x.action != 0) return error.BadExpression;
    if (n < x.params.len or !paramsFit(g, x.params, stack[n - x.params.len .. n])) return error.BadExpression;
    const depth = n - x.params.len;
    stack[depth] = .{ .kind = x.returns, .enumeration = x.enumeration };
    return depth + 1;
}

fn paramsFit(g: *const Graph, params: Range, values: []const Ty) bool {
    for (values, 0..) |v, i| {
        const p = g.get(.params, params.start + @as(u32, @intCast(i))); // safe: below a u32 length
        if (!v.eql(.{ .kind = p.kind, .enumeration = p.enumeration })) return false;
    }
    return true;
}
