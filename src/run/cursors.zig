//! Where a session's flows are, saved so they survive a recompiled story.
//!
//! A step is saved by the section it belongs to and its place in that
//! section's walk, with its kind and its line id to check it by. Restored
//! under another version, a step that moved is found again by its line id;
//! one that is gone ends its flow, and the report says so. The facts are
//! saved apart, by their own snapshots.
//!
//!     magic    "RRFLOWS\0"
//!     version  u16 (1)
//!     story    u64     the hash of the story it was taken under
//!     flows    max_flows × flow
//!     flow     state u8 (0 stopped, 1 telling, 2 ended); when telling:
//!              at anchor, effect_at u32, depth u8, depth × frame
//!     frame    back anchor, effect_at u32, pool u8; when a pool:
//!              section str, given u8, picks u8, picks × candidate name str
//!     anchor   present u8; when present: section str, place u32, kind u8, line u64
//!     str      u16 length, then that many bytes

const std = @import("std");
const story = @import("../story.zig");
const flow_ = @import("flow.zig");
const pool = @import("pool.zig");

const NodeId = story.NodeId;
const SectionId = story.SectionId;

pub const magic = "RRFLOWS\x00".*;
pub const version: u16 = 1;

pub const SaveError = error{
    OutOfMemory,
    /// A flow owes an action's outcome: give it before saving.
    AwaitingOutcome,
};

pub const RestoreError = error{
    OutOfMemory,
    /// Bytes that are not a save of flows, or are cut short.
    BadCursors,
    UnsupportedVersion,
};

/// What a restore could not keep.
pub const Report = struct {
    /// Taken under the story it is restored into.
    same_story: bool,
    /// Steps found again by their line id after they moved.
    moved: u8 = 0,
    /// Flows ended because a step they were at is gone.
    lost: u8 = 0,
    /// Pool candidates no longer in their pool, left out.
    dropped: u8 = 0,
};

/// Every step's section and place in it, by walking each section from its entry.
const Places = struct {
    of: std.AutoHashMapUnmanaged(u32, Place) = .empty,
    /// Each section's steps in walk order.
    order: []std.ArrayList(u32),

    const Place = struct { section: u32, place: u32 };

    fn init(gpa: std.mem.Allocator, s: *const story.Story) error{OutOfMemory}!Places {
        var p: Places = .{ .order = try gpa.alloc(std.ArrayList(u32), s.len(.sections)) };
        for (p.order) |*o| o.* = .empty;
        errdefer p.deinit(gpa);
        var todo: std.ArrayList(u32) = .empty;
        defer todo.deinit(gpa);
        for (0..s.len(.sections)) |i| {
            const sec = s.section(.fromRaw(@intCast(i))); // safe: below a u32 count
            try p.walk(gpa, s, @intCast(i), sec.entry, &todo); // safe: below a u32 count
            for (0..sec.candidates.len) |k| try p.walk(gpa, s, @intCast(i), s.candidate(sec.candidates.start + @as(u32, @intCast(k))).entry, &todo); // safe: below u32 counts
        }
        return p;
    }

    fn deinit(p: *Places, gpa: std.mem.Allocator) void {
        p.of.deinit(gpa);
        for (p.order) |*o| o.deinit(gpa);
        gpa.free(p.order);
    }

    // Every step reached from `root` without leaving the section, claimed for `section` in walk order.
    fn walk(p: *Places, gpa: std.mem.Allocator, s: *const story.Story, section: u32, root: ?NodeId, todo: *std.ArrayList(u32)) error{OutOfMemory}!void {
        const r = root orelse return;
        try todo.append(gpa, r.raw());
        while (todo.pop()) |n| {
            const gop = try p.of.getOrPut(gpa, n);
            if (gop.found_existing) continue;
            gop.value_ptr.* = .{ .section = section, .place = @intCast(p.order[section].items.len) }; // safe: below a u32 count
            try p.order[section].append(gpa, n);
            var after: [story.max_choices + 2]?NodeId = @splat(null);
            const node = s.node(.fromRaw(n));
            switch (node.step) {
                .line => |x| after[0] = x.next,
                .choices => |x| {
                    after[0] = x.next;
                    for (0..x.choices.len) |k| after[k + 1] = s.choice(x.choices.start + @as(u32, @intCast(k))).target; // safe: below max_choices
                },
                .branch => |x| {
                    after[0] = x.otherwise;
                    after[1] = x.then;
                },
                .gather => |x| after[0] = x.next,
                .effects => |x| after[0] = x.next,
                .call => |x| after[0] = x.next,
                .jump, .ret, .end => {},
            }
            var k = after.len;
            while (k > 0) {
                k -= 1;
                if (after[k]) |a| try todo.append(gpa, a.raw());
            }
        }
    }
};

/// The line id a step is checked by: a line's, or the first choice's; 0 for other steps.
fn lineOf(s: *const story.Story, id: NodeId) u64 {
    return switch (s.node(id).step) {
        .line => |x| s.text(x.text).line.raw(),
        .choices => |x| s.text(s.choice(x.choices.start).text).line.raw(),
        else => 0,
    };
}

/// Where each of `flows` is in `s`, as bytes.
pub fn save(gpa: std.mem.Allocator, s: *const story.Story, flows: []const flow_.Flow) SaveError![]u8 {
    var places: Places = try .init(gpa, s);
    defer places.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const w: Writer = .{ .gpa = gpa, .out = &out };
    try w.bytes(&magic);
    try w.int(u16, version);
    try w.int(u64, s.hash());
    for (flows) |*f| {
        if (f.pending == .outcomes) return error.AwaitingOutcome;
        try w.int(u8, if (!f.started) 0 else if (f.ended) 2 else 1);
        if (!f.started or f.ended) continue;
        const at: ?NodeId = if (f.pending == .choices) f.pending.choices.node else f.at;
        try w.anchor(s, &places, at);
        try w.int(u32, if (f.pending == .choices) 0 else f.effect_at);
        try w.int(u8, f.depth);
        for (f.frames[0..f.depth]) |fr| try w.frame(s, &places, fr);
    }
    return out.toOwnedSlice(gpa);
}

const Writer = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),

    fn bytes(w: Writer, b: []const u8) error{OutOfMemory}!void {
        try w.out.appendSlice(w.gpa, b);
    }

    fn int(w: Writer, comptime T: type, v: T) error{OutOfMemory}!void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try w.bytes(&b);
    }

    fn str(w: Writer, s: []const u8) error{OutOfMemory}!void {
        try w.int(u16, @intCast(s.len)); // safe: names are at most a few hundred bytes
        try w.bytes(s);
    }

    fn anchor(w: Writer, s: *const story.Story, places: *const Places, at: ?NodeId) error{OutOfMemory}!void {
        const id = at orelse return w.int(u8, 0);
        const place = places.of.get(id.raw()) orelse return w.int(u8, 0);
        try w.int(u8, 1);
        try w.str(s.section(.fromRaw(place.section)).name);
        try w.int(u32, place.place);
        try w.int(u8, @backingInt(@as(story.format.NodeKind, s.node(id).step)));
        try w.int(u64, lineOf(s, id));
    }

    fn frame(w: Writer, s: *const story.Story, places: *const Places, fr: flow_.Frame) error{OutOfMemory}!void {
        try w.anchor(s, places, fr.back);
        try w.int(u32, fr.effect_at);
        const p = fr.pool orelse return w.int(u8, 0);
        try w.int(u8, 1);
        try w.str(s.section(p.section).name);
        try w.int(u8, p.given);
        try w.int(u8, p.picks.len);
        for (p.picks.slice()) |c| try w.str(s.candidate(c).name);
    }
};

/// Puts the session's flows where `bytes` says, in this story; what could not be kept is reported.
pub fn restore(gpa: std.mem.Allocator, s: *const story.Story, flows: []flow_.Flow, bytes: []const u8) RestoreError!Report {
    var places: Places = try .init(gpa, s);
    defer places.deinit(gpa);
    var r: Reader = .{ .b = bytes };
    if (!std.mem.eql(u8, try r.take(magic.len), &magic)) return error.BadCursors;
    if (try r.int(u16) != version) return error.UnsupportedVersion;
    var report: Report = .{ .same_story = try r.int(u64) == s.hash() };
    // Read whole before anything changes, so a refused save leaves the session as it was.
    const read = try gpa.alloc(flow_.Flow, flows.len);
    defer gpa.free(read);
    for (read, flows) |*f, into| {
        f.* = .{ .id = into.id, .arena = undefined };
        try readFlow(&r, s, &places, f, &report);
    }
    if (r.at != bytes.len) return error.BadCursors;
    for (flows, read) |*into, from| {
        const arena = into.arena;
        into.* = from;
        into.arena = arena;
    }
    return report;
}

fn readFlow(r: *Reader, s: *const story.Story, places: *const Places, f: *flow_.Flow, report: *Report) RestoreError!void {
    switch (try r.int(u8)) {
        0 => return,
        2 => {
            f.started = true;
            f.ended = true;
            return;
        },
        1 => {},
        else => return error.BadCursors,
    }
    f.started = true;
    const at = try r.anchor(s, places, report);
    f.effect_at = try r.int(u32);
    const depth = try r.int(u8);
    if (depth > story.max_call_depth) return error.BadCursors;
    var lost = at.lost;
    f.at = at.node;
    for (0..depth) |_| {
        const fr = try r.frame(s, places, report);
        lost = lost or fr.lost;
        f.frames[f.depth] = fr.frame;
        f.depth += 1;
    }
    if (f.at) |n| if (f.effect_at > effectsLen(s, n)) {
        f.effect_at = 0;
    };
    if (lost) {
        f.reset();
        report.lost += 1;
    }
}

fn effectsLen(s: *const story.Story, n: NodeId) u32 {
    return switch (s.node(n).step) {
        .effects => |x| x.effects.len,
        else => 0,
    };
}

const Found = struct { node: ?NodeId, lost: bool = false };

const Reader = struct {
    b: []const u8,
    at: usize = 0,

    fn take(r: *Reader, n: usize) RestoreError![]const u8 {
        if (r.b.len - r.at < n) return error.BadCursors;
        defer r.at += n;
        return r.b[r.at..][0..n];
    }

    fn int(r: *Reader, comptime T: type) RestoreError!T {
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    fn str(r: *Reader) RestoreError![]const u8 {
        return r.take(try r.int(u16));
    }

    // A saved step found in this story: where it was, else by its line id in its section.
    fn anchor(r: *Reader, s: *const story.Story, places: *const Places, report: *Report) RestoreError!Found {
        switch (try r.int(u8)) {
            0 => return .{ .node = null },
            1 => {},
            else => return error.BadCursors,
        }
        const name = try r.str();
        const place = try r.int(u32);
        const kind = try r.int(u8);
        const line = try r.int(u64);
        const section = s.sectionNamed(name) orelse return .{ .node = null, .lost = true };
        const order = places.order[section.raw()].items;
        if (place < order.len and fits(s, order[place], kind, line)) return .{ .node = .fromRaw(order[place]) };
        if (line != 0) for (order) |n| if (fits(s, n, kind, line)) {
            report.moved +|= 1;
            return .{ .node = .fromRaw(n) };
        };
        return .{ .node = null, .lost = true };
    }

    fn frame(r: *Reader, s: *const story.Story, places: *const Places, report: *Report) RestoreError!struct { frame: flow_.Frame, lost: bool } {
        const back = try r.anchor(s, places, report);
        var fr: flow_.Frame = .{ .back = back.node, .effect_at = try r.int(u32) };
        if (back.node) |n| if (fr.effect_at > effectsLen(s, n)) {
            fr.effect_at = 0;
        };
        switch (try r.int(u8)) {
            0 => return .{ .frame = fr, .lost = back.lost },
            1 => {},
            else => return error.BadCursors,
        }
        const name = try r.str();
        const given = try r.int(u8);
        const count = try r.int(u8);
        if (count > pool.max_pick or given > count) return error.BadCursors;
        const section = s.sectionNamed(name);
        var p: flow_.Frame.Pool = .{ .section = section orelse .fromRaw(0), .picks = .{} };
        for (0..count) |k| {
            const candidate = try r.str();
            const found = if (section) |sec| candidateNamed(s, sec, candidate) else null;
            if (found) |c| {
                p.picks.list[p.picks.len] = c;
                p.picks.len += 1;
                if (k < given) p.given += 1;
            } else report.dropped +|= 1;
        }
        if (section == null) return .{ .frame = fr, .lost = true };
        fr.pool = p;
        return .{ .frame = fr, .lost = back.lost };
    }
};

fn fits(s: *const story.Story, n: u32, kind: u8, line: u64) bool {
    const id: NodeId = .fromRaw(n);
    return @backingInt(@as(story.format.NodeKind, s.node(id).step)) == kind and lineOf(s, id) == line;
}

fn candidateNamed(s: *const story.Story, section: SectionId, name: []const u8) ?u32 {
    const sec = s.section(section);
    if (sec.kind != .pool) return null;
    for (0..sec.candidates.len) |k| {
        const i = sec.candidates.start + @as(u32, @intCast(k)); // safe: below a u32 length
        if (std.mem.eql(u8, s.candidate(i).name, name)) return i;
    }
    return null;
}
