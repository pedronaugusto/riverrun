//! The syntax tree: a story's files as the reader understood them, before
//! any name is resolved. Every node keeps its span, so the checker and the
//! tools can point back at the text. The reader allocates all of it in one
//! arena the caller owns.

const Span = @import("source.zig").Span;

/// One file: its declarations and its sections, in the order written.
pub const File = struct {
    path: []const u8,
    /// `module name` at the top: what the file declares is `name.x` to other modules. Null is the root module.
    module: ?Name = null,
    decls: []const Decl,
    sections: []const Section,
};

// ---------------------------------------------------------------- declarations

pub const Decl = union(enum) {
    /// `version: 3`: which version of the story this is, which migration rules count from.
    version: struct { number: u32, span: Span },
    cast: []const CastEntry,
    extras: []const Name,
    facts: Facts,
    consts: []const Const,
    externs: []const Extern,
};

pub const Name = struct { text: []const u8, span: Span };

pub const CastEntry = struct {
    id: Name,
    /// How the character is shown: "Mum".
    display: []const u8,
    /// Who they are, for the people screen: "Frank, her father".
    relation: ?[]const u8,
    tags: []const Tag,
};

pub const Facts = struct {
    /// The scope the host names: `life`, `player`, `world`… Null is the story's default scope.
    scope: ?Name,
    entries: []const Fact,
};

pub const Fact = struct {
    name: Name,
    /// `opinion(person): int`: a value for each of the things of a kind, or each value of an enumeration.
    key: ?Type = null,
    type: Type,
    /// `int from -100 to 100`: the least and the most an int holds.
    bounds: ?Bounds = null,
    /// Written by the game's mechanics, never by the story.
    game: bool,
    /// `(clock)`: an int the game only advances, so a comparison with it can be woken by its value.
    clock: bool = false,
    /// `(moment)`: what happened, held only until what watches conditions has seen it, and never saved.
    moment: bool = false,
};

pub const Type = union(enum) {
    boolean,
    int,
    text,
    one_of: []const Name,
    set_of: []const Name,
    /// `ref of kind`: an opaque handle to one of the host's things, named in the story by stable text ids.
    ref: Name,
};

pub const Bounds = struct { min: i64, max: i64 };

pub const Const = struct { name: Name, value: Expr };

pub const Extern = struct {
    name: Name,
    params: []const Param,
    /// Null for an action; a type for a query, or for an action's outcome.
    returns: ?Type,
    /// `(action)` after a return type: an action whose outcome the host decides. Without it a return makes a query.
    action: bool = false,
    /// `(reads stock(kind))`: the stamp the host bumps when what the query reads changes, keyed by its parameters.
    reads: ?Stamp = null,
};

pub const Param = struct { name: ?Name, type: Type };

pub const Stamp = struct { family: Name, keys: []const Name };

// ---------------------------------------------------------------- sections

pub const Section = struct {
    name: Name,
    kind: Kind,
    tags: []const Tag,
    body: []const Stmt,
    /// `= name` inside it: the parts of a scene, or the candidates of a pool.
    subsections: []const Subsection,

    pub const Kind = union(enum) {
        scene,
        /// Candidates chosen by specificity; `n` of them at once.
        pool: u16,
        /// Rules, each `= name when { condition }` with effects under it: what fires when a condition becomes true.
        rules,
        /// Any other kind a host registers with the compiler: `(quest)`.
        other: Name,
    };
};

pub const Subsection = struct {
    name: Name,
    /// A pool candidate's condition.
    when: ?Expr,
    tags: []const Tag,
    body: []const Stmt,
};

/// A tag: `# key value, value · key value`. riverrun carries it and never reads it.
pub const Tag = struct {
    key: Name,
    values: []const []const u8,
};

pub const Stmt = struct {
    span: Span,
    tags: []const Tag,
    kind: union(enum) {
        line: Line,
        /// `{ condition }` with the statements it gates.
        cond: Cond,
        /// `* text` (once) or `+ text` (sticky), with what follows it.
        choice: Choice,
        /// `-` joins branches; it may carry a label and a statement.
        gather: Gather,
        effect: Effect,
        flow: Flow,
        /// `{ condition: -> a | -> b }`: a flow chosen by a condition.
        flow_if: FlowIf,
    },
};

pub const Line = struct {
    /// Null for narration.
    speaker: ?Name,
    text: Text,
    /// Effects indented under the line: they happen when the line is delivered, so a host
    /// that does not deliver it (a line Iris does not overhear) does not apply them.
    effects: []const Stmt,
};

/// Text: literal runs, interpolated facts, and words chosen by a condition.
pub const Text = []const Piece;

pub const Piece = union(enum) {
    literal: []const u8,
    /// `{fact}`
    value: Expr,
    /// `{ condition: these words | those words }`
    choose: struct { cond: Expr, then: Text, otherwise: Text },
    /// `{seq: a | b | c}`, `{cycle: …}`, `{once: …}`, `{shuffle: …}`
    alternatives: struct { kind: Alternatives, options: []const Text },
    /// `{count -> one: pelt | other: pelts}`, `{marta -> feminine: she | other: they}`: words chosen by a
    /// plural category or a gender, each branch labelled by one.
    select: struct { operand: Expr, branches: []const Branch },
};

pub const Branch = struct { label: Name, text: Text };

pub const Alternatives = enum {
    /// Each in turn, then the last for ever.
    seq,
    /// Each in turn, round again.
    cycle,
    /// Each once, then nothing.
    once,
    /// In an order the seed decides.
    shuffle,
};

/// `{ condition }` with what it gates, and what `{ else }` gates after it.
pub const Cond = struct { cond: Expr, body: []const Stmt, otherwise: []const Stmt = &.{} };

pub const Choice = struct {
    sticky: bool,
    cond: ?Expr,
    text: Text,
    body: []const Stmt,
};

pub const Gather = struct { label: ?Name, then: ?*const Stmt };

pub const Effect = union(enum) {
    /// `~ fact = value`, or `~ fact(key) = value` for a fact kept per thing
    set: struct { fact: Name, key: ?*const Expr = null, value: Expr },
    /// `~ set += item`, or `~ int += amount`
    add: Change,
    /// `~ set -= item`, or `~ int -= amount`
    remove: Change,
    /// `~ action(args)`
    call: Call,
};

/// What `+=` and `-=` change: a set by an item, or an int by a number or a constant. Which is the fact's
/// type to say, so the reader keeps the right side as an expression, a name or a number, and the checker decides.
pub const Change = struct { fact: Name, key: ?*const Expr = null, amount: Expr };

pub const Flow = union(enum) {
    /// `-> name`, or `-> end`.
    jump: Name,
    /// `->> name`: run it and come back.
    call: Name,
    /// `<-`: back to whoever called.
    ret,
};

pub const FlowIf = struct { cond: Expr, then: Flow, otherwise: Flow };

// ---------------------------------------------------------------- expressions

pub const Expr = struct {
    span: Span,
    kind: union(enum) {
        name: []const u8,
        int: i64,
        string: []const u8,
        boolean: bool,
        call: Call,
        not: *const Expr,
        binary: struct { op: Op, lhs: *const Expr, rhs: *const Expr },
    },

    pub const Op = enum { eq, ne, lt, le, gt, ge, has, hasnt, @"and", @"or" };
};

pub const Call = struct { name: Name, args: []const Expr };
