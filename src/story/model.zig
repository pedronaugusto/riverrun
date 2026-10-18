//! The compiled story as the executor and the tools see it: sections as
//! nodes of a graph, steps joined by edges, conditions and effects as terms.
//! The builder takes these, the reader gives them back, and they are the
//! same values: what is written is what is read.

const aegis = @import("aegis");
const facts = @import("../facts.zig");
const format = @import("format.zig");

pub const FactId = facts.FactId;
pub const ScopeId = facts.ScopeId;
pub const ExternId = facts.ExternId;
pub const Range = format.Range;
pub const Term = format.Term;
pub const SlotKind = format.SlotKind;

pub const SectionId = aegis.id.Id(enum { section }, u32);
pub const NodeId = aegis.id.Id(enum { node }, u32);
pub const TextId = aegis.id.Id(enum { text }, u32);
pub const CastId = aegis.id.Id(enum { cast }, u16);
pub const EnumId = aegis.id.Id(enum { enumeration }, u16);
/// A kind of the host's things, by its place in the story's kinds.
pub const RefKindId = aegis.id.Id(enum { ref_kind }, u16);
/// A line, by the 64-bit XxHash (seed 0) of its `# id` text: what a translation and a voice key on.
pub const LineId = aegis.id.NonZero(enum { line }, u64);

pub const FactDecl = struct {
    name: []const u8,
    scope: ScopeId,
    kind: facts.Kind,
    enumeration: ?EnumId = null,
    /// For a `ref`: the kind of the host's things it holds.
    ref_kind: ?RefKindId = null,
    role: facts.Role = .story,
    /// For a fact kept per thing: what keys it.
    key: Key = .none,
    /// For a bounded int: the least and the most it holds.
    bounds: ?facts.Bounds = null,

    pub const Key = union(enum) { none, items: EnumId, ref: RefKindId };
};

pub const Cast = struct {
    /// Empty for an extra.
    name: []const u8,
    display: LineId,
    relation: ?LineId = null,
    tags: Range = .empty,
    extra: bool = false,
};

pub const Param = struct {
    kind: facts.Kind,
    enumeration: ?EnumId = null,
    ref_kind: ?RefKindId = null,
};

/// One of the host's things a story names.
pub const Thing = struct { kind: []const u8, id: []const u8 };

pub const Extern = struct {
    name: []const u8,
    params: Range,
    returns: ?Param,
    /// An action is performed by the host when the story reaches it, and may
    /// return an outcome the host writes into a fact; a query is pure, asked at any time.
    action: bool,
    /// For a query: the stamp the host bumps when what it reads changes, keyed by some of its parameters.
    stamp: ?Stamp = null,
};

pub const Stamp = struct {
    family: []const u8,
    /// Bit `i` for parameter `i`.
    keys: u32 = 0,
};

/// A call of a builtin a registered kind adds: its package evaluates it.
pub const BuiltinCall = struct {
    kind: []const u8,
    name: []const u8,
    /// What each argument names, in `builtin_args`.
    args: Range,
    returns: facts.Kind,
    /// The `(clock)` its int answer moves with, one for one, while it moves at all (`since` over a clock), so what
    /// watches it can wait for the number it is compared with in the clock's heap.
    clock: ?FactId = null,
};

/// What `since_changed(fact, clock)` reads, and the state that keeps the clock's value at the fact's last change.
pub const Change = struct { fact: FactId, clock: FactId, at: FactId };

/// A block a package owns, as it wrote it.
pub const Block = struct { version: u32, bytes: []const u8 };

pub const Section = struct {
    name: []const u8,
    kind: Kind = .scene,
    /// How many candidates a pool gives at once.
    pick: u16 = 1,
    /// The kind a host registered, for `other`.
    kind_name: []const u8 = "",
    tags: Range = .empty,
    /// The first node; null for a pool with only candidates, or a section declared and not yet entered.
    entry: ?NodeId = null,
    candidates: Range = .empty,
    /// Its visit count; null for a registered kind's section or part whose visits nothing reads.
    visits: ?FactId,

    pub const Kind = format.SectionKind;
};

pub const Candidate = struct {
    name: []const u8,
    /// Empty matches always.
    when: Range = .empty,
    specificity: u16 = 0,
    tags: Range = .empty,
    entry: NodeId,
    visits: FactId,
    /// The turn it was last given, for least recently seen first.
    seen: FactId,
    /// Its weight in a draw, where its pool draws by weight; 0 for none given.
    weight: u16 = 0,
    /// For a rule that migrates a save, the version it migrates to; 0 for an ordinary rule.
    migrate: u16 = 0,
};

pub const Node = struct {
    tags: Range = .empty,
    step: Step,

    /// Where the flow goes after a step; null ends the flow.
    pub const Next = ?NodeId;

    pub const Step = union(format.NodeKind) {
        /// A line delivered: its effects happen only if it is.
        line: struct { text: TextId, speaker: ?CastId = null, effects: Range = .empty, next: Next = null },
        /// Choices offered together; `next` is where the flow goes when none is open.
        choices: struct { choices: Range, next: Next = null },
        branch: struct { cond: Range, then: Next, otherwise: Next },
        /// Where branches meet; a labelled one counts its visits.
        gather: struct { visits: ?FactId = null, next: Next = null },
        effects: struct { effects: Range, next: Next = null },
        jump: SectionId,
        /// `->>`: run the section, then come back to `next`.
        call: struct { section: SectionId, next: Next = null },
        ret,
        end,
    };
};

pub const Choice = struct {
    text: TextId,
    /// Empty is always open. A closed choice is still offered, marked closed.
    cond: Range = .empty,
    sticky: bool = false,
    /// How often it was taken: a once-only choice is gone after one.
    visits: FactId,
    tags: Range = .empty,
    target: NodeId,
};

pub const Text = struct {
    line: LineId,
    slots: Range = .empty,
};

pub const Slot = struct {
    kind: SlotKind,
    /// The value, or a `choose`'s condition.
    expr: Range = .empty,
    /// Branches: 2 for a `choose`, the alternatives' count, 0 for a value.
    arity: u8 = 0,
    /// Alternatives' state, in the reserved scope.
    state: ?FactId = null,
};

pub const Effect = union(format.EffectKind) {
    set: struct { fact: FactId, value: Range },
    add: Item,
    remove: Item,
    call: struct { action: ExternId, args: Range, result: ?FactId = null },
    /// `~ int += n`, `~ int -= n`: the int moves by the value of `by`, a number (negative for `-=`).
    change: struct { fact: FactId, by: Range },

    /// `key`: for a fact kept per thing, the terms of its key; empty for a fact with one value. A `set`'s and a
    /// `change`'s terms leave the key first, then the value.
    pub const Item = struct { fact: FactId, item: u8, key: Range = .empty };
};

pub const Tag = struct {
    key: []const u8,
    values: Range,
};

pub const TagValue = struct {
    text: []const u8,
    /// The section the value names, where the host's tag schema says so.
    section: ?SectionId = null,
    /// The value's line in the string table, where the host's tag schema types it as words a player reads.
    line: ?LineId = null,
};
