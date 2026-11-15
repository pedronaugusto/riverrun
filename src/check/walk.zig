//! The second pass: every statement of every section, its names resolved,
//! its expressions, effects and text typed, its tags held to the schema, its
//! width measured and its id given. A statement written on the row of a
//! condition or a gather (`{ spot = door }  DAD: How long… ^k1`) owns that
//! row's id and the brackets under it; a line's delivery is a tag of the
//! key the host names for one.

const std = @import("std");
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
            if (try valueFirst(c, u, s, k)) return;
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
    if (l.speaker == null) try lookalike(c, u, l);
    try exprs.text(c, u.scope, l.text);
    try width.check(c, ids.rowOf(s, l.text), l.text, c.options.width.line, "line");
    try tags.check(c, u.scope.module, u.scope.section, u.scope.part, try delivered(c, s, l), .line);
    try ids.give(c, s, u.path, key, l.text);
    u.path.ordinal += 1;
    if (l.effects.len > 0 and l.text.len > 0 and canSayNothing(l.text)) {
        const at: syntax.Span = .{ .file = l.text[0].span.file, .start = l.text[0].span.start, .end = l.text[l.text.len - 1].span.end };
        try c.warn(at, "this line can say nothing (a `once` used up, or words chosen with none), and a line with nothing to say is not delivered: the effects under it are applied only when it says something", .{});
    }
    for (l.effects) |*e| try stmt(c, u, e);
}

// Whether words can come out empty when said: every literal run blank, and every other piece able to say nothing, a
// `{once: …}` once it is used up, words chosen by a condition, a plural or a gender with a branch of none, or
// alternatives with an empty one. A value said (`{coins}`) is taken to say something.
fn canSayNothing(t: ast.Text) bool {
    for (t) |piece| {
        const empty = switch (piece.kind) {
            .literal => |w| std.mem.trim(u8, w, " \t").len == 0,
            .value => false,
            .choose => |ch| canSayNothing(ch.then) or canSayNothing(ch.otherwise),
            .alternatives => |alt| alt.kind == .once or for (alt.options) |o| {
                if (canSayNothing(o)) break true;
            } else false,
            .select => |sel| for (sel.branches) |b| {
                if (canSayNothing(b.text)) break true;
            } else false,
        };
        if (!empty) return false;
    }
    return true;
}

// A narration row that begins with a value, `{name(to)} has the parcel.`: the reader reads braces at a row's start
// as a condition on the row, and only the type says otherwise. Braces holding a value a line can say (words, a
// number, a value of a list) before narration are the line's first words, as `{…}` is anywhere in a line. True where
// it was read so, and the line checked with its words.
fn valueFirst(c: *Checker, u: *Unit, s: *const ast.Stmt, k: *const ast.Cond) Error!bool {
    if (!k.on_row or k.otherwise.len > 0 or k.body.len != 1 or k.body[0].kind != .line) return false;
    const l = &k.body[0].kind.line;
    if (l.speaker != null) return false;
    const e = &k.cond;
    // a name or a query's answer, as a value a line says is written; a sum or a comparison stays a condition
    if (e.kind != .name and e.kind != .call) return false;
    const t = try exprs.typeOf(c, u.scope, e) orelse {
        // what is wrong with it is said once, and the row is walked as written
        try body(c, u, k.body);
        return true;
    };
    // a visit count before a row is a condition, true once the place was seen (`{ kitchen } Again.`)
    const sayable = switch (t) {
        .text, .one_of => true,
        .int => !exprs.isVisits(c, e),
        else => false,
    };
    switch (@as(enum { line, condition }, if (sayable) .line else .condition)) {
        .line => {},
        .condition => {
            // a condition after all, typed once
            try exprs.typedCondition(c, e, t);
            if (never(c, e)) try c.warn(e.span, "this condition can never hold: what it gates is never said", .{});
            try body(c, u, k.body);
            return true;
        },
    }
    const text = try c.arena.alloc(ast.Piece, l.text.len + 2);
    text[0] = .{ .span = k.cond_span, .kind = .{ .value = e.* } };
    text[1] = .{ .span = .{ .file = k.cond_span.file, .start = k.cond_span.end, .end = k.cond_span.end }, .kind = .{ .literal = " " } };
    @memcpy(text[2..], l.text);
    try c.value_first.put(c.arena, s, text);
    var said = l.*;
    said.text = text;
    try line(c, u, &k.body[0], &said);
    return true;
}

// Narration that reads like a line, a writer's slip a play would show only as words: its first words, in any case,
// a speaker's id or name or an extra's words, a delivery after them or not, and then a colon (`Ada: …`, `ADA:No
// space.`, `ADA : …`, `Ada (quietly): …`). Narration with a colon after other words (`Ada had one thing to say: no.`,
// `The rule: pay first.`) is narration and nothing is said.
fn lookalike(c: *Checker, u: *const Unit, l: *const ast.Line) Error!void {
    if (l.text.len == 0 or l.text[0].kind != .literal) return;
    const piece = l.text[0];
    const words = piece.kind.literal;
    const colon = std.mem.findScalar(u8, words, ':') orelse return;
    var who = std.mem.trimEnd(u8, words[0..colon], " \t");
    if (std.mem.endsWith(u8, who, ")")) if (std.mem.findScalarLast(u8, who, '(')) |open| {
        who = std.mem.trimEnd(u8, who[0..open], " \t");
    };
    if (who.len == 0) return;
    const id = c.speaker_names.find(u.scope.module, try c.lower(who)) orelse for (c.speakers.items, 0..) |sp, i| {
        if (sp.display) |d| if (std.ascii.eqlIgnoreCase(d, who)) break sym.idOf(sym.SpeakerId, i);
    } else return;
    // over the words and the colon, where the literal is written as it reads (no escape before the colon)
    const plain = piece.span.end - piece.span.start == words.len;
    const at: syntax.Span = if (plain) .{ .file = piece.span.file, .start = piece.span.start, .end = piece.span.start + @as(u32, @intCast(colon)) + 1 } else piece.span; // safe: a row is far shorter than a u32
    const upper = try std.ascii.allocUpperString(c.arena, c.speakers.items[id.raw()].key);
    try c.warn(at, "`{s}` reads like a line, and is narration: a line is its speaker's id in capitals, then `:` and a space: `{s}: …`", .{ words[0 .. colon + 1], upper });
}

// A line's tags with its delivery among them, first, as a tag of the key the host names for one.
fn delivered(c: *Checker, s: *const ast.Stmt, l: *const ast.Line) Error![]const ast.Tag {
    const d = l.delivery orelse return s.tags;
    const key = c.options.delivery orelse {
        try c.err(d.span, "`({s})` is a delivery, and this game takes none: its vocabulary names no key for one (`Options.delivery`)", .{d.words.text});
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
    try width.check(c, ids.rowOf(s, ch.text), ch.text, c.options.width.choice, "choice");
    try tags.check(c, u.scope.module, u.scope.section, u.scope.part, s.tags, .choice);
    try ids.give(c, s, u.path, null, ch.text);
    u.path.ordinal += 1;
    try body(c, u, ch.body);
}
