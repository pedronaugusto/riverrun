//! What a fact holds, and the ids facts are known by.
//!
//! Every fact has one of six kinds. An enumeration and a set name their
//! items by index into the items the fact was declared with; the names stay
//! in the declaration, so a value is a few bytes and a snapshot can still
//! match items by name when the declaration changes.

const std = @import("std");
const aegis = @import("aegis");

/// The most facts a story declares, its visit counts and the executor's own state included.
pub const max_facts = 4096;
/// The most scopes a story keeps facts in.
pub const max_scopes = 32;
/// The most values of a `one of`, and items of a `set of`.
pub const max_items = 256;
/// The longest text a text fact holds, in bytes.
pub const max_text = 1024;
/// The longest name of a fact, a scope or an item, in bytes, its module included.
pub const max_name = 256;
/// The most keys a fact kept per thing holds a value for.
pub const max_keys = 1 << 20;

/// What a fact kept per thing is keyed by: a thing's handle, or an item's index.
pub const Key = u64;

/// The least and the most a bounded int holds: `int from -100 to 100`.
pub const Bounds = struct {
    min: i64,
    max: i64,

    pub fn clamp(b: Bounds, v: i64) i64 {
        return @max(b.min, @min(b.max, v));
    }

    pub fn holds(b: Bounds, v: i64) bool {
        return v >= b.min and v <= b.max;
    }
};

/// A fact, by its place in the story's declarations.
pub const FactId = aegis.id.Id(enum { fact }, u16);
/// A scope, by its place in the story's scopes.
pub const ScopeId = aegis.id.Id(enum { scope }, u8);
/// A host function the story declares (a query or an action), by its place in the story's list.
pub const ExternId = aegis.id.Id(enum { @"extern" }, u16);

pub const Kind = enum(u8) {
    boolean = 0,
    int = 1,
    /// One of the declared values, or none until one is set.
    one_of = 2,
    /// Any of the declared items.
    set_of = 3,
    /// Text typed in by the player.
    text = 4,
    /// One of the host's things (a person, an item kind, a place): its handle, opaque to riverrun.
    ref = 5,
};

/// The items of a set, by index.
pub const Set = std.bit_set.Static(max_items);

pub const Value = union(Kind) {
    boolean: bool,
    int: i64,
    /// The index of the value among the fact's items, or `none`.
    one_of: u16,
    set_of: Set,
    /// Borrowed: from a store, valid until the fact is set again.
    text: []const u8,
    /// The host's handle, or `no_ref`.
    ref: u64,

    /// A `one of` that holds no value yet: every `=` is false of it.
    pub const none: u16 = std.math.maxInt(u16);
    /// A `ref` that holds no thing yet: every `=` is false of it too.
    pub const no_ref: u64 = 0;

    /// What a fact of `kind` holds before anything sets it.
    pub fn initial(kind: Kind) Value {
        return switch (kind) {
            .boolean => .{ .boolean = false },
            .int => .{ .int = 0 },
            .one_of => .{ .one_of = none },
            .set_of => .{ .set_of = .empty },
            .text => .{ .text = "" },
            .ref => .{ .ref = no_ref },
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        if (@as(Kind, a) != @as(Kind, b)) return false;
        return switch (a) {
            .boolean => |x| x == b.boolean,
            .int => |x| x == b.int,
            .one_of => |x| x == b.one_of,
            .set_of => |x| x.eql(b.set_of),
            .text => |x| std.mem.eql(u8, x, b.text),
            .ref => |x| x == b.ref,
        };
    }
};

test "values start empty and compare by kind and content" {
    try std.testing.expect(Value.initial(.one_of).eql(.{ .one_of = Value.none }));
    var kept: Set = .empty;
    kept.set(3);
    try std.testing.expect(!Value.initial(.set_of).eql(.{ .set_of = kept }));
    try std.testing.expect(!Value.initial(.int).eql(.{ .boolean = false }));
    try std.testing.expect((Value{ .text = "Iris" }).eql(.{ .text = "Iris" }));
}
