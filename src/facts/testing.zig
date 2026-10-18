//! A small schema shaped like the proof's, for the facts layer's tests.

const value = @import("value.zig");
const Schema = @import("schema.zig").Schema;

pub const life_scope: value.ScopeId = .fromRaw(0);
pub const player_scope: value.ScopeId = .fromRaw(1);

pub const life: value.FactId = .fromRaw(0);
pub const kept: value.FactId = .fromRaw(1);
pub const met: value.FactId = .fromRaw(2);
pub const hour: value.FactId = .fromRaw(3);
pub const name: value.FactId = .fromRaw(4);
pub const carried: value.FactId = .fromRaw(5);
pub const target: value.FactId = .fromRaw(6);
pub const ally: value.FactId = .fromRaw(7);

pub const schema: Schema = .{
    .scopes = &.{ "life", "player" },
    .facts = &.{
        .{ .name = "life", .scope = life_scope, .kind = .one_of, .items = &.{ "stay", "go" } },
        .{ .name = "kept", .scope = life_scope, .kind = .set_of, .items = &.{ "ruth", "stock", "dad" } },
        .{ .name = "met", .scope = life_scope, .kind = .boolean },
        .{ .name = "hour", .scope = life_scope, .kind = .int, .role = .game },
        .{ .name = "name", .scope = player_scope, .kind = .text },
        .{ .name = "carried", .scope = player_scope, .kind = .set_of, .items = &.{ "play", "gave", "hands" } },
        .{ .name = "target", .scope = life_scope, .kind = .ref, .ref_kind = "person" },
        .{ .name = "ally", .scope = life_scope, .kind = .ref, .ref_kind = "person" },
    },
};
