//! A package for addStory's test, as a game's would be: a kind of section
//! whose parts are wares, each a fact the story reads; a tag naming one,
//! which the package judges; a check that a stock has wares; and a pass
//! that writes the package's block; and, played without the game, a stall
//! that opens with its wares.

const std = @import("std");
const riverrun = @import("riverrun-compiler");

const check = riverrun.check;
const ast = riverrun.syntax.ast;

const stock: check.Kind = .{ .name = "stock", .declare = declare };
const keys = [_]check.Schema.Key{.{ .name = "sells", .on = .{ .section = true }, .value = .{ .judge = sells } }};

/// `== wares (stock)`, each part a ware the game counts, and `# sells furs` on any section.
pub const package: riverrun.Package = .{
    .kinds = &.{stock},
    .keys = &keys,
    .check = .{ .run = stocked },
    .compile = .{ .name = "stall", .run = block },
    .running = .{ .name = "stall", .start = open, .stop = close },
};

// Played without the game: the stall opens with the wares its block counts.
const Stall = struct { wares: u8 };

fn open(gpa: std.mem.Allocator, game: riverrun.Running.Game, told: *riverrun.Running.Told) error{ OutOfMemory, Stopped }!?*anyopaque {
    const b = game.story.block("stall") orelse return null;
    if (b.bytes.len != 1) return told.stop("the stall's block is not one count", .{});
    const s = try gpa.create(Stall);
    s.* = .{ .wares = b.bytes[0] };
    try told.say(.{ .what = "opens", .name = "stall", .words = &.{try told.arena.print("{d} wares", .{s.wares})} });
    return s;
}

fn close(gpa: std.mem.Allocator, state: *anyopaque) void {
    gpa.destroy(@as(*Stall, @ptrCast(@alignCast(state))));
}

fn isStock(s: check.symbols.Section) bool {
    return s.kind == .other and std.mem.eql(u8, s.kind.other, stock.name);
}

// Each ware is an int fact the game keeps.
fn declare(arena: std.mem.Allocator, s: *const ast.Section, _: []const ast.File) error{OutOfMemory}![]const check.Declared {
    const out = try arena.alloc(check.Declared, s.subsections.len);
    for (out, s.subsections) |*d, p| d.* = .{ .scope = "world", .fact = .{ .span = p.name.span, .name = p.name, .type = .int, .game = true } };
    return out;
}

// `sells` names a ware of a stock.
fn sells(c: *check.Checker, t: check.Schema.Tagged) error{OutOfMemory}!void {
    const ware = t.tag.values[0];
    for (c.sections.items) |s| if (isStock(s)) for (s.parts) |p| if (std.mem.eql(u8, p.name, ware)) return;
    try c.err(t.tag.key.span, "`{s}` is not a ware of any stock", .{ware});
}

fn stocked(_: ?*anyopaque, c: *check.Checker, story: *const check.Checked) error{OutOfMemory}!void {
    for (story.sections) |s| if (isStock(s) and s.parts.len == 0) try c.err(s.node.name.span, "the stock `{s}` has no wares", .{s.name});
}

// The block: how many wares the story stocks.
fn block(_: ?*anyopaque, c: *riverrun.compile.Compiler) riverrun.compile.Compiler.Error!void {
    var n: u8 = 0;
    for (c.checked.sections) |s| if (isStock(s)) {
        n +|= std.math.cast(u8, s.parts.len) orelse std.math.maxInt(u8);
    };
    try c.b.block("stall", 1, &.{n});
}
