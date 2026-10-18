//! The facts layer: typed state in scopes the host names, behind a store the
//! host can implement, with the default store, snapshots and change stamps.
//!
//! Both the dialogue executor and the quest package read facts, so they are
//! riverrun's own layer and need nothing else in it. riverrun keeps scopes
//! apart; the host decides where each is saved.

const value = @import("facts/value.zig");
const schema = @import("facts/schema.zig");
const store = @import("facts/store.zig");
const changes = @import("facts/changes.zig");

pub const max_facts = value.max_facts;
pub const max_scopes = value.max_scopes;
pub const max_items = value.max_items;
pub const max_text = value.max_text;
pub const max_name = value.max_name;
pub const max_keys = value.max_keys;
pub const Key = value.Key;
pub const KeyDecl = schema.KeyDecl;

pub const FactId = value.FactId;
pub const ScopeId = value.ScopeId;
pub const ExternId = value.ExternId;
pub const Kind = value.Kind;
pub const Set = value.Set;
pub const Value = value.Value;

pub const reserved_scope = schema.reserved_scope;
pub const Role = schema.Role;
pub const Decl = schema.Decl;
pub const Schema = schema.Schema;
pub const SchemaError = schema.Error;

pub const Store = store.Store;
pub const SetError = store.SetError;
pub const Effect = store.Effect;
pub const Call = store.Call;
pub const apply = store.apply;

pub const Changes = changes.Changes;
pub const Watcher = changes.Watcher;

pub const Memory = @import("facts/memory.zig").Memory;
pub const snapshot = @import("facts/snapshot.zig");
pub const RefNames = snapshot.RefNames;

test {
    _ = value;
    _ = schema;
    _ = store;
    _ = changes;
    _ = Memory;
    _ = @import("facts/memory.zig");
    _ = snapshot;
}
