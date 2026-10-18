//! A story's rules sections, fired over a `Watch`.
//!
//! A rule fires its effects when its condition becomes true: it held false
//! when last evaluated and holds now. Each time any condition of a rules
//! section is evaluated, the section fires at most one rule: the first, in
//! the order written, whose condition has just become true; the others that
//! became true with it do not fire, and wait to become true again. What each
//! rule held is kept in the facts (the reserved scope's `rule.<section>.<rule>`),
//! so a restored save remembers it and fires nothing twice; a rule whose
//! condition holds when the story first starts fires at the first step.
//!
//! Rules emit their effects and never apply them, as everything in riverrun
//! does. `step` is one round: the rules that fired, with their effects. The
//! host applies them, which may make other conditions true, and steps again;
//! `settle` runs those rounds for a host that applies effects at once,
//! bounded by a named error so rules that keep firing each other cannot hang.

const std = @import("std");
const facts = @import("../facts.zig");
const story = @import("../story.zig");
const run = @import("../run.zig");
const Watch = @import("Watch.zig");

const Rules = @This();

pub const Error = Watch.Error || error{
    /// `settle` ran `max_rounds` rounds and the rules still fired.
    NoFixedPoint,
};

/// The most rounds `settle` runs before it gives up on rules that keep firing.
pub const max_rounds = 64;

/// A rule that fired, and what it does.
pub const Fired = struct {
    section: story.SectionId,
    /// The rule, by its index in the story's candidates.
    rule: u32,
    name: []const u8,
    tags: story.Range,
    /// Valid until the next step.
    effects: []const facts.Effect,
};

const Rule = struct { section: story.SectionId, candidate: u32 };

watch: Watch,
rules: []Rule,
/// By rules section, its first rule and how many it has.
sections: []struct { id: story.SectionId, first: u32, len: u32 },
touched: std.DynamicBitSetUnmanaged,
fired: std.ArrayList(Fired) = .empty,

/// Every rule of `s`, watched over `store`. The story, store, host and owners outlive it.
pub fn init(gpa: std.mem.Allocator, s: *const story.Story, store: facts.Store, host: *const run.Host, owners: *const [facts.max_scopes]u64, options: Watch.Options) Error!Rules {
    var w: Watch = try .init(gpa, s, store, host, owners, options);
    errdefer w.deinit();
    var rules: std.ArrayList(Rule) = .empty;
    errdefer rules.deinit(gpa);
    var sections: std.ArrayList(@typeInfo(@FieldType(Rules, "sections")).pointer.child) = .empty;
    errdefer sections.deinit(gpa);
    for (0..s.len(.sections)) |i| {
        const id: story.SectionId = .fromRaw(@intCast(i)); // safe: below a u32 count
        const sec = s.section(id);
        if (sec.kind != .rules) continue;
        var watched: u32 = 0;
        for (0..sec.candidates.len) |k| watched += @intFromBool(s.candidate(sec.candidates.start + @as(u32, @intCast(k))).migrate == 0); // safe: below a u32 length
        try sections.append(gpa, .{ .id = id, .first = @intCast(rules.items.len), .len = watched }); // safe: below a u32 count
        for (0..sec.candidates.len) |k| {
            const index = sec.candidates.start + @as(u32, @intCast(k)); // safe: below a u32 length
            // a migration runs once, when an older save loads, and is never watched
            if (s.candidate(index).migrate != 0) continue;
            // a rule's watched condition is numbered by its place among the rules
            _ = try w.add(s.candidate(index).when, @intCast(rules.items.len), .{}); // safe: below a u32 count
            try rules.append(gpa, .{ .section = id, .candidate = index });
        }
    }
    const touched: std.DynamicBitSetUnmanaged = try .initEmpty(gpa, sections.items.len);
    return .{ .watch = w, .rules = try rules.toOwnedSlice(gpa), .sections = try sections.toOwnedSlice(gpa), .touched = touched };
}

pub fn deinit(r: *Rules) void {
    const gpa = r.watch.gpa;
    gpa.free(r.rules);
    gpa.free(r.sections);
    r.touched.deinit(gpa);
    r.fired.deinit(gpa);
    r.watch.deinit();
    r.* = undefined;
}

/// One round: what changed is evaluated, and each rules section touched fires the first of its rules that just
/// became true. Empty when nothing fired.
pub fn step(r: *Rules) Error![]const Fired {
    r.fired.clearRetainingCapacity();
    const evaluated = try r.watch.step();
    const s = r.watch.story;
    r.touched.unsetAll();
    for (evaluated) |e| r.touched.set(r.sectionOf(e.user));
    var holds: std.DynamicBitSetUnmanaged = try .initEmpty(r.watch.arena.allocator(), r.rules.len);
    for (evaluated) |e| if (e.holds) holds.set(e.user);
    var evaluated_now: std.DynamicBitSetUnmanaged = try .initEmpty(r.watch.arena.allocator(), r.rules.len);
    for (evaluated) |e| evaluated_now.set(e.user);
    var it = r.touched.iterator(.{});
    while (it.next()) |si| {
        const sec = r.sections[si];
        var fired_here = false;
        for (sec.first..sec.first + sec.len) |ri| {
            const rule = r.rules[ri];
            const c = s.candidate(rule.candidate);
            const was = r.watch.store.get(c.seen).int != 0;
            // a rule not evaluated this round holds what it held
            const now = if (evaluated_now.isSet(ri)) holds.isSet(ri) else was;
            if (now == was) continue;
            try r.watch.store.set(c.seen, .{ .int = @intFromBool(now) });
            if (!now or fired_here) continue;
            fired_here = true;
            try r.fire(rule, c);
        }
    }
    return r.fired.items;
}

/// A new game: its saves are of this version, and no migration has anything to do.
pub fn start(r: *Rules) Error!void {
    const s = r.watch.story;
    try r.watch.store.set(s.versionFact(), .{ .int = s.version() });
}

/// After a save is restored: each migration to a version past the save's and no later than the story's, in the
/// order of their versions and then as written, whose condition holds (or which has none). The save's version is
/// then the story's, so each runs once. Empty for a save of this version.
pub fn migrate(r: *Rules) Error![]const Fired {
    r.fired.clearRetainingCapacity();
    const s = r.watch.story;
    const saved = r.watch.store.get(s.versionFact()).int;
    const now: i64 = s.version();
    var to = saved + 1;
    while (to <= now) : (to += 1) for (0..s.len(.sections)) |i| {
        const sec = s.section(.fromRaw(@intCast(i))); // safe: below a u32 count
        if (sec.kind != .rules) continue;
        for (0..sec.candidates.len) |k| {
            const index = sec.candidates.start + @as(u32, @intCast(k)); // safe: below a u32 length
            const c = s.candidate(index);
            if (c.migrate != to) continue;
            if (!try run.eval.condition(r.watch.context(), c.when)) continue;
            try r.fire(.{ .section = .fromRaw(@intCast(i)), .candidate = index }, c); // safe: below a u32 count
        }
    };
    if (saved < now) try r.watch.store.set(s.versionFact(), .{ .int = now });
    return r.fired.items;
}

/// Rounds until no rule fires, `apply` given each round's effects to apply before the next.
pub fn settle(r: *Rules, user: anytype, comptime apply: fn (@TypeOf(user), []const Fired) anyerror!void) (Error || error{ApplyFailed})!u32 {
    var rounds: u32 = 0;
    while (rounds < max_rounds) : (rounds += 1) {
        const fired = try r.step();
        if (fired.len == 0) return rounds;
        apply(user, fired) catch return error.ApplyFailed;
    }
    return error.NoFixedPoint;
}

fn sectionOf(r: *const Rules, rule: u32) usize {
    const id = r.rules[rule].section;
    for (r.sections, 0..) |sec, i| if (sec.id.eql(id)) return i;
    unreachable; // unreachable: every rule was listed under its section
}

fn fire(r: *Rules, rule: Rule, c: story.Candidate) Error!void {
    const s = r.watch.story;
    try r.watch.store.set(c.visits, .{ .int = r.watch.store.get(c.visits).int +| 1 });
    const cx = r.watch.context();
    const n = s.node(c.entry);
    const list: []const facts.Effect = switch (n.step) {
        .effects => |e| blk: {
            const out = try cx.arena.alloc(facts.Effect, e.effects.len);
            for (out, 0..) |*o, k| o.* = try run.eval.effect(cx, s.effect(e.effects.start + @as(u32, @intCast(k)))); // safe: below a u32 length
            break :blk out;
        },
        else => &.{},
    };
    try r.fired.append(r.watch.gpa, .{ .section = rule.section, .rule = rule.candidate, .name = c.name, .tags = c.tags, .effects = list });
}
