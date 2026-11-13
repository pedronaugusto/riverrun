//! The default store: every fact in memory, a value each, texts owned by the
//! store's allocator. A host with no state of its own keeps its facts here; one with state of its
//! own implements `Store` over it instead. A fact kept per thing holds a value
//! only for the keys set, each with the stamp of its last change.

const std = @import("std");
const value = @import("value.zig");
const schema_ = @import("schema.zig");
const store_ = @import("store.zig");
const Changes = @import("changes.zig").Changes;

const FactId = value.FactId;
const ScopeId = value.ScopeId;
const Value = value.Value;
const Key = value.Key;

/// A key's value, and the stamp of its last change.
pub const Keyed = struct { value: Value, stamp: u64 };
const Schema = schema_.Schema;
const SetError = store_.SetError;

pub const Memory = struct {
    gpa: std.mem.Allocator,
    /// Borrowed: it outlives the store.
    schema: Schema,
    values: []Value,
    /// By fact: a fact kept per thing's values, by key in the order first set, so a snapshot writes them
    /// in one order; empty for the others.
    keyed: []std.array_hash_map.Auto(Key, Keyed),
    changes: Changes,

    /// A store for `schema`'s facts, each at its initial value.
    pub fn init(gpa: std.mem.Allocator, schema: Schema) (schema_.Error || error{OutOfMemory})!Memory {
        try schema.validate(gpa);
        const values = try gpa.alloc(Value, schema.facts.len);
        errdefer gpa.free(values);
        for (values, schema.facts) |*v, d| v.* = .initial(d.kind);
        const keyed = try gpa.alloc(std.array_hash_map.Auto(Key, Keyed), schema.facts.len);
        errdefer gpa.free(keyed);
        @memset(keyed, .empty);
        return .{ .gpa = gpa, .schema = schema, .values = values, .keyed = keyed, .changes = try .init(gpa, schema.facts.len) };
    }

    pub fn deinit(m: *Memory) void {
        for (m.values) |v| freeText(m.gpa, v);
        m.gpa.free(m.values);
        for (m.keyed) |*k| k.deinit(m.gpa);
        m.gpa.free(m.keyed);
        m.changes.deinit(m.gpa);
        m.* = undefined;
    }

    pub fn store(m: *Memory) store_.Store {
        return .{ .ptr = m, .vtable = &vtable };
    }

    const vtable: store_.Store.VTable = .{
        .get = struct {
            fn f(ptr: *anyopaque, fact: FactId) Value {
                const m: *Memory = @ptrCast(@alignCast(ptr)); // safe: made by `store` from a *Memory
                return m.get(fact);
            }
        }.f,
        .set = struct {
            fn f(ptr: *anyopaque, fact: FactId, v: Value) SetError!void {
                const m: *Memory = @ptrCast(@alignCast(ptr)); // safe: made by `store` from a *Memory
                return m.set(fact, v);
            }
        }.f,
        .changes = struct {
            fn f(ptr: *anyopaque) *const Changes {
                const m: *Memory = @ptrCast(@alignCast(ptr)); // safe: made by `store` from a *Memory
                return &m.changes;
            }
        }.f,
        .getKey = struct {
            fn f(ptr: *anyopaque, fact: FactId, key: Key) Value {
                const m: *Memory = @ptrCast(@alignCast(ptr)); // safe: made by `store` from a *Memory
                return m.getKey(fact, key);
            }
        }.f,
        .setKey = struct {
            fn f(ptr: *anyopaque, fact: FactId, key: Key, v: Value) SetError!void {
                const m: *Memory = @ptrCast(@alignCast(ptr)); // safe: made by `store` from a *Memory
                return m.setKey(fact, key, v);
            }
        }.f,
        .bounds = struct {
            fn f(ptr: *anyopaque, fact: FactId) ?value.Bounds {
                const m: *Memory = @ptrCast(@alignCast(ptr)); // safe: made by `store` from a *Memory
                return m.schema.decl(fact).bounds;
            }
        }.f,
        .keyStamp = struct {
            fn f(ptr: *anyopaque, fact: FactId, key: Key) u64 {
                const m: *Memory = @ptrCast(@alignCast(ptr)); // safe: made by `store` from a *Memory
                return if (m.keyed[fact.raw()].get(key)) |k| k.stamp else 0;
            }
        }.f,
    };

    pub fn get(m: *const Memory, fact: FactId) Value {
        return m.values[fact.raw()];
    }

    pub fn set(m: *Memory, fact: FactId, v: Value) SetError!void {
        const d = m.schema.decl(fact);
        if (d.key != .none) return error.WrongKey;
        try check(d, v);
        const slot = &m.values[fact.raw()];
        if (slot.eql(v)) return;
        const next: Value = if (v == .text and v.text.len > 0) .{ .text = try m.gpa.dupe(u8, v.text) } else v;
        freeText(m.gpa, slot.*);
        slot.* = next;
        m.changes.mark(fact);
    }

    pub fn getKey(m: *const Memory, fact: FactId, key: Key) Value {
        return if (m.keyed[fact.raw()].get(key)) |k| k.value else .initial(m.schema.decl(fact).kind);
    }

    pub fn setKey(m: *Memory, fact: FactId, key: Key, v: Value) SetError!void {
        const d = m.schema.decl(fact);
        if (d.key == .none) return error.WrongKey;
        try check(d, v);
        const map = &m.keyed[fact.raw()];
        if (map.get(key)) |have| {
            if (have.value.eql(v)) return;
        } else if (v.eql(.initial(d.kind))) return;
        if (!map.contains(key) and map.count() == value.max_keys) return error.TooManyKeys;
        m.changes.markKey(fact, key);
        try map.put(m.gpa, key, .{ .value = v, .stamp = m.changes.now() });
    }

    /// Every fact of `scope` back to its initial value: a new life, a new game.
    pub fn reset(m: *Memory, scope: ScopeId) void {
        for (m.schema.facts, 0..) |d, i| {
            if (!d.scope.eql(scope)) continue;
            const id: FactId = .fromRaw(@intCast(i)); // safe: validated to max_facts
            if (d.key != .none) {
                if (m.keyed[i].count() > 0) m.changes.mark(id);
                m.keyed[i].clearRetainingCapacity();
                continue;
            }
            m.set(id, .initial(d.kind)) catch unreachable; // glint-ignore: Z026 -- an initial value fits its kind and allocates nothing
        }
    }
};

/// Whether `v` fits the declaration `d`.
pub fn check(d: schema_.Decl, v: Value) SetError!void {
    if (@as(value.Kind, v) != d.kind) return error.WrongKind;
    switch (v) {
        .one_of => |x| if (x != Value.none and x >= d.items.len) return error.ItemOutOfRange,
        .set_of => |x| if (x.findLastSet()) |last| {
            if (last >= d.items.len) return error.ItemOutOfRange;
        },
        .text => |x| if (x.len > value.max_text) return error.TextTooLong,
        .int => |x| if (d.bounds) |b| if (!b.holds(x)) return error.OutOfBounds,
        .boolean, .ref => {},
    }
}

fn freeText(gpa: std.mem.Allocator, v: Value) void {
    if (v == .text and v.text.len > 0) gpa.free(v.text);
}

const testing = @import("testing.zig");

test "a store holds its facts' kinds and marks what changed" {
    const gpa = std.testing.allocator;
    var m: Memory = try .init(gpa, testing.schema);
    defer m.deinit();
    const s = m.store();
    try std.testing.expectEqual(Value.none, s.get(testing.life).one_of);
    try s.set(testing.life, .{ .one_of = 1 });
    try std.testing.expectError(error.WrongKind, s.set(testing.life, .{ .int = 1 }));
    try std.testing.expectError(error.ItemOutOfRange, s.set(testing.life, .{ .one_of = 2 }));
    const before = s.changes().now();
    try s.set(testing.life, .{ .one_of = 1 });
    try std.testing.expectEqual(before, s.changes().now());
    try s.set(testing.name, .{ .text = "Iris" });
    try s.set(testing.name, .{ .text = "Iris June" });
    try std.testing.expectEqualStrings("Iris June", s.get(testing.name).text);
    var long: [value.max_text + 1]u8 = @splat('a');
    try std.testing.expectError(error.TextTooLong, s.set(testing.name, .{ .text = &long }));
}

test "effects are applied by the host, and an action is handed back" {
    const gpa = std.testing.allocator;
    var m: Memory = try .init(gpa, testing.schema);
    defer m.deinit();
    const s = m.store();
    try std.testing.expectEqual(@as(?store_.Call, null), try store_.apply(s, .{ .add = .{ .fact = testing.kept, .item = 2 } }));
    _ = try store_.apply(s, .{ .add = .{ .fact = testing.kept, .item = 0 } });
    _ = try store_.apply(s, .{ .remove = .{ .fact = testing.kept, .item = 2 } });
    try std.testing.expectEqual(@as(usize, 1), s.get(testing.kept).set_of.count());
    try std.testing.expectError(error.ItemOutOfRange, store_.apply(s, .{ .add = .{ .fact = testing.kept, .item = 9 } }));
    const call = (try store_.apply(s, .{ .call = .{ .action = .fromRaw(0), .args = &.{.{ .one_of = 1 }}, .result = testing.met } })).?;
    try std.testing.expectEqual(@as(u16, 0), call.action.raw());
    try std.testing.expect(call.result.?.eql(testing.met));
    m.reset(testing.life_scope);
    try std.testing.expectEqual(@as(usize, 0), s.get(testing.kept).set_of.count());
}

test "an int changes by an amount, and never past what it holds" {
    const gpa = std.testing.allocator;
    var m: Memory = try .init(gpa, testing.schema);
    defer m.deinit();
    const s = m.store();
    _ = try store_.apply(s, .{ .change = .{ .fact = testing.hour, .by = 5 } });
    _ = try store_.apply(s, .{ .change = .{ .fact = testing.hour, .by = -2 } });
    try std.testing.expectEqual(@as(i64, 3), s.get(testing.hour).int);
    try s.set(testing.hour, .{ .int = std.math.maxInt(i64) });
    try std.testing.expectError(error.Overflow, store_.apply(s, .{ .change = .{ .fact = testing.hour, .by = 1 } }));
    try std.testing.expectError(error.WrongKind, store_.apply(s, .{ .change = .{ .fact = testing.met, .by = 1 } }));
}

test "a fact kept per thing holds a value only for the keys set, each with its own stamp" {
    const gpa = std.testing.allocator;
    const world: ScopeId = .fromRaw(0);
    const per_person: Schema = .{ .scopes = &.{"world"}, .facts = &.{
        .{ .name = "opinion", .scope = world, .kind = .int, .key = .{ .ref = "person" } },
        .{ .name = "met", .scope = world, .kind = .boolean },
    } };
    var m: Memory = try .init(gpa, per_person);
    defer m.deinit();
    const s = m.store();
    const opinion: FactId = .fromRaw(0);
    try std.testing.expectEqual(@as(i64, 0), s.getKey(opinion, 7).int);
    try s.setKey(opinion, 7, .{ .int = -50 });
    const stamp = s.keyStamp(opinion, 7);
    try s.setKey(opinion, 9, .{ .int = 3 });
    try std.testing.expectEqual(stamp, s.keyStamp(opinion, 7));
    try std.testing.expect(s.keyStamp(opinion, 9) > stamp);
    try std.testing.expectEqual(@as(u64, 0), s.keyStamp(opinion, 11));
    try std.testing.expectError(error.WrongKey, s.set(opinion, .{ .int = 1 }));
    try std.testing.expectError(error.WrongKey, s.setKey(.fromRaw(1), 7, .{ .boolean = true }));
    _ = try store_.apply(s, .{ .change = .{ .fact = opinion, .key = 7, .by = 10 } });
    try std.testing.expectEqual(@as(i64, -40), s.getKey(opinion, 7).int);
    m.reset(world);
    try std.testing.expectEqual(@as(i64, 0), s.getKey(opinion, 7).int);
}
