//! Conditions watched: each re-evaluated only when what it reads may have
//! changed, never polled. This is the evaluator rules stand on, and a
//! package's watched conditions too (cairn's quests).
//!
//! A condition is filed, when it is added, under every fact it reads (a fact
//! kept per thing under the key it reads, where the condition writes that
//! key as a constant, else under the whole fact), under
//! the stamp of every query it asks (by the query's keyed arguments where
//! they are written in the condition, else by the stamp's whole family), and,
//! where a comparison reads a `(clock)` fact, a `since_changed` or a builtin
//! that moves with a clock once, added or subtracted among anything else,
//! under the clock's value at which the comparison next flips, in a heap per
//! clock: `hour >= arrived + 3` waits for `arrived + 3`. Each time it is
//! evaluated that value is worked out anew from what the comparison reads
//! now, so when `arrived` changes (which wakes it, as any fact it reads) it
//! waits for the new one. A comparison that reads two clocks, or one twice,
//! is filed under each clock and wakes when one moves. A condition may be watched
//! for a thing (`this`, where its section is kept per thing) and given roles:
//! both are constants to it, so `alive(giver)` is filed under the giver's key
//! alone. A condition removed is taken out of all it was filed under, and its
//! id is the next one added's. A step takes what changed since the last (the
//! store's marks, the stamps the host bumped, the clocks' moves), marks the
//! conditions filed there, and evaluates them in the order they were added,
//! each once. It reads what changed from the store's log while it keeps up,
//! so a step's work follows the marks, not the facts watched. A clock moving
//! wakes only the conditions whose moment came; one moving back (a restored
//! moment) wakes all that read it.
//!
//! A `(moment)` is what happened: it holds the value the host wrote until a
//! step has evaluated every condition marked, then goes back to its initial
//! value, so a condition that read it falls at the next step.
//!
//! What a step reports is every condition it evaluated and what it holds
//! now: a client keeps what it held before, as a rule keeps it in the facts,
//! so a report survives a save. Nothing allocates in a step once the
//! conditions are added; a step with a budget evaluates that many and leaves
//! the rest marked, first in line next step, so a budget changes when, never
//! what.

const std = @import("std");
const aegis = @import("aegis");
const facts = @import("../facts.zig");
const story_ = @import("../story.zig");
const run = @import("../run.zig");
const heap_ = @import("heap.zig");

const Watch = @This();
const FactId = facts.FactId;
const Term = story_.Term;
const Range = story_.Range;

/// A watched condition, by the order it was added.
pub const CondId = aegis.id.Id(enum { condition }, u32);

pub const Error = run.EvalError || facts.SetError || error{
    /// More conditions watched than a 32-bit id holds.
    TooManyConditions,
};

pub const Options = struct {
    /// The most conditions one step evaluates; null for all that are marked.
    budget: ?u32 = null,
    /// What answers registered kinds' builtins in the conditions a package adds.
    builtins: ?run.Builtins = null,
};

/// One condition evaluated by a step, and what it holds now.
pub const Evaluated = struct { cond: CondId, holds: bool, user: u32 };

/// A fact a condition reads, for one key where it is kept per thing.
pub const Read = struct { fact: FactId, key: ?facts.Key = null };

/// What a condition is watched for, beside its terms.
pub const For = struct {
    /// The thing it is evaluated for, where its section is kept per thing: what `this` pushes.
    this: u64 = facts.Value.no_ref,
    /// The roles it is given, which its terms read as they are: constants to it.
    roles: []const run.Role = &.{},
    /// Facts it reads that its terms do not show: what a registered builtin reads.
    also: []const Read = &.{},
};

const Cond = struct {
    terms: Range,
    user: u32,
    this: u64,
    /// Its own copy of the roles it was given.
    roles: []const run.Role = &.{},
    /// The clocks it compares with numbers: where in the heap each next flip waits.
    thresholds: std.ArrayList(Threshold) = .empty,
    /// Every list it is filed in, so a removal takes it out of each.
    filed: std.ArrayList(Filed) = .empty,
    /// Watched: false once removed, its id free.
    live: bool = true,
};

// One list a condition is filed in, and its place there, so a removal takes it out at once.
const Filed = struct {
    in: union(enum) { fact: FactId, key: FactKey, stamp: StampKey },
    pos: u32,

    fn same(a: Filed, b: @FieldType(Filed, "in")) bool {
        return std.meta.eql(a.in, b);
    }
};

// A comparison that reads a clock-like value once, added or subtracted: the clock's own value, how far it moved
// since a fact changed, or a builtin's answer that moves with it. `left` less `right` is that value, `sign` before
// it, and the rest, which does not move with the clock: so the comparison flips only where the value passes the
// rest, and nowhere else.
const Threshold = struct {
    clock: FactId,
    op: Term.Op,
    /// +1 where the value is added, -1 where it is taken away.
    sign: i2,
    /// The comparison's two sides, as ranges of the story's terms.
    left: Range,
    right: Range,
    /// This condition's slot in the clock's heap.
    slot: u32,
};

const FactKey = struct { fact: u16, key: facts.Key };

// A query's stamp as the host bumps it: its family, and the hash of its keyed arguments' values (0 for the family).
const StampKey = struct { family: u32, key: u64 };

gpa: std.mem.Allocator,
story: *const story_.Story,
store: facts.Store,
host: *const run.Host,
options: Options,
owners: *const [facts.max_scopes]u64,
conds: std.ArrayList(Cond) = .empty,
/// By fact: the conditions that read it as a plain value, or read a fact kept per thing by a key not known now.
by_fact: []std.ArrayList(u32),
/// By a fact kept per thing and a key written as a constant: the conditions that read it.
by_key: std.AutoHashMapUnmanaged(FactKey, std.ArrayList(u32)) = .empty,
/// By fact: the keys conditions are filed under, which a change of the fact's stamp is checked against.
keys_of: []std.array_hash_map.Auto(facts.Key, void),
/// By a query's stamp and keyed values, or by its family alone (key 0).
by_stamp: std.AutoHashMapUnmanaged(StampKey, std.ArrayList(u32)) = .empty,
/// By clock fact: the heap of the next instants its comparisons flip at.
heaps: []heap_.Heap,
/// By fact: the clock value it last held, for telling a clock that moved back.
clock_was: []i64,
/// The `since_changed` watches, by the fact each keeps a clock value for.
changes_of: []std.ArrayList(u32),
/// The story's moments, cleared once every condition has seen them.
moments: []const FactId,
marked: std.DynamicBitSetUnmanaged = .{},
/// Bumped stamps since the last step.
bumped: std.ArrayList(StampKey) = .empty,
watcher: facts.Watcher,
interest: std.ArrayList(FactId) = .empty,
changed: []FactId = &.{},
arena: std.heap.ArenaAllocator,
evaluated: std.ArrayList(Evaluated) = .empty,
added_since: bool = false,
/// What of the story the named error the last step returned was met at: the terms of the condition, or the
/// comparison, being evaluated. A client that evaluates more in the watch's context (a rule's effects) says it here.
met: ?story_.At = null,
/// The ids of conditions removed, the next added's.
free: std.ArrayList(u32) = .empty,

/// A watch over `s`'s facts in `store`, its queries answered by `host`; all outlive it. `owners` is whose facts
/// each scope holds, as a session's are.
pub fn init(gpa: std.mem.Allocator, s: *const story_.Story, store: facts.Store, host: *const run.Host, owners: *const [facts.max_scopes]u64, options: Options) error{OutOfMemory}!Watch {
    const n = s.len(.facts);
    const by_fact = try gpa.alloc(std.ArrayList(u32), n);
    errdefer gpa.free(by_fact);
    @memset(by_fact, .empty);
    const keys_of = try gpa.alloc(std.array_hash_map.Auto(facts.Key, void), n);
    errdefer gpa.free(keys_of);
    @memset(keys_of, .empty);
    const heaps = try gpa.alloc(heap_.Heap, n);
    errdefer gpa.free(heaps);
    @memset(heaps, .{});
    const clock_was = try gpa.alloc(i64, n);
    errdefer gpa.free(clock_was);
    for (clock_was, 0..) |*v, i| v.* = clockValue(s, store, .fromRaw(@intCast(i))); // safe: below max_facts
    const changes_of = try gpa.alloc(std.ArrayList(u32), n);
    errdefer gpa.free(changes_of);
    @memset(changes_of, .empty);
    for (0..s.len(.changes)) |i| {
        const c = s.change(@intCast(i)); // safe: below a u32 count
        try changes_of[c.fact.raw()].append(gpa, @intCast(i)); // safe: below a u32 count
    }
    var moments: std.ArrayList(FactId) = .empty;
    errdefer moments.deinit(gpa);
    for (0..n) |i| if (s.fact(.fromRaw(@intCast(i))).role == .moment) try moments.append(gpa, .fromRaw(@intCast(i))); // safe: below max_facts
    return .{
        .gpa = gpa,
        .story = s,
        .store = store,
        .host = host,
        .options = options,
        .owners = owners,
        .by_fact = by_fact,
        .keys_of = keys_of,
        .heaps = heaps,
        .clock_was = clock_was,
        .changes_of = changes_of,
        .moments = try moments.toOwnedSlice(gpa),
        .watcher = .init(&.{}, store.changes()),
        .arena = .init(gpa),
    };
}

pub fn deinit(w: *Watch) void {
    const gpa = w.gpa;
    for (w.conds.items) |*c| release(gpa, c);
    w.conds.deinit(gpa);
    w.free.deinit(gpa);
    for (w.by_fact) |*l| l.deinit(gpa);
    gpa.free(w.by_fact);
    var it = w.by_stamp.valueIterator();
    while (it.next()) |l| l.deinit(gpa);
    w.by_stamp.deinit(gpa);
    var kt = w.by_key.valueIterator();
    while (kt.next()) |l| l.deinit(gpa);
    w.by_key.deinit(gpa);
    for (w.keys_of) |*l| l.deinit(gpa);
    gpa.free(w.keys_of);
    for (w.heaps) |*h| h.deinit(gpa);
    gpa.free(w.heaps);
    gpa.free(w.clock_was);
    for (w.changes_of) |*l| l.deinit(gpa);
    gpa.free(w.changes_of);
    gpa.free(w.moments);
    w.marked.deinit(gpa);
    w.bumped.deinit(gpa);
    w.interest.deinit(gpa);
    gpa.free(w.changed);
    w.arena.deinit();
    w.evaluated.deinit(gpa);
    w.* = undefined;
}

fn clockValue(s: *const story_.Story, store: facts.Store, f: FactId) i64 {
    return if (s.fact(f).role == .clock) store.get(f).int else 0;
}

fn release(gpa: std.mem.Allocator, c: *Cond) void {
    c.thresholds.deinit(gpa);
    c.filed.deinit(gpa);
    gpa.free(c.roles);
}

/// Watches the condition `terms`, a range of the story's terms that the reader typed as a condition, for `user`
/// (a rule, a quest's stage: the client's own number), for what `f` says. It is evaluated at the next step, and
/// whenever what it reads changes.
pub fn add(w: *Watch, terms: Range, user: u32, f: For) Error!CondId {
    const reuse = w.free.items.len > 0;
    if (!reuse and w.conds.items.len == std.math.maxInt(u32)) return error.TooManyConditions;
    const id: u32 = if (reuse) w.free.items[w.free.items.len - 1] else @intCast(w.conds.items.len); // safe: checked above
    if (!reuse) {
        try w.conds.ensureUnusedCapacity(w.gpa, 1);
        try w.marked.resize(w.gpa, w.conds.items.len + 1, false);
    }
    var c: Cond = .{ .terms = terms, .user = user, .this = f.this };
    errdefer {
        w.unfile(id, &c);
        release(w.gpa, &c);
    }
    c.roles = try w.gpa.dupe(run.Role, f.roles);
    try w.file(&c, id, f.also);
    if (reuse) {
        _ = w.free.pop();
        w.conds.items[id] = c;
    } else w.conds.appendAssumeCapacity(c);
    w.marked.set(id);
    w.added_since = true;
    return .fromRaw(id);
}

/// Stops watching `cond`: it is taken out of everything it was filed under, never evaluated again, and its id is
/// the next added condition's.
pub fn remove(w: *Watch, cond: CondId) error{OutOfMemory}!void {
    const id = cond.raw();
    const c = &w.conds.items[id];
    aegis.assert.invariant(c.live, "the condition is added and not yet removed");
    try w.free.ensureUnusedCapacity(w.gpa, 1);
    w.unfile(id, c);
    release(w.gpa, c);
    c.* = .{ .terms = .empty, .user = 0, .this = facts.Value.no_ref, .live = false };
    w.marked.unset(id);
    w.free.appendAssumeCapacity(id);
}

// Takes condition `id` out of every list it is filed in, each at its place, and its heaps' slots back. A list left
// empty is let go.
fn unfile(w: *Watch, id: u32, c: *Cond) void {
    for (c.filed.items) |f| {
        const l = w.listOf(f.in) orelse continue;
        const last: u32 = @intCast(l.items.len - 1); // safe: it holds this condition
        if (f.pos != last) {
            // the last of the list takes this one's place, and is told so
            const moved = l.items[last];
            l.items[f.pos] = moved;
            const other = if (moved == id) c else &w.conds.items[moved];
            for (other.filed.items) |*g| if (g.same(f.in) and g.pos == last) {
                g.pos = f.pos;
                break;
            };
        }
        l.items.len -= 1;
        if (l.items.len == 0) switch (f.in) {
            .fact => {},
            .key => |k| {
                var gone = w.by_key.fetchRemove(k).?; // listOf found it
                gone.value.deinit(w.gpa);
                _ = w.keys_of[k.fact].swapRemove(k.key);
            },
            .stamp => |k| {
                var gone = w.by_stamp.fetchRemove(k).?; // listOf found it
                gone.value.deinit(w.gpa);
            },
        };
    }
    for (c.thresholds.items) |t| w.heaps[t.clock.raw()].release(t.slot);
}

fn listOf(w: *Watch, in: @FieldType(Filed, "in")) ?*std.ArrayList(u32) {
    return switch (in) {
        .fact => |f| &w.by_fact[f.raw()],
        .key => |k| w.by_key.getPtr(k),
        .stamp => |k| w.by_stamp.getPtr(k),
    };
}

/// Whether the condition holds now, evaluated on the spot: for a client that needs a condition it was not told of.
pub fn holds(w: *Watch, cond: CondId) Error!bool {
    const c = &w.conds.items[cond.raw()];
    return run.eval.condition(w.contextOf(c), c.terms);
}

/// The host's word that what a query reads changed: `family` is the stamp a query declared, `keyed` the values of
/// the parameters that key it, in order (empty for a stamp with no keys). Conditions filed under it wake next step.
pub fn bump(w: *Watch, family: []const u8, keyed: []const facts.Value) Error!void {
    const f = familyIndex(w.story, family) orelse return;
    try w.bumped.append(w.gpa, .{ .family = f, .key = keyHash(keyed) });
}

/// Marks every condition, as after a restore that changed facts the store did not stamp.
pub fn markAll(w: *Watch) void {
    w.marked.setAll();
}

/// The conditions evaluated this step, in the order added, each with what it holds now. Valid until the next step.
pub fn step(w: *Watch) Error![]const Evaluated {
    _ = w.arena.reset(.retain_capacity);
    w.met = null;
    if (w.added_since) try w.refreshInterest();
    try w.markChanged();
    w.evaluated.clearRetainingCapacity();
    var budget = w.options.budget orelse std.math.maxInt(u32);
    var it = w.marked.iterator(.{});
    while (it.next()) |i| {
        if (budget == 0) break;
        budget -= 1;
        w.marked.unset(i);
        const c = &w.conds.items[i];
        if (!c.live) continue;
        const cx = w.contextOf(c);
        const now = try run.eval.condition(cx, c.terms);
        try w.evaluated.append(w.gpa, .{ .cond = .fromRaw(@intCast(i)), .holds = now, .user = c.user }); // safe: below a u32 count
        for (c.thresholds.items) |t| try w.arm(cx, t);
    }
    // a moment is over once every condition has seen it; with a budget it waits for the rest
    if (w.marked.count() == 0) for (w.moments) |m| {
        const start = w.story.fact(m).start();
        if (!w.store.get(m).eql(start)) try w.store.set(m, start);
    };
    return w.evaluated.items;
}

/// The context conditions are evaluated in: no flow, and the scopes' owners.
pub fn context(w: *Watch) run.eval.Context {
    return .{
        .story = w.story,
        .store = w.store,
        .host = w.host,
        .call = .{ .flow = run.no_flow, .owners = w.owners },
        .arena = w.arena.allocator(),
        .builtins = w.options.builtins,
        .met = &w.met,
    };
}

// The context one condition is evaluated in: the thing it is for, and its roles.
fn contextOf(w: *Watch, c: *const Cond) run.eval.Context {
    var cx = w.context();
    cx.call.this = c.this;
    cx.roles = c.roles;
    return cx;
}

// ---------------------------------------------------------------- what changed

// What changed since the last step, from the store's log while it holds it, so the work follows the marks; else
// from the stamps of every fact read.
fn markChanged(w: *Watch) Error!void {
    const changes = w.store.changes();
    const before = w.watcher.seen;
    if (changes.marksSince(before)) |logged| {
        var marks = logged;
        while (marks.next()) |m| try w.changedOne(m.fact, m.key, before);
    } else {
        const changed = w.watcher.take(changes, w.changed) catch unreachable; // glint-ignore: Z026 -- `changed` holds the whole interest
        for (changed) |f| try w.changedOne(f, null, before);
    }
    for (w.bumped.items) |b| {
        if (w.by_stamp.get(b)) |l| for (l.items) |ci| w.marked.set(ci);
        if (b.key != 0) if (w.by_stamp.get(.{ .family = b.family, .key = 0 })) |l| for (l.items) |ci| w.marked.set(ci);
    }
    w.bumped.clearRetainingCapacity();
    // what `since_changed` wrote is the evaluator's own: no condition reads it as a fact, so it is seen and passed
    w.watcher.seen = changes.now();
}

// One fact that changed, for one key where the store said which: what reads it is marked.
fn changedOne(w: *Watch, f: FactId, key: ?facts.Key, before: u64) Error!void {
    // a fact `since_changed` watches keeps the clock's value at its change, before anything reads it
    for (w.changes_of[f.raw()].items) |ci| {
        const c = w.story.change(ci);
        try w.store.set(c.at, .{ .int = w.store.get(c.clock).int });
    }
    for (w.by_fact[f.raw()].items) |ci| w.marked.set(ci);
    if (key) |k| {
        if (w.by_key.get(.{ .fact = f.raw(), .key = k })) |l| for (l.items) |ci| w.marked.set(ci);
    } else for (w.keys_of[f.raw()].keys()) |k| if (w.store.keyStamp(f, k) > before) {
        if (w.by_key.get(.{ .fact = f.raw(), .key = k })) |l| for (l.items) |ci| w.marked.set(ci);
    };
    if (w.story.fact(f).role == .clock) w.clockMoved(f);
}

fn clockMoved(w: *Watch, clock: FactId) void {
    const now = w.store.get(clock).int;
    const h = &w.heaps[clock.raw()];
    if (now < w.clock_was[clock.raw()]) {
        // a moment restored: every comparison with this clock is evaluated again
        for (h.conds.items) |cond| w.marked.set(cond);
    } else while (h.peek()) |top| {
        if (top.instant > now) break;
        w.marked.set(top.cond);
        h.remove(top.slot);
    }
    w.clock_was[clock.raw()] = now;
}

// Puts the condition's next flip of this comparison in its clock's heap, from what its sides are now. With `v` the
// clock-like value and `r` the rest, the sides differ by `sign * v + r`, and the clock moves `v` one for one; so the
// difference is 0 where the clock is `now - sign * difference`, and the comparison flips there or one past, by its
// operator and sign: `>=` with the value added becomes true where the difference reaches 0, with it taken away
// false one past, and `=` and `!=` flip at both. The least instant past now is armed; none past now, none is.
fn arm(w: *Watch, cx: run.eval.Context, t: Threshold) Error!void {
    const now = w.store.get(t.clock).int;
    const difference = @as(i128, (try run.eval.value(cx, t.left)).int) - (try run.eval.value(cx, t.right)).int;
    const zero = @as(i128, now) - @as(i128, t.sign) * difference;
    const h = &w.heaps[t.clock.raw()];
    var next: ?i64 = null;
    for (flips(t.op, t.sign)) |past| {
        const instant = std.math.cast(i64, zero + past) orelse continue;
        if (instant > now and (next == null or instant < next.?)) next = instant;
    }
    if (next) |instant| h.set(t.slot, instant) else h.remove(t.slot);
}

// Where past the difference's 0 a comparison flips, as the clock-like value climbs: `<` and `>=` where the
// difference reaches 0 if the value is added, one past if it is taken away; `>` and `<=` the other way about; `=`
// and `!=` at both.
fn flips(op: Term.Op, sign: i2) []const i128 {
    const at: []const i128 = &.{0};
    const one_past: []const i128 = &.{1};
    return switch (op) {
        .lt, .ge => if (sign > 0) at else one_past,
        .gt, .le => if (sign > 0) one_past else at,
        else => &.{ 0, 1 },
    };
}

fn refreshInterest(w: *Watch) Error!void {
    w.interest.clearRetainingCapacity();
    for (w.by_fact, w.heaps, w.changes_of, w.keys_of, 0..) |l, h, ch, ks, i| {
        if (l.items.len > 0 or h.slots() > 0 or ch.items.len > 0 or ks.count() > 0) try w.interest.append(w.gpa, .fromRaw(@intCast(i))); // safe: below max_facts
    }
    w.gpa.free(w.changed);
    w.changed = try w.gpa.alloc(FactId, w.interest.items.len);
    const seen = w.watcher.seen;
    w.watcher = .init(w.interest.items, w.store.changes());
    w.watcher.seen = seen;
    w.added_since = false;
}

// ---------------------------------------------------------------- filing a condition

// A condition being filed, by its id: where it is filed is noted in it as it is.
const Filing = struct { id: u32, cond: *Cond };

// Files the condition under what it reads, and its clock comparisons in their heaps.
fn file(w: *Watch, c: *Cond, id: u32, also: []const Read) Error!void {
    const terms = c.terms;
    const at: Filing = .{ .id = id, .cond = c };
    var compared: std.DynamicBitSetUnmanaged = try .initEmpty(w.gpa, terms.len);
    defer compared.deinit(w.gpa);
    try w.comparisons(at, &compared);
    // every term a comparison did not account for is read as it is
    var starts: [story_.max_stack]u32 = undefined;
    var n: usize = 0;
    for (0..terms.len) |k| {
        const t = w.story.term(terms.start + @as(u32, @intCast(k))); // safe: below a u32 length
        if (!compared.isSet(k)) switch (t.op) {
            .fact, .happened => try fileFact(w, at, .fromRaw(@intCast(t.arg))), // safe: validated to a fact id
            .since_changed => {
                const ch = w.story.change(t.arg);
                try fileFact(w, at, ch.fact);
                try fileFact(w, at, ch.clock);
            },
            .role => try w.fileRole(at, .fromRaw(@intCast(t.arg))), // safe: validated to a fact id
            .query => try w.fileQuery(at, t, starts[0..n], @intCast(k)), // safe: below a u32 length
            .keyed => try w.fileKeyed(at, t, starts[0..n], @intCast(k)), // safe: below a u32 length
            else => {},
        };
        n = stackAfter(w.story, t, &starts, n, @intCast(k)); // safe: below a u32 length
    }
    for (also) |r| if (r.key) |key| try w.fileKey(at, r.fact, key) else try fileFact(w, at, r.fact);
}

fn fileFact(w: *Watch, at: Filing, f: FactId) Error!void {
    const l = &w.by_fact[f.raw()];
    if (l.items.len > 0 and l.items[l.items.len - 1] == at.id) return;
    try at.cond.filed.append(w.gpa, .{ .in = .{ .fact = f }, .pos = @intCast(l.items.len) }); // safe: below a u32 count
    errdefer _ = at.cond.filed.pop();
    try l.append(w.gpa, at.id);
}

// A role given is a constant, which nothing wakes; one not given reads as its fact, for the thing the condition is
// for where it is kept per thing.
fn fileRole(w: *Watch, at: Filing, f: FactId) Error!void {
    for (at.cond.roles) |r| if (r.fact.eql(f)) return;
    if (w.story.fact(f).key != .none and at.cond.this != facts.Value.no_ref) return w.fileKey(at, f, at.cond.this);
    try fileFact(w, at, f);
}

// A fact kept per thing, read for one key.
fn fileKey(w: *Watch, at: Filing, f: FactId, key: facts.Key) Error!void {
    const in: FactKey = .{ .fact = f.raw(), .key = key };
    const gop = try w.by_key.getOrPut(w.gpa, in);
    if (!gop.found_existing) {
        gop.value_ptr.* = .empty;
        try w.keys_of[f.raw()].put(w.gpa, key, {});
    }
    try at.cond.filed.append(w.gpa, .{ .in = .{ .key = in }, .pos = @intCast(gop.value_ptr.items.len) }); // safe: below a u32 count
    errdefer _ = at.cond.filed.pop();
    try gop.value_ptr.append(w.gpa, at.id);
}

// A comparison that reads one clock-like value once, added or subtracted among anything else (`hour >= arrived + 3`,
// `since_changed(f, day) > 8`, `since(stage, day) - grace < 2`): the clock is read only through the comparison, which
// can flip only where the value passes the rest, so it waits in the clock's heap. What else the comparison reads is
// filed as it is, and wakes it; a comparison that reads two clocks, or one twice, or one inside a query's
// arguments, is not taken here, and each clock it reads wakes it as a fact.
fn comparisons(w: *Watch, at: Filing, compared: *std.DynamicBitSetUnmanaged) Error!void {
    const terms = at.cond.terms;
    if (terms.len < 3) return;
    // where the value each term leaves begins
    const begin = try w.gpa.alloc(u32, terms.len);
    defer w.gpa.free(begin);
    var starts: [story_.max_stack]u32 = undefined;
    var n: usize = 0;
    for (0..terms.len) |k| {
        const t = w.story.term(terms.start + @as(u32, @intCast(k))); // safe: below a u32 length
        n = stackAfter(w.story, t, &starts, n, @intCast(k)); // safe: below a u32 length
        begin[k] = starts[n - 1];
    }
    for (2..terms.len) |k| {
        const op = w.story.term(terms.start + @as(u32, @intCast(k))); // safe: below a u32 length
        switch (op.op) {
            .lt, .le, .gt, .ge, .eq, .ne => {},
            else => continue,
        }
        const right = begin[k - 1];
        const left = begin[k];
        // the one clock-like term of the comparison, which must stand in its sums
        var only: ?u32 = null;
        var clocks: usize = 0;
        for (left..k) |i| if (w.clockOf(terms.start + @as(u32, @intCast(i))) != null) {
            clocks += 1; // safe: below a u32 length
            only = @intCast(i); // safe: below a u32 length
        };
        if (clocks != 1) continue;
        const sign = linear(w.story, terms.start, begin, left, right, 1, only.?) orelse linear(w.story, terms.start, begin, right, @intCast(k), -1, only.?) orelse continue; // safe: below a u32 length
        const term = w.story.term(terms.start + only.?);
        // a change of the fact `since_changed` reads moves where the comparison flips, so the fact wakes it too
        if (term.op == .since_changed) try fileFact(w, at, w.story.change(term.arg).fact);
        var t: Threshold = .{
            .clock = w.clockOf(terms.start + only.?).?,
            .op = op.op,
            .sign = sign,
            .left = .{ .start = terms.start + left, .len = right - left },
            .right = .{ .start = terms.start + right, .len = @as(u32, @intCast(k)) - right }, // safe: below a u32 length
            .slot = 0,
        };
        try at.cond.thresholds.ensureUnusedCapacity(w.gpa, 1);
        t.slot = try w.heaps[t.clock.raw()].slot(w.gpa, at.id);
        at.cond.thresholds.appendAssumeCapacity(t);
        compared.set(only.?);
    }
}

// The clock a term reads one for one, if it does: a `(clock)` fact, a `since_changed`'s clock, or the clock a
// builtin's answer moves with.
fn clockOf(w: *const Watch, at: u32) ?FactId {
    const t = w.story.term(at);
    return switch (t.op) {
        .fact => blk: {
            const f: FactId = .fromRaw(@intCast(t.arg)); // safe: validated to a fact id
            break :blk if (w.story.fact(f).role == .clock) f else null;
        },
        .since_changed => w.story.change(t.arg).clock,
        .builtin => w.story.builtin(t.arg).clock,
        else => null,
    };
}

// The sign term `want` stands with in the value the terms `from` to `to` leave, `sign` before it, where it stands
// in that value's sums alone; null where it does not stand there, or stands inside something else (a query's
// argument). `begin` is where each term's value begins, relative to `base`.
fn linear(s: *const story_.Story, base: u32, begin: []const u32, from: u32, to: u32, sign: i2, want: u32) ?i2 {
    if (want < from or want >= to) return null;
    const last = s.term(base + to - 1);
    if (last.op == .add or last.op == .sub) {
        const mid = begin[to - 2];
        return linear(s, base, begin, from, mid, sign, want) orelse linear(s, base, begin, mid, to - 1, if (last.op == .sub) -sign else sign, want);
    }
    return if (to - from == 1) sign else null;
}

// A query's stamp: by the values of its keyed arguments where each is a constant written in the condition, else by
// the stamp's whole family.
// `starts` are where each value on the stack began, `k` the query's place in the condition: an argument written as
// one constant term is known now.
fn fileQuery(w: *Watch, at: Filing, t: Term, starts: []const u32, k: u32) Error!void {
    const base = at.cond.terms.start;
    const x = w.story.externFn(.fromRaw(@intCast(t.arg))); // safe: validated to an extern id
    const st = x.stamp orelse return;
    const family = familyIndex(w.story, st.family) orelse return;
    const params = x.params.len;
    const first = starts.len - params;
    var keyed: [story_.format.max_params]facts.Value = undefined;
    var nk: usize = 0;
    var exact = st.keys != 0;
    for (0..params) |p| {
        if (st.keys & (@as(u32, 1) << @intCast(p)) == 0) continue; // safe: at most max_params parameters
        const from = starts[first + p];
        const to = if (p + 1 < params) starts[first + p + 1] else k;
        const v = if (to - from == 1) w.constantAt(at.cond, base + from) else null;
        if (v) |value| {
            keyed[nk] = value;
            nk += 1;
        } else exact = false;
    }
    const key: StampKey = .{ .family = family, .key = if (exact) keyHash(keyed[0..nk]) else 0 };
    const gop = try w.by_stamp.getOrPut(w.gpa, key);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try at.cond.filed.append(w.gpa, .{ .in = .{ .stamp = key }, .pos = @intCast(gop.value_ptr.items.len) }); // safe: below a u32 count
    errdefer _ = at.cond.filed.pop();
    try gop.value_ptr.append(w.gpa, at.id);
}

// A read of a fact kept per thing: by its key where the key is one constant term, else by the whole fact.
fn fileKeyed(w: *Watch, at: Filing, t: Term, starts: []const u32, k: u32) Error!void {
    const f: FactId = .fromRaw(@intCast(t.arg)); // safe: validated to a fact id
    const from = starts[starts.len - 1];
    const key = if (k - from == 1) (if (w.constantAt(at.cond, at.cond.terms.start + from)) |v| run.eval.keyOf(v) else null) else null;
    const exact = key orelse return fileFact(w, at, f);
    try w.fileKey(at, f, exact);
}

// The value a single constant term pushes, if it is one: a constant written, the thing the condition is for, or a
// role it was given.
fn constantAt(w: *const Watch, c: *const Cond, at: u32) ?facts.Value {
    const t = w.story.term(at);
    return switch (t.op) {
        .thing => .{ .ref = w.host.refs[t.arg] },
        .item => .{ .one_of = t.itemIndex() },
        .int => .{ .int = w.story.int(t.arg) },
        .true => .{ .boolean = true },
        .false => .{ .boolean = false },
        .this => .{ .ref = c.this },
        .role => for (c.roles) |r| {
            if (r.fact.eql(.fromRaw(std.math.cast(@TypeOf(r.fact.raw()), t.arg) orelse continue))) break r.value;
        } else null,
        else => null,
    };
}

// Where each value on the stack began, after term `t` at `k`: what a query's arguments are found by.
fn stackAfter(s: *const story_.Story, t: Term, starts: *[story_.max_stack]u32, n: usize, k: u32) usize {
    switch (t.op) {
        .not, .keyed => return n,
        .eq, .ne, .lt, .le, .gt, .ge, .has, .hasnt, .@"and", .@"or", .add, .sub => return n - 1,
        .query => {
            const params = s.externFn(.fromRaw(@intCast(t.arg))).params.len; // safe: validated to an extern id
            if (params == 0) {
                starts[n] = k;
                return n + 1;
            }
            return n - params + 1;
        },
        else => {
            starts[n] = k;
            return n + 1;
        },
    }
}

fn familyIndex(s: *const story_.Story, family: []const u8) ?u32 {
    for (0..s.len(.externs)) |i| {
        const x = s.externFn(.fromRaw(@intCast(i))); // safe: validated below none16
        if (x.stamp) |st| if (std.mem.eql(u8, st.family, family)) return @intCast(i); // safe: below none16
    }
    return null;
}

// The hash a stamp's keyed values are filed by; 0, the whole family's, for none or for a key that is not a scalar.
fn keyHash(keyed: []const facts.Value) u64 {
    if (keyed.len == 0) return 0;
    var h: std.hash.Wyhash = .init(0x7269766572);
    for (keyed) |v| {
        h.update(&.{@backingInt(@as(facts.Kind, v))});
        switch (v) {
            .boolean => |b| h.update(&.{@intFromBool(b)}),
            .int => |i| h.update(std.mem.asBytes(&i)),
            .one_of => |i| h.update(std.mem.asBytes(&i)),
            .ref => |r| h.update(std.mem.asBytes(&r)),
            .text, .set_of => return 0,
        }
    }
    return h.final() | 1;
}
