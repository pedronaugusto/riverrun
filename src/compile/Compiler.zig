//! A checked story being compiled: the builder it fills, and the maps from
//! the checker's ids to the format's. Every id the checker gave has its
//! place here before any statement is compiled, so a statement compiles
//! against this index alone. A package's pass for its registered kind gets
//! this too, to find what the story's sections and facts became, and to say
//! where the story is wrong if it finds what its check should have.

const std = @import("std");
const syntax = @import("../syntax.zig");
const check = @import("../check.zig");
const story = @import("riverrun").story;
const ExternId = @import("riverrun").facts.ExternId;

const Compiler = @This();
const sym = check.symbols;
const ast = syntax.ast;

pub const Error = story.BuildError || error{
    /// A pass a package registered failed: it says why in the diagnostics (`err`), or riverrun says it did not.
    PassFailed,
};

/// The scope a fact declared without one is kept in: riverrun's, as `story` is.
pub const default_scope = "default";

gpa: std.mem.Allocator,
/// Names built while compiling, alive until the story is written.
arena: std.mem.Allocator,
b: *story.Builder,
checked: *const check.Checked,
/// Where a package's pass reports what it refuses, as the checker does.
diags: *syntax.Diagnostics,

/// By the checker's id, what each became in the format.
facts: []story.FactId,
enums: []story.EnumId,
kinds: []story.RefKindId,
externs: []ExternId,
cast: []story.CastId,
/// Null for a registered kind's section or part whose visits nothing reads: its package runs it, and counts nothing.
visits: []?story.FactId,
sections: []story.SectionId,
/// For each section, the sections its parts compile to; null for a pool's candidates.
parts: [][]?story.SectionId,
/// The gather each label names, reserved before the bodies are compiled.
labels: []story.NodeId,
/// The section or part being compiled, for `place`.
where: []const u8 = "",
places: u32 = 0,

/// Reports an error where the story is written; the story is then refused.
pub fn err(c: *Compiler, span: syntax.Span, comptime fmt: []const u8, args: anytype) Error!void {
    try c.diags.add(c.gpa, span, .err, fmt, args);
}

/// A name as the format keeps it: qualified by its module, the root module's bare.
pub fn qualified(c: *const Compiler, module: sym.ModuleId, name: []const u8) Error![]const u8 {
    const m = c.checked.modules[module.raw()];
    if (m.len == 0) return name;
    return c.arena.print("{s}.{s}", .{ m, name });
}

/// What a section became.
pub fn section(c: *const Compiler, id: sym.SectionId) story.SectionId {
    return c.sections[id.raw()];
}

/// The section a part of a scene or a registered kind became.
pub fn part(c: *const Compiler, p: sym.PartRef) ?story.SectionId {
    return c.parts[p.section.raw()][p.index];
}

/// What a fact became.
pub fn fact(c: *const Compiler, id: sym.FactId) story.FactId {
    return c.facts[id.raw()];
}

/// The format's type for one of the checker's.
pub fn param(c: *const Compiler, t: sym.Type) story.Param {
    return switch (t) {
        .boolean => .{ .kind = .boolean },
        .int => .{ .kind = .int },
        .text => .{ .kind = .text },
        .one_of => |e| .{ .kind = .one_of, .enumeration = c.enums[e.raw()] },
        .set_of => |e| .{ .kind = .set_of, .enumeration = c.enums[e.raw()] },
        .ref => |k| .{ .kind = .ref, .ref_kind = c.kinds[k.raw()] },
    };
}

/// A tag list as the format carries it: each value that names a section, where the host's schema typed it so,
/// carries what that section became; each the schema types as words a player reads goes into the string table,
/// its line id made of where the tag stands (`at`), its key and its place, never of its words, so a typo fixed
/// keeps its translations.
pub fn tags(c: *Compiler, list: []const ast.Tag, at: ?[]const u8) Error!story.Range {
    if (list.len == 0) return .empty;
    const out = try c.arena.alloc(story.TagIn, list.len);
    for (list, out) |*t, *o| {
        const named = c.checked.tags.get(t);
        const words = c.checked.text_tags.contains(t);
        const where: []const u8 = if (!words) "" else at orelse try c.place();
        const values = try c.arena.alloc(story.TagValue, t.values.len);
        for (t.values, values, 0..) |v, *to, i| {
            const s: ?story.SectionId = if (named) |n| (if (n.len == t.values.len) c.section(n[i]) else null) else null;
            const line: ?story.LineId = if (!words) null else blk: {
                const id = if (t.values.len == 1) try c.arena.print("{s}#{s}", .{ where, t.key.text }) else try c.arena.print("{s}#{s}.{d}", .{ where, t.key.text, i });
                break :blk try c.b.line(id, try escaped(c.arena, v));
            };
            to.* = .{ .text = v, .section = s, .line = line };
        }
        o.* = .{ .key = t.key.text, .values = values };
    }
    return c.b.tagList(out);
}

/// Where tags stand that no line or choice holds: the section or part being compiled and a count of them, so each
/// has a place of its own for its words' line id.
pub fn place(c: *Compiler) Error![]const u8 {
    c.places += 1;
    return c.arena.print("{s}@{d}", .{ c.where, c.places });
}

/// Words as a template that holds no slot: `\`, `{`, `}` and `|` escaped.
pub fn escaped(arena: std.mem.Allocator, words: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (words) |ch| {
        if (ch == '\\' or ch == '{' or ch == '}' or ch == '|') try out.append(arena, '\\');
        try out.append(arena, ch);
    }
    return out.items;
}

/// The id text a line or a choice is known by.
pub fn lineId(c: *const Compiler, s: *const ast.Stmt) []const u8 {
    return (c.checked.lines.get(s) orelse unreachable).text; // unreachable: the checker gave every line and choice an id
}

/// A fresh step that hands the flow back: what a choice with no words of its own goes to.
pub fn back(c: *Compiler) Error!story.NodeId {
    return c.b.node(.{ .step = .ret });
}
