//! The syntax tree: a story's files as the reader understood them, before
//! any name is resolved, and as they are written. Every node keeps its span,
//! the range of bytes it is written in, so the checker and the tools can
//! point back at the text; a file's rows keep every byte of it, comments,
//! blank lines and layout included, so the file prints back as it was
//! (`print.zig`) and a tool that edits the tree writes the text. The reader
//! allocates all of it in one arena the caller owns.
//!
//! Every construct carries its range: a node has a `span`, and a value that
//! cannot hold one (a `Type`, which packages build, a condition's braces
//! around its expression, a parenthetical around a name) has its range in a
//! field beside it, named for it with `_span`: `type_span` is where `type` is
//! written, its names inside it.

const source = @import("source.zig");
const Span = source.Span;

/// One file: its declarations and its sections, in the order written, over the rows they are written on.
pub const File = struct {
    path: []const u8,
    /// The whole file, from its first byte to its last.
    span: Span,
    /// The file begins with a UTF-8 byte-order mark, which comes before its first row.
    bom: bool = false,
    /// Every row of the file, in order: with `bom`, the file byte for byte.
    rows: []const Row = &.{},
    /// `module name` at the top: what the file declares is `name.x` to other modules. Null is the root module.
    module: ?Name = null,
    decls: []const Decl,
    sections: []const Section,

    /// Where `span` starts, as a line and a column: its row, and its byte in the row.
    pub fn place(f: *const File, span: Span) source.Place {
        if (span.start > f.span.end) return .{ .line = 0, .col = 0 };
        if (f.rows.len == 0) return .{ .line = 1, .col = 1 };
        // the last row starting at or before it
        var lo: usize = 0;
        var hi: usize = f.rows.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (f.rows[mid].start <= span.start) lo = mid else hi = mid;
        }
        const row = f.rows[lo];
        return .{ .line = @intCast(lo + 1), .col = span.start + 1 - @min(span.start, row.start) }; // safe: rows are at most max_bytes
    }
};

/// One line of a file as it is written: what it says and how it is laid out. A row is printed as its indentation,
/// its words, its id and its comment, each after the spaces before it, the spaces at its end and its line ending,
/// so the rows of a file print it back byte for byte.
pub const Row = struct {
    /// Where the row starts in its file.
    start: u32,
    /// The spaces before its words.
    indent: u32 = 0,
    /// Its words: a heading, an entry, a statement or a row of brackets, without its id or comment. Empty on a
    /// blank row.
    text: []const u8 = "",
    /// The spaces between its words and its id.
    before_id: u32 = 0,
    /// `^` and the line's id at the end of its words; empty without one.
    id: []const u8 = "",
    /// The spaces between what comes before its comment and the comment.
    before_comment: u32 = 0,
    /// `//` and what follows it, without the spaces at the row's end; empty without a comment.
    comment: []const u8 = "",
    /// The spaces at the row's end.
    trailing: u32 = 0,
    ending: Ending,

    pub const Ending = enum {
        lf,
        crlf,
        /// The file's last row, with no line ending after it.
        none,

        pub fn bytes(e: Ending) []const u8 {
            return switch (e) {
                .lf => "\n",
                .crlf => "\r\n",
                .none => "",
            };
        }
    };

    /// How many bytes the row is, its line ending included.
    pub fn len(r: Row) u32 {
        return @intCast(r.indent + r.text.len + r.before_id + r.id.len + r.before_comment + r.comment.len + r.trailing + r.ending.bytes().len); // safe: a row is a part of its file
    }
};

// ---------------------------------------------------------------- declarations

/// A declaration: its heading and the entries under it.
pub const Decl = struct {
    span: Span,
    kind: union(enum) {
        /// `version: 3`: which version of the story this is, which migration rules count from.
        version: u32,
        cast: []const CastEntry,
        extras: []const Name,
        facts: Facts,
        consts: []const Const,
        externs: []const Extern,
    },
};

pub const Name = struct { text: []const u8, span: Span };

pub const CastEntry = struct {
    /// Its row, and the rows of brackets under it.
    span: Span,
    id: Name,
    /// How the character is shown: "Mum".
    display: []const u8,
    /// Who they are, for the people screen: "Frank, her father".
    relation: ?[]const u8,
    /// The tags in brackets on the rows under it: `[gender feminine]`.
    tags: []const Tag,
};

pub const Facts = struct {
    span: Span,
    /// The scope the host names: `life`, `player`, `world`… Null is the story's default scope.
    scope: ?Name,
    /// The parentheses the scope is written in.
    scope_span: ?Span = null,
    entries: []const Fact,
};

pub const Fact = struct {
    span: Span,
    name: Name,
    /// `opinion(person): int`: a value for each of the things of a kind, or each value of an enumeration.
    key: ?Type = null,
    /// Where `key` is written, inside the parentheses.
    key_span: ?Span = null,
    type: Type,
    /// Where `type` is written; none for a fact a package declares.
    type_span: ?Span = null,
    /// `int from -100 to 100`: the least and the most an int holds.
    bounds: ?Bounds = null,
    /// Written by the game's mechanics, never by the story.
    game: bool,
    /// `(clock)`: an int the game only advances, so a comparison with it can be woken by its value.
    clock: bool = false,
    /// `(moment)`: what happened, held only until what watches conditions has seen it, and never saved.
    moment: bool = false,
    /// `(role)`: in a section's own facts, one of the things the section is about, given to it when it starts
    /// (a quest's stranger): never set by the story.
    role: bool = false,
    /// Where each of its marks is written, `(game)`, `(clock)`, `(moment)` or `(role)`, parentheses and all.
    marks: []const Span = &.{},
};

/// A type, as the reader reads it and a package's `Kind.declare` builds it. It has no range of its own: what holds
/// one has it beside it (`Fact.type_span`).
pub const Type = union(enum) {
    boolean,
    int,
    text,
    one_of: []const Name,
    set_of: []const Name,
    /// `ref of kind`: an opaque handle to one of the host's things, named in the story by stable text ids.
    ref: Name,
};

/// `from -100 to 100`, after an int.
pub const Bounds = struct { span: Span, min: i64, max: i64 };

pub const Const = struct { span: Span, name: Name, value: Expr };

pub const Extern = struct {
    span: Span,
    name: Name,
    params: []const Param,
    /// Null for an action; a type for a query, or for an action's outcome.
    returns: ?Type,
    /// Where `returns` is written, after `->`.
    returns_span: ?Span = null,
    /// `(action)` after a return type: an action whose outcome the host decides. Without it a return makes a query.
    action: bool = false,
    /// Where `(action)` is written.
    action_span: ?Span = null,
    /// `(reads stock(kind))`: the stamp the host bumps when what the query reads changes, keyed by its parameters.
    reads: ?Stamp = null,
    /// Where `(reads …)` is written, parentheses and all.
    reads_span: ?Span = null,
};

pub const Param = struct {
    span: Span,
    name: ?Name,
    type: Type,
    /// Where `type` is written.
    type_span: ?Span = null,
};

pub const Stamp = struct { span: Span, family: Name, keys: []const Name };

// ---------------------------------------------------------------- sections

pub const Section = struct {
    span: Span,
    name: Name,
    kind: Kind,
    /// The parentheses the kind is written in: `(pool 2)`; none for a scene written without one.
    kind_span: ?Span = null,
    /// The tags in brackets on the rows under its heading.
    tags: []const Tag,
    /// `facts:` blocks under its heading: facts of its own, `section.name` to the rest of the story.
    facts: []const Facts = &.{},
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
    span: Span,
    name: Name,
    /// A pool candidate's or a rule's condition.
    when: ?Expr,
    /// The braces `when` is written in.
    when_span: ?Span = null,
    /// The tags in brackets first under its heading.
    tags: []const Tag,
    body: []const Stmt,
};

/// A tag: `[key value, value]`, or a line's id, `^k7f3a2`, whose key is `id`. riverrun carries it and never reads
/// it.
pub const Tag = struct {
    /// The bracket, `[` to `]`; for an id, `^` and the id.
    span: Span,
    /// Its key, where it is written; for an id, `id` at the `^`.
    key: Name,
    values: []const []const u8,
    /// Where each value is written, one for each of `values`: what is wrong with a value is said there.
    spans: []const Span = &.{},

    /// Where value `i` is written; the key's place where the reader kept none.
    pub fn at(t: Tag, i: usize) Span {
        return if (i < t.spans.len) t.spans[i] else t.key.span;
    }
};

pub const Stmt = struct {
    /// From its first word to the end of the last thing under it.
    span: Span,
    /// A line's or a choice's tags: its id at the end of its row, then the tags in brackets first under it. A
    /// statement written on a row after a condition (`{ met } Go.`) or a gather (`- (ask) * Run.`) has them, and
    /// the condition or the gather has none; nothing else has tags.
    tags: []const Tag,
    kind: union(enum) {
        line: Line,
        /// `{ condition }` with the statements it gates.
        cond: Cond,
        /// `* text` (once) or `+ text` (sticky), with what follows it.
        choice: Choice,
        /// `-` joins branches; it may carry a label and a statement.
        gather: Gather,
        /// An effect in a bracket: `[fact = value]`. A row of brackets that is a step is one effect each.
        effect: Effect,
        flow: Flow,
        /// `{ condition: -> a | -> b }`: a flow chosen by a condition.
        flow_if: FlowIf,
    },
};

pub const Line = struct {
    /// Null for narration.
    speaker: ?Name,
    /// `DAD (quietly):`: how the line is delivered, a tag of the key the host names for it.
    delivery: ?Delivery = null,
    text: Text,
    /// Effects in brackets under the line: they happen when the line is delivered, so a host that does not deliver
    /// it (a line Iris does not overhear) does not apply them.
    effects: []const Stmt,
};

/// A speaker's parenthetical: `(laughing manically)`.
pub const Delivery = struct {
    /// The parentheses and what is between them.
    span: Span,
    /// The words between them, the tag's one value.
    words: Name,
};

/// Text: literal runs, interpolated facts, and words chosen by a condition.
pub const Text = []const Piece;

pub const Piece = struct {
    /// Where the piece is written: a literal run with its escapes, or the braces and what is between them.
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        literal: []const u8,
        /// `{fact}`
        value: Expr,
        /// `{ condition: these words | those words }`
        choose: struct { cond: Expr, then: Text, otherwise: Text },
        /// `{seq: a | b | c}`, `{cycle: …}`, `{once: …}`, `{shuffle: …}`
        alternatives: struct { kind: Alternatives, options: []const Text },
        /// `{count as one: pelt | other: pelts}`, `{marta as feminine: she | other: they}`: words chosen by a
        /// plural category or a gender, each branch labelled by one.
        select: struct { operand: Expr, branches: []const Branch },
    };
};

pub const Branch = struct { span: Span, label: Name, text: Text };

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
pub const Cond = struct {
    cond: Expr,
    /// The braces `cond` is written in.
    cond_span: Span,
    body: []const Stmt,
    otherwise: []const Stmt = &.{},
    /// `{ else }`, where it is written.
    else_span: ?Span = null,
    /// `{ met } Go.`: the condition and the one statement it gates written on one row, which has the row's tags.
    on_row: bool = false,
};

pub const Choice = struct {
    sticky: bool,
    cond: ?Expr,
    /// The braces `cond` is written in.
    cond_span: ?Span = null,
    text: Text,
    body: []const Stmt,
};

pub const Gather = struct {
    label: ?Name,
    /// The parentheses `label` is written in: `(ask)`.
    label_span: ?Span = null,
    then: ?*const Stmt,
};

pub const Effect = union(enum) {
    /// `[fact = value]`, or `[fact(key) = value]` for a fact kept per thing
    set: struct { span: Span, fact: Name, key: ?*const Expr = null, value: Expr },
    /// `[set += item]`, or `[int += amount]`
    add: Change,
    /// `[set -= item]`, or `[int -= amount]`
    remove: Change,
    /// `[action(args)]`
    call: Call,

    /// Where the effect is written, inside its bracket.
    pub fn span(e: Effect) Span {
        return switch (e) {
            .set => |s| s.span,
            .add, .remove => |c| c.span,
            .call => |c| c.span,
        };
    }
};

/// What `+=` and `-=` change: a set by an item, or an int by a number or a constant. Which is the fact's
/// type to say, so the reader keeps the right side as an expression, a name or a number, and the checker decides.
pub const Change = struct { span: Span, fact: Name, key: ?*const Expr = null, amount: Expr };

pub const Flow = struct {
    /// From its first arrow to its last word: `-> name ->`.
    span: Span,
    kind: union(enum) {
        /// `-> name`, or `-> end`.
        jump: Name,
        /// `-> name ->`: run it and come back.
        call: Name,
        /// `<-`: back to whoever called.
        ret,
    },
};

pub const FlowIf = struct {
    /// The braces and what is between them.
    span: Span,
    cond: Expr,
    then: Flow,
    otherwise: Flow,
};

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

    /// `add` and `sub` are an int's `+` and `-`; the rest compare or join conditions.
    pub const Op = enum { eq, ne, lt, le, gt, ge, has, hasnt, @"and", @"or", add, sub };
};

/// `name(args)`: a query's, a builtin's or an action's.
pub const Call = struct { span: Span, name: Name, args: []const Expr };
