//! The store: where a story's facts live, behind an interface.
//!
//! The executor reads facts through a `Store` the host gives it, by id and
//! kind, and writes only its own bookkeeping (visit counts, alternatives,
//! pools' memory, in the reserved scope). The story's effects are never
//! applied by riverrun: a step emits them as `Effect` records and the host
//! applies them, lantern at once through `apply`, void-engine as commands at
//! its tick boundary. A host backs the interface with whatever holds its
//! state; `Memory` is the default.

const std = @import("std");
const value = @import("value.zig");
const Changes = @import("changes.zig").Changes;

const FactId = value.FactId;
const ExternId = value.ExternId;
const Value = value.Value;
const Key = value.Key;

pub const SetError = error{
    OutOfMemory,
    /// The value is not of the fact's kind.
    WrongKind,
    /// A `one of` or an item past the fact's items.
    ItemOutOfRange,
    TextTooLong,
    /// An int changed past what it holds.
    Overflow,
    /// A fact kept per thing written without its key, or one fact written with a key.
    WrongKey,
    /// A fact kept per thing holds a value for `max_keys` keys already.
    TooManyKeys,
};

pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The fact's value; a text is valid until the fact is set again.
        get: *const fn (ptr: *anyopaque, fact: FactId) Value,
        /// Sets the fact, and marks it changed if the value differs.
        set: *const fn (ptr: *anyopaque, fact: FactId, v: Value) SetError!void,
        /// The stamps watchers read.
        changes: *const fn (ptr: *anyopaque) *const Changes,
        /// A fact kept per thing: its value for `key`, its initial value until one is set.
        getKey: *const fn (ptr: *anyopaque, fact: FactId, key: Key) Value,
        /// Sets it for `key`; marks the fact changed, and the key's own stamp, if the value differs.
        setKey: *const fn (ptr: *anyopaque, fact: FactId, key: Key, v: Value) SetError!void,
        /// The stamp of the key's last change, 0 if it never changed: a watcher of one key compares it.
        keyStamp: *const fn (ptr: *anyopaque, fact: FactId, key: Key) u64,
    };

    pub fn get(s: Store, fact: FactId) Value {
        return s.vtable.get(s.ptr, fact);
    }

    pub fn set(s: Store, fact: FactId, v: Value) SetError!void {
        return s.vtable.set(s.ptr, fact, v);
    }

    pub fn changes(s: Store) *const Changes {
        return s.vtable.changes(s.ptr);
    }

    pub fn getKey(s: Store, fact: FactId, key: Key) Value {
        return s.vtable.getKey(s.ptr, fact, key);
    }

    pub fn setKey(s: Store, fact: FactId, key: Key, v: Value) SetError!void {
        return s.vtable.setKey(s.ptr, fact, key, v);
    }

    pub fn keyStamp(s: Store, fact: FactId, key: Key) u64 {
        return s.vtable.keyStamp(s.ptr, fact, key);
    }

    fn read(s: Store, fact: FactId, key: ?Key) Value {
        return if (key) |k| s.getKey(fact, k) else s.get(fact);
    }

    fn write(s: Store, fact: FactId, key: ?Key, v: Value) SetError!void {
        return if (key) |k| s.setKey(fact, k, v) else s.set(fact, v);
    }
};

/// What a step of the story does to the world: emitted, never applied by riverrun.
pub const Effect = union(enum) {
    /// `~ fact = value`; `key` for a fact kept per thing.
    set: struct { fact: FactId, key: ?Key = null, value: Value },
    /// `~ set += item`
    add: Item,
    /// `~ set -= item`
    remove: Item,
    /// `~ action(args)`: an action the story declared, performed by the host.
    call: Call,
    /// `~ int += n`, `~ int -= n`: the int moves by `by`.
    change: struct { fact: FactId, key: ?Key = null, by: i64 },

    pub const Item = struct { fact: FactId, key: ?Key = null, item: u16 };
};

pub const Call = struct {
    action: ExternId,
    /// Valid until the executor's next step.
    args: []const Value,
    /// A check with an outcome: the fact the host writes the action's result
    /// into before the story's next step, which the story then branches on.
    result: ?FactId = null,
};

/// Applies a fact effect to `store`, as a host that applies effects at once
/// does; an action is handed back for the host to perform.
pub fn apply(store: Store, effect: Effect) SetError!?Call {
    switch (effect) {
        .set => |e| try store.write(e.fact, e.key, e.value),
        .add, .remove => |e| {
            const now = store.read(e.fact, e.key);
            if (now != .set_of) return error.WrongKind;
            if (e.item >= value.max_items) return error.ItemOutOfRange;
            var items = now.set_of;
            items.setValue(e.item, effect == .add);
            try store.write(e.fact, e.key, .{ .set_of = items });
        },
        .change => |e| {
            const now = store.read(e.fact, e.key);
            if (now != .int) return error.WrongKind;
            try store.write(e.fact, e.key, .{ .int = std.math.add(i64, now.int, e.by) catch return error.Overflow });
        },
        .call => |c| return c,
    }
    return null;
}
