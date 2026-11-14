//! The compile layer: a checked story into the compiled format, the graph
//! and its string table. It needs `check` and `story`, and refuses a story
//! whose diagnostics hold an error.
//!
//! First the index: every declaration of every file entered in the builder,
//! with the maps from the checker's ids to the format's (`declare`). Then
//! each file on its own: its sections' bodies compiled against the index
//! (`body`, `exprs`, `text`), so a file's steps depend only on the index and
//! its own tree, which is what a cache of compiled files would key on. Then
//! each pass a package registered for its kind of section, which may add the
//! package's block. Last the link: the builder writes the graph, read back
//! and validated, and the string table for its hash.

const std = @import("std");
const syntax = @import("syntax.zig");
const check = @import("check.zig");
const story = @import("riverrun").story;

pub const Compiler = @import("compile/Compiler.zig");
const declare = @import("compile/declare.zig");
const body = @import("compile/body.zig");
const exprs = @import("compile/exprs.zig");

pub const Error = Compiler.Error || error{
    /// The diagnostics hold an error: what the checker refused is never compiled.
    StoryHasErrors,
};

/// A condition of the story as terms, for a package's pass: its stages' conditions, compiled as riverrun's are.
pub const condition = exprs.condition;

/// What a package adds when its kind of section is compiled: a pass over the whole story, which reads what the
/// checker resolved and what the compiler made of it, and may add a block (`Compiler.b.block`). What it refuses
/// it reports with `Compiler.err`, and the story is refused; one that fails saying nothing is reported by name.
pub const Pass = struct {
    /// Whose it is: the package's name.
    name: []const u8,
    user: ?*anyopaque = null,
    run: *const fn (user: ?*anyopaque, c: *Compiler) Compiler.Error!void,
};

pub const Options = struct {
    /// The string table's language.
    locale: []const u8 = "en",
    passes: []const Pass = &.{},
};

/// The compiled graph and its string table, owned by the caller.
pub const Compiled = struct {
    graph: []u8,
    words: []u8,

    pub fn deinit(c: *Compiled, gpa: std.mem.Allocator) void {
        gpa.free(c.graph);
        gpa.free(c.words);
        c.* = undefined;
    }
};

/// Compiles `checked`, which `diags` must hold no error for; each pass reports into `diags`.
pub fn run(gpa: std.mem.Allocator, diags: *syntax.Diagnostics, checked: *const check.Checked, options: Options) Error!Compiled {
    if (diags.errors() > 0) return error.StoryHasErrors;
    var b: story.Builder = try .init(gpa);
    defer b.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Compiler = .{
        .gpa = gpa,
        .arena = a,
        .b = &b,
        .checked = checked,
        .diags = diags,
        .facts = try a.alloc(story.FactId, checked.facts.len),
        .enums = try a.alloc(story.EnumId, checked.enums.len),
        .kinds = try a.alloc(story.RefKindId, checked.kinds.len),
        .externs = try a.alloc(@import("riverrun").facts.ExternId, checked.externs.len),
        .cast = try a.alloc(story.CastId, checked.speakers.len),
        .visits = try a.alloc(?story.FactId, checked.visits.len),
        .sections = try a.alloc(story.SectionId, checked.sections.len),
        .parts = try a.alloc([]?story.SectionId, checked.sections.len),
        .labels = try a.alloc(story.NodeId, checked.labels.len),
    };
    b.version = std.math.cast(u16, checked.version) orelse return error.TooLarge;
    try declare.run(&c);
    for (0..checked.files.len) |f| try file(&c, @intCast(f)); // safe: a FileId numbers the files
    for (options.passes) |p| try pass(&c, p);
    const graph = try b.bytes(gpa);
    errdefer gpa.free(graph);
    const written: story.Story = try .init(graph, .{ .verify_hash = false });
    return .{ .graph = graph, .words = try b.stringBytes(gpa, options.locale, written.hash()) };
}

// A package's pass, which never fails silently: an error it reports refuses the story, and a failure it does not
// explain is reported by its name.
fn pass(c: *Compiler, p: Pass) Error!void {
    const before = c.diags.errors();
    p.run(p.user, c) catch |e| {
        if (e == error.PassFailed and c.diags.errors() == before) try c.err(.none, "`{s}`'s pass failed and said nothing of why", .{p.name});
        return e;
    };
    if (c.diags.errors() > before) return error.PassFailed;
}

// riverrun's own number on a part, `[weight 3]`, `[migrate 2]`, which the checker held to a u16 above 0; 0 for none.
fn ownNumber(tags: []const syntax.ast.Tag, key: []const u8) u16 {
    for (tags) |t| if (std.mem.eql(u8, t.key.text, key) and t.values.len == 1) {
        return std.fmt.parseInt(u16, t.values[0], 10) catch 0;
    };
    return 0;
}

// One file's sections, against the index.
fn file(c: *Compiler, f: syntax.FileId) Compiler.Error!void {
    for (c.checked.sections, 0..) |*s, i| {
        if (s.file != f) continue;
        try section(c, check.symbols.idOf(check.symbols.SectionId, i), s);
    }
}

fn section(c: *Compiler, id: check.symbols.SectionId, s: *const check.symbols.Section) Compiler.Error!void {
    const to = c.section(id);
    c.where = try c.qualified(s.module, s.name);
    c.places = 0;
    switch (s.kind) {
        .scene, .other => {
            // a scene with parts and no body of its own opens with its first part
            const opens = s.node.body.len == 0 and s.parts.len > 0;
            const entry = if (opens) try c.b.node(.{ .step = .{ .jump = c.parts[id.raw()][0].? } }) else try body.chain(c, s.node.body, null) orelse try c.back();
            c.b.enter(to, entry);
            for (s.parts, c.parts[id.raw()]) |p, ps| c.b.enter(ps.?, try body.chain(c, p.node.body, null) orelse try c.back());
        },
        .rules => {
            const base = try c.qualified(s.module, s.name);
            for (s.parts) |p| {
                // a rule's body is its effects, fired as one step; one with none fires nothing
                const entry = try body.chain(c, p.node.body, null) orelse try c.b.node(.{ .step = .end });
                try c.b.candidate(to, .{
                    .name = p.name,
                    .when = if (p.node.when) |*w| try exprs.condition(c, w) else .empty,
                    .tags = try c.tags(p.node.tags, try c.arena.print("{s}.{s}", .{ base, p.name })),
                    .entry = entry,
                    .visits = c.visits[p.visit.raw()].?, // a rule's visits are always kept
                    .seen = try c.b.state(try c.arena.print("rule.{s}.{s}", .{ base, p.name })),
                    .migrate = ownNumber(p.node.tags, "migrate"),
                });
            }
        },
        .pool => {
            const base = try c.qualified(s.module, s.name);
            for (s.parts) |p| {
                const entry = try body.chain(c, p.node.body, null) orelse try c.back();
                try c.b.candidate(to, .{
                    .name = p.name,
                    .when = if (p.node.when) |*w| try exprs.condition(c, w) else .empty,
                    .tags = try c.tags(p.node.tags, try c.arena.print("{s}.{s}", .{ base, p.name })),
                    .entry = entry,
                    .visits = c.visits[p.visit.raw()].?, // a candidate's visits are always kept
                    .seen = try c.b.state(try c.arena.print("seen.{s}.{s}", .{ base, p.name })),
                    .weight = ownNumber(p.node.tags, "weight"),
                });
            }
        },
    }
}

test {
    _ = Compiler;
    _ = declare;
    _ = body;
    _ = exprs;
    _ = @import("compile/text.zig");
    _ = @import("compile/compile_test.zig");
    _ = @import("compile/proof_test.zig");
}
