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
/// Where the declaration or the statement being compiled is written: where a limit of the compiled format it
/// meets is reported (`refuse`).
at: syntax.Span = .none,
/// Where each step is written, by its node id, and each choice, by its place in the story's choices: what `at`
/// held when it was made.
steps_at: std.ArrayList(syntax.Span) = .empty,
choices_at: std.ArrayList(syntax.Span) = .empty,

/// A step of the graph, made where the statement being compiled is written (`at`).
pub fn node(c: *Compiler, n: story.Node) Error!story.NodeId {
    const id = try c.b.node(n);
    try mark(c.arena, &c.steps_at, id.raw(), c.at);
    return id;
}

/// A step reserved before (a label's gather), defined where the statement being compiled is written.
pub fn define(c: *Compiler, id: story.NodeId, n: story.Node) Error!void {
    c.b.define(id, n);
    try mark(c.arena, &c.steps_at, id.raw(), c.at);
}

/// Choices offered together, each written where its statement is.
pub fn choiceList(c: *Compiler, list: []const story.Choice, spans: []const syntax.Span) Error!story.Range {
    const r = try c.b.choiceList(list);
    for (spans, 0..) |s, k| try mark(c.arena, &c.choices_at, r.start + @as(u32, @intCast(k)), s); // safe: below max_choices
    return r;
}

fn mark(arena: std.mem.Allocator, list: *std.ArrayList(syntax.Span), i: usize, span: syntax.Span) error{OutOfMemory}!void {
    if (list.items.len <= i) try list.appendNTimes(arena, .none, i + 1 - list.items.len);
    list.items[i] = span;
}

/// Where every step and every choice of the graph is written, for the `count` of each the builder made: a step or a
/// choice a package's pass made through the builder alone is written nowhere (`Span.none`).
pub fn written(c: *const Compiler, gpa: std.mem.Allocator) error{OutOfMemory}!Where {
    const steps = try gpa.alloc(syntax.Span, c.b.nodes.items.len);
    errdefer gpa.free(steps);
    const choices = try gpa.alloc(syntax.Span, c.b.choices.items.len);
    for (steps, 0..) |*s, i| s.* = if (i < c.steps_at.items.len) c.steps_at.items[i] else .none;
    for (choices, 0..) |*s, i| s.* = if (i < c.choices_at.items.len) c.choices_at.items[i] else .none;
    return .{ .steps = steps, .choices = choices };
}

/// Where a compiled story's steps and choices are written in its files: what a tool shows a step by, a run-time
/// error's place among them. Kept beside the compiled story in memory, never in the format.
pub const Where = struct {
    /// By node id.
    steps: []const syntax.Span,
    /// By a choice's place in the story's choices.
    choices: []const syntax.Span,

    pub fn deinit(w: *Where, gpa: std.mem.Allocator) void {
        gpa.free(w.steps);
        gpa.free(w.choices);
        w.* = undefined;
    }
};

/// Reports an error where the story is written; the story is then refused.
pub fn err(c: *Compiler, span: syntax.Span, comptime fmt: []const u8, args: anytype) Error!void {
    try c.diags.add(c.gpa, span, .err, fmt, args);
}

/// Reports that the compiled format cannot hold what is being compiled, where it is written (`at`), in words a
/// writer acts on: a limit of the format, which the checker cannot see, since it is met only as names are joined
/// and things are counted.
pub fn refuse(c: *Compiler, e: story.BuildError) Error!void {
    const max_name = @import("riverrun").facts.max_name;
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.NameTooLong => c.err(c.at, "this name, with the names it is written within, is longer than a compiled story holds ({d} bytes): shorten it", .{max_name}),
        error.TooManyFacts => c.err(c.at, "the story declares more facts than a compiled story holds ({d}), counting the visits and the state it keeps", .{@import("riverrun").facts.max_facts}),
        error.TooManyItems => c.err(c.at, "this lists more values than a compiled story holds ({d})", .{@import("riverrun").facts.max_items}),
        error.TooManyScopes => c.err(c.at, "the story keeps facts in more scopes than a compiled story holds ({d})", .{@import("riverrun").facts.max_scopes}),
        error.TooManyChoices => c.err(c.at, "this offers more choices at once than a compiled story holds ({d})", .{story.max_choices}),
        error.TooManySlots => c.err(c.at, "these words hold more values and choices of words than a line holds ({d})", .{story.max_slots}),
        error.TooManyCast => c.err(c.at, "the story has more speakers than a compiled story holds", .{}),
        error.TooManyParams => c.err(c.at, "this takes more parameters than a compiled story holds", .{}),
        error.TooLarge => c.err(c.at, "the story is larger than a compiled story holds", .{}),
        else => c.err(c.at, "the compiled story cannot hold this ({t}): riverrun's checker should have said why; please report it", .{e}),
    };
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
        c.at = t.span;
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
    return c.node(.{ .step = .ret });
}
