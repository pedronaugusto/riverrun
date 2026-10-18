//! The check layer: a story's syntax trees with every name resolved, every
//! expression typed, every flow followed and every tag held to the host's
//! schema. All of what it finds is reported, not the first; what it resolves
//! is a `Checked` the compiler reads. It needs only `syntax`, and nothing at
//! run time needs it.
//!
//! Its passes, in order: declare every name (`declare`), walk every
//! statement (`walk`: names, types, tags, widths, ids), then the graph
//! (`flow`: dead ends, reachability, returns), then what no single statement
//! shows (a fact nothing sets), then each package's own pass.

const std = @import("std");
const syntax = @import("syntax.zig");

pub const symbols = @import("check/symbols.zig");
pub const Checked = @import("check/Checked.zig");
/// The checker while it works: what a package's pass and its kind's hooks are given, to read the story and to
/// report where it is written.
pub const Checker = @import("check/Checker.zig");
pub const Options = Checker.Options;
pub const Schema = Checker.Schema;
pub const Mode = Checker.Mode;
pub const Width = Checker.Width;
pub const Kind = Checker.Kind;
pub const Declared = Checker.Declared;
pub const Pass = Checker.Pass;
pub const Builtin = Checker.Builtin;
pub const Things = Checker.Things;

const declare = @import("check/declare.zig");
const walk = @import("check/walk.zig");
const flow = @import("check/flow.zig");

/// Checks the files of one story, numbered as their spans' `file`. Problems
/// go to `diags`; what could be resolved is returned even when some could
/// not, for tools. The trees must outlive the result.
pub fn run(gpa: std.mem.Allocator, diags: *syntax.Diagnostics, files: []const syntax.ast.File, options: Options) error{OutOfMemory}!Checked {
    std.debug.assert(files.len <= std.math.maxInt(syntax.FileId) + 1);
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    var c: Checker = .{ .gpa = gpa, .arena = arena.allocator(), .diags = diags, .files = files, .options = options };
    try c.numberModules();
    try declare.run(&c);
    try walk.run(&c);
    try flow.run(&c);
    for (c.facts.items) |f| if (!f.game and !f.moment and !f.set) {
        try c.warn(f.span, "nothing sets `{s}`: declare it `(game)` if the game writes it", .{f.name});
    };
    const out: Checked = .{
        .arena = arena,
        .files = files,
        .speakers = c.speakers.items,
        .facts = c.facts.items,
        .consts = c.consts.items,
        .externs = c.externs.items,
        .enums = c.enums.items,
        .kinds = c.kinds.items,
        .modules = c.module_names.items,
        .version = c.version,
        .registered = try registered(arena.allocator(), options.kinds),
        .sections = c.sections.items,
        .labels = c.labels.items,
        .visits = c.visits.items,
        .entries = c.entries.items,
        .edges = c.edges.items,
        .speaker_names = c.speaker_names,
        .value_names = c.value_names,
        .section_names = c.section_names,
        .names = c.names,
        .exprs = c.exprs,
        .lines = c.lines,
        .tags = c.tags,
        .text_tags = c.text_tags,
    };
    for (options.passes) |p| try p.run(p.user, &c, &out);
    return out;
}

fn registered(arena: std.mem.Allocator, kinds: []const Kind) error{OutOfMemory}![]const symbols.Registered {
    const out = try arena.alloc(symbols.Registered, kinds.len);
    for (kinds, out) |k, *r| r.* = .{ .name = k.name, .builtins = k.builtins };
    return out;
}

test {
    _ = symbols;
    _ = Checked;
    _ = @import("check/schema.zig");
    _ = @import("check/tags.zig");
    _ = @import("check/ids.zig");
    _ = @import("check/width.zig");
    _ = @import("check/never.zig");
    _ = @import("check/proof_test.zig");
    _ = @import("check/errors_test.zig");
}
