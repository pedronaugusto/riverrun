//! A compiled story, read in place: validated once when opened, then every
//! section, step, choice and condition read from the bytes as it is asked
//! for. Nothing is copied or allocated, so a story embedded in a game is
//! ready the moment it is opened.

const std = @import("std");
const facts = @import("../facts.zig");
const format = @import("format.zig");
const tables = @import("tables.zig");
const validate = @import("validate.zig");
const codec = @import("codec.zig");
const model = @import("model.zig");

const Graph = tables.Graph;

pub const Error = tables.Error;

pub const Options = struct {
    /// Checks the bytes against the header's hash. A host that verified them
    /// another way, or a fuzz target that wants the checks after it, turns it off.
    verify_hash: bool = true,
};

pub const Story = struct {
    g: Graph,

    pub fn init(data: []const u8, options: Options) Error!Story {
        const g: Graph = try .open(data, format.magic, options.verify_hash);
        try validate.all(&g);
        return .{ .g = g };
    }

    /// The story's hash: what a snapshot and a string table are stamped with.
    pub fn hash(s: *const Story) u64 {
        return s.g.header.hash;
    }

    pub fn bytes(s: *const Story) []const u8 {
        return s.g.bytes;
    }

    pub fn len(s: *const Story, comptime table: format.Table) u32 {
        return s.g.len(table);
    }

    pub fn str(s: *const Story, n: format.Str) []const u8 {
        return s.g.raw(.names)[n.offset..][0..n.len];
    }

    // ------------------------------------------------------------ declarations

    pub fn reservedScope(s: *const Story) facts.ScopeId {
        return .fromRaw(s.g.get(.meta, 0).reserved_scope);
    }

    pub fn seed(s: *const Story) facts.FactId {
        return .fromRaw(s.g.get(.meta, 0).seed);
    }

    /// The story's version, which migration rules count from; 0 when none is declared.
    pub fn version(s: *const Story) u16 {
        return s.g.get(.meta, 0).version;
    }

    /// The fact that keeps the version a save was taken under.
    pub fn versionFact(s: *const Story) facts.FactId {
        return .fromRaw(s.g.get(.meta, 0).version_fact);
    }

    pub fn turn(s: *const Story) facts.FactId {
        return .fromRaw(s.g.get(.meta, 0).turn);
    }

    pub fn scope(s: *const Story, id: facts.ScopeId) []const u8 {
        return s.str(s.g.get(.scopes, id.raw()));
    }

    pub fn items(s: *const Story, e: model.EnumId) Range {
        return s.g.get(.enums, e.raw());
    }

    pub fn item(s: *const Story, i: u32) []const u8 {
        return s.str(s.g.get(.items, i));
    }

    pub fn fact(s: *const Story, id: facts.FactId) model.FactDecl {
        const f = s.g.get(.facts, id.raw());
        const kind: facts.Kind = @fromBackingInt(f.kind);
        return .{
            .name = s.str(f.name),
            .scope = .fromRaw(f.scope),
            .kind = kind,
            .enumeration = if (kind == .ref or kind == .int) null else codec.optional(model.EnumId, f.enumeration),
            .bounds = if (kind == .int and f.enumeration != format.none16) blk: {
                const b = s.g.get(.bounds, f.enumeration);
                break :blk .{ .min = b.min, .max = b.max };
            } else null,
            .ref_kind = if (kind == .ref) .fromRaw(f.enumeration) else null,
            .role = @fromBackingInt(f.role),
            .key = if (f.key_kind == @backingInt(facts.Kind.one_of)) .{ .items = .fromRaw(f.key_type) } else if (f.key_kind == @backingInt(facts.Kind.ref)) .{ .ref = .fromRaw(f.key_type) } else .none,
        };
    }

    /// An enumeration's items' names, on `arena`.
    pub fn itemNames(s: *const Story, arena: std.mem.Allocator, e: model.EnumId) error{OutOfMemory}![]const []const u8 {
        const r = s.items(e);
        const list = try arena.alloc([]const u8, r.len);
        for (list, 0..) |*n, k| n.* = s.item(r.start + @as(u32, @intCast(k))); // safe: validated to max_items
        return list;
    }

    pub fn factNamed(s: *const Story, name: []const u8) ?facts.FactId {
        for (0..s.len(.facts)) |i| {
            if (std.mem.eql(u8, s.str(s.g.get(.facts, @intCast(i)).name), name)) return .fromRaw(@intCast(i)); // safe: validated to max_facts
        }
        return null;
    }

    pub fn castMember(s: *const Story, id: model.CastId) model.Cast {
        const c = s.g.get(.cast, id.raw());
        return .{
            .name = s.str(c.name),
            .display = model.LineId.fromRaw(c.display) catch unreachable, // unreachable: validated nonzero
            .relation = if (c.relation == 0) null else model.LineId.fromRaw(c.relation) catch unreachable, // unreachable: nonzero here
            .tags = c.tags,
            .extra = c.extra == 1,
        };
    }

    pub fn externFn(s: *const Story, id: facts.ExternId) model.Extern {
        const x = s.g.get(.externs, id.raw());
        return .{
            .name = s.str(x.name),
            .params = x.params,
            .returns = if (x.returns == format.no_kind) null else typed(@fromBackingInt(x.returns), x.enumeration),
            .action = x.action == 1,
            .stamp = if (x.stamp.len == 0) null else .{ .family = s.str(x.stamp), .keys = x.keys },
        };
    }

    pub fn builtin(s: *const Story, i: u32) model.BuiltinCall {
        const b = s.g.get(.builtins, i);
        return .{ .kind = s.str(b.kind), .name = s.str(b.name), .args = b.args, .returns = @fromBackingInt(b.returns) };
    }

    pub fn builtinArg(s: *const Story, i: u32) u32 {
        return s.g.get(.builtin_args, i);
    }

    /// The block a package named `name` owns, if the story carries one: the package validates its bytes.
    pub fn block(s: *const Story, name: []const u8) ?model.Block {
        for (0..s.len(.blocks)) |i| {
            const b = s.g.get(.blocks, @intCast(i)); // safe: below a u32 count
            if (std.mem.eql(u8, s.str(b.name), name)) return .{ .version = b.version, .bytes = s.g.raw(.block_bytes)[b.bytes.start..][0..b.bytes.len] };
        }
        return null;
    }

    pub fn param(s: *const Story, i: u32) model.Param {
        const p = s.g.get(.params, i);
        return typed(@fromBackingInt(p.kind), p.enumeration);
    }

    fn typed(kind: facts.Kind, field: u16) model.Param {
        if (kind == .ref) return .{ .kind = kind, .ref_kind = .fromRaw(field) };
        return .{ .kind = kind, .enumeration = codec.optional(model.EnumId, field) };
    }

    /// The name of a kind of the host's things.
    pub fn refKind(s: *const Story, id: model.RefKindId) []const u8 {
        return s.str(s.g.get(.kinds, id.raw()));
    }

    /// What the `i`th `since_changed` reads.
    pub fn change(s: *const Story, i: u32) model.Change {
        const c = s.g.get(.changes, i);
        return .{ .fact = .fromRaw(c.fact), .clock = .fromRaw(c.clock), .at = .fromRaw(c.at) };
    }

    /// The `i`th thing the story names: what a host resolves to its handle at load.
    pub fn thing(s: *const Story, i: u32) model.Thing {
        const t = s.g.get(.things, i);
        return .{ .kind = s.str(s.g.get(.kinds, t.kind)), .id = s.str(t.id) };
    }

    /// The facts as a schema for a store: names and items borrowed from the story, lists on `arena`.
    pub fn schema(s: *const Story, arena: std.mem.Allocator) error{OutOfMemory}!facts.Schema {
        const scopes = try arena.alloc([]const u8, s.len(.scopes));
        for (scopes, 0..) |*n, i| n.* = s.scope(.fromRaw(@intCast(i))); // safe: validated to max_scopes
        const decls = try arena.alloc(facts.Decl, s.len(.facts));
        for (decls, 0..) |*d, i| {
            const f = s.fact(.fromRaw(@intCast(i))); // safe: validated to max_facts
            var names: []const []const u8 = &.{};
            if (f.enumeration) |e| {
                const r = s.items(e);
                const list = try arena.alloc([]const u8, r.len);
                for (list, 0..) |*n, k| n.* = s.item(r.start + @as(u32, @intCast(k))); // safe: validated to max_items
                names = list;
            }
            d.* = .{ .name = f.name, .scope = f.scope, .kind = f.kind, .items = names, .ref_kind = if (f.ref_kind) |k| s.refKind(k) else "", .role = f.role, .bounds = f.bounds, .key = switch (f.key) {
                .none => .none,
                .ref => |k| .{ .ref = s.refKind(k) },
                .items => |e| .{ .items = try s.itemNames(arena, e) },
            } };
        }
        return .{ .scopes = scopes, .facts = decls };
    }

    // ------------------------------------------------------------ the graph

    pub fn section(s: *const Story, id: model.SectionId) model.Section {
        const r = s.g.get(.sections, id.raw());
        return .{
            .name = s.str(r.name),
            .kind = @fromBackingInt(r.kind),
            .pick = r.pick,
            .kind_name = s.str(r.kind_name),
            .tags = r.tags,
            .entry = codec.optional(model.NodeId, r.entry),
            .candidates = r.candidates,
            .visits = .fromRaw(r.visits),
        };
    }

    /// A section by its qualified name, `module.name`.
    pub fn sectionNamed(s: *const Story, name: []const u8) ?model.SectionId {
        for (0..s.len(.sections)) |i| {
            if (std.mem.eql(u8, s.str(s.g.get(.sections, @intCast(i)).name), name)) return .fromRaw(@intCast(i)); // safe: below a u32 count
        }
        return null;
    }

    pub fn candidate(s: *const Story, i: u32) model.Candidate {
        const c = s.g.get(.candidates, i);
        return .{
            .name = s.str(c.name),
            .when = c.when,
            .specificity = c.specificity,
            .tags = c.tags,
            .entry = .fromRaw(c.entry),
            .visits = .fromRaw(c.visits),
            .seen = .fromRaw(c.seen),
            .weight = c.weight,
            .migrate = c.migrate,
        };
    }

    pub fn node(s: *const Story, id: model.NodeId) model.Node {
        return codec.decodeNode(s.g.get(.nodes, id.raw()));
    }

    pub fn choice(s: *const Story, i: u32) model.Choice {
        const c = s.g.get(.choices, i);
        return .{
            .text = .fromRaw(c.text),
            .cond = c.cond,
            .sticky = c.sticky == 1,
            .visits = .fromRaw(c.visits),
            .tags = c.tags,
            .target = .fromRaw(c.target),
        };
    }

    pub fn text(s: *const Story, id: model.TextId) model.Text {
        const t = s.g.get(.texts, id.raw());
        return .{ .line = model.LineId.fromRaw(t.line) catch unreachable, .slots = t.slots }; // unreachable: validated nonzero
    }

    pub fn slot(s: *const Story, i: u32) model.Slot {
        const r = s.g.get(.slots, i);
        return .{ .kind = @fromBackingInt(r.kind), .expr = r.expr, .arity = r.arity, .state = codec.optional(facts.FactId, r.state) };
    }

    pub fn effect(s: *const Story, i: u32) model.Effect {
        return codec.decodeEffect(s.g.get(.effects, i));
    }

    /// Term `i`: an op and its argument, as `format.Term` documents.
    pub fn term(s: *const Story, i: u32) model.Term {
        return @bitCast(s.g.get(.terms, i));
    }

    pub fn int(s: *const Story, i: u32) i64 {
        return s.g.get(.ints, i);
    }

    pub fn literal(s: *const Story, i: u32) []const u8 {
        return s.str(s.g.get(.literals, i));
    }

    pub fn tag(s: *const Story, i: u32) model.Tag {
        const t = s.g.get(.tags, i);
        return .{ .key = s.str(t.key), .values = t.values };
    }

    pub fn tagValue(s: *const Story, i: u32) model.TagValue {
        const v = s.g.get(.tag_values, i);
        return .{ .text = s.str(v.text), .section = codec.optional(model.SectionId, v.section), .line = if (v.line == 0) null else model.LineId.fromRaw(v.line) catch null };
    }

    /// The first value of the tag `key` in `r`, if it carries one.
    pub fn tagNamed(s: *const Story, r: Range, key: []const u8) ?model.Tag {
        for (0..r.len) |k| {
            const t = s.tag(r.start + @as(u32, @intCast(k))); // safe: below a u32 length
            if (std.mem.eql(u8, t.key, key)) return t;
        }
        return null;
    }
};

const Range = format.Range;
