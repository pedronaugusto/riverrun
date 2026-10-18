//! Which candidates a pool gives: of those whose condition holds, the most
//! specific, then the least recently given, then an order the seed and the
//! turn decide, so equals take turns and a replay picks the same. Giving a
//! candidate stamps it with the turn and counts a visit.

const std = @import("std");
const facts = @import("../facts.zig");
const story = @import("../story.zig");
const eval = @import("eval.zig");

/// The most candidates a pool gives at once.
pub const max_pick = 8;

pub const Error = eval.Error || facts.SetError || error{
    /// A pool asks to give more candidates at once than `max_pick`.
    PickTooLarge,
};

/// Candidates given, by their index in the story's candidates.
pub const Picks = struct {
    list: [max_pick]u32 = undefined,
    len: u8 = 0,

    pub fn slice(p: *const Picks) []const u32 {
        return p.list[0..p.len];
    }
};

const Ranked = struct { index: u32, specificity: u16, seen: i64, key: u64 };

/// The candidates `pool` gives now, in the order they are said.
pub fn pick(cx: eval.Context, pool: story.Section) Error!Picks {
    if (pool.pick > max_pick) return error.PickTooLarge;
    const turn_fact = cx.story.turn();
    const turn = cx.store.get(turn_fact).int +| 1;
    try cx.store.set(turn_fact, .{ .int = turn });
    const seed: u64 = @bitCast(cx.store.get(cx.story.seed()).int);
    var rng = std.Random.SplitMix64.init(seed ^ (@as(u64, @bitCast(turn)) *% 0x9E3779B97F4A7C15));
    var matched: std.ArrayList(Ranked) = .empty;
    for (0..pool.candidates.len) |k| {
        const index = pool.candidates.start + @as(u32, @intCast(k)); // safe: below a u32 length
        const c = cx.story.candidate(index);
        if (!try eval.condition(cx, c.when)) continue;
        try matched.append(cx.arena, .{ .index = index, .specificity = c.specificity, .seen = cx.store.get(c.seen).int, .key = rng.next() });
    }
    std.mem.sortUnstable(Ranked, matched.items, {}, before);
    var out: Picks = .{};
    for (matched.items[0..@min(matched.items.len, pool.pick)]) |r| {
        const c = cx.story.candidate(r.index);
        try cx.store.set(c.seen, .{ .int = turn });
        try cx.store.set(c.visits, .{ .int = cx.store.get(c.visits).int +| 1 });
        out.list[out.len] = r.index;
        out.len += 1;
    }
    return out;
}

fn before(_: void, a: Ranked, b: Ranked) bool {
    if (a.specificity != b.specificity) return a.specificity > b.specificity;
    if (a.seen != b.seen) return a.seen < b.seen;
    return a.key < b.key;
}
