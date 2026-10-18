//! The syntax tree: a story's files as the reader understood them, before
//! any name is resolved. Every node keeps its span, so the checker and the
//! tools can point back at the text. The reader allocates all of it in one
//! arena the caller owns.

const Span = @import("source.zig").Span;

/// One file: its declarations and its sections, in the order written.
pub const File = struct {
    path: []const u8,
    decls: []const Decl,
    sections: []const Section,
};

// ---------------------------------------------------------------- declarations

pub const Decl = union(enum) {
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
    type: Type,
    /// Written by the game's mechanics, never by the story.
    game: bool,
};

pub const Type = union(enum) {
    boolean,
    int,
    text,
    one_of: []const Name,
    set_of: []const Name,
};

pub const Const = struct { name: Name, value: Expr };

pub const Extern = struct {
    name: Name,
    params: []const Type,
    /// Null for an action; a type for a query.
    returns: ?Type,
};

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
};

pub const Cond = struct { cond: Expr, body: []const Stmt };

pub const Choice = struct {
    sticky: bool,
    cond: ?Expr,
    text: Text,
    body: []const Stmt,
};

pub const Gather = struct { label: ?Name, then: ?*const Stmt };

pub const Effect = union(enum) {
    /// `~ fact = value`
    set: struct { fact: Name, value: Expr },
    /// `~ set += item`
    add: struct { fact: Name, item: Name },
    /// `~ set -= item`
    remove: struct { fact: Name, item: Name },
    /// `~ action(args)`
    call: Call,
};

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

    pub const Op = enum { eq, ne, has, hasnt, @"and", @"or" };
};

pub const Call = struct { name: Name, args: []const Expr };
