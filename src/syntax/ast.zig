//! The syntax tree: a story's files as the reader understood them, before
//! any name is resolved, and as they are written. Every node keeps its span,
//! the range of bytes it is written in, so the checker and the tools can
//! point back at the text; a file's rows keep every byte of it, comments,
//! blank lines and layout included, so the file prints back as it was
//! (`print.zig`) and a tool that edits the tree writes the text. The reader
//! allocates all of it in one arena the caller owns.

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
/// its words, its tags and its comment, each after the spaces before it, the spaces at its end and its line
/// ending, so the rows of a file print it back byte for byte.
pub const Row = struct {
    /// Where the row starts in its file.
    start: u32,
    /// The spaces before its words.
    indent: u32 = 0,
    /// Its words: a heading, an entry or a statement, without its tags or comment. Empty on a blank row.
    text: []const u8 = "",
    /// The spaces between its words and its tags.
    before_tags: u32 = 0,
    /// `#` and the tags after it, up to its comment or its end, without the spaces after them; empty without tags.
    tags: []const u8 = "",
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
        return @intCast(r.indent + r.text.len + r.before_tags + r.tags.len + r.before_comment + r.comment.len + r.trailing + r.ending.bytes().len); // safe: a row is a part of its file
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
    span: Span,
    id: Name,
    /// How the character is shown: "Mum".
    display: []const u8,
    /// Who they are, for the people screen: "Frank, her father".
    relation: ?[]const u8,
    tags: []const Tag,
};

pub const Facts = struct {
    span: Span,
    /// The scope the host names: `life`, `player`, `world`… Null is the story's default scope.
    scope: ?Name,
    entries: []const Fact,
};

pub const Fact = struct {
    span: Span,
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
    /// `(role)`: in a section's own facts, one of the things the section is about, given to it when it starts
    /// (a quest's stranger): never set by the story.
    role: bool = false,
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

pub const Const = struct { span: Span, name: Name, value: Expr };

pub const Extern = struct {
    span: Span,
    name: Name,
    params: []const Param,
    /// Null for an action; a type for a query, or for an action's outcome.
    returns: ?Type,
    /// `(action)` after a return type: an action whose outcome the host decides. Without it a return makes a query.
    action: bool = false,
    /// `(reads stock(kind))`: the stamp the host bumps when what the query reads changes, keyed by its parameters.
    reads: ?Stamp = null,
};

pub const Param = struct { span: Span, name: ?Name, type: Type };

pub const Stamp = struct { span: Span, family: Name, keys: []const Name };

// ---------------------------------------------------------------- sections

pub const Section = struct {
    span: Span,
    name: Name,
    kind: Kind,
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
    /// A pool candidate's condition.
    when: ?Expr,
    tags: []const Tag,
    body: []const Stmt,
};

/// A tag: `# key value, value · key value`. riverrun carries it and never reads it.
pub const Tag = struct {
    span: Span,
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
    /// The tags at the end of its row. A statement written on a row after a condition (`{ met } Go.`) or a gather
    /// (`- (ask) * Run.`) has the row's tags, and the condition or the gather has none.
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
        /// `{count -> one: pelt | other: pelts}`, `{marta -> feminine: she | other: they}`: words chosen by a
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
    body: []const Stmt,
    otherwise: []const Stmt = &.{},
    /// `{ met } Go.`: the condition and the one statement it gates written on one row, which has the row's tags.
    on_row: bool = false,
};

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
