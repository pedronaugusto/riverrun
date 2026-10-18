//! Conditions that can never hold, where that can be told without running
//! the story: one that folds to false from literals and constants, and one
//! whose `and` asks a fact two things that cannot both be true
//! (`spot = piano and spot = door`, `kept has dad and kept hasnt dad`).
//! Anything else is the runtime's to find; this never guesses.

const std = @import("std");
const syntax = @import("../syntax.zig");
const sym = @import("symbols.zig");
const Checker = @import("Checker.zig");

const ast = syntax.ast;

/// The most comparisons of one fact an `and` is searched for; past them the
/// rest of it goes unexamined, which can only miss a contradiction.
pub const max_atoms = 32;

/// Whether `e`, already typed, can never be true.
pub fn never(c: *const Checker, e: *const ast.Expr) bool {
    if (fold(c, e) == .no) return true;
    var atoms: Atoms = .{};
    atoms.gather(c, e);
    return atoms.contradict();
}

const Truth = enum { yes, no, unknown };

fn fold(c: *const Checker, e: *const ast.Expr) Truth {
    return switch (e.kind) {
        .boolean => |b| if (b) .yes else .no,
        .name => switch (constant(c, e) orelse return .unknown) {
            .boolean => |b| if (b) .yes else .no,
            else => .unknown,
        },
        .not => |inner| switch (fold(c, inner)) {
            .yes => .no,
            .no => .yes,
            .unknown => .unknown,
        },
        .binary => |b| switch (b.op) {
            .@"and" => both(fold(c, b.lhs), fold(c, b.rhs), .no, .yes),
            .@"or" => both(fold(c, b.lhs), fold(c, b.rhs), .yes, .no),
            .eq, .ne => {
                const same = equal(c, b.lhs, b.rhs) orelse return .unknown;
                return if (same == (b.op == .eq)) .yes else .no;
            },
            .has, .hasnt => .unknown,
        },
        else => .unknown,
    };
}

// `and` and `or`: `decides` either way decides; both `other` is `other`.
fn both(a: Truth, b: Truth, decides: Truth, other: Truth) Truth {
    if (a == decides or b == decides) return decides;
    if (a == other and b == other) return other;
    return .unknown;
}

// Whether two fixed values are equal, or null when either can change.
fn equal(c: *const Checker, a: *const ast.Expr, b: *const ast.Expr) ?bool {
    const x = fixed(c, a) orelse return null;
    const y = fixed(c, b) orelse return null;
    return switch (x) {
        .boolean => |v| y == .boolean and y.boolean == v,
        .int => |v| y == .int and y.int == v,
        .text => |v| y == .text and std.mem.eql(u8, y.text, v),
        .value => |v| y == .value and y.value.eql(v),
    };
}

const Fixed = union(enum) { boolean: bool, int: i64, text: []const u8, value: sym.Value };

fn fixed(c: *const Checker, e: *const ast.Expr) ?Fixed {
    return switch (e.kind) {
        .boolean => |b| .{ .boolean = b },
        .int => if (ref(c, e)) |r| (if (r == .value) .{ .value = r.value } else null) else .{ .int = e.kind.int },
        .string => |s| .{ .text = s },
        .name => if (ref(c, e)) |r| switch (r) {
            .value => |v| .{ .value = v },
            .constant => |id| switch (c.consts.items[id.raw()].value) {
                .boolean => |b| .{ .boolean = b },
                .int => |n| .{ .int = n },
                .text => |s| .{ .text = s },
            },
            else => null,
        } else null,
        else => null,
    };
}

fn ref(c: *const Checker, e: *const ast.Expr) ?sym.Ref {
    const typed = c.exprs.get(e) orelse return null;
    return typed.ref;
}

fn constant(c: *const Checker, e: *const ast.Expr) ?sym.Constant {
    const r = ref(c, e) orelse return null;
    return if (r == .constant) c.consts.items[r.constant.raw()].value else null;
}

// One thing an `and` asks of one fact.
const Atom = struct {
    fact: sym.FactId,
    value: sym.Value,
    /// `=` or `has`, against `!=` or `hasnt`.
    is: bool,
    /// Asked with `has` or `hasnt`: the fact is a set.
    set: bool,
};

const Atoms = struct {
    items: [max_atoms]Atom = undefined,
    len: usize = 0,

    fn gather(a: *Atoms, c: *const Checker, e: *const ast.Expr) void {
        if (e.kind != .binary) return;
        const b = e.kind.binary;
        switch (b.op) {
            .@"and" => {
                a.gather(c, b.lhs);
                a.gather(c, b.rhs);
            },
            .eq, .ne, .has, .hasnt => {
                const is = b.op == .eq or b.op == .has;
                const set = b.op == .has or b.op == .hasnt;
                if (asks(c, b.lhs, b.rhs) orelse asks(c, b.rhs, b.lhs)) |pair| a.add(.{ .fact = pair.fact, .value = pair.value, .is = is, .set = set });
            },
            .@"or" => {},
        }
    }

    fn add(a: *Atoms, atom: Atom) void {
        if (a.len == max_atoms) return;
        a.items[a.len] = atom;
        a.len += 1;
    }

    // `fact = value` and `fact = other`; `fact = value` and `fact != value`. For a set,
    // only `has` against `hasnt` of one value: a set holds many.
    fn contradict(a: *const Atoms) bool {
        const all = a.items[0..a.len];
        for (all, 0..) |x, i| for (all[i + 1 ..]) |y| {
            if (!x.fact.eql(y.fact)) continue;
            const same = x.value.eql(y.value);
            if (same and x.is != y.is) return true;
            if (!same and x.is and y.is and !x.set) return true;
        };
        return false;
    }
};

const Pair = struct { fact: sym.FactId, value: sym.Value };

fn asks(c: *const Checker, f: *const ast.Expr, v: *const ast.Expr) ?Pair {
    const fr = ref(c, f) orelse return null;
    const vr = ref(c, v) orelse return null;
    if (fr != .fact or vr != .value) return null;
    return .{ .fact = fr.fact, .value = vr.value };
}
