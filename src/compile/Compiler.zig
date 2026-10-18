//! A checked story being compiled: the builder it fills, and the maps from
//! the checker's ids to the format's. Every id the checker gave has its
//! place here before any statement is compiled, so a statement compiles
//! against this index alone. A package's pass for its registered kind gets
//! this too, to find what the story's sections and facts became.

const std = @import("std");
const syntax = @import("../syntax.zig");
const check = @import("../check.zig");
const story = @import("../story.zig");
const ExternId = @import("../facts.zig").ExternId;

const Compiler = @This();
const sym = check.symbols;
const ast = syntax.ast;

pub const Error = story.BuildError || error{
    /// A pass a package registered failed, and says so itself.
    PassFailed,
};

/// The scope a fact declared without one is kept in: riverrun's, as `story` is.
pub const default_scope = "default";

gpa: std.mem.Allocator,
/// Names built while compiling, alive until the story is written.
arena: std.mem.Allocator,
b: *story.Builder,
checked: *const check.Checked,

/// By the checker's id, what each became in the format.
facts: []story.FactId,
enums: []story.EnumId,
kinds: []story.RefKindId,
externs: []ExternId,
cast: []story.CastId,
visits: []story.FactId,
sections: []story.SectionId,
/// For each section, the sections its parts compile to; null for a pool's candidates.
parts: [][]?story.SectionId,
/// The gather each label names, reserved before the bodies are compiled.
labels: []story.NodeId,

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
/// carries what that section became.
pub fn tags(c: *const Compiler, list: []const ast.Tag) Error!story.Range {
    if (list.len == 0) return .empty;
    const out = try c.arena.alloc(story.TagIn, list.len);
    for (list, out) |*t, *o| {
        const named = c.checked.tags.get(t);
        const values = try c.arena.alloc(story.TagValue, t.values.len);
        for (t.values, values, 0..) |v, *to, i| {
            const s: ?story.SectionId = if (named) |n| (if (n.len == t.values.len) c.section(n[i]) else null) else null;
            to.* = .{ .text = v, .section = s };
        }
        o.* = .{ .key = t.key.text, .values = values };
    }
    return c.b.tagList(out);
}

/// The id text a line or a choice is known by.
pub fn lineId(c: *const Compiler, s: *const ast.Stmt) []const u8 {
    return (c.checked.lines.get(s) orelse unreachable).text; // unreachable: the checker gave every line and choice an id
}

/// A fresh step that hands the flow back: what a choice with no words of its own goes to.
pub fn back(c: *Compiler) Error!story.NodeId {
    return c.b.node(.{ .step = .ret });
}
