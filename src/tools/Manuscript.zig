//! A story as its writer has it: each of its files' text read to the tree
//! that keeps every byte, and every diagnostic the reader, the checker and
//! the compiler gave it, in one list. What `riverrun check`, `tag` and
//! `compile` hold, read the same way a game's build reads its story, so a
//! story that checks here builds there.

const std = @import("std");
const aegis = @import("aegis");
const river = @import("riverrun-compiler");

const Manuscript = @This();
const syntax = river.syntax;
const ast = syntax.ast;

/// A file of the story: where it is, and its bytes.
pub const Page = struct { path: []const u8, text: []const u8 };

/// The most files one story holds: as many as a span's file id numbers.
pub const max_files = std.math.maxInt(syntax.FileId) + 1;

gpa: std.mem.Allocator,
/// Holds the pages' text and their trees.
arena: *std.heap.ArenaAllocator,
diags: syntax.Diagnostics = .{},
/// Each page's tree, in the order given: a diagnostic's `span.file` is its place here.
files: []const ast.File,
/// What the checker resolved, once `check` has run.
checked: ?river.check.Checked = null,

/// Reads each page, copied, to its tree; what the reader refuses is in `diags`.
pub fn read(gpa: std.mem.Allocator, pages: []const Page) error{ OutOfMemory, TooManyFiles }!Manuscript {
    if (pages.len > max_files) return error.TooManyFiles;
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    var m: Manuscript = .{ .gpa = gpa, .arena = arena, .files = &.{} };
    errdefer m.diags.deinit(gpa);
    const a = arena.allocator();
    const files = try a.alloc(ast.File, pages.len);
    for (pages, files, 0..) |p, *f, i| {
        f.* = try syntax.parse(a, gpa, &m.diags, @intCast(i), try a.dupe(u8, p.path), try a.dupe(u8, p.text)); // safe: at most max_files
    }
    m.files = files;
    return m;
}

pub fn deinit(m: *Manuscript) void {
    if (m.checked) |*c| c.deinit();
    m.diags.deinit(m.gpa);
    m.arena.deinit();
    m.gpa.destroy(m.arena);
    m.* = undefined;
}

/// The errors among the diagnostics so far.
pub fn errors(m: *const Manuscript) usize {
    return m.diags.errors();
}

/// Checks the story against a vocabulary's options, as a game's build does: every file together, every problem
/// reported.
pub fn check(m: *Manuscript, options: river.check.Options) error{OutOfMemory}!void {
    aegis.assert.invariant(m.checked == null, "a manuscript is checked once");
    m.checked = try river.check.run(m.gpa, &m.diags, m.files, options);
}

/// Compiles the checked story with the vocabulary's passes: its graph and string table, which the caller owns, or
/// null when it is refused, the reasons in the diagnostics.
pub fn compile(m: *Manuscript, passes: []const river.compile.Pass) river.compile.Compiler.Error!?river.compile.Compiled {
    const checked = &(m.checked orelse return null);
    return river.compile.run(m.gpa, &m.diags, checked, .{ .passes = passes }) catch |e| switch (e) {
        // what the checker refused is never compiled; a package's pass refused it, and said where
        error.StoryHasErrors, error.PassFailed => null,
        else => |other| other,
    };
}

/// Reads, checks and compiles `pages` with a joined vocabulary, as the game's build does.
pub fn build(gpa: std.mem.Allocator, pages: []const Page, joined: river.Joined, mode: river.check.Mode) (river.compile.Compiler.Error || error{TooManyFiles})!struct { Manuscript, ?river.compile.Compiled } {
    var m: Manuscript = try .read(gpa, pages);
    errdefer m.deinit();
    var options = joined.options;
    options.mode = mode;
    try m.check(options);
    // compiled before `m` is copied out: the diagnostics compiling adds are in the copy
    const out = try m.compile(joined.passes);
    return .{ m, out };
}

test "a story is read, checked and compiled as one, and refused with every reason" {
    const gpa = std.testing.allocator;
    const joined = comptime river.join(struct {
        pub const options: river.check.Options = .{};
    });
    {
        var m, var out = try build(gpa, &.{ .{ .path = "a.river", .text = "== a\n-> b\n" }, .{ .path = "b.river", .text = "== b\nGo.\n-> end\n" } }, joined, .development);
        defer m.deinit();
        defer if (out) |*o| o.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), m.errors());
        try std.testing.expect(out != null);
    }
    {
        var m, const out = try build(gpa, &.{.{ .path = "a.river", .text = "== a\n-> nowhere\n" }}, joined, .development);
        defer m.deinit();
        try std.testing.expect(out == null);
        try std.testing.expect(m.errors() > 0);
    }
}
