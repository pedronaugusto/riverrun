//! One clock's waiting comparisons: a binary heap of the instants at which
//! each next flips, indexed by slot so a condition moves its own entry in
//! place. A slot is a condition's for good once given; the heap's room is
//! taken when a slot is, so arming and disarming never allocate.

const std = @import("std");

const none = std.math.maxInt(u32);

pub const Entry = struct { instant: i64, slot: u32 };

pub const Top = struct { instant: i64, cond: u32, slot: u32 };

pub const Heap = struct {
    /// By slot: the condition it is for.
    conds: std.ArrayList(u32) = .empty,
    /// By slot: where its entry is in `items`, or `none` while it waits for nothing.
    pos: std.ArrayList(u32) = .empty,
    items: std.ArrayList(Entry) = .empty,

    pub fn deinit(h: *Heap, gpa: std.mem.Allocator) void {
        h.conds.deinit(gpa);
        h.pos.deinit(gpa);
        h.items.deinit(gpa);
        h.* = undefined;
    }

    /// A new slot for `cond`, waiting for nothing yet.
    pub fn slot(h: *Heap, gpa: std.mem.Allocator, cond: u32) error{OutOfMemory}!u32 {
        if (h.conds.items.len == none - 1) return error.OutOfMemory;
        try h.conds.append(gpa, cond);
        errdefer _ = h.conds.pop();
        try h.pos.append(gpa, none);
        errdefer _ = h.pos.pop();
        try h.items.ensureTotalCapacity(gpa, h.conds.items.len);
        return @intCast(h.conds.items.len - 1); // safe: checked above
    }

    pub fn slots(h: *const Heap) usize {
        return h.conds.items.len;
    }

    /// The soonest instant, and whose it is.
    pub fn peek(h: *const Heap) ?Top {
        if (h.items.items.len == 0) return null;
        const e = h.items.items[0];
        return .{ .instant = e.instant, .cond = h.conds.items[e.slot], .slot = e.slot };
    }

    /// `slot` waits for `instant`, whether or not it waited before.
    pub fn set(h: *Heap, s: u32, instant: i64) void {
        const at = h.pos.items[s];
        if (at == none) {
            h.items.appendAssumeCapacity(.{ .instant = instant, .slot = s });
            h.pos.items[s] = @intCast(h.items.items.len - 1); // safe: at most one entry per slot
            h.up(h.items.items.len - 1);
            return;
        }
        const was = h.items.items[at].instant;
        h.items.items[at].instant = instant;
        if (instant < was) h.up(at) else h.down(at);
    }

    /// `slot` waits for nothing.
    pub fn remove(h: *Heap, s: u32) void {
        const at = h.pos.items[s];
        if (at == none) return;
        const last = h.items.items.len - 1;
        h.swap(at, last);
        _ = h.items.pop();
        h.pos.items[s] = none;
        if (at < h.items.items.len) {
            h.up(at);
            h.down(at);
        }
    }

    fn less(h: *const Heap, a: usize, b: usize) bool {
        const x = h.items.items[a];
        const y = h.items.items[b];
        // equal instants by slot, so the order is the same however the heap was built
        return x.instant < y.instant or (x.instant == y.instant and x.slot < y.slot);
    }

    fn swap(h: *Heap, a: usize, b: usize) void {
        std.mem.swap(Entry, &h.items.items[a], &h.items.items[b]);
        h.pos.items[h.items.items[a].slot] = @intCast(a); // safe: below the slot count, a u32
        h.pos.items[h.items.items[b].slot] = @intCast(b); // safe: below the slot count, a u32
    }

    fn up(h: *Heap, start: usize) void {
        var i = start;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (!h.less(i, parent)) return;
            h.swap(i, parent);
            i = parent;
        }
    }

    fn down(h: *Heap, start: usize) void {
        var i = start;
        const n = h.items.items.len;
        while (true) {
            const l = 2 * i + 1;
            if (l >= n) return;
            const r = l + 1;
            const child = if (r < n and h.less(r, l)) r else l;
            if (!h.less(child, i)) return;
            h.swap(i, child);
            i = child;
        }
    }
};

test "the soonest instant comes first, and a slot moves its own entry" {
    const gpa = std.testing.allocator;
    var h: Heap = .{};
    defer h.deinit(gpa);
    const a = try h.slot(gpa, 10);
    const b = try h.slot(gpa, 11);
    const c = try h.slot(gpa, 12);
    h.set(a, 50);
    h.set(b, 20);
    h.set(c, 30);
    try std.testing.expectEqual(@as(u32, 11), h.peek().?.cond);
    h.set(b, 60);
    try std.testing.expectEqual(@as(u32, 12), h.peek().?.cond);
    h.remove(c);
    try std.testing.expectEqual(@as(i64, 50), h.peek().?.instant);
    h.remove(a);
    h.remove(b);
    try std.testing.expectEqual(@as(?Top, null), h.peek());
    try std.testing.expectEqual(@as(usize, 3), h.slots());
}
