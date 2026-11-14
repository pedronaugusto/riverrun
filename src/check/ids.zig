//! Line ids: what translations, recorded voices and saves key on, so they
//! survive a typo fix. A line or a choice is given one with the tag
//! `# id k7f3a2`, which `riverrun tag` writes; every id is unique in the
//! story. A release refuses a line without one. A development build
//! derives one, so a story can be played before it is tagged.
//!
//! A pool's candidate is named by its section and part, which are unique
//! already; its lines carry ids as any line does.

const std = @import("std");
const syntax = @import("../syntax.zig");
const sym = @import("symbols.zig");
const Checker = @import("Checker.zig");
const id_key = @import("schema.zig").id_key;

const ast = syntax.ast;
const Error = Checker.Error;

/// Where a line is, for an id derived from it.
pub const Path = struct {
    section: []const u8,
    part: ?[]const u8,
    /// The line's place among the lines and choices of its section or part, from zero.
    ordinal: u32,
};

/// Gives the line or choice `stmt` its id, from its tags.
pub fn give(c: *Checker, stmt: *const ast.Stmt, path: Path, speaker: ?[]const u8, text: ast.Text) Error!void {
    const id: sym.LineId = if (try written(c, stmt.tags)) |w| .{ .text = w, .written = true } else switch (c.options.mode) {
        .release => return c.err(stmt.span, "a release needs every line's `# id`: `riverrun tag` writes them", .{}),
        .development => .{ .text = try derive(c, path, speaker, text), .written = false },
    };
    const slot = try c.line_ids.getOrPut(c.arena, id.text);
    if (slot.found_existing) {
        return c.err(stmt.span, "the line id `{s}` is used twice: first at {f}", .{ id.text, c.place(slot.value_ptr.*) });
    }
    slot.value_ptr.* = stmt.span;
    try c.lines.put(c.arena, stmt, id);
}

fn written(c: *Checker, tagged: []const ast.Tag) Error!?[]const u8 {
    var found: ?[]const u8 = null;
    for (tagged) |tag| {
        if (!std.mem.eql(u8, tag.key.text, id_key)) continue;
        if (found != null) {
            try c.err(tag.key.span, "a line has one `id`", .{});
            continue;
        }
        if (tag.values.len != 1 or !isId(tag.values[0])) {
            try c.err(tag.key.span, "`id` takes one id: letters, digits, `_` and `-`", .{});
            continue;
        }
        found = tag.values[0];
    }
    return found;
}

fn isId(v: []const u8) bool {
    if (v.len == 0) return false;
    for (v) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) return false;
    return true;
}

/// A development id: `~` and sixteen hex digits of a hash of the section, the
/// part, the line's place in it, its speaker and its literal words. It moves
/// when any of those do, which is why a release needs written ones; the `~`
/// keeps it apart from any id a writer or `riverrun tag` writes.
pub fn derive(c: *Checker, path: Path, speaker: ?[]const u8, text: ast.Text) Error![]const u8 {
    var h: std.hash.Wyhash = .init(0);
    h.update(path.section);
    h.update(&.{0});
    h.update(path.part orelse "");
    h.update(&.{0});
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, path.ordinal)));
    h.update(speaker orelse "");
    h.update(&.{0});
    words(&h, text);
    return c.arena.print("~{x:0>16}", .{h.final()});
}

fn words(h: *std.hash.Wyhash, text: ast.Text) void {
    for (text) |piece| switch (piece.kind) {
        .literal => |s| h.update(s),
        .value => h.update("{}"),
        .choose => |ch| {
            words(h, ch.then);
            h.update("|");
            words(h, ch.otherwise);
        },
        .alternatives => |alt| for (alt.options) |o| {
            words(h, o);
            h.update("|");
        },
        .select => |sel| for (sel.branches) |b| {
            h.update(b.label.text);
            words(h, b.text);
            h.update("|");
        },
    };
}

test "a derived id is stable and moves with the words" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: syntax.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    var c: Checker = .{ .gpa = std.testing.allocator, .arena = arena.allocator(), .diags = &diags, .files = &.{}, .options = .{} };
    const path: Path = .{ .section = "kitchen_1985", .part = null, .ordinal = 2 };
    const go: ast.Text = &.{.{ .span = .none, .kind = .{ .literal = "Go." } }};
    const a = try derive(&c, path, "dad", go);
    try std.testing.expectEqualStrings(a, try derive(&c, path, "dad", go));
    try std.testing.expect(!std.mem.eql(u8, a, try derive(&c, path, "dad", &.{.{ .span = .none, .kind = .{ .literal = "Go on." } }})));
    try std.testing.expectEqual(@as(usize, 17), a.len);
}
