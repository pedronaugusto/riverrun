//! What changed: a stamp per fact, so a reader of a few facts learns which of
//! them changed without the store keeping a list of who is listening.
//!
//! A store marks a fact each time its value changes. A `Watcher` holds the
//! facts it reads and the stamp it last saw, and takes the ones changed since
//! into the caller's buffer. Any number of watchers read one `Changes`, and
//! nothing is allocated after `init`. The quest package re-evaluates only the
//! conditions that read a fact that changed this way.

const std = @import("std");
const FactId = @import("value.zig").FactId;

pub const Changes = struct {
    stamps: []u64,
    clock: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, facts: usize) error{OutOfMemory}!Changes {
        const stamps = try gpa.alloc(u64, facts);
        @memset(stamps, 0);
        return .{ .stamps = stamps };
    }

    pub fn deinit(c: *Changes, gpa: std.mem.Allocator) void {
        gpa.free(c.stamps);
        c.* = undefined;
    }

    /// Called by a store when `fact`'s value changes.
    pub fn mark(c: *Changes, fact: FactId) void {
        c.clock += 1;
        c.stamps[fact.raw()] = c.clock;
    }

    /// The stamp of the latest change: a watcher that saw it has seen everything.
    pub fn now(c: *const Changes) u64 {
        return c.clock;
    }

    pub fn changedSince(c: *const Changes, fact: FactId, since: u64) bool {
        return c.stamps[fact.raw()] > since;
    }
};

pub const Watcher = struct {
    /// The facts this watcher reads.
    interest: []const FactId,
    seen: u64,

    /// A watcher that will be told of changes from now on.
    pub fn init(interest: []const FactId, changes: *const Changes) Watcher {
        return .{ .interest = interest, .seen = changes.now() };
    }

    /// The facts of its interest changed since the last take, in the order of its interest.
    /// `out` holds as many ids as the interest, so every change fits.
    pub fn take(w: *Watcher, changes: *const Changes, out: []FactId) error{BufferTooSmall}![]FactId {
        if (out.len < w.interest.len) return error.BufferTooSmall;
        var n: usize = 0;
        for (w.interest) |fact| {
            if (!changes.changedSince(fact, w.seen)) continue;
            out[n] = fact;
            n += 1;
        }
        w.seen = changes.now();
        return out[0..n];
    }
};

test "a watcher is told only of the facts it reads, once each" {
    const gpa = std.testing.allocator;
    var changes: Changes = try .init(gpa, 8);
    defer changes.deinit(gpa);
    changes.mark(.fromRaw(1));
    const reads = [_]FactId{ .fromRaw(2), .fromRaw(5) };
    var quest: Watcher = .init(&reads, &changes);
    var other: Watcher = .init(&.{.fromRaw(1)}, &changes);
    changes.mark(.fromRaw(5));
    changes.mark(.fromRaw(1));
    var out: [2]FactId = undefined;
    const changed = try quest.take(&changes, &out);
    try std.testing.expectEqual(@as(usize, 1), changed.len);
    try std.testing.expectEqual(@as(u16, 5), changed[0].raw());
    try std.testing.expectEqual(@as(usize, 0), (try quest.take(&changes, &out)).len);
    try std.testing.expectEqual(@as(usize, 1), (try other.take(&changes, &out)).len);
    var small: [1]FactId = undefined;
    try std.testing.expectError(error.BufferTooSmall, quest.take(&changes, &small));
}
