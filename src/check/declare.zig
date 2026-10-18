//! The first pass: every name a story declares, in every file, entered in
//! its namespace before anything is resolved, so a file may use what a
//! later one declares. A section's own facts, and those its registered
//! kind declares, are named within it, after the story's own. Speakers, the expression namespace (facts, constants,
//! queries and actions) and sections are three namespaces; a part is named
//! within its section and a label within its section or part. A name
//! declared twice is reported where both are.

const std = @import("std");
const syntax = @import("../syntax.zig");
const sym = @import("symbols.zig");
const Checker = @import("Checker.zig");

const ast = syntax.ast;
const schema_file = @import("schema.zig");
const Span = syntax.Span;
const Error = Checker.Error;

fn hasTag(tags: []const ast.Tag, key: []const u8) bool {
    for (tags) |t| if (std.mem.eql(u8, t.key.text, key)) return true;
    return false;
}

/// The functions riverrun itself answers in a condition: no query may take their names.
pub const riverrun_builtins = [_][]const u8{ "seen", "since_changed", "happened" };

pub fn run(c: *Checker) Error!void {
    for (c.files, 0..) |*file, i| {
        const module = c.moduleOf(@intCast(i)); // safe: a FileId numbers the files
        for (file.decls) |*decl| switch (decl.*) {
            .version => |v| {
                if (c.version != 0) try c.err(v.span, "the story's version is declared twice: first at {f}", .{c.place(c.version_span)});
                c.version = v.number;
                c.version_span = v.span;
            },
            .cast => |entries| for (entries) |*e| try castEntry(c, module, e),
            .extras => |extras| for (extras) |*n| try extra(c, module, n),
            .facts => |*f| for (f.entries) |*e| try fact(c, module, if (f.scope) |sc| sc.text else null, e, null),
            .consts => |consts| for (consts) |*k| try constant(c, module, k),
            .externs => |externs| for (externs) |*e| try external(c, module, e),
        };
    }
    for (c.files, 0..) |*file, i| {
        for (file.sections) |*s| try section(c, @intCast(i), s); // safe: a FileId numbers the files
    }
    // last, so a story's own declarations come first and what a section brings is the second of two names
    for (0..c.sections.items.len) |i| try brought(c, sym.idOf(sym.SectionId, i));
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

// `by` is the section that brings it, for a fact a section declares rather than the story.
fn fact(c: *Checker, module: sym.ModuleId, scope: ?[]const u8, f: *const ast.Fact, by: ?sym.SectionId) Error!void {
    if (c.facts.items.len == sym.limits.facts) {
        return c.err(f.name.span, "the story declares more than {d} facts", .{sym.limits.facts});
    }
    if (f.role and by == null) return c.err(f.name.span, "`(role)` is a thing a section is given: declare `{s}` in the section's own `facts:`", .{f.name.text});
    const t = try typeOf(c, f.type, f.name.span);
    if (f.clock and t != .int) try c.err(f.name.span, "a clock counts, so `(clock)` is an int's: `{s}` is {s}", .{ f.name.text, try c.describe(t) });
    if (f.clock and f.moment) try c.err(f.name.span, "`{s}` is a clock or a moment: a clock lasts, and a moment is over at once", .{f.name.text});
    const key: ?sym.Type = if (f.key) |k| try typeOf(c, k, f.name.span) else null;
    if (key != null and (f.clock or f.moment or t == .text)) {
        try c.err(f.name.span, "`{s}` is kept per thing, so it cannot be a clock, a moment or text", .{f.name.text});
    }
    if (f.bounds != null and f.clock) try c.err(f.name.span, "`{s}` is a clock, which only moves on: it has no bounds", .{f.name.text});
    const id = sym.idOf(sym.FactId, c.facts.items.len);
    if (!try named(c, module, f.name, .{ .fact = id }, by)) return;
    try c.facts.append(c.arena, .{
        .name = f.name.text,
        .scope = scope,
        .type = t,
        .game = f.game,
        .clock = f.clock,
        .moment = f.moment,
        .key = key,
        .bounds = f.bounds,
        .module = module,
        .span = f.name.span,
        .by = by,
        .role = f.role,
    });
}

// What a section brings into the story: its own facts, then those its registered kind declares, entered as the
// story's own.
fn brought(c: *Checker, id: sym.SectionId) Error!void {
    const s = c.section(id);
    const kind = c.kindOfSection(id);
    if (kind) |k| if (k.per) |per| if (per(s.node)) |name| {
        s.per = try c.kindOf(name.text, name.span);
    };
    for (s.node.facts) |block| for (block.entries) |*e| try within(c, id, if (block.scope) |sc| sc.text else null, e.*);
    const declare = (kind orelse return).declare orelse return;
    for (try declare(c.arena, s.node, c.files)) |d| {
        if (d.within) {
            try within(c, id, d.scope, d.fact);
        } else try fact(c, s.module, d.scope, &d.fact, id);
    }
}

// A fact named within section `id`: `section.name` to the rest of the story, `name` inside it, and kept per thing
// where the section is. A role is given to the section, never set by the story.
fn within(c: *Checker, id: sym.SectionId, scope: ?[]const u8, declared: ast.Fact) Error!void {
    const s = c.section(id);
    if (try shadowed(c, s, declared.name)) return;
    var f = declared;
    if (s.per) |per| {
        if (f.key != null) return c.err(f.name.span, "`{s}` is in `{s}`, which keeps it per {s}: it takes no key of its own", .{ f.name.text, s.name, c.kinds.items[per.raw()] });
        f.key = .{ .ref = .{ .text = c.kinds.items[per.raw()], .span = f.name.span } };
    }
    f.name.text = try c.arena.print("{s}.{s}", .{ s.name, f.name.text });
    f.game = f.game or f.role;
    s.declares = true;
    try fact(c, s.module, scope, &f, id);
}

// A name declared within section `s` is `s.name` outside it and `name` inside, so it must neither be read as a
// module's (`s` a module's name too, with a fact so named) nor hide, inside `s`, a name the section's module sees.
fn shadowed(c: *Checker, s: *const sym.Section, name: ast.Name) Error!bool {
    if (c.moduleNamed(s.name)) |m| if (c.value_names.map.get(.{ .module = m, .name = name.text }) != null) {
        try c.err(name.span, "`{s}.{s}` would name the module `{s}`'s `{s}`: rename the section or the module's fact", .{ s.name, name.text, s.name, name.text });
        return true;
    };
    const hidden = c.valueNamed(s.module, name.text) orelse return false;
    const first = switch (hidden) {
        .fact => |id| c.facts.items[id.raw()].span,
        .constant => |id| c.consts.items[id.raw()].span,
        .external => |id| c.externs.items[id.raw()].span,
    };
    try c.err(name.span, "`{s}` in `{s}` would hide `{s}`, declared at {f}, inside it: name one otherwise", .{ name.text, s.name, name.text, c.place(first) });
    return true;
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
    if (!try named(c, module, k.name, .{ .constant = id }, null)) return;
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
    if (!try named(c, module, e.name, .{ .external = id }, null)) return;
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

// Enters a name in the expression namespace; false when it is already there. `by` is the section that brings it.
fn named(c: *Checker, module: sym.ModuleId, name: ast.Name, what: sym.Named, by: ?sym.SectionId) Error!bool {
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
    if (by) |s| {
        const owner = c.section(s);
        const kind = if (owner.kind == .other) owner.kind.other else "section";
        try c.err(name.span, "`{s}` is declared twice: first at {f}, then by the {s} `{s}`", .{ name.text, c.place(first), kind, owner.name });
    } else try c.err(name.span, "`{s}` is declared twice: first at {f}", .{ name.text, c.place(first) });
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
            // a migration may run unconditionally, once, when an older save loads
            for (s.subsections) |sub| if (sub.when == null and !hasTag(sub.tags, schema_file.migrate_key)) {
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
