//! The index: every declaration of the story entered in the builder before
//! any statement is compiled, so each file's statements compile against it
//! alone. Enumerations, kinds of things, facts, externs, the cast, the visit
//! counts and the sections, in that order, each kept in the compiler's maps.

const std = @import("std");
const check = @import("../check.zig");
const story = @import("riverrun").story;
const Compiler = @import("Compiler.zig");

const sym = check.symbols;
const Error = Compiler.Error;
const ExternId = @import("riverrun").facts.ExternId;

pub fn run(c: *Compiler) Error!void {
    const k = c.checked;
    for (k.enums, c.enums) |e, *out| out.* = try c.b.enumeration(e.values);
    for (k.kinds, c.kinds) |name, *out| out.* = try c.b.refKind(name);
    for (k.facts, c.facts) |*f, *out| out.* = try fact(c, f);
    for (k.externs, c.externs) |*x, *out| out.* = try external(c, x);
    for (k.visits, c.visits) |v, *out| out.* = try c.b.visits(try visitName(c, v));
    for (k.sections, c.sections, c.parts) |*s, *out, *parts| {
        out.* = try section(c, s);
        parts.* = try partSections(c, s);
    }
    // tags may name any section, so they come once every section has its place
    for (k.sections, c.sections, c.parts) |*s, id, parts| {
        c.b.sectionTags(id, try c.tags(s.node.tags));
        for (s.parts, parts) |p, ps| if (ps) |pid| c.b.sectionTags(pid, try c.tags(p.node.tags));
    }
    for (k.speakers, c.cast) |*s, *out| out.* = try speaker(c, s);
    for (k.labels, c.labels) |_, *out| out.* = try c.b.reserve();
}

fn fact(c: *Compiler, f: *const sym.Fact) Error!story.FactId {
    const t = c.param(f.type);
    return c.b.fact(.{
        .name = try c.qualified(f.module, f.name),
        .scope = try c.b.scope(f.scope orelse Compiler.default_scope),
        .kind = t.kind,
        .enumeration = t.enumeration,
        .ref_kind = t.ref_kind,
        .role = if (f.clock) .clock else if (f.moment) .moment else if (f.game) .game else .story,
        .bounds = if (f.bounds) |b| .{ .min = b.min, .max = b.max } else null,
        .key = if (f.key) |k| switch (k) {
            .ref => |kind| .{ .ref = c.kinds[kind.raw()] },
            .one_of => |e| .{ .items = c.enums[e.raw()] },
            else => unreachable, // unreachable: the reader keys a fact by a kind of things or an enumeration
        } else .none,
    });
}

fn external(c: *Compiler, x: *const sym.Extern) Error!ExternId {
    const params = try c.arena.alloc(story.Param, x.params.len);
    for (x.params, params) |p, *out| out.* = c.param(p);
    const returns: ?story.Param = if (x.returns) |r| c.param(r) else null;
    const id = try c.b.externFn(try c.qualified(x.module, x.name), params, returns, !x.asks());
    if (x.reads) |st| {
        var keys: u32 = 0;
        for (st.keys) |key| keys |= @as(u32, 1) << @intCast(key); // safe: a query has at most format's 32 parameters, which the builder checked
        try c.b.stamp(id, st.family, keys);
    }
    return id;
}

// A cast member's display and relation are words of the string table, by ids the cast's own key makes.
fn speaker(c: *Compiler, s: *const sym.Speaker) Error!story.CastId {
    const display = try c.b.line(try c.arena.print("cast:{s}", .{s.key}), try escaped(c, s.display orelse s.key));
    const relation: ?story.LineId = if (s.relation) |r| try c.b.line(try c.arena.print("cast:{s}:who", .{s.key}), try escaped(c, r)) else null;
    return c.b.castMember(.{
        .name = if (s.extra) "" else try c.qualified(s.module, s.key),
        .display = display,
        .relation = relation,
        .tags = try c.tags(s.tags),
        .extra = s.extra,
    });
}

/// Words as a template that holds no slot: `\`, `{`, `}` and `|` escaped.
pub fn escaped(c: *Compiler, words: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (words) |ch| {
        if (ch == '\\' or ch == '{' or ch == '}' or ch == '|') try out.append(c.arena, '\\');
        try out.append(c.arena, ch);
    }
    return out.items;
}

// A visit count's name: a section's, `section.part`, or `section#label` (`section.part#label` in a part).
fn visitName(c: *Compiler, v: sym.Visit) Error![]const u8 {
    const k = c.checked;
    return switch (v.of) {
        .section => |id| sectionName(c, id),
        .part => |p| c.arena.print("{s}.{s}", .{ try sectionName(c, p.section), k.sections[p.section.raw()].parts[p.index].name }),
        .label => |id| {
            const l = k.labels[id.raw()];
            const at = try sectionName(c, l.section);
            if (l.part) |p| return c.arena.print("{s}.{s}#{s}", .{ at, k.sections[l.section.raw()].parts[p].name, l.name });
            return c.arena.print("{s}#{s}", .{ at, l.name });
        },
    };
}

pub fn sectionName(c: *Compiler, id: sym.SectionId) Error![]const u8 {
    const s = c.checked.sections[id.raw()];
    return c.qualified(s.module, s.name);
}

fn section(c: *Compiler, s: *const sym.Section) Error!story.SectionId {
    const visits = c.visits[s.visit.raw()];
    const name = try c.qualified(s.module, s.name);
    return switch (s.kind) {
        .scene => c.b.section(.{ .name = name, .visits = visits }),
        .pool => |n| c.b.section(.{ .name = name, .kind = .pool, .pick = n, .visits = visits }),
        .rules => c.b.section(.{ .name = name, .kind = .rules, .visits = visits }),
        .other => |kind| c.b.section(.{ .name = name, .kind = .other, .kind_name = kind, .visits = visits }),
    };
}

// The sections a scene's or a registered kind's parts become, `section.part`; a pool's candidates and a rules
// section's rules are their own.
fn partSections(c: *Compiler, s: *const sym.Section) Error![]?story.SectionId {
    const out = try c.arena.alloc(?story.SectionId, s.parts.len);
    const base = try c.qualified(s.module, s.name);
    for (s.parts, out) |p, *o| o.* = switch (s.kind) {
        .pool, .rules => null,
        .scene => try c.b.section(.{ .name = try c.arena.print("{s}.{s}", .{ base, p.name }), .visits = c.visits[p.visit.raw()] }),
        .other => |kind| try c.b.section(.{ .name = try c.arena.print("{s}.{s}", .{ base, p.name }), .kind = .other, .kind_name = kind, .visits = c.visits[p.visit.raw()] }),
    };
    return out;
}
