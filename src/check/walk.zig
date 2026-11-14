//! The second pass: every statement of every section, its names resolved,
//! its expressions, effects and text typed, its tags held to the schema, its
//! width measured and its id given. A statement written on the row of a
//! condition or a gather (`{ spot = door }  DAD: How long… ^k1`) owns that
//! row's id and the brackets under it; a line's delivery is a tag of the
//! key the host names for one.

const syntax = @import("../syntax.zig");
const sym = @import("symbols.zig");
const Checker = @import("Checker.zig");
const exprs = @import("exprs.zig");
const never = @import("never.zig").never;
const tags = @import("tags.zig");
const ids = @import("ids.zig");
const width = @import("width.zig");
const flow = @import("flow.zig");

const ast = syntax.ast;
const Error = Checker.Error;

/// One body being walked: a section's own, or one of its parts.
const Unit = struct {
    scope: exprs.Scope,
    path: ids.Path,
};

pub fn run(c: *Checker) Error!void {
    for (c.files, 0..) |file, i| for (file.decls) |decl| switch (decl.kind) {
        .cast => |entries| for (entries) |e| try tags.check(c, c.moduleOf(@intCast(i)), null, null, e.tags, .cast), // safe: a FileId numbers the files
        else => {},
    };
    for (0..c.sections.items.len) |i| try section(c, sym.idOf(sym.SectionId, i));
}

fn section(c: *Checker, id: sym.SectionId) Error!void {
    const s = c.section(id).*;
    try tags.check(c, s.module, id, null, s.node.tags, .section);
    var unit: Unit = .{
        .scope = .{ .module = s.module, .section = id, .part = null },
        .path = .{ .section = s.name, .part = null, .ordinal = 0 },
    };
    try body(c, &unit, s.node.body);
    for (s.parts, 0..) |p, i| {
        unit = .{
            .scope = .{ .module = s.module, .section = id, .part = @intCast(i) }, // safe: parts were numbered in u16
            .path = .{ .section = s.name, .part = p.name, .ordinal = 0 },
        };
        try tags.check(c, s.module, id, unit.scope.part, p.node.tags, .part);
        if (p.node.when) |*w| {
            // a rule's and a registered kind's conditions are watched; a pool's candidates are asked when called
            var watched = unit.scope;
            watched.watched = s.kind == .rules or s.kind == .other;
            try exprs.condition(c, watched, w);
            if (never(c, w)) {
                if (s.kind == .rules) {
                    try c.warn(w.span, "the rule `{s}` can never fire: its condition can never hold", .{p.name});
                } else try c.warn(w.span, "the candidate `{s}` can never be picked: its condition can never hold", .{p.name});
            }
        }
        if (s.kind == .rules) for (p.node.body) |st| if (st.kind != .effect) {
            try c.err(st.span, "a rule's body is its effects, `[…]`: a rule says nothing and goes nowhere", .{});
        };
        try body(c, &unit, p.node.body);
    }
}

fn body(c: *Checker, u: *Unit, stmts: []const ast.Stmt) Error!void {
    for (stmts) |*s| try stmt(c, u, s);
}

fn stmt(c: *Checker, u: *Unit, s: *const ast.Stmt) Error!void {
    switch (s.kind) {
        .line => |*l| try line(c, u, s, l),
        .choice => |*ch| try choice(c, u, s, ch),
        .cond => |*k| {
            try exprs.condition(c, u.scope, &k.cond);
            if (never(c, &k.cond)) try c.warn(k.cond.span, "this condition can never hold: what it gates is never said", .{});
            try body(c, u, k.body);
            try body(c, u, k.otherwise);
        },
        .gather => |g| if (g.then) |then| try stmt(c, u, then),
        .effect => |*e| try exprs.effect(c, u.scope, e),
        .flow => |*f| try flow.resolve(c, u.scope, f),
        .flow_if => |*f| {
            try exprs.condition(c, u.scope, &f.cond);
            try flow.resolve(c, u.scope, &f.then);
            try flow.resolve(c, u.scope, &f.otherwise);
        },
    }
}

fn line(c: *Checker, u: *Unit, s: *const ast.Stmt, l: *const ast.Line) Error!void {
    var key: ?[]const u8 = null;
    if (l.speaker) |*who| {
        const k = try c.lower(who.text);
        key = k;
        if (c.speaker_names.find(u.scope.module, k)) |id| {
            try c.names.put(c.arena, who, .{ .speaker = id });
        } else try c.err(who.span, "`{s}` is not a speaker: speakers come from `cast:` and `extras:`", .{who.text});
    }
    try exprs.text(c, u.scope, l.text);
    try width.check(c, s.span, l.text, c.options.width.line, "line");
    try tags.check(c, u.scope.module, u.scope.section, u.scope.part, try delivered(c, s, l), .line);
    try ids.give(c, s, u.path, key, l.text);
    u.path.ordinal += 1;
    for (l.effects) |*e| try stmt(c, u, e);
}

// A line's tags with its delivery among them, first, as a tag of the key the host names for one.
fn delivered(c: *Checker, s: *const ast.Stmt, l: *const ast.Line) Error![]const ast.Tag {
    const d = l.delivery orelse return s.tags;
    const key = c.options.delivery orelse {
        try c.err(d.span, "`({s})` is a delivery, and the host names no key for one: `Options.delivery`", .{d.words.text});
        return s.tags;
    };
    const all = try c.arena.alloc(ast.Tag, s.tags.len + 1);
    all[0] = .{
        .span = d.span,
        .key = .{ .text = key, .span = d.span },
        .values = try c.arena.dupe([]const u8, &.{d.words.text}),
        .spans = try c.arena.dupe(syntax.Span, &.{d.words.span}),
    };
    @memcpy(all[1..], s.tags);
    try c.line_tags.put(c.arena, s, all);
    return all;
}

fn choice(c: *Checker, u: *Unit, s: *const ast.Stmt, ch: *const ast.Choice) Error!void {
    if (ch.cond) |*k| {
        try exprs.condition(c, u.scope, k);
        if (never(c, k)) try c.warn(k.span, "this choice can never be offered: its condition can never hold", .{});
    }
    try exprs.text(c, u.scope, ch.text);
    try width.check(c, s.span, ch.text, c.options.width.choice, "choice");
    try tags.check(c, u.scope.module, u.scope.section, u.scope.part, s.tags, .choice);
    try ids.give(c, s, u.path, null, ch.text);
    u.path.ordinal += 1;
    try body(c, u, ch.body);
}
