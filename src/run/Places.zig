//! Where each step of a story is: the section it belongs to and its place
//! in that section's walk. Found once, when a session is made, by walking
//! each section from its entry (and a pool's candidates from theirs) without
//! following a jump or a call, so a step is its own section's however a
//! flow came to it. A line says where it is from here, and the cursors save
//! a step by its section and place.

const std = @import("std");
const story = @import("../story.zig");

const NodeId = story.NodeId;
const SectionId = story.SectionId;

const Places = @This();

/// Each step's section and place, by its node id.
of: std.AutoHashMapUnmanaged(u32, Place) = .empty,
/// Each section's steps in walk order.
order: []std.ArrayList(u32),

pub const Place = struct { section: u32, place: u32 };

/// Where a step is, as a line says it: its section, and its part where the section it was written in is a part.
pub const Where = struct { section: SectionId, part: ?SectionId };

pub fn init(gpa: std.mem.Allocator, s: *const story.Story) error{OutOfMemory}!Places {
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

pub fn deinit(p: *Places, gpa: std.mem.Allocator) void {
    p.of.deinit(gpa);
    for (p.order) |*o| o.deinit(gpa);
    gpa.free(p.order);
    p.* = undefined;
}

/// The section and part step `id` was written in, if any section's walk reaches it.
pub fn where(p: *const Places, s: *const story.Story, id: NodeId) ?Where {
    const place = p.of.get(id.raw()) orelse return null;
    const own: SectionId = .fromRaw(place.section);
    const whole = s.section(own).part_of orelse return .{ .section = own, .part = null };
    return .{ .section = whole, .part = own };
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
