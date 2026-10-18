//! A line's words: its template from the string table, with each slot
//! filled. Values are written as the player reads them; a `choose` takes the
//! branch its condition gives; alternatives take the branch their state says
//! and move it on, once per delivery, however often a translation uses the
//! slot. A shuffle's order comes from the seed, so a replay says the same.

const std = @import("std");
const facts = @import("../facts.zig");
const story = @import("../story.zig");
const eval = @import("eval.zig");

const Value = facts.Value;

pub const Error = eval.Error || facts.SetError || error{
    /// The string table has no words for the line: it does not serve this story.
    MissingLine,
};

/// The words of text `id`, in `cx.arena`.
pub fn render(cx: eval.Context, words: *const story.Strings, id: story.TextId) Error![]const u8 {
    const t = cx.story.text(id);
    const template = words.template(t.line) orelse return error.MissingLine;
    var filled: Filled = .{ .count = @intCast(t.slots.len) }; // safe: validated to max_slots
    for (0..t.slots.len) |k| {
        const s = cx.story.slot(t.slots.start + @as(u32, @intCast(k))); // safe: below max_slots
        switch (s.kind) {
            .value => filled.values[k] = try written(cx, s.expr),
            .choose => filled.branches[k] = if (try eval.condition(cx, s.expr)) 0 else 1,
            .plural => filled.categories[k] = cx.language.pluralOf(words.locale(), (try eval.value(cx, s.expr)).int),
            .gender => filled.categories[k] = try genderOf(cx, s.expr),
            else => filled.branches[k] = try alternative(cx, s),
        }
    }
    var out: std.Io.Writer.Allocating = .init(cx.arena);
    story.template.render(template, &filled, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

/// What each slot holds, worked out before the template is written.
pub const Filled = struct {
    count: u8,
    values: [story.max_slots][]const u8 = @splat(""),
    branches: [story.max_slots]?u8 = @splat(null),
    categories: [story.max_slots][]const u8 = @splat("other"),

    pub fn value(f: *const Filled, slot: u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (slot < f.count) try w.writeAll(f.values[slot]);
    }

    pub fn branch(f: *const Filled, slot: u8) ?u8 {
        return if (slot < f.count) f.branches[slot] else null;
    }

    pub fn category(f: *const Filled, slot: u8) []const u8 {
        return if (slot < f.count) f.categories[slot] else "other";
    }
};

// A gender is a cast member's, from its `gender` tag, or a thing's, as the host says.
fn genderOf(cx: eval.Context, r: story.Range) Error![]const u8 {
    const v = try eval.value(cx, r);
    if (v == .ref) return cx.language.genderOf(v.ref);
    const member = cx.story.castMember(.fromRaw(@intCast(v.int))); // safe: the compiler wrote a cast index
    const tag = cx.story.tagNamed(member.tags, "gender") orelse return "other";
    if (tag.values.len == 0) return "other";
    return cx.story.tagValue(tag.values.start).text;
}

/// A value as the player reads it: a number, an item's name, a set's names joined, a text.
fn written(cx: eval.Context, r: story.Range) Error![]const u8 {
    const v = try eval.value(cx, r);
    const e = eval.enumeration(cx.story, r);
    return switch (v) {
        .boolean => |b| if (b) "true" else "false",
        .int => |i| try cx.arena.print("{d}", .{i}),
        .one_of => |i| if (i == Value.none or e == null) "" else itemName(cx.story, e.?, i),
        .text => |x| try cx.arena.dupe(u8, x),
        .set_of => |set| try joined(cx, set, e),
        // a thing is said through a query the host answers, `{name(target)}`: its handle says nothing
        .ref => "",
    };
}

fn itemName(s: *const story.Story, e: story.EnumId, i: u16) []const u8 {
    const r = s.items(e);
    return if (i < r.len) s.item(r.start + i) else "";
}

fn joined(cx: eval.Context, set: facts.Set, e: ?story.EnumId) Error![]const u8 {
    const en = e orelse return "";
    var out: std.Io.Writer.Allocating = .init(cx.arena);
    var it = set.iterator(.{});
    var first = true;
    while (it.next()) |i| {
        if (!first) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.writeAll(itemName(cx.story, en, @intCast(i))) catch return error.OutOfMemory; // safe: below max_items
        first = false;
    }
    return out.written();
}

/// The branch an alternative gives now, its state moved on; null once a `once` is used up.
fn alternative(cx: eval.Context, s: story.Slot) Error!?u8 {
    const fact = s.state.?; // alternatives keep state: validated
    const at = cx.store.get(fact).int;
    const n: i64 = s.arity;
    const state = @max(at, 0);
    const chosen: ?u8, const next: i64 = switch (s.kind) {
        .sequence => .{ @intCast(@min(state, n - 1)), @min(state + 1, n) }, // safe: below arity
        .cycle => .{ @intCast(@mod(state, n)), @mod(state + 1, n) }, // safe: below arity
        .once => .{ if (state < n) @intCast(state) else null, @min(state + 1, n) }, // safe: below arity
        .shuffle => .{ shuffled(cx, fact, s.arity, state), state +| 1 },
        .value, .choose, .plural, .gender => unreachable, // unreachable: `render` handles them
    };
    try cx.store.set(fact, .{ .int = next });
    return chosen;
}

// The branch at `state` of an order shuffled afresh every round of `arity`, from the seed.
fn shuffled(cx: eval.Context, fact: facts.FactId, arity: u8, state: i64) u8 {
    const round: u64 = @intCast(@divTrunc(state, arity)); // safe: state is not negative
    const seed: u64 = @bitCast(cx.store.get(cx.story.seed()).int);
    var rng = std.Random.SplitMix64.init(seed ^ (round *% 0x9E3779B97F4A7C15) ^ (@as(u64, fact.raw()) << 48));
    var order: [story.max_slots]u8 = undefined;
    for (order[0..arity], 0..) |*o, i| o.* = @intCast(i); // safe: below max_slots
    var i: usize = arity;
    while (i > 1) : (i -= 1) {
        const j = rng.next() % i;
        std.mem.swap(u8, &order[i - 1], &order[j]);
    }
    return order[@intCast(@mod(state, arity))]; // safe: below arity
}
