//! What changed: a stamp per fact, so a reader of a few facts learns which of
//! them changed without the store keeping a list of who is listening, and a
//! log of the latest marks, so a reader that keeps up learns what changed
//! without asking every fact it reads.
//!
//! A store marks a fact each time its value changes, a fact kept per thing
//! with the key that changed. A `Watcher` holds the facts it reads and the
//! stamp it last saw, and takes the ones changed since into the caller's
//! buffer; a reader of many facts reads the log since its stamp instead, while
//! the log still holds it. Any number of readers read one `Changes`, and
//! nothing is allocated after `init`. The quest package re-evaluates only the
//! conditions that read a fact that changed this way.

const std = @import("std");
const value = @import("value.zig");
const FactId = value.FactId;

/// The most marks the log keeps: a reader further behind asks the stamps.
pub const log_size = 4096;

/// One mark: the fact that changed, and for a fact kept per thing the key that did, where the store said.
pub const Mark = struct { fact: FactId, key: ?value.Key = null };

pub const Changes = struct {
    stamps: []u64,
    clock: u64 = 0,
    /// The latest marks, the one at stamp `t` at `t % log_size`.
    log: []Mark,

    pub fn init(gpa: std.mem.Allocator, facts: usize) error{OutOfMemory}!Changes {
        const stamps = try gpa.alloc(u64, facts);
        errdefer gpa.free(stamps);
        @memset(stamps, 0);
        return .{ .stamps = stamps, .log = try gpa.alloc(Mark, log_size) };
    }

    pub fn deinit(c: *Changes, gpa: std.mem.Allocator) void {
        gpa.free(c.stamps);
        gpa.free(c.log);
        c.* = undefined;
    }

    /// Called by a store when `fact`'s value changes.
    pub fn mark(c: *Changes, fact: FactId) void {
        c.clock += 1;
        c.stamps[fact.raw()] = c.clock;
        c.log[c.clock % log_size] = .{ .fact = fact };
    }

    /// Called by a store when a fact kept per thing changes for `key`: what reads that key alone is told.
    pub fn markKey(c: *Changes, fact: FactId, key: value.Key) void {
        c.mark(fact);
        c.log[c.clock % log_size].key = key;
    }

    /// The marks since stamp `since`, oldest first, while the log holds them all with room to spare for what
    /// the reader marks as it reads; null when it does not, and the stamps must be asked.
    pub fn marksSince(c: *const Changes, from: u64) ?Marks {
        if (from > c.clock or c.clock - from > log_size / 2) return null;
        return .{ .changes = c, .at = from, .to = c.clock };
    }

    pub const Marks = struct {
        changes: *const Changes,
        at: u64,
        to: u64,

        pub fn next(m: *Marks) ?Mark {
            if (m.at == m.to) return null;
            m.at += 1;
            return m.changes.log[m.at % log_size];
        }
    };

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

test "the log gives the marks since a stamp, with their keys, while it holds them" {
    const gpa = std.testing.allocator;
    var changes: Changes = try .init(gpa, 8);
    defer changes.deinit(gpa);
    const from = changes.now();
    changes.mark(.fromRaw(3));
    changes.markKey(.fromRaw(4), 41);
    var marks = changes.marksSince(from).?;
    try std.testing.expectEqual(@as(u16, 3), marks.next().?.fact.raw());
    try std.testing.expectEqual(@as(?value.Key, 41), marks.next().?.key);
    try std.testing.expectEqual(@as(?Mark, null), marks.next());
    // too far behind, the reader asks the stamps
    for (0..log_size) |_| changes.mark(.fromRaw(1));
    try std.testing.expectEqual(@as(?Changes.Marks, null), changes.marksSince(from));
}
