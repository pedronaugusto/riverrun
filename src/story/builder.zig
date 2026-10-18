//! Builds a compiled story: what the compiler fills from a checked tree, and
//! what tests build by hand.
//!
//! Declarations come first, then sections, which can be declared before
//! their steps so a jump can name a section not yet built. A step can be
//! reserved and defined later, for edges that point forward: a choice's body
//! before the gather it returns to. `bytes` writes the graph and reads it
//! back through the reader, so the builder never emits what a reader refuses;
//! `stringBytes` writes the string table beside it.

const std = @import("std");
const facts = @import("../facts.zig");
const format = @import("format.zig");
const tables = @import("tables.zig");
const codec = @import("codec.zig");
const model = @import("model.zig");
const strings = @import("strings.zig");
const templates = @import("template.zig");
const Story = @import("reader.zig").Story;

const Range = format.Range;
const Term = format.Term;
const FactId = facts.FactId;
const ScopeId = facts.ScopeId;

pub const Error = error{
    OutOfMemory,
    TooLarge,
    TooManyFacts,
    TooManyScopes,
    TooManyItems,
    TooManyChoices,
    TooManySlots,
    TooManyCast,
    NameTooLong,
    EmptyName,
    DuplicateFact,
    DuplicateItem,
    DuplicateLineId,
    DuplicateBlock,
    TooManyParams,
    LineIdZero,
    /// A scope named `story` declared by the story, or a story fact put in it.
    ReservedScope,
    /// A reserved step never defined, or a scene never entered.
    UndefinedNode,
    CandidatesNotContiguous,
    NotAPool,
    BadTemplate,
} || tables.Error;

pub const TagIn = struct { key: []const u8, values: []const model.TagValue = &.{} };

pub const SectionIn = struct {
    name: []const u8,
    kind: model.Section.Kind = .scene,
    pick: u16 = 1,
    kind_name: []const u8 = "",
    tags: Range = .empty,
    visits: FactId,
};

pub const CandidateIn = struct {
    name: []const u8,
    when: Range = .empty,
    tags: Range = .empty,
    entry: model.NodeId,
    visits: FactId,
    seen: FactId,
};

pub const Builder = struct {
    gpa: std.mem.Allocator,
    /// Copies of names and lines, alive as long as the builder.
    arena: std.heap.ArenaAllocator,
    interned: std.StringHashMapUnmanaged(format.Str) = .empty,
    fact_names: std.StringHashMapUnmanaged(void) = .empty,
    names: std.ArrayList(u8) = .empty,
    scopes: std.ArrayList(format.Str) = .empty,
    enums: std.ArrayList(Range) = .empty,
    items: std.ArrayList(format.Str) = .empty,
    facts: std.ArrayList(format.Fact) = .empty,
    cast: std.ArrayList(format.Cast) = .empty,
    externs: std.ArrayList(format.Extern) = .empty,
    params: std.ArrayList(format.Param) = .empty,
    literals: std.ArrayList(format.Str) = .empty,
    ints: std.ArrayList(i64) = .empty,
    terms: std.ArrayList(u32) = .empty,
    sections: std.ArrayList(format.Section) = .empty,
    candidates: std.ArrayList(format.Candidate) = .empty,
    nodes: std.ArrayList(format.Node) = .empty,
    defined: std.ArrayList(bool) = .empty,
    choices: std.ArrayList(format.Choice) = .empty,
    texts: std.ArrayList(format.Text) = .empty,
    slots: std.ArrayList(format.Slot) = .empty,
    effects: std.ArrayList(format.Effect) = .empty,
    tags: std.ArrayList(format.Tag) = .empty,
    tag_values: std.ArrayList(format.TagValue) = .empty,
    kinds: std.ArrayList(format.Str) = .empty,
    things: std.ArrayList(format.Thing) = .empty,
    builtins: std.ArrayList(format.BuiltinCall) = .empty,
    builtin_args: std.ArrayList(u32) = .empty,
    blocks: std.ArrayList(format.Block) = .empty,
    block_bytes: std.ArrayList(u8) = .empty,
    lines: std.ArrayList(strings.Line) = .empty,
    reserved: ScopeId = .fromRaw(0),
    seed: FactId = .fromRaw(0),
    turn: FactId = .fromRaw(0),

    /// A builder with the reserved scope and the executor's seed and turn declared.
    pub fn init(gpa: std.mem.Allocator) Error!Builder {
        var b: Builder = .{ .gpa = gpa, .arena = .init(gpa) };
        errdefer b.deinit();
        try b.scopes.append(gpa, try b.intern(facts.reserved_scope));
        b.seed = try b.state("seed");
        b.turn = try b.state("turn");
        return b;
    }

    pub fn deinit(b: *Builder) void {
        const gpa = b.gpa;
        b.interned.deinit(gpa);
        b.fact_names.deinit(gpa);
        inline for (.{ "names", "scopes", "enums", "items", "facts", "cast", "externs", "params", "literals", "ints", "terms", "sections", "candidates", "nodes", "defined", "choices", "texts", "slots", "effects", "tags", "tag_values", "kinds", "things", "builtins", "builtin_args", "blocks", "block_bytes", "lines" }) |field| {
            @field(b, field).deinit(gpa);
        }
        b.arena.deinit();
        b.* = undefined;
    }

    fn intern(b: *Builder, name: []const u8) Error!format.Str {
        if (b.interned.get(name)) |s| return s;
        if (b.names.items.len + name.len > format.max_bytes) return error.TooLarge;
        const s: format.Str = .{ .offset = @intCast(b.names.items.len), .len = @intCast(name.len) }; // safe: below max_bytes
        try b.names.appendSlice(b.gpa, name);
        try b.interned.put(b.gpa, try b.arena.allocator().dupe(u8, name), s);
        return s;
    }

    fn declName(b: *Builder, name: []const u8) Error!format.Str {
        if (name.len == 0) return error.EmptyName;
        if (name.len > facts.max_name) return error.NameTooLong;
        return b.intern(name);
    }

    // ------------------------------------------------------------ declarations

    /// The scope named `name`, declared if it is new.
    pub fn scope(b: *Builder, name: []const u8) Error!ScopeId {
        if (std.mem.eql(u8, name, facts.reserved_scope)) return error.ReservedScope;
        const s = try b.declName(name);
        for (b.scopes.items, 0..) |have, i| {
            if (have.offset == s.offset and have.len == s.len) return .fromRaw(@intCast(i)); // safe: below max_scopes
        }
        if (b.scopes.items.len == facts.max_scopes) return error.TooManyScopes;
        try b.scopes.append(b.gpa, s);
        return .fromRaw(@intCast(b.scopes.items.len - 1)); // safe: below max_scopes
    }

    /// The values of a `one of`, or the items of a `set of`.
    pub fn enumeration(b: *Builder, names: []const []const u8) Error!model.EnumId {
        if (names.len == 0) return error.EmptyName;
        if (names.len > facts.max_items) return error.TooManyItems;
        if (b.enums.items.len == format.none16 - 1) return error.TooManyItems;
        const start: u32 = @intCast(b.items.items.len); // safe: below max_bytes
        for (names, 0..) |n, i| {
            for (names[0..i]) |before| if (std.mem.eql(u8, before, n)) return error.DuplicateItem;
            try b.items.append(b.gpa, try b.declName(n));
        }
        try b.enums.append(b.gpa, .{ .start = start, .len = @intCast(names.len) }); // safe: below max_items
        return .fromRaw(@intCast(b.enums.items.len - 1)); // safe: checked above
    }

    /// The kind of the host's things named `name`, declared if it is new.
    pub fn refKind(b: *Builder, name: []const u8) Error!model.RefKindId {
        const s = try b.declName(name);
        for (b.kinds.items, 0..) |have, i| {
            if (have.offset == s.offset and have.len == s.len) return .fromRaw(@intCast(i)); // safe: below none16
        }
        if (b.kinds.items.len == format.none16 - 1) return error.TooLarge;
        try b.kinds.append(b.gpa, s);
        return .fromRaw(@intCast(b.kinds.items.len - 1)); // safe: checked above
    }

    /// One of the host's things, named by its text id, for `Term.of(.thing, i)`. The same thing twice is one.
    pub fn thing(b: *Builder, kind: model.RefKindId, id: []const u8) Error!u24 {
        const s = try b.declName(id);
        for (b.things.items, 0..) |t, i| {
            if (t.kind == kind.raw() and t.id.offset == s.offset and t.id.len == s.len) return arg(i);
        }
        try b.things.append(b.gpa, .{ .id = s, .kind = kind.raw() });
        return arg(b.things.items.len - 1);
    }

    pub fn fact(b: *Builder, d: model.FactDecl) Error!FactId {
        const in_reserved = d.scope.eql(b.reserved);
        if (in_reserved != (d.role == .visits or d.role == .state)) return error.ReservedScope;
        if ((d.kind == .one_of or d.kind == .set_of) != (d.enumeration != null)) return error.BadKind;
        if ((d.kind == .ref) != (d.ref_kind != null)) return error.BadKind;
        if (d.role == .clock and d.kind != .int) return error.BadKind;
        if (b.facts.items.len == facts.max_facts) return error.TooManyFacts;
        const name = try b.declName(d.name);
        const gop = try b.fact_names.getOrPut(b.gpa, d.name);
        if (gop.found_existing) return error.DuplicateFact;
        gop.key_ptr.* = try b.arena.allocator().dupe(u8, d.name);
        try b.facts.append(b.gpa, .{
            .name = name,
            .enumeration = codec.typeField(d.enumeration, d.ref_kind),
            .scope = d.scope.raw(),
            .kind = @backingInt(d.kind),
            .role = @backingInt(d.role),
        });
        return .fromRaw(@intCast(b.facts.items.len - 1)); // safe: below max_facts
    }

    /// The visit count of what `name` names (a section, a choice by its line id, a gather by its label):
    /// an int in the reserved scope, named `visits:<name>` so it is matched by name across versions.
    pub fn visits(b: *Builder, name: []const u8) Error!FactId {
        return b.reservedFact("visits:", name, .visits);
    }

    /// State of the executor's own: alternatives, pools' memory, the seed. `state:<name>` in the reserved scope.
    pub fn state(b: *Builder, name: []const u8) Error!FactId {
        return b.reservedFact("state:", name, .state);
    }

    fn reservedFact(b: *Builder, comptime prefix: []const u8, name: []const u8, role: facts.Role) Error!FactId {
        if (prefix.len + name.len > facts.max_name) return error.NameTooLong;
        var buf: [facts.max_name]u8 = undefined;
        const full = buf[0 .. prefix.len + name.len];
        @memcpy(full[0..prefix.len], prefix);
        @memcpy(full[prefix.len..], name);
        return b.fact(.{ .name = full, .scope = b.reserved, .kind = .int, .role = role });
    }

    pub fn castMember(b: *Builder, c: model.Cast) Error!model.CastId {
        if (b.cast.items.len == format.none16 - 1) return error.TooManyCast;
        if (c.extra != (c.name.len == 0)) return error.EmptyName;
        try b.cast.append(b.gpa, .{
            .display = c.display.raw(),
            .relation = if (c.relation) |r| r.raw() else 0,
            .name = if (c.extra) .empty else try b.declName(c.name),
            .tags = c.tags,
            .extra = @intFromBool(c.extra),
        });
        return .fromRaw(@intCast(b.cast.items.len - 1)); // safe: checked above
    }

    pub fn externFn(b: *Builder, name: []const u8, params: []const model.Param, returns: ?model.Param, action: bool) Error!facts.ExternId {
        if (b.externs.items.len == format.none16 - 1) return error.TooLarge;
        if (params.len > format.max_params) return error.TooManyParams;
        const start: u32 = @intCast(b.params.items.len); // safe: below max_bytes
        for (params) |p| try b.params.append(b.gpa, .{ .kind = @backingInt(p.kind), .enumeration = codec.typeField(p.enumeration, p.ref_kind) });
        try b.externs.append(b.gpa, .{
            .name = try b.declName(name),
            .params = .{ .start = start, .len = @intCast(params.len) }, // safe: below max_bytes
            .enumeration = if (returns) |r| codec.typeField(r.enumeration, r.ref_kind) else format.none16,
            .returns = if (returns) |r| @backingInt(r.kind) else format.no_kind,
            .action = @intFromBool(action),
            .stamp = .empty,
            .keys = 0,
        });
        return .fromRaw(@intCast(b.externs.items.len - 1)); // safe: checked above
    }

    /// The stamp of what the query `x` reads, keyed by the parameters whose bits are set in `keys`.
    pub fn stamp(b: *Builder, x: facts.ExternId, family: []const u8, keys: u32) Error!void {
        const e = &b.externs.items[x.raw()];
        e.stamp = try b.declName(family);
        e.keys = keys;
    }

    /// A call of a registered kind's builtin, for `Term.of(.builtin, i)`.
    pub fn builtinCall(b: *Builder, kind: []const u8, name: []const u8, args: []const u32, returns: facts.Kind) Error!u24 {
        const start = try count(b.builtin_args.items.len);
        try b.builtin_args.appendSlice(b.gpa, args);
        try b.builtins.append(b.gpa, .{
            .kind = try b.declName(kind),
            .name = try b.declName(name),
            .args = .{ .start = start, .len = try count(args.len) },
            .returns = @backingInt(returns),
        });
        return arg(b.builtins.items.len - 1);
    }

    /// A block a package owns, carried beside the graph. One name, one block.
    pub fn block(b: *Builder, name: []const u8, version: u32, data: []const u8) Error!void {
        const n = try b.declName(name);
        for (b.blocks.items) |have| if (have.name.offset == n.offset and have.name.len == n.len) return error.DuplicateBlock;
        if (b.block_bytes.items.len + data.len > format.max_bytes) return error.TooLarge;
        const start = try count(b.block_bytes.items.len);
        try b.block_bytes.appendSlice(b.gpa, data);
        try b.blocks.append(b.gpa, .{ .name = n, .version = version, .bytes = .{ .start = start, .len = try count(data.len) } });
    }

    /// A line's words for the string table, keyed by the hash of its `# id` text.
    pub fn line(b: *Builder, id_text: []const u8, template: []const u8) Error!model.LineId {
        templates.validate(template, null) catch return error.BadTemplate;
        const id = try strings.lineId(id_text);
        for (b.lines.items) |l| if (l.id.eql(id)) return error.DuplicateLineId;
        const a = b.arena.allocator();
        try b.lines.append(b.gpa, .{ .id = id, .id_text = try a.dupe(u8, id_text), .template = try a.dupe(u8, template) });
        return id;
    }

    pub fn tagList(b: *Builder, list: []const TagIn) Error!Range {
        const start = try count(b.tags.items.len);
        for (list) |t| {
            const vstart = try count(b.tag_values.items.len);
            for (t.values) |v| try b.tag_values.append(b.gpa, .{ .text = try b.intern(v.text), .section = codec.raw32(v.section) });
            try b.tags.append(b.gpa, .{ .key = try b.declName(t.key), .values = .{ .start = vstart, .len = try count(t.values.len) } });
        }
        return .{ .start = start, .len = try count(list.len) };
    }

    // ------------------------------------------------------------ terms

    /// A text literal, for `Term.of(.text, i)`.
    pub fn literal(b: *Builder, words: []const u8) Error!u24 {
        try b.literals.append(b.gpa, try b.intern(words));
        return arg(b.literals.items.len - 1);
    }

    /// An integer, for `Term.of(.int, i)`.
    pub fn int(b: *Builder, v: i64) Error!u24 {
        try b.ints.append(b.gpa, v);
        return arg(b.ints.items.len - 1);
    }

    /// A condition or a value, in postfix.
    pub fn expr(b: *Builder, terms: []const Term) Error!Range {
        const start = try count(b.terms.items.len);
        for (terms) |t| try b.terms.append(b.gpa, @bitCast(t));
        return .{ .start = start, .len = try count(terms.len) };
    }

    pub fn text(b: *Builder, line_id: model.LineId, list: []const model.Slot) Error!model.TextId {
        if (list.len > format.max_slots) return error.TooManySlots;
        const start = try count(b.slots.items.len);
        for (list) |s| try b.slots.append(b.gpa, .{ .expr = s.expr, .state = codec.raw16(s.state), .kind = @backingInt(s.kind), .arity = s.arity });
        try b.texts.append(b.gpa, .{ .line = line_id.raw(), .slots = .{ .start = start, .len = @intCast(list.len) } }); // safe: below max_slots
        return .fromRaw(try count(b.texts.items.len - 1));
    }

    // ------------------------------------------------------------ the graph

    pub fn section(b: *Builder, s: SectionIn) Error!model.SectionId {
        try b.sections.append(b.gpa, .{
            .name = try b.declName(s.name),
            .kind_name = try b.intern(s.kind_name),
            .tags = s.tags,
            .candidates = .{ .start = try count(b.candidates.items.len), .len = 0 },
            .entry = format.none,
            .pick = s.pick,
            .visits = s.visits.raw(),
            .kind = @backingInt(s.kind),
        });
        return .fromRaw(try count(b.sections.items.len - 1));
    }

    /// Where the section begins.
    pub fn enter(b: *Builder, s: model.SectionId, n: model.NodeId) void {
        b.sections.items[s.raw()].entry = n.raw();
    }

    /// A pool's candidate. A pool's candidates are added one after another, with no other pool's between.
    pub fn candidate(b: *Builder, pool: model.SectionId, c: CandidateIn) Error!void {
        const s = &b.sections.items[pool.raw()];
        if (s.kind != @backingInt(model.Section.Kind.pool)) return error.NotAPool;
        if (s.candidates.len == 0) s.candidates.start = try count(b.candidates.items.len);
        if (s.candidates.end() != b.candidates.items.len) return error.CandidatesNotContiguous;
        if (c.when.end() > b.terms.items.len) return error.OutOfRange;
        const when: []const u32 = b.terms.items[c.when.start..][0..c.when.len];
        try b.candidates.append(b.gpa, .{
            .name = try b.declName(c.name),
            .when = c.when,
            .tags = c.tags,
            .entry = c.entry.raw(),
            .specificity = b.specificity(when),
            .visits = c.visits.raw(),
            .seen = c.seen.raw(),
        });
        s.candidates.len += 1;
    }

    // How many criteria a condition holds: each comparison, fact or query one;
    // `and` adds, `or` takes the lesser, so the most specific match wins.
    fn specificity(b: *const Builder, when: []const u32) u16 {
        var stack: [format.max_stack]u16 = undefined;
        var n: usize = 0;
        // A malformed condition counts nothing here: the reader refuses it when the story is written.
        for (when) |word| {
            const t: Term = @bitCast(word);
            const pops: usize = switch (t.op) {
                .fact, .int, .item, .text, .true, .false, .thing => 0,
                .not => 1,
                .eq, .ne, .lt, .le, .gt, .ge, .has, .hasnt, .@"and", .@"or" => 2,
                .query => if (t.arg < b.externs.items.len) b.externs.items[t.arg].params.len else return 0,
                .builtin => 0,
            };
            if (n < pops or n - pops == stack.len) return 0;
            const top = n - pops;
            stack[top] = switch (t.op) {
                .fact => 1,
                .int, .item, .text, .true, .false, .thing => 0,
                .not => stack[top],
                .eq, .ne, .lt, .le, .gt, .ge, .has, .hasnt, .query, .builtin => 1,
                .@"and" => stack[top] +| stack[top + 1],
                .@"or" => @min(stack[top], stack[top + 1]),
            };
            n = top + 1;
        }
        return if (n == 1) stack[0] else 0;
    }

    /// A step to define later, for an edge that points forward.
    pub fn reserve(b: *Builder) Error!model.NodeId {
        try b.nodes.append(b.gpa, codec.encodeNode(.{ .step = .end }));
        try b.defined.append(b.gpa, false);
        return .fromRaw(try count(b.nodes.items.len - 1));
    }

    pub fn define(b: *Builder, id: model.NodeId, n: model.Node) void {
        std.debug.assert(!b.defined.items[id.raw()]);
        b.nodes.items[id.raw()] = codec.encodeNode(n);
        b.defined.items[id.raw()] = true;
    }

    pub fn node(b: *Builder, n: model.Node) Error!model.NodeId {
        const id = try b.reserve();
        b.define(id, n);
        return id;
    }

    /// Choices offered together, for a `choices` step.
    pub fn choiceList(b: *Builder, list: []const model.Choice) Error!Range {
        if (list.len == 0) return error.BadNode;
        if (list.len > format.max_choices) return error.TooManyChoices;
        const start = try count(b.choices.items.len);
        for (list) |c| try b.choices.append(b.gpa, .{
            .cond = c.cond,
            .tags = c.tags,
            .text = c.text.raw(),
            .target = c.target.raw(),
            .visits = c.visits.raw(),
            .sticky = @intFromBool(c.sticky),
        });
        return .{ .start = start, .len = @intCast(list.len) }; // safe: below max_choices
    }

    pub fn effectList(b: *Builder, list: []const model.Effect) Error!Range {
        const start = try count(b.effects.items.len);
        for (list) |e| try b.effects.append(b.gpa, codec.encodeEffect(e));
        return .{ .start = start, .len = try count(list.len) };
    }

    // ------------------------------------------------------------ writing

    /// The compiled graph, read back and validated before it is returned. The caller owns the bytes.
    pub fn bytes(b: *const Builder, gpa: std.mem.Allocator) Error![]u8 {
        for (b.defined.items) |d| if (!d) return error.UndefinedNode;
        for (b.sections.items) |s| {
            if (s.kind != @backingInt(model.Section.Kind.pool) and s.entry == format.none) return error.UndefinedNode;
        }
        const meta = [_]format.Meta{.{ .seed = b.seed.raw(), .turn = b.turn.raw(), .reserved_scope = b.reserved.raw() }};
        var parts: [format.table_count]tables.Part = undefined;
        inline for (@typeInfo(format.Table).@"enum".field_names, 0..) |field, i| {
            const R = format.Record(@field(format.Table, field));
            parts[i] = if (comptime std.mem.eql(u8, field, "meta")) tables.part(R, &meta) else tables.part(R, @field(b, field).items);
        }
        const out = try tables.assemble(gpa, format.magic, &parts);
        errdefer gpa.free(out);
        _ = try Story.init(out, .{});
        return out;
    }

    /// The string table of every line added, for the story whose hash is `story_hash`.
    pub fn stringBytes(b: *const Builder, gpa: std.mem.Allocator, locale: []const u8, story_hash: u64) Error![]u8 {
        return strings.write(gpa, b.lines.items, locale, story_hash);
    }
};

fn count(n: usize) Error!u32 {
    return std.math.cast(u32, n) orelse error.TooLarge;
}

fn arg(n: usize) Error!u24 {
    return std.math.cast(u24, n) orelse error.TooLarge;
}
