//! The compiled story's layout: the records of every table, as they lie in
//! the file. `docs/format.md` is the specification; this file is its Zig.
//!
//! A story is a header, a directory with an entry per table, and the tables:
//! arrays of fixed-size little-endian records. Names are spans of one byte
//! table; lists are ranges of another table. Nothing in a record is a
//! pointer, so the reader views the bytes as they are.

const std = @import("std");

pub const magic = "RIVERRUN".*;
/// A reader refuses another major version; a newer minor adds tables at the
/// end of the directory or fields at the end of a record, which an older
/// reader skips by the stride the directory gives.
pub const major: u16 = 1;
pub const minor: u16 = 0;

/// The largest story a reader accepts.
pub const max_bytes = 64 * 1024 * 1024;
/// The most choices offered at one point.
pub const max_choices = 32;
/// The most slots in one text, and branches of one alternative.
pub const max_slots = 32;
/// The deepest stack a condition or a list of arguments reaches.
pub const max_stack = 64;
/// The most nested calls (`->>`) a cursor holds: the executor's bound.
pub const max_call_depth = 64;

/// An absent index.
pub const none: u32 = std.math.maxInt(u32);
/// An absent fact, cast member, enumeration or extern.
pub const none16: u16 = std.math.maxInt(u16);
/// An extern that returns nothing.
pub const no_kind: u8 = std.math.maxInt(u8);

pub const Header = extern struct {
    magic: [8]u8,
    major: u16,
    minor: u16,
    flags: u32,
    /// XxHash64, seed 0, of the whole file with this field zero.
    hash: u64,
    /// The file's length in bytes.
    length: u32,
    /// Entries in the directory that follows.
    tables: u32,
};

pub const Dir = extern struct {
    offset: u32,
    count: u32,
    /// Bytes per record: at least the record's size here.
    stride: u32,
    reserved: u32,
};

pub const Table = enum(u32) {
    meta,
    names,
    scopes,
    enums,
    items,
    facts,
    cast,
    externs,
    params,
    literals,
    ints,
    terms,
    sections,
    candidates,
    nodes,
    choices,
    texts,
    slots,
    effects,
    tags,
    tag_values,
    /// The kinds of the host's things a story's refs hold: `person`, `item_kind`.
    kinds,
    /// The host's things a story names by their text ids, each of a kind.
    things,
    /// Calls of the builtins a registered kind of section adds, which its package evaluates.
    builtins,
    /// Their arguments: what each names, by its index in the story.
    builtin_args,
    /// Named, versioned blocks a package owns (`cairn`), beside the graph, which its own reader validates.
    blocks,
    block_bytes,
    /// What `since_changed(fact, clock)` reads: a fact, a clock, and the state that keeps the clock's value at the
    /// fact's last change, which the rules evaluator writes.
    changes,
};

pub const table_count = @typeInfo(Table).@"enum".field_names.len;

/// A span of the `names` table.
pub const Str = extern struct {
    offset: u32,
    len: u32,

    pub const empty: Str = .{ .offset = 0, .len = 0 };
};

/// A run of records of another table.
pub const Range = extern struct {
    start: u32,
    len: u32,

    pub const empty: Range = .{ .start = 0, .len = 0 };

    pub fn end(r: Range) u64 {
        return @as(u64, r.start) + r.len;
    }
};

pub const Meta = extern struct {
    /// The executor's seed for shuffles and pools: an int fact of the reserved scope.
    seed: u16,
    /// The executor's turn counter, which pools' memory is stamped with.
    turn: u16,
    /// The reserved scope, `story`.
    reserved_scope: u8,
    pad: [3]u8 = @splat(0),
};

pub const Fact = extern struct {
    name: Str,
    /// For a `one of` or a `set of`, its enumeration; for a `ref`, its kind; `none16` otherwise.
    enumeration: u16,
    scope: u8,
    kind: u8,
    role: u8,
    pad: [3]u8 = @splat(0),
};

pub const Cast = extern struct {
    /// The line id of how the speaker is shown, in the string table.
    display: u64,
    /// The line id of who they are, or 0.
    relation: u64,
    /// Empty for an extra.
    name: Str,
    tags: Range,
    extra: u8,
    pad: [7]u8 = @splat(0),
};

pub const Extern = extern struct {
    name: Str,
    params: Range,
    /// The family of the stamp the host bumps when what a query reads changes; empty for none.
    stamp: Str,
    /// Of the return: its enumeration, or a ref's kind.
    enumeration: u16,
    /// The kind it returns, or `no_kind`.
    returns: u8,
    /// 1 for an action, performed by the host when reached; 0 for a query, pure and asked at any time.
    action: u8,
    /// Which parameters key the stamp: bit `i` for parameter `i`.
    keys: u32,
};

/// The most parameters an extern takes: a stamp keys them by a 32-bit mask.
pub const max_params = 32;

pub const Param = extern struct {
    enumeration: u16,
    kind: u8,
    pad: u8 = 0,
};

pub const SectionKind = enum(u8) { scene = 0, pool = 1, other = 2, rules = 3 };

pub const Section = extern struct {
    name: Str,
    /// The kind a host registered, for `other`.
    kind_name: Str,
    tags: Range,
    candidates: Range,
    /// The first node, or `none` for a pool with only candidates.
    entry: u32,
    /// How many candidates a pool gives at once.
    pick: u16,
    visits: u16,
    kind: u8,
    pad: [3]u8 = @splat(0),
};

pub const Candidate = extern struct {
    name: Str,
    /// Terms of the condition; empty matches always.
    when: Range,
    tags: Range,
    entry: u32,
    /// How many criteria the condition holds: the most specific match wins.
    specificity: u16,
    visits: u16,
    /// The turn the candidate was last given: an int fact of the reserved scope.
    seen: u16,
    pad: u16 = 0,
};

pub const NodeKind = enum(u8) {
    line = 0,
    choices = 1,
    branch = 2,
    gather = 3,
    effects = 4,
    jump = 5,
    call = 6,
    ret = 7,
    end = 8,
};

/// One step of a section. What `a` to `d` hold depends on the kind; `docs/format.md` lists them.
pub const Node = extern struct {
    tags: Range,
    a: u32,
    b: u32,
    c: u32,
    d: u32,
    next: u32,
    speaker: u16,
    kind: u8,
    pad: u8 = 0,
};

pub const Choice = extern struct {
    /// Terms of the condition; empty is always open.
    cond: Range,
    tags: Range,
    text: u32,
    target: u32,
    visits: u16,
    sticky: u8,
    pad: u8 = 0,
};

pub const Text = extern struct {
    /// The line id its template is found by in the string table.
    line: u64,
    slots: Range,
};

pub const SlotKind = enum(u8) {
    /// `{fact}`: a value written into the text.
    value = 0,
    /// `{ condition: a | b }`
    choose = 1,
    /// Alternatives: in order, stopping at the last.
    sequence = 2,
    /// Alternatives: in order, round again.
    cycle = 3,
    /// Alternatives: in order, then nothing.
    once = 4,
    /// Alternatives: in an order the seed shuffles.
    shuffle = 5,
};

pub const Slot = extern struct {
    /// The value, or the condition of a `choose`; empty for alternatives.
    expr: Range,
    /// Alternatives' state: an int fact of the reserved scope.
    state: u16,
    kind: u8,
    /// Branches: 2 for a `choose`, the alternatives' count, 0 for a value.
    arity: u8,
};

pub const EffectKind = enum(u8) { set = 0, add = 1, remove = 2, call = 3, change = 4 };

pub const Effect = extern struct {
    /// The value of a `set`, the amount of a `change`, or the arguments of a `call`.
    expr: Range,
    fact: u16,
    item: u16,
    action: u16,
    /// A check with an outcome: where the host writes the action's result.
    result: u16,
    kind: u8,
    pad: [3]u8 = @splat(0),
};

pub const Tag = extern struct {
    key: Str,
    values: Range,
};

pub const TagValue = extern struct {
    text: Str,
    /// The section the value names, where the host's schema types it so.
    section: u32,
};

pub const BuiltinCall = extern struct {
    /// The registered kind of section that adds it: `quest`.
    kind: Str,
    name: Str,
    /// What each argument names, in `builtin_args`: a section, a part (its section's index << 16 | the part), or a fact.
    args: Range,
    /// The kind it pushes: boolean or int.
    returns: u8,
    pad: [3]u8 = @splat(0),
};

pub const Block = extern struct {
    name: Str,
    version: u32,
    pad: u32 = 0,
    /// Its bytes, in `block_bytes`.
    bytes: Range,
};

/// What `since_changed(fact, clock)` reads.
pub const Change = extern struct {
    fact: u16,
    /// A `(clock)` fact.
    clock: u16,
    /// An int of the reserved scope: the clock's value when `fact` last changed.
    at: u16,
    pad: u16 = 0,
};

/// One of the host's things a story names: its kind and its text id, resolved to a handle at load.
pub const Thing = extern struct {
    id: Str,
    kind: u16,
    pad: u16 = 0,
};

/// The record type of each table.
pub fn Record(comptime t: Table) type {
    return switch (t) {
        .meta => Meta,
        .names => u8,
        .scopes, .items, .literals => Str,
        .enums => Range,
        .facts => Fact,
        .cast => Cast,
        .externs => Extern,
        .params => Param,
        .ints => i64,
        .terms => u32,
        .sections => Section,
        .candidates => Candidate,
        .nodes => Node,
        .choices => Choice,
        .texts => Text,
        .slots => Slot,
        .effects => Effect,
        .tags => Tag,
        .tag_values => TagValue,
        .kinds => Str,
        .things => Thing,
        .builtins => BuiltinCall,
        .builtin_args => u32,
        .blocks => Block,
        .block_bytes => u8,
        .changes => Change,
    };
}

/// Where table data begins: the header, then the directory.
pub const tables_offset = @sizeOf(Header) + table_count * @sizeOf(Dir);

/// Tables start at a multiple of this, so a reader on any host can view them in place.
pub const alignment = 8;

// ---------------------------------------------------------------- terms

/// One term of a condition or a value, in postfix: a tight loop evaluates
/// them on a small stack. There are no jumps: a term can only push or combine.
pub const Term = packed struct(u32) {
    op: Op,
    arg: u24,

    pub const Op = enum(u8) {
        /// Push a fact's value: `arg` is its id.
        fact = 0,
        /// Push an integer: `arg` indexes `ints`.
        int = 1,
        /// Push a value of an enumeration: `arg` is the enumeration << 8 | the item.
        item = 2,
        /// Push a text: `arg` indexes `literals`.
        text = 3,
        true = 4,
        false = 5,
        eq = 6,
        ne = 7,
        /// A set holds an item.
        has = 8,
        hasnt = 9,
        @"and" = 10,
        @"or" = 11,
        not = 12,
        /// Call a query with its arguments off the stack: `arg` is its extern id.
        query = 13,
        /// Ints compared.
        lt = 14,
        le = 15,
        gt = 16,
        ge = 17,
        /// Push one of the host's things, by its handle: `arg` indexes `things`.
        thing = 18,
        /// Push a builtin's answer, which its package gives: `arg` indexes `builtins`.
        builtin = 19,
        /// Push how far a clock has moved since a fact last changed: `arg` indexes `changes`.
        since_changed = 20,
        /// Push whether a moment happened: holds something other than its initial value. `arg` is its fact id.
        happened = 21,
    };

    pub fn of(op: Op, arg: u24) Term {
        return .{ .op = op, .arg = arg };
    }

    pub fn item(enumeration: u16, index: u8) Term {
        return .{ .op = .item, .arg = @as(u24, enumeration) << 8 | index };
    }

    pub fn itemEnum(t: Term) u16 {
        return @intCast(t.arg >> 8); // safe: an item's arg holds a u16 above its low byte
    }

    pub fn itemIndex(t: Term) u8 {
        return @truncate(t.arg); // safe: the low byte is the item
    }
};

comptime {
    // The sizes docs/format.md gives.
    const sizes = .{ .{ Header, 32 }, .{ Dir, 16 }, .{ Meta, 8 }, .{ Fact, 16 }, .{ Cast, 40 }, .{ Extern, 32 }, .{ Param, 4 }, .{ Section, 44 }, .{ Candidate, 36 }, .{ Node, 32 }, .{ Choice, 28 }, .{ Text, 16 }, .{ Slot, 12 }, .{ Effect, 20 }, .{ Tag, 16 }, .{ TagValue, 12 }, .{ Thing, 12 }, .{ BuiltinCall, 28 }, .{ Block, 24 }, .{ Change, 8 } };
    for (sizes) |s| if (@sizeOf(s[0]) != s[1]) @compileError("a record's size is not the specification's");
    for (@typeInfo(Table).@"enum".field_names) |field| {
        const R = Record(@field(Table, field));
        if (@sizeOf(R) % @alignOf(R) != 0) @compileError("a record's size is a multiple of its alignment");
    }
}
