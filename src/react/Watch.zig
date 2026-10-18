//! Conditions watched: each re-evaluated only when what it reads may have
//! changed, never polled. This is the evaluator rules stand on, and a
//! package's watched conditions too (cairn's quests).
//!
//! A condition is filed, when it is added, under every fact it reads (a fact
//! kept per thing under the key it reads, where the condition writes that
//! key as a constant, else under the whole fact), under
//! the stamp of every query it asks (by the query's keyed arguments where
//! they are written in the condition, else by the stamp's whole family), and,
//! where it compares a `(clock)` fact or a `since_changed` with a number,
//! under the clock's value at which the comparison can next flip, in a heap
//! per clock. A step takes what changed since the last (the store's stamps,
//! the stamps the host bumped, the clocks' moves), marks the conditions filed
//! there, and evaluates them in the order they were added, each once. A
//! clock moving wakes only the conditions whose moment came; one moving back
//! (a restored moment) wakes all that read it.
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

const Cond = struct {
    terms: Range,
    user: u32,
    /// The clocks it compares with numbers: where in the heap each next flip waits.
    thresholds: []const Threshold,
};

// A number a clock-like value is compared with: the clock's own value, or how far it moved since a fact changed.
const Threshold = struct {
    clock: FactId,
    k: i64,
    /// For `since_changed`: the state that keeps the clock's value at the fact's last change.
    at: ?FactId,
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
keys_of: []std.ArrayList(facts.Key),
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

/// A watch over `s`'s facts in `store`, its queries answered by `host`; all outlive it. `owners` is whose facts
/// each scope holds, as a session's are.
pub fn init(gpa: std.mem.Allocator, s: *const story_.Story, store: facts.Store, host: *const run.Host, owners: *const [facts.max_scopes]u64, options: Options) error{OutOfMemory}!Watch {
    const n = s.len(.facts);
    const by_fact = try gpa.alloc(std.ArrayList(u32), n);
    errdefer gpa.free(by_fact);
    @memset(by_fact, .empty);
    const keys_of = try gpa.alloc(std.ArrayList(facts.Key), n);
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
    for (w.conds.items) |c| gpa.free(c.thresholds);
    w.conds.deinit(gpa);
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

/// Watches the condition `terms`, a range of the story's terms that the reader typed as a condition, for `user`
/// (a rule, a quest's stage: the client's own number). `also` are facts it reads that its terms do not show:
/// what a registered builtin reads. It is evaluated at the next step, and whenever what it reads changes.
pub fn add(w: *Watch, terms: Range, user: u32, also: []const FactId) Error!CondId {
    if (w.conds.items.len == std.math.maxInt(u32)) return error.TooManyConditions;
    const id: u32 = @intCast(w.conds.items.len); // safe: checked above
    const thresholds = try w.file(terms, id, also);
    errdefer w.gpa.free(thresholds);
    try w.conds.append(w.gpa, .{ .terms = terms, .user = user, .thresholds = thresholds });
    try w.marked.resize(w.gpa, w.conds.items.len, true);
    w.added_since = true;
    return .fromRaw(id);
}

/// Whether the condition holds now, evaluated on the spot: for a client that needs a condition it was not told of.
pub fn holds(w: *Watch, cond: CondId) Error!bool {
    return run.eval.condition(w.context(), w.conds.items[cond.raw()].terms);
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
    if (w.added_since) try w.refreshInterest();
    try w.markChanged();
    w.evaluated.clearRetainingCapacity();
    const cx = w.context();
    var budget = w.options.budget orelse std.math.maxInt(u32);
    var it = w.marked.iterator(.{});
    while (it.next()) |i| {
        if (budget == 0) break;
        budget -= 1;
        w.marked.unset(i);
        const c = w.conds.items[i];
        const now = try run.eval.condition(cx, c.terms);
        try w.evaluated.append(w.gpa, .{ .cond = .fromRaw(@intCast(i)), .holds = now, .user = c.user }); // safe: below a u32 count
        for (c.thresholds) |t| w.arm(t);
    }
    // a moment is over once every condition has seen it; with a budget it waits for the rest
    if (w.marked.count() == 0) for (w.moments) |m| {
        const kind = w.story.fact(m).kind;
        if (!w.store.get(m).eql(.initial(kind))) try w.store.set(m, .initial(kind));
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
    };
}

// ---------------------------------------------------------------- what changed

fn markChanged(w: *Watch) Error!void {
    const changes = w.store.changes();
    const before = w.watcher.seen;
    const changed = w.watcher.take(changes, w.changed) catch unreachable; // unreachable: `changed` holds the whole interest
    // a fact `since_changed` watches keeps the clock's value at its change, before anything reads it
    for (changed) |f| for (w.changes_of[f.raw()].items) |ci| {
        const c = w.story.change(ci);
        try w.store.set(c.at, .{ .int = w.store.get(c.clock).int });
    };
    for (changed) |f| {
        for (w.by_fact[f.raw()].items) |ci| w.marked.set(ci);
        for (w.keys_of[f.raw()].items) |key| if (w.store.keyStamp(f, key) > before) {
            if (w.by_key.get(.{ .fact = f.raw(), .key = key })) |l| for (l.items) |ci| w.marked.set(ci);
        };
        if (w.story.fact(f).role == .clock) w.clockMoved(f);
    }
    for (w.bumped.items) |b| {
        if (w.by_stamp.get(b)) |l| for (l.items) |ci| w.marked.set(ci);
        if (b.key != 0) if (w.by_stamp.get(.{ .family = b.family, .key = 0 })) |l| for (l.items) |ci| w.marked.set(ci);
    }
    w.bumped.clearRetainingCapacity();
    // what `since_changed` wrote is the evaluator's own: no condition reads it as a fact, so it is seen and passed
    w.watcher.seen = changes.now();
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

// Puts the condition's next flip of this comparison in its clock's heap: the least threshold past now.
fn arm(w: *Watch, t: Threshold) void {
    const now = w.store.get(t.clock).int;
    const base = if (t.at) |at| w.store.get(at).int else 0;
    const h = &w.heaps[t.clock.raw()];
    var next: ?i64 = null;
    for ([_]i64{ t.k, t.k +| 1 }) |q| {
        const instant = base +| q;
        if (instant > now and (next == null or instant < next.?)) next = instant;
    }
    if (next) |instant| h.set(t.slot, instant) else h.remove(t.slot);
}

fn refreshInterest(w: *Watch) Error!void {
    w.interest.clearRetainingCapacity();
    for (w.by_fact, w.heaps, w.changes_of, w.keys_of, 0..) |l, h, ch, ks, i| {
        if (l.items.len > 0 or h.slots() > 0 or ch.items.len > 0 or ks.items.len > 0) try w.interest.append(w.gpa, .fromRaw(@intCast(i))); // safe: below max_facts
    }
    w.gpa.free(w.changed);
    w.changed = try w.gpa.alloc(FactId, w.interest.items.len);
    const seen = w.watcher.seen;
    w.watcher = .init(w.interest.items, w.store.changes());
    w.watcher.seen = seen;
    w.added_since = false;
}

// ---------------------------------------------------------------- filing a condition

// Files the condition under what it reads; returns its clock comparisons, each given its slot in a heap.
fn file(w: *Watch, terms: Range, id: u32, also: []const FactId) Error![]const Threshold {
    var thresholds: std.ArrayList(Threshold) = .empty;
    errdefer thresholds.deinit(w.gpa);
    var compared: std.DynamicBitSetUnmanaged = try .initEmpty(w.gpa, terms.len);
    defer compared.deinit(w.gpa);
    try w.comparisons(terms, &thresholds, &compared, id);
    // every term a comparison did not account for is read as it is
    var starts: [story_.max_stack]u32 = undefined;
    var n: usize = 0;
    for (0..terms.len) |k| {
        const at = terms.start + @as(u32, @intCast(k)); // safe: below a u32 length
        const t = w.story.term(at);
        if (!compared.isSet(k)) switch (t.op) {
            .fact, .happened => try fileFact(w, .fromRaw(@intCast(t.arg)), id), // safe: validated to a fact id
            .since_changed => {
                const c = w.story.change(t.arg);
                try fileFact(w, c.fact, id);
                try fileFact(w, c.clock, id);
            },
            .query => try w.fileQuery(t, starts[0..n], @intCast(k), terms.start, id), // safe: below a u32 length
            .keyed => try w.fileKeyed(t, starts[0..n], @intCast(k), terms.start, id), // safe: below a u32 length
            else => {},
        };
        n = stackAfter(w.story, t, &starts, n, @intCast(k)); // safe: below a u32 length
    }
    for (also) |f| try fileFact(w, f, id);
    return thresholds.toOwnedSlice(w.gpa);
}

fn fileFact(w: *Watch, f: FactId, id: u32) Error!void {
    const l = &w.by_fact[f.raw()];
    if (l.items.len > 0 and l.items[l.items.len - 1] == id) return;
    try l.append(w.gpa, id);
}

// `clock OP number`, `number OP clock`, `since_changed(…) OP number` and its mirror: the clock is read only through
// the comparison, which can flip only where the clock passes the number, so it waits in the clock's heap.
fn comparisons(w: *Watch, terms: Range, out: *std.ArrayList(Threshold), compared: *std.DynamicBitSetUnmanaged, id: u32) Error!void {
    if (terms.len < 3) return;
    for (0..terms.len - 2) |k| {
        const a = w.story.term(terms.start + @as(u32, @intCast(k))); // safe: below a u32 length
        const b = w.story.term(terms.start + @as(u32, @intCast(k + 1))); // safe: below a u32 length
        const op = w.story.term(terms.start + @as(u32, @intCast(k + 2))); // safe: below a u32 length
        switch (op.op) {
            .lt, .le, .gt, .ge, .eq, .ne => {},
            else => continue,
        }
        const clocky, const number = if (b.op == .int) .{ a, b } else if (a.op == .int) .{ b, a } else continue;
        const t: Threshold = switch (clocky.op) {
            .fact => blk: {
                const f: FactId = .fromRaw(@intCast(clocky.arg)); // safe: validated to a fact id
                if (w.story.fact(f).role != .clock) continue;
                break :blk .{ .clock = f, .k = w.story.int(number.arg), .at = null, .slot = 0 };
            },
            .since_changed => blk: {
                const c = w.story.change(clocky.arg);
                // a change of the fact moves where the comparison flips, so the fact wakes it too
                try fileFact(w, c.fact, id);
                break :blk .{ .clock = c.clock, .k = w.story.int(number.arg), .at = c.at, .slot = 0 };
            },
            else => continue,
        };
        var armed = t;
        armed.slot = try w.heaps[t.clock.raw()].slot(w.gpa, id);
        try out.append(w.gpa, armed);
        compared.set(k);
        compared.set(k + 1);
    }
}

// A query's stamp: by the values of its keyed arguments where each is a constant written in the condition, else by
// the stamp's whole family.
// `starts` are where each value on the stack began, `k` the query's place in the condition: an argument written as
// one constant term is known now.
fn fileQuery(w: *Watch, t: Term, starts: []const u32, k: u32, base: u32, id: u32) Error!void {
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
        const v = if (to - from == 1) w.constantAt(base + from) else null;
        if (v) |value| {
            keyed[nk] = value;
            nk += 1;
        } else exact = false;
    }
    const key: u64 = if (exact) keyHash(keyed[0..nk]) else 0;
    const gop = try w.by_stamp.getOrPut(w.gpa, .{ .family = family, .key = key });
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(w.gpa, id);
}

// A read of a fact kept per thing: by its key where the key is one constant term, else by the whole fact.
fn fileKeyed(w: *Watch, t: Term, starts: []const u32, k: u32, base: u32, id: u32) Error!void {
    const f: FactId = .fromRaw(@intCast(t.arg)); // safe: validated to a fact id
    const from = starts[starts.len - 1];
    const key = if (k - from == 1) (if (w.constantAt(base + from)) |v| run.eval.keyOf(v) else null) else null;
    const exact = key orelse return fileFact(w, f, id);
    const gop = try w.by_key.getOrPut(w.gpa, .{ .fact = f.raw(), .key = exact });
    if (!gop.found_existing) {
        gop.value_ptr.* = .empty;
        try w.keys_of[f.raw()].append(w.gpa, exact);
    }
    try gop.value_ptr.append(w.gpa, id);
}

// The value a single constant term pushes, if it is one.
fn constantAt(w: *const Watch, at: u32) ?facts.Value {
    const t = w.story.term(at);
    return switch (t.op) {
        .thing => .{ .ref = w.host.refs[t.arg] },
        .item => .{ .one_of = t.itemIndex() },
        .int => .{ .int = w.story.int(t.arg) },
        .true => .{ .boolean = true },
        .false => .{ .boolean = false },
        else => null,
    };
}

// Where each value on the stack began, after term `t` at `k`: what a query's arguments are found by.
fn stackAfter(s: *const story_.Story, t: Term, starts: *[story_.max_stack]u32, n: usize, k: u32) usize {
    switch (t.op) {
        .not, .keyed => return n,
        .eq, .ne, .lt, .le, .gt, .ge, .has, .hasnt, .@"and", .@"or" => return n - 1,
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
