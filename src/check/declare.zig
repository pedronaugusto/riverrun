//! The first pass: every name a story declares, in every file, entered in
//! its namespace before anything is resolved, so a file may use what a
//! later one declares. Speakers, the expression namespace (facts, constants,
//! queries and actions) and sections are three namespaces; a part is named
//! within its section and a label within its section or part. A name
//! declared twice is reported where both are.

const std = @import("std");
const syntax = @import("../syntax.zig");
const sym = @import("symbols.zig");
const Checker = @import("Checker.zig");

const ast = syntax.ast;
const Span = syntax.Span;
const Error = Checker.Error;

/// The functions riverrun itself answers in a condition: no query may take their names.
pub const riverrun_builtins = [_][]const u8{ "seen", "since_changed" };

pub fn run(c: *Checker) Error!void {
    for (c.files, 0..) |*file, i| {
        const module = c.moduleOf(@intCast(i)); // safe: a FileId numbers the files
        for (file.decls) |*decl| switch (decl.*) {
            .cast => |entries| for (entries) |*e| try castEntry(c, module, e),
            .extras => |extras| for (extras) |*n| try extra(c, module, n),
            .facts => |*f| for (f.entries) |*e| try fact(c, module, f.scope, e),
            .consts => |consts| for (consts) |*k| try constant(c, module, k),
            .externs => |externs| for (externs) |*e| try external(c, module, e),
        };
    }
    for (c.files, 0..) |*file, i| {
        for (file.sections) |*s| try section(c, @intCast(i), s); // safe: a FileId numbers the files
    }
}

// ---------------------------------------------------------------- speakers

fn castEntry(c: *Checker, module: sym.ModuleId, e: *const ast.CastEntry) Error!void {
    try speaker(c, .{
        .key = try c.lower(e.id.text),
        .display = e.display,
        .relation = e.relation,
        .extra = false,
        .module = module,
        .span = e.id.span,
        .tags = e.tags,
    });
}

fn extra(c: *Checker, module: sym.ModuleId, n: *const ast.Name) Error!void {
    try speaker(c, .{ .key = try c.lower(n.text), .display = null, .relation = null, .extra = true, .module = module, .span = n.span, .tags = &.{} });
}

fn speaker(c: *Checker, s: sym.Speaker) Error!void {
    const slot = try c.speaker_names.map.getOrPut(c.arena, .{ .module = s.module, .name = s.key });
    if (slot.found_existing) {
        const first = c.speakers.items[slot.value_ptr.raw()];
        return c.err(s.span, "the speaker `{s}` is declared twice: first at {f}", .{ s.key, c.place(first.span) });
    }
    const index = try c.grow(sym.Speaker, &c.speakers, s, s.span, "speakers") orelse {
        c.speaker_names.map.removeByPtr(slot.key_ptr);
        return;
    };
    slot.value_ptr.* = sym.idOf(sym.SpeakerId, index);
}

// ---------------------------------------------------------------- the expression namespace

fn fact(c: *Checker, module: sym.ModuleId, scope: ?ast.Name, f: *const ast.Fact) Error!void {
    if (c.facts.items.len == sym.limits.facts) {
        return c.err(f.name.span, "the story declares more than {d} facts", .{sym.limits.facts});
    }
    const t = try typeOf(c, f.type, f.name.span);
    if (f.clock and t != .int) try c.err(f.name.span, "a clock counts, so `(clock)` is an int's: `{s}` is {s}", .{ f.name.text, try c.describe(t) });
    const id = sym.idOf(sym.FactId, c.facts.items.len);
    if (!try named(c, module, f.name, .{ .fact = id })) return;
    try c.facts.append(c.arena, .{
        .name = f.name.text,
        .scope = if (scope) |s| s.text else null,
        .type = t,
        .game = f.game,
        .clock = f.clock,
        .module = module,
        .span = f.name.span,
    });
}

fn constant(c: *Checker, module: sym.ModuleId, k: *const ast.Const) Error!void {
    const value: sym.Constant, const t: sym.Type = switch (k.value.kind) {
        .int => |n| .{ .{ .int = n }, .int },
        .string => |s| .{ .{ .text = s }, .text },
        .boolean => |b| .{ .{ .boolean = b }, .boolean },
        else => return c.err(k.value.span, "a constant is a number, text in quotes, or true or false", .{}),
    };
    const id = sym.idOf(sym.ConstId, c.consts.items.len);
    if (c.consts.items.len == sym.limits.ids) return c.err(k.name.span, "the story has more constants than {d}", .{sym.limits.ids});
    if (!try named(c, module, k.name, .{ .constant = id })) return;
    try c.consts.append(c.arena, .{ .name = k.name.text, .type = t, .value = value, .module = module, .span = k.name.span });
}

fn external(c: *Checker, module: sym.ModuleId, e: *const ast.Extern) Error!void {
    for (riverrun_builtins) |own| if (std.mem.eql(u8, e.name.text, own)) {
        return c.err(e.name.span, "`{s}` is riverrun's own. Name the query something else", .{own});
    };
    const params = try c.arena.alloc(sym.Type, e.params.len);
    const names = try c.arena.alloc(?[]const u8, e.params.len);
    for (e.params, params, names) |p, *out, *n| {
        out.* = try typeOf(c, p.type, e.name.span);
        n.* = if (p.name) |pn| pn.text else null;
    }
    const returns: ?sym.Type = if (e.returns) |r| try typeOf(c, r, e.name.span) else null;
    const reads: ?sym.Stamp = if (e.reads) |st| try stamp(c, e, st, names) else null;
    if (reads != null and (returns == null or e.action)) try c.err(e.name.span, "`(reads …)` stamps a query: `{s}` is an action", .{e.name.text});
    if (c.externs.items.len == sym.limits.ids) return c.err(e.name.span, "the story has more queries and actions than {d}", .{sym.limits.ids});
    const id = sym.idOf(sym.ExternId, c.externs.items.len);
    if (!try named(c, module, e.name, .{ .external = id })) return;
    try c.externs.append(c.arena, .{
        .name = e.name.text,
        .params = params,
        .param_names = names,
        .returns = returns,
        .action = e.action,
        .reads = reads,
        .module = module,
        .span = e.name.span,
    });
}

fn paramIndex(names: []const ?[]const u8, name: []const u8) ?u16 {
    for (names, 0..) |n, i| {
        if (n != null and std.mem.eql(u8, n.?, name)) return @intCast(i); // safe: a query has few parameters
    }
    return null;
}

// A stamp's keys, each the name of one of the query's parameters.
fn stamp(c: *Checker, e: *const ast.Extern, st: ast.Stamp, names: []const ?[]const u8) Error!sym.Stamp {
    const keys = try c.arena.alloc(u16, st.keys.len);
    for (st.keys, keys) |k, *out| {
        out.* = paramIndex(names, k.text) orelse blk: {
            try c.err(k.span, "`{s}` keys the stamp of `{s}`, and it has no parameter of that name", .{ k.text, e.name.text });
            break :blk 0;
        };
    }
    return .{ .family = st.family.text, .keys = keys };
}

// Enters a name in the expression namespace; false when it is already there.
fn named(c: *Checker, module: sym.ModuleId, name: ast.Name, what: sym.Named) Error!bool {
    const slot = try c.value_names.map.getOrPut(c.arena, .{ .module = module, .name = name.text });
    if (!slot.found_existing) {
        slot.value_ptr.* = what;
        return true;
    }
    const first = switch (slot.value_ptr.*) {
        .fact => |id| c.facts.items[id.raw()].span,
        .constant => |id| c.consts.items[id.raw()].span,
        .external => |id| c.externs.items[id.raw()].span,
    };
    try c.err(name.span, "`{s}` is declared twice: first at {f}", .{ name.text, c.place(first) });
    return false;
}

/// A declared type, its enumeration shared with any other that names the same values in the same order.
pub fn typeOf(c: *Checker, t: ast.Type, span: Span) Error!sym.Type {
    return switch (t) {
        .boolean => .boolean,
        .int => .int,
        .text => .text,
        .one_of => |values| .{ .one_of = try enumeration(c, values, span) },
        .set_of => |values| .{ .set_of = try enumeration(c, values, span) },
        .ref => |kind| .{ .ref = try c.kindOf(kind.text, kind.span) },
    };
}

fn enumeration(c: *Checker, values: []const ast.Name, span: Span) Error!sym.EnumId {
    for (values, 0..) |v, i| for (values[0..i]) |w| if (std.mem.eql(u8, v.text, w.text)) {
        try c.err(v.span, "`{s}` is named twice in one type", .{v.text});
    };
    if (values.len > sym.limits.values) try c.err(span, "a type holds more than {d} values", .{sym.limits.values});
    for (c.enums.items, 0..) |e, i| {
        if (e.values.len != values.len) continue;
        const same = for (e.values, values) |a, b| {
            if (!std.mem.eql(u8, a, b.text)) break false;
        } else true;
        if (same) return sym.idOf(sym.EnumId, i);
    }
    const texts = try c.arena.alloc([]const u8, values.len);
    for (values, texts) |v, *out| out.* = v.text;
    const index = try c.grow(sym.Enum, &c.enums, .{ .values = texts }, span, "types") orelse return .fromRaw(0);
    return sym.idOf(sym.EnumId, index);
}

// ---------------------------------------------------------------- sections

fn section(c: *Checker, file: syntax.FileId, s: *const ast.Section) Error!void {
    const module = c.moduleOf(file);
    if (std.mem.eql(u8, s.name.text, "end")) return c.err(s.name.span, "`end` is where `-> end` goes: no section can be called it", .{});
    if (c.sections.items.len == sym.limits.ids) return c.err(s.name.span, "the story has more sections than {d}", .{sym.limits.ids});
    const id = sym.idOf(sym.SectionId, c.sections.items.len);
    const slot = try c.section_names.map.getOrPut(c.arena, .{ .module = module, .name = s.name.text });
    if (slot.found_existing) {
        const first = c.section(slot.value_ptr.*).node.name.span;
        return c.err(s.name.span, "the section `{s}` is declared twice: first at {f}", .{ s.name.text, c.place(first) });
    }
    slot.value_ptr.* = id;
    try c.sections.append(c.arena, .{
        .name = s.name.text,
        .module = module,
        .file = file,
        .node = s,
        .kind = try kindOf(c, s),
        .parts = &.{},
        .labels = &.{},
        .visit = try c.visit(.{ .section = id }, s.name.span),
    });
    c.section(id).labels = try labels(c, id, null, s.body);
    const parts = try c.arena.alloc(sym.Part, s.subsections.len);
    for (s.subsections, parts, 0..) |*sub, *p, i| {
        for (s.subsections[0..i]) |prev| if (std.mem.eql(u8, prev.name.text, sub.name.text)) {
            try c.err(sub.name.span, "the part `{s}` is declared twice in `{s}`: first at {f}", .{ sub.name.text, s.name.text, c.place(prev.name.span) });
        };
        const index: u16 = @intCast(i); // safe: parts are fewer than the lines of a file, which lines bound
        p.* = .{ .name = sub.name.text, .node = sub, .labels = &.{}, .visit = try c.visit(.{ .part = .{ .section = id, .index = index } }, sub.name.span) };
        p.labels = try labels(c, id, index, sub.body);
    }
    c.section(id).parts = parts;
    try shape(c, s);
}

fn kindOf(c: *Checker, s: *const ast.Section) Error!sym.Section.Kind {
    return switch (s.kind) {
        .scene => .scene,
        .pool => |n| .{ .pool = n },
        .rules => .rules,
        .other => |name| {
            for (c.options.kinds) |k| if (std.mem.eql(u8, k.name, name.text)) return .{ .other = name.text };
            try c.err(name.span, "`({s})` is not a kind of section: a scene, `(pool)`, or a kind the host registers", .{name.text});
            return .scene;
        },
    };
}

// What a pool or a scene must be, apart from its flow.
fn shape(c: *Checker, s: *const ast.Section) Error!void {
    switch (s.kind) {
        .pool => |n| {
            if (s.body.len > 0) try c.err(s.body[0].span, "a pool holds only its candidates, each `= name when {{ … }}`", .{});
            if (n == 0) try c.err(s.name.span, "a pool gives at least one line", .{});
            if (s.subsections.len < n) try c.err(s.name.span, "the pool `{s}` gives {d}, but has {d} candidates", .{ s.name.text, n, s.subsections.len });
        },
        .rules => {
            if (s.body.len > 0) try c.err(s.body[0].span, "a rules section holds only its rules, each `= name when {{ … }}`", .{});
            for (s.subsections) |sub| if (sub.when == null) {
                try c.err(sub.name.span, "the rule `{s}` needs its condition: `= {s} when {{ … }}`, its effects under it", .{ sub.name.text, sub.name.text });
            };
        },
        .scene => for (s.subsections) |sub| if (sub.when) |w| {
            try c.err(w.span, "`when` belongs to a pool's candidates and to rules: `{s}` is a scene", .{s.name.text});
        },
        .other => {},
    }
}

// The labels of one body, at any depth, numbered with their visit counts.
fn labels(c: *Checker, s: sym.SectionId, part: ?u16, body: []const ast.Stmt) Error![]const sym.LabelId {
    var out: std.ArrayList(sym.LabelId) = .empty;
    try collect(c, s, part, body, &out);
    return out.toOwnedSlice(c.arena);
}

fn collect(c: *Checker, s: sym.SectionId, part: ?u16, body: []const ast.Stmt, out: *std.ArrayList(sym.LabelId)) Error!void {
    for (body) |*st| switch (st.kind) {
        .gather => |g| if (g.label) |name| {
            for (out.items) |l| if (std.mem.eql(u8, c.labels.items[l.raw()].name, name.text)) {
                try c.err(name.span, "the label `{s}` is used twice here: first at {f}", .{ name.text, c.place(c.labels.items[l.raw()].stmt.span) });
            };
            const label_id = sym.idOf(sym.LabelId, c.labels.items.len);
            const visit = try c.visit(.{ .label = label_id }, name.span);
            _ = try c.grow(sym.Label, &c.labels, .{ .name = name.text, .stmt = st, .section = s, .part = part, .visit = visit }, name.span, "labels") orelse return;
            try out.append(c.arena, label_id);
        },
        .choice => |ch| try collect(c, s, part, ch.body, out),
        .cond => |k| {
            try collect(c, s, part, k.body, out);
            try collect(c, s, part, k.otherwise, out);
        },
        else => {},
    };
}
