//! The compiler as a game's build runs it, through `addStory`:
//!
//!     riverrun-compile <graph out> <words out> [--release] <file.river>…
//!
//! It reads the files, checks them against the host's vocabulary (the
//! `vocabulary` module the build gives it: `pub const options`, and
//! `pub const passes` where packages add theirs), and writes the graph and
//! its string table. Every diagnostic is printed as `file:line:col:
//! severity: message`; an error stops it before anything is written.

const std = @import("std");
const riverrun = @import("riverrun");
const vocabulary = @import("vocabulary");

const syntax = riverrun.syntax;
const max_file = syntax.max_file;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    const graph_path = args.next() orelse return usage();
    const words_path = args.next() orelse return usage();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var options: riverrun.check.Options = vocabulary.options;
    var paths: std.ArrayList([]const u8) = .empty;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--release")) options.mode = .release else try paths.append(arena, try arena.dupe(u8, a));
    }
    if (paths.items.len == 0) return usage();

    var diags: syntax.Diagnostics = .{};
    defer diags.deinit(gpa);
    const cwd = std.Io.Dir.cwd();
    const trees = try arena.alloc(syntax.ast.File, paths.items.len);
    for (paths.items, trees, 0..) |path, *tree, i| {
        const bytes = try cwd.readFileAlloc(io, path, arena, .limited(max_file + 1));
        tree.* = try syntax.parse(arena, gpa, &diags, @intCast(i), path, bytes); // safe: fewer files than a FileId holds, which the checker asserts
    }
    var checked = try riverrun.check.run(gpa, &diags, trees, options);
    defer checked.deinit();

    var buf: [4096]u8 = undefined;
    var err = std.Io.File.stderr().writer(io, &buf);
    for (diags.list.items) |d| {
        const severity = switch (d.severity) {
            .err => "error",
            .warning => "warning",
        };
        try err.interface.print("{s}:{d}:{d}: {s}: {s}\n", .{ trees[d.span.file].path, d.span.line, d.span.col, severity, d.message });
    }
    try err.interface.flush();
    if (diags.errors() > 0) return 1;

    const passes: []const riverrun.compile.Pass = if (@hasDecl(vocabulary, "passes")) vocabulary.passes else &.{};
    var out = try riverrun.compile.run(gpa, &diags, &checked, .{ .passes = passes });
    defer out.deinit(gpa);
    try cwd.writeFile(io, .{ .sub_path = graph_path, .data = out.graph });
    try cwd.writeFile(io, .{ .sub_path = words_path, .data = out.words });
    return 0;
}

fn usage() u8 {
    std.log.err("usage: riverrun-compile <graph out> <words out> [--release] <file.river>…", .{});
    return 2;
}
