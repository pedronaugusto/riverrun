//! What a checked story holds, by id: its speakers, facts, constants,
//! queries and actions, the enumerations their types name, its sections
//! with their parts and labels, and the visit counts kept for them; and what
//! each node of the syntax tree turned out to mean.
//!
//! Names are looked up by module and name: a name is found in the asking
//! file's module first, then in the root module. Every file is in the root
//! module today; modules are a reader change and that one rule.

const std = @import("std");
const aegis = @import("aegis");
const syntax = @import("../syntax.zig");

const ast = syntax.ast;
const Span = syntax.Span;

pub const ModuleId = aegis.id.Id(enum { module }, u16);
pub const SpeakerId = aegis.id.Id(enum { speaker }, u16);
pub const FactId = aegis.id.Id(enum { fact }, u16);
pub const ConstId = aegis.id.Id(enum { constant }, u16);
pub const ExternId = aegis.id.Id(enum { external }, u16);
pub const EnumId = aegis.id.Id(enum { enumeration }, u16);
pub const SectionId = aegis.id.Id(enum { section }, u16);
pub const LabelId = aegis.id.Id(enum { label }, u16);
pub const VisitId = aegis.id.Id(enum { visit }, u16);
pub const KindId = aegis.id.Id(enum { kind }, u16);

/// The module every name falls back to, and today the only one.
pub const root: ModuleId = .fromRaw(0);

/// The most of each a story declares; past it the checker says so.
pub const limits = struct {
    /// Facts, as the runtime's store bounds them.
    pub const facts = @import("riverrun").facts.max_facts;
    /// Values of one enumeration.
    pub const values = std.math.maxInt(u16);
    /// Anything numbered by a 16-bit id: speakers, sections, labels, visit counts.
    pub const ids = std.math.maxInt(u16);
};

// ---------------------------------------------------------------- types

pub const Type = union(enum) {
    boolean,
    int,
    text,
    one_of: EnumId,
    set_of: EnumId,
    /// A handle to one of the host's things of a kind: `ref of person`.
    ref: KindId,

    pub fn eql(a: Type, b: Type) bool {
        return switch (a) {
            .boolean => b == .boolean,
            .int => b == .int,
            .text => b == .text,
            .one_of => |e| b == .one_of and b.one_of.eql(e),
            .set_of => |e| b == .set_of and b.set_of.eql(e),
            .ref => |k| b == .ref and b.ref.eql(k),
        };
    }
};

/// An enumeration: the values of a `one of` or a `set of`, in the order
/// written. Two types that name the same values in the same order are one.
pub const Enum = struct { values: []const []const u8 };

/// One value of an enumeration.
pub const Value = struct {
    enumeration: EnumId,
    index: u16,

    pub fn eql(a: Value, b: Value) bool {
        return a.enumeration.eql(b.enumeration) and a.index == b.index;
    }
};

// ---------------------------------------------------------------- symbols

pub const Speaker = struct {
    /// What a speaker matches, in lower case: the cast's id (`dad` for `DAD`), or an extra's words.
    key: []const u8,
    /// How the character is shown; null for an extra, who is shown as written.
    display: ?[]const u8,
    relation: ?[]const u8,
    extra: bool,
    module: ModuleId,
    span: Span,
    tags: []const ast.Tag,
};

pub const Fact = struct {
    name: []const u8,
    /// The scope the host names, or null for the story's default.
    scope: ?[]const u8,
    type: Type,
    /// Written by the game's mechanics, never by the story.
    game: bool,
    /// An int the game only advances.
    clock: bool = false,
    /// What happened: seen only by what watches conditions.
    moment: bool = false,
    /// For a fact kept per thing: what keys it, the things of a kind or an enumeration's values.
    key: ?Type = null,
    /// For a bounded int: the least and the most it holds.
    bounds: ?ast.Bounds = null,
    module: ModuleId,
    span: Span,
    /// Whether any effect of the story sets it.
    set: bool = false,
    /// The section that declares it, for a fact the section brings rather than the story: its own, or its kind's.
    by: ?SectionId = null,
    /// One of the things its section is about, given when the section starts: `(role)`.
    role: bool = false,
};

pub const Constant = union(enum) { boolean: bool, int: i64, text: []const u8 };

pub const Const = struct {
    name: []const u8,
    type: Type,
    value: Constant,
    module: ModuleId,
    span: Span,
};

pub const Extern = struct {
    name: []const u8,
    params: []const Type,
    /// Each parameter's name, where it has one.
    param_names: []const ?[]const u8 = &.{},
    /// Null for an action, which runs as an effect; a type for a query, which an expression asks,
    /// or for an action's outcome.
    returns: ?Type,
    /// An action with an outcome the host decides: `~ fact = name(…)`.
    action: bool = false,
    /// The stamp the host bumps when what the query reads changes.
    reads: ?Stamp = null,
    module: ModuleId,
    span: Span,

    /// Whether an expression may ask it: a query, not an action of either kind.
    pub fn asks(e: Extern) bool {
        return e.returns != null and !e.action;
    }
};

/// A query's stamp: its family, and the parameters that key it.
pub const Stamp = struct { family: []const u8, keys: []const u16 };

pub const SinceChanged = struct { fact: FactId, clock: FactId };

/// One of the host's things, named in the story by its stable id: `wolf_pelt`.
pub const Thing = struct { kind: KindId, id: []const u8 };

pub const Section = struct {
    name: []const u8,
    module: ModuleId,
    file: syntax.FileId,
    node: *const ast.Section,
    kind: Kind,
    parts: []Part,
    /// The labels of the section's own body.
    labels: []const LabelId,
    visit: VisitId,
    /// A tag hands the section's end to the host, which goes on to a section it names.
    leads: bool = false,
    /// Something calls it with `->>`.
    called: bool = false,
    /// It declares facts within it, its own or its kind's, which its own conditions name without the section's name.
    declares: bool = false,

    pub const Kind = union(enum) {
        scene,
        /// Picks this many of its candidates.
        pool: u16,
        /// Rules: each part fires its effects when its condition becomes true.
        rules,
        /// A kind the host registers: `quest`.
        other: []const u8,
    };
};

/// `= name` in a section: a part of a scene, or a candidate of a pool.
pub const Part = struct {
    name: []const u8,
    node: *const ast.Subsection,
    labels: []const LabelId,
    visit: VisitId,
    /// A flow goes to it, or it opens a scene with no body of its own.
    reached: bool = false,
};

pub const PartRef = struct { section: SectionId, index: u16 };

/// A function a registered kind's conditions may call, which its package evaluates: `since(stage, fact)`.
pub const Builtin = struct {
    name: []const u8,
    params: []const Arg,
    returns: Returns,

    /// What a builtin's argument names: never a value, always something of the story.
    pub const Arg = enum {
        /// A part of the section the call is in: a quest's stage.
        part,
        section,
        /// A fact, which must be an int.
        int_fact,
        /// Any fact.
        fact,
    };

    pub const Returns = enum { boolean, int };
};

/// A kind of section a package registered, as the compiler needs it: its name and its builtins.
pub const Registered = struct { name: []const u8, builtins: []const Builtin };

/// `- (name)`: a gather that flow can go to by name.
pub const Label = struct {
    name: []const u8,
    stmt: *const ast.Stmt,
    section: SectionId,
    part: ?u16,
    visit: VisitId,
};

/// A visit count: how often a section, a part or a label has been reached, which
/// `seen(name)` reads. The compiler keeps one fact for each.
pub const Visit = struct {
    of: union(enum) { section: SectionId, part: PartRef, label: LabelId },
    /// An expression reads it.
    read: bool = false,
};

// ---------------------------------------------------------------- what nodes mean

/// Where a flow goes.
pub const Target = union(enum) {
    end,
    section: SectionId,
    part: PartRef,
    label: LabelId,
};

/// What a name in the tree refers to.
pub const Ref = union(enum) {
    speaker: SpeakerId,
    fact: FactId,
    constant: ConstId,
    query: ExternId,
    action: ExternId,
    value: Value,
    visits: VisitId,
    target: Target,
    thing: Thing,
    /// `since_changed(fact, clock)`: how far the clock has moved since the fact last changed.
    since_changed: SinceChanged,
    /// `happened(moment)`: whether a moment happened this step.
    happened: FactId,
    /// `opinion(margaret)`: a fact kept per thing, read for one key.
    keyed: FactId,
    /// A builtin of the section's registered kind: which kind of `check.Options.kinds`, which builtin.
    builtin: BuiltinRef,
};

pub const BuiltinRef = struct {
    kind: u16,
    builtin: u16,
    /// What each argument names, in order: a part, a section or a fact.
    args: []const BuiltinArg,
};

pub const BuiltinArg = union(enum) { part: PartRef, section: SectionId, fact: FactId };

/// An expression's type, and what it names when it is a name or a call.
pub const Typed = struct { type: Type, ref: ?Ref = null };

/// A line's or a choice's id: written as `# id …`, or derived in a development build.
pub const LineId = struct { text: []const u8, written: bool };

/// A flow from one section to another: what reachability walks.
pub const Edge = struct {
    from: SectionId,
    to: SectionId,
    how: enum { jump, call, tag },
};

// ---------------------------------------------------------------- names

pub const Key = struct { module: ModuleId, name: []const u8 };

pub const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h: std.hash.Wyhash = .init(k.module.raw());
        h.update(k.name);
        return h.final();
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.module.eql(b.module) and std.mem.eql(u8, a.name, b.name);
    }
};

/// A namespace: names by module.
pub fn Names(comptime V: type) type {
    return struct {
        const Self = @This();

        map: std.HashMapUnmanaged(Key, V, KeyContext, std.hash_map.default_max_load_percentage) = .empty,

        /// The name as `module` sees it: its own first, then the root's.
        pub fn find(n: *const Self, module: ModuleId, name: []const u8) ?V {
            if (n.map.get(.{ .module = module, .name = name })) |v| return v;
            if (module.eql(root)) return null;
            return n.map.get(.{ .module = root, .name = name });
        }
    };
}

/// What shares the expression namespace: a name in a condition or an effect is one of these.
pub const Named = union(enum) { fact: FactId, constant: ConstId, external: ExternId };

/// An id from a table position the checker just appended.
pub fn idOf(comptime Id: type, index: usize) Id {
    std.debug.assert(index <= limits.ids);
    return .fromRaw(@intCast(index)); // safe: the table bounds were checked when it grew
}

test "types compare by kind and enumeration" {
    const a: Type = .{ .one_of = .fromRaw(1) };
    try std.testing.expect(a.eql(.{ .one_of = .fromRaw(1) }));
    try std.testing.expect(!a.eql(.{ .set_of = .fromRaw(1) }));
    try std.testing.expect(!a.eql(.{ .one_of = .fromRaw(2) }));
    try std.testing.expect((Type{ .int = {} }).eql(.int));
}

test "a module sees its own names, then the root's" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var n: Names(u8) = .{};
    try n.map.put(arena.allocator(), .{ .module = root, .name = "kept" }, 1);
    try n.map.put(arena.allocator(), .{ .module = .fromRaw(2), .name = "kept" }, 2);
    try std.testing.expectEqual(@as(?u8, 2), n.find(.fromRaw(2), "kept"));
    try std.testing.expectEqual(@as(?u8, 1), n.find(.fromRaw(3), "kept"));
    try std.testing.expectEqual(@as(?u8, null), n.find(root, "spot"));
}
