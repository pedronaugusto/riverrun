//! What facts a story declares: their names, scopes, kinds and items.
//!
//! The schema is the story's, and every store is made for one. Names are
//! qualified by their module (`module.name`, the root module's bare), so
//! many files and writers never clash.

const std = @import("std");
const value = @import("value.zig");

const FactId = value.FactId;
const ScopeId = value.ScopeId;
const Kind = value.Kind;

/// The scope the executor keeps its own state in: visit counts, alternatives,
/// pools' memory and the seed. A host saves it as it saves any other scope.
pub const reserved_scope = "story";

/// Who writes a fact.
pub const Role = enum(u8) {
    /// The story's effects.
    story = 0,
    /// The game's mechanics, never the story: `(game)`.
    game = 1,
    /// The executor: how often a section, a choice or a gather was reached.
    visits = 2,
    /// The executor: alternatives, pools' memory, the seed.
    state = 3,
    /// The game's, and only ever advanced: a clock, `(clock)`, whose comparisons can be woken by its value.
    clock = 4,
    /// What happened, `(moment)`: held until what watches conditions has seen it, then back to its initial value;
    /// never saved.
    moment = 5,
};

pub const Decl = struct {
    name: []const u8,
    scope: ScopeId,
    kind: Kind,
    /// The values of a `one of` or the items of a `set of`; empty otherwise.
    items: []const []const u8 = &.{},
    /// For a `ref`: the kind of the host's things it holds, which names it in a snapshot.
    ref_kind: []const u8 = "",
    role: Role = .story,

    pub fn itemNamed(d: Decl, name: []const u8) ?u16 {
        for (d.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, name)) return @intCast(i); // safe: items are at most max_items
        }
        return null;
    }
};

pub const Error = error{
    OutOfMemory,
    TooManyFacts,
    TooManyScopes,
    TooManyItems,
    NameTooLong,
    EmptyName,
    DuplicateFact,
    DuplicateScope,
    DuplicateItem,
    ScopeOutOfRange,
    /// A `one of` or a `set of` with no items, or another kind with some.
    ItemsDoNotFitKind,
};

pub const Schema = struct {
    scopes: []const []const u8,
    facts: []const Decl,

    /// Checks every bound and that no name is declared twice.
    pub fn validate(s: Schema, gpa: std.mem.Allocator) Error!void {
        if (s.facts.len > value.max_facts) return error.TooManyFacts;
        if (s.scopes.len > value.max_scopes) return error.TooManyScopes;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        for (s.scopes) |scope| {
            try checkName(scope);
            if ((try seen.getOrPut(gpa, scope)).found_existing) return error.DuplicateScope;
        }
        seen.clearRetainingCapacity();
        var items: std.StringHashMapUnmanaged(void) = .empty;
        defer items.deinit(gpa);
        for (s.facts) |d| {
            try checkName(d.name);
            if ((try seen.getOrPut(gpa, d.name)).found_existing) return error.DuplicateFact;
            if (d.scope.raw() >= s.scopes.len) return error.ScopeOutOfRange;
            const listed = d.kind == .one_of or d.kind == .set_of;
            if (listed != (d.items.len > 0)) return error.ItemsDoNotFitKind;
            if ((d.kind == .ref) != (d.ref_kind.len > 0)) return error.ItemsDoNotFitKind;
            if (d.items.len > value.max_items) return error.TooManyItems;
            items.clearRetainingCapacity();
            for (d.items) |item| {
                try checkName(item);
                if ((try items.getOrPut(gpa, item)).found_existing) return error.DuplicateItem;
            }
        }
    }

    pub fn decl(s: Schema, id: FactId) Decl {
        return s.facts[id.raw()];
    }

    pub fn scopeNamed(s: Schema, name: []const u8) ?ScopeId {
        for (s.scopes, 0..) |scope, i| {
            if (std.mem.eql(u8, scope, name)) return .fromRaw(@intCast(i)); // safe: validated to max_scopes
        }
        return null;
    }

    pub fn factNamed(s: Schema, name: []const u8) ?FactId {
        for (s.facts, 0..) |d, i| {
            if (std.mem.eql(u8, d.name, name)) return .fromRaw(@intCast(i)); // safe: validated to max_facts
        }
        return null;
    }
};

fn checkName(name: []const u8) Error!void {
    if (name.len == 0) return error.EmptyName;
    if (name.len > value.max_name) return error.NameTooLong;
}

test "a schema with a name declared twice is refused" {
    const gpa = std.testing.allocator;
    const life: ScopeId = .fromRaw(0);
    const twice: Schema = .{ .scopes = &.{"life"}, .facts = &.{
        .{ .name = "met", .scope = life, .kind = .boolean },
        .{ .name = "met", .scope = life, .kind = .int },
    } };
    try std.testing.expectError(error.DuplicateFact, twice.validate(gpa));
    const bare: Schema = .{ .scopes = &.{"life"}, .facts = &.{.{ .name = "life", .scope = life, .kind = .one_of }} };
    try std.testing.expectError(error.ItemsDoNotFitKind, bare.validate(gpa));
}

test "a set holds at most max_items" {
    const gpa = std.testing.allocator;
    var names: [value.max_items + 1][]const u8 = undefined;
    var buf: [value.max_items + 1][8]u8 = undefined;
    for (&names, &buf, 0..) |*n, *b, i| n.* = try std.mem.print(b, "i{d}", .{i});
    const big: Schema = .{ .scopes = &.{"life"}, .facts = &.{.{ .name = "kept", .scope = .fromRaw(0), .kind = .set_of, .items = &names }} };
    try std.testing.expectError(error.TooManyItems, big.validate(gpa));
    const fits: Schema = .{ .scopes = &.{"life"}, .facts = &.{.{ .name = "kept", .scope = .fromRaw(0), .kind = .set_of, .items = names[0..value.max_items] }} };
    try fits.validate(gpa);
}
