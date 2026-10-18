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

pub const SetError = error{
    OutOfMemory,
    /// The value is not of the fact's kind.
    WrongKind,
    /// A `one of` or an item past the fact's items.
    ItemOutOfRange,
    TextTooLong,
    /// An int changed past what it holds.
    Overflow,
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
};

/// What a step of the story does to the world: emitted, never applied by riverrun.
pub const Effect = union(enum) {
    /// `~ fact = value`
    set: struct { fact: FactId, value: Value },
    /// `~ set += item`
    add: Item,
    /// `~ set -= item`
    remove: Item,
    /// `~ action(args)`: an action the story declared, performed by the host.
    call: Call,
    /// `~ int += n`, `~ int -= n`: the int moves by `by`.
    change: struct { fact: FactId, by: i64 },

    pub const Item = struct { fact: FactId, item: u16 };
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
        .set => |e| try store.set(e.fact, e.value),
        .add, .remove => |e| {
            const now = store.get(e.fact);
            if (now != .set_of) return error.WrongKind;
            if (e.item >= value.max_items) return error.ItemOutOfRange;
            var items = now.set_of;
            items.setValue(e.item, effect == .add);
            try store.set(e.fact, .{ .set_of = items });
        },
        .change => |e| {
            const now = store.get(e.fact);
            if (now != .int) return error.WrongKind;
            try store.set(e.fact, .{ .int = std.math.add(i64, now.int, e.by) catch return error.Overflow });
        },
        .call => |c| return c,
    }
    return null;
}
