//! A package for addStory's test, as a game's would be: a kind of section
//! whose parts are wares, each a fact the story reads; a tag naming one,
//! which the package judges; a check that a stock has wares; and a pass
//! that writes the package's block; and, played without the game, a stall
//! that opens with its wares, and the game's two calls into it offered as
//! the play's commands: a stock opened for trade with its keeper, once, and
//! a ware restocked by a number.

const std = @import("std");
const riverrun = @import("riverrun-compiler");

const check = riverrun.check;
const ast = riverrun.syntax.ast;
const runtime = @import("riverrun");
const facts = runtime.facts;
const Story = runtime.story.Story;
const SectionId = runtime.story.SectionId;
const Running = riverrun.Running;

const stock: check.Kind = .{ .name = "stock", .declare = declare };
const keys = [_]check.Schema.Key{.{ .name = "sells", .on = .{ .section = true }, .value = .{ .judge = sells } }};

/// `== wares (stock)`, each part a ware the game counts, and `# sells furs` on any section.
pub const package: riverrun.Package = .{
    .kinds = &.{stock},
    .keys = &keys,
    .check = .{ .run = stocked },
    .compile = .{ .name = "stall", .run = block },
    .running = .{ .name = "stall", .start = open, .stop = close, .commands = &.{
        .{ .name = "open", .object = "stock", .help = "the game opens a stock for trade, its keeper given", .forms = stocks, .run = openStock },
        .{ .name = "restock", .object = "ware", .help = "the game adds to a ware's count", .forms = wares, .run = restock },
    } },
};

// Played without the game: the stall opens with the wares its block counts.
const Stall = struct {
    wares: u8,
    story: *const Story,
    /// The stocks opened for trade, by section.
    opened: std.ArrayList(SectionId) = .empty,
    gpa: std.mem.Allocator,
};

fn open(gpa: std.mem.Allocator, game: Running.Game, told: *Running.Told) error{ OutOfMemory, Stopped }!?*anyopaque {
    const b = game.story.block("stall") orelse return null;
    if (b.bytes.len != 1) return told.stop("the stall's block is not one count", .{});
    const s = try gpa.create(Stall);
    s.* = .{ .wares = b.bytes[0], .story = game.story, .gpa = gpa };
    try told.say(.{ .what = "opens", .name = "stall", .words = &.{try told.arena.print("{d} wares", .{s.wares})} });
    return s;
}

fn close(gpa: std.mem.Allocator, state: *anyopaque) void {
    const s: *Stall = @ptrCast(@alignCast(state));
    s.opened.deinit(gpa);
    gpa.destroy(s);
}

// The story's stocks, each opened with a keeper where the story names the kind of thing a keeper is.
fn stocks(state: *anyopaque, a: std.mem.Allocator) error{OutOfMemory}![]const Running.Form {
    const s: *Stall = @ptrCast(@alignCast(state));
    var out: std.ArrayList(Running.Form) = .empty;
    var keeper: []const Running.Param = &.{};
    for (0..s.story.len(.kinds)) |k| if (std.mem.eql(u8, s.story.refKind(.fromRaw(@intCast(k))), "item_kind")) { // safe: below a u16 count
        keeper = try a.dupe(Running.Param, &.{.{ .name = "keeper", .type = .{ .kind = .ref, .ref_kind = .fromRaw(@intCast(k)) } }}); // safe: below a u16 count
    };
    for (0..s.story.len(.sections)) |i| {
        const sec = s.story.section(.fromRaw(@intCast(i))); // safe: below a u32 count
        if (sec.part_of == null and std.mem.eql(u8, sec.kind_name, "stock")) try out.append(a, .{ .object = sec.name, .params = keeper });
    }
    return out.items;
}

// Each ware of a stock, by the fact that counts it.
fn wares(state: *anyopaque, a: std.mem.Allocator) error{OutOfMemory}![]const Running.Form {
    const s: *Stall = @ptrCast(@alignCast(state));
    var out: std.ArrayList(Running.Form) = .empty;
    const count = try a.dupe(Running.Param, &.{.{ .name = "count", .type = .{ .kind = .int } }});
    for (0..s.story.len(.sections)) |i| {
        const sec = s.story.section(.fromRaw(@intCast(i))); // safe: below a u32 count
        const of = sec.part_of orelse continue;
        if (!std.mem.eql(u8, s.story.section(of).kind_name, "stock")) continue;
        const name = sec.name[std.mem.findScalarLast(u8, sec.name, '.').? + 1 ..];
        if (s.story.factNamed(name) != null) try out.append(a, .{ .object = name, .params = count });
    }
    return out.items;
}

fn openStock(state: *anyopaque, form: usize, args: []const facts.Value, told: *Running.Told) error{ OutOfMemory, Refused, Stopped }!void {
    const s: *Stall = @ptrCast(@alignCast(state));
    const forms = try stocks(state, told.arena);
    const section = s.story.sectionNamed(forms[form].object).?;
    for (s.opened.items) |o| if (o.eql(section)) return told.refuse("`{s}` is open already: a stock opens once", .{forms[form].object});
    try s.opened.append(s.gpa, section);
    _ = args;
    try told.say(.{ .what = "opened", .name = forms[form].object });
}

fn restock(state: *anyopaque, form: usize, args: []const facts.Value, told: *Running.Told) error{ OutOfMemory, Refused, Stopped }!void {
    const s: *Stall = @ptrCast(@alignCast(state));
    const forms = try wares(state, told.arena);
    if (args[0].int <= 0) return told.refuse("a ware is restocked by 1 or more, not {d}", .{args[0].int});
    const fact = s.story.factNamed(forms[form].object).?;
    try told.say(.{ .what = "restocked", .name = forms[form].object, .effects = &.{.{ .change = .{ .fact = fact, .by = args[0].int } }} });
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
