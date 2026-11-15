//! The checker while it works through a story: what the host and its
//! packages give it (the options, their schemas, kinds and passes), the
//! tables it fills, the side tables of what each node means, and where it
//! reports. The passes are functions over it, in the order `check` runs
//! them, and a package's judges and passes are given it too.

const std = @import("std");
const syntax = @import("../syntax.zig");
const sym = @import("symbols.zig");

const Checker = @This();
const Checked = @import("Checked.zig");
const aegis = @import("aegis");
const ast = syntax.ast;
const Span = syntax.Span;
const Allocator = std.mem.Allocator;

pub const Error = error{OutOfMemory};

/// How finished a build is. A release refuses a line without a written id; a
/// development build derives one.
pub const Mode = enum { development, release };

pub const Options = struct {
    mode: Mode = .development,
    /// The sections the host starts the story at. Empty: every section nothing else leads to.
    entries: []const []const u8 = &.{},
    /// The host's tags. Null: tags are carried unchecked, and none leads anywhere.
    schema: ?*const Schema = null,
    /// Kinds of section besides scenes and pools that a package registers: `quest`.
    kinds: []const Kind = &.{},
    /// The packages' checks of the whole story, each run once riverrun's are done.
    passes: []const Pass = &.{},
    width: Width = .{},
    /// The host's things by kind, the ids a story may name: `item_kind` holds `wolf_pelt`. A kind not listed is
    /// carried unchecked, so a host without a manifest still compiles.
    things: []const Things = &.{},
    /// The key of the schema a speaker's delivery fills, `DAD (quietly): …`: one tag of the line, typed by the
    /// schema like any key. Null: the host takes no delivery, and one written is refused.
    delivery: ?[]const u8 = null,
};

pub const Things = struct { kind: []const u8, ids: []const []const u8 };

/// A kind of section a package registers, `(quest)`: the vocabulary it adds to the language, never grammar.
pub const Kind = struct {
    name: []const u8,
    /// The tags its sections, parts, lines and choices may carry, checked before the host's.
    schema: ?*const Schema = null,
    /// Functions its sections' conditions may call, which the package evaluates: `since(stage, fact)`.
    builtins: []const Builtin = &.{},
    /// The facts a section of this kind brings into the story (a calendar's `weekday`, a quest's stages), read
    /// from the section's own text, and the story's (`files`: what other sections a quest inherits from), before
    /// any name is resolved. What that text gets wrong is the package's to report, in its pass or its tags' judges.
    declare: ?*const fn (arena: Allocator, section: *const ast.Section, files: []const ast.File) Error![]const Declared = null,
    /// The kind of thing a section of this kind is kept per, if it is (a quest that runs many times, one instance
    /// a thing): every fact the section declares within it is kept per such a thing, and read and written inside it
    /// for the one it is evaluated for.
    per: ?*const fn (section: *const ast.Section) ?ast.Name = null,

    pub fn builtin(k: Kind, name: []const u8) ?u16 {
        for (k.builtins, 0..) |b, i| if (std.mem.eql(u8, b.name, name)) return @intCast(i); // safe: a kind has few builtins
        return null;
    }
};

/// A fact a registered kind's section declares, as a `facts (scope):` entry declares one: typed and scoped, named
/// beside the story's own so that a name declared twice is reported, read by conditions and saved in snapshots.
pub const Declared = struct {
    /// The scope it is kept in; null for the story's default.
    scope: ?[]const u8 = null,
    /// As the reader would have read it, its name's span where the section declares it.
    fact: ast.Fact,
    /// Named within its section: `section.name` to the rest of the story and `name` inside the section, as a
    /// quest's stages are. Otherwise it is named as a fact of the section's file is (a calendar's `weekday`).
    within: bool = false,
};

/// What a package checks of the whole story once riverrun has: what no schema can type (a calendar that does not
/// hold together, a quest that can get stuck), reported in the story's diagnostics where it is written, as
/// riverrun's own are (`c.err`). It reads the story and declares nothing.
pub const Pass = struct {
    user: ?*anyopaque = null,
    run: *const fn (user: ?*anyopaque, c: *Checker, story: *const Checked) Error!void,
};

pub const Builtin = sym.Builtin;

/// The host's tags, or a kind's, as it gives them to the checker: which keys it knows, where each may stand, and
/// what its values are.
pub const Schema = struct {
    keys: []const Key,

    /// Where a tag stands.
    pub const Place = enum { cast, section, part, line, choice };

    pub const Places = struct {
        cast: bool = false,
        section: bool = false,
        part: bool = false,
        line: bool = false,
        choice: bool = false,

        pub fn has(p: Places, at: Schema.Place) bool {
            return switch (at) {
                inline else => |t| @field(p, @tagName(t)),
            };
        }
    };

    pub const Value = union(enum) {
        /// A mark: the key alone.
        none,
        /// Digits, with an optional fraction: `2.5`.
        number,
        /// Letters, digits and `_`.
        word,
        /// Any words; quote them to hold `,`, `]` or `//`: `[title "Who was he?"]`.
        text,
        /// One of these words.
        words: []const []const u8,
        /// One of the values of the story's fact with this name, a `one of` or a `set of`.
        values_of: []const u8,
        /// A section of the story.
        section,
        /// Judged by the package that defines the key, against the story: `every week` names one of a
        /// calendar's units, `after asked` one of a quest's stages. Called once for each tag whose count holds.
        judge: Judge,
    };

    /// What a package makes of a tag's values: it reports what is wrong with `Checker.err`, at the value
    /// (`tag.at(i)`).
    pub const Judge = *const fn (c: *Checker, t: Tagged) Error!void;

    /// A tag being judged, and where it stands.
    pub const Tagged = struct {
        tag: *const ast.Tag,
        /// The tags written beside it, itself among them: a schedule's `every` reads its `calendar`.
        beside: []const ast.Tag,
        /// The section it is in; null on a cast entry.
        section: ?sym.SectionId,
        /// The part of the section it is in; null in the section's own body.
        part: ?u16,
        place: Schema.Place,
        /// The module its names are looked up in.
        module: sym.ModuleId,
    };

    pub const Count = enum {
        one,
        /// One or more.
        many,
        /// None or more: a key that is also a mark.
        any,
    };

    pub const Key = struct {
        name: []const u8,
        on: Places,
        value: Value = .none,
        count: Count = .one,
        /// On a section, with a section value: when the section ends the host goes on to that one.
        leads: bool = false,
        /// On a section or a part: the game runs it into a running flow, as an interruption (a scheduled scene
        /// come due), so `<-` there goes back to where the flow was, as from a call.
        interrupts: bool = false,
    };

    pub const Found = union(enum) { found: *const Key, elsewhere, unknown };

    /// The key called `name` that may stand at `at`, else whether any key has the name.
    pub fn find(s: *const Schema, name: []const u8, at: Schema.Place) Found {
        var elsewhere = false;
        for (s.keys) |*k| if (std.mem.eql(u8, k.name, name)) {
            if (k.on.has(at)) return .{ .found = k };
            elsewhere = true;
        };
        return if (elsewhere) .elsewhere else .unknown;
    }
};

/// Whether a key called `name` is the host's, or a registered kind's, wherever it may stand.
pub fn isKey(c: *const Checker, name: []const u8) bool {
    if (c.options.schema) |s| if (s.find(name, .line) != .unknown) return true;
    for (c.options.kinds) |k| if (k.schema) |s| if (s.find(name, .line) != .unknown) return true;
    return false;
}

/// Whether `name`, as `module` sees it, is an action: an extern with no answer, or one marked `(action)`.
pub fn isAction(c: *const Checker, module: sym.ModuleId, name: []const u8) bool {
    const named = c.valueNamed(module, name) orelse return false;
    if (named != .external) return false;
    const e = c.externs.items[named.external.raw()];
    return e.action or e.returns == null;
}

/// The kind a package registered for `section`, if it is one.
pub fn kindOfSection(c: *const Checker, id: sym.SectionId) ?*const Kind {
    const k = c.sections.items[id.raw()].kind;
    if (k != .other) return null;
    for (c.options.kinds) |*registered| if (std.mem.eql(u8, registered.name, k.other)) return registered;
    return null;
}

/// The most terminal columns a line's or a choice's text may take. A `{value}`
/// counts as `value` columns, or as none when that is null: only the host knows
/// how wide a fact is said. Words chosen by a condition count as the wider choice.
pub const Width = struct {
    line: ?u32 = null,
    choice: ?u32 = null,
    value: ?u32 = null,
};

gpa: Allocator,
/// What `Checked` keeps is allocated here.
arena: Allocator,
diags: *syntax.Diagnostics,
files: []const ast.File,
options: Options,

speakers: std.ArrayList(sym.Speaker) = .empty,
facts: std.ArrayList(sym.Fact) = .empty,
consts: std.ArrayList(sym.Const) = .empty,
externs: std.ArrayList(sym.Extern) = .empty,
enums: std.ArrayList(sym.Enum) = .empty,
sections: std.ArrayList(sym.Section) = .empty,
labels: std.ArrayList(sym.Label) = .empty,
visits: std.ArrayList(sym.Visit) = .empty,
edges: std.ArrayList(sym.Edge) = .empty,
entries: std.ArrayList(sym.SectionId) = .empty,
/// The kinds of the host's things a story names, by `KindId`.
kinds: std.ArrayList([]const u8) = .empty,
/// Each module's name, by `ModuleId`; the root's is empty.
module_names: std.ArrayList([]const u8) = .empty,
/// Each file's module, by `FileId`.
file_modules: []const sym.ModuleId = &.{},
/// The story's version, `version: 3`, and where it is declared; 0 when none is.
version: u32 = 0,
version_span: Span = .none,

speaker_names: sym.Names(sym.SpeakerId) = .{},
value_names: sym.Names(sym.Named) = .{},
section_names: sym.Names(sym.SectionId) = .{},

names: std.AutoHashMapUnmanaged(*const ast.Name, sym.Ref) = .empty,
exprs: std.AutoHashMapUnmanaged(*const ast.Expr, sym.Typed) = .empty,
lines: std.AutoHashMapUnmanaged(*const ast.Stmt, sym.LineId) = .empty,
tags: std.AutoHashMapUnmanaged(*const ast.Tag, []const sym.SectionId) = .empty,
/// A line's tags where it has a delivery: the delivery, as a tag of the host's key, then its own.
line_tags: std.AutoHashMapUnmanaged(*const ast.Stmt, []const ast.Tag) = .empty,
value_first: std.AutoHashMapUnmanaged(*const ast.Stmt, ast.Text) = .empty,
/// The tags whose values the schema types as words a player reads, which a translation carries.
text_tags: std.AutoHashMapUnmanaged(*const ast.Tag, void) = .empty,
/// Each line id in use, and where, so a second use can say where the first is.
line_ids: std.StringHashMapUnmanaged(Span) = .empty,
/// Where a section first returns with `<-`, for the warning when nothing calls it.
returns: std.AutoHashMapUnmanaged(sym.SectionId, Span) = .empty,

pub fn err(c: *Checker, span: Span, comptime fmt: []const u8, args: anytype) Error!void {
    try c.diags.add(c.gpa, span, .err, fmt, args);
}

pub fn warn(c: *Checker, span: Span, comptime fmt: []const u8, args: anytype) Error!void {
    try c.diags.add(c.gpa, span, .warning, fmt, args);
}

/// The module a file's names belong to: the one its `module` line names, or the root.
pub fn moduleOf(c: *const Checker, file: syntax.FileId) sym.ModuleId {
    aegis.assert.invariant(file < c.files.len, "the file is one of the story's");
    return if (file < c.file_modules.len) c.file_modules[file] else sym.root;
}

/// Numbers every file's module, the root first, before any name is declared.
pub fn numberModules(c: *Checker) Error!void {
    try c.module_names.append(c.arena, "");
    const out = try c.arena.alloc(sym.ModuleId, c.files.len);
    for (c.files, out) |f, *m| {
        const name = if (f.module) |n| n.text else "";
        m.* = c.moduleNamed(name) orelse blk: {
            const index = try c.grow([]const u8, &c.module_names, name, if (f.module) |n| n.span else .none, "modules") orelse break :blk sym.root;
            break :blk sym.idOf(sym.ModuleId, index);
        };
    }
    c.file_modules = out;
}

pub fn moduleNamed(c: *const Checker, name: []const u8) ?sym.ModuleId {
    for (c.module_names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) return sym.idOf(sym.ModuleId, i);
    return null;
}

/// A name in the expression namespace as `module` sees it; `other.name` is looked up in module `other` alone.
pub fn valueNamed(c: *const Checker, module: sym.ModuleId, name: []const u8) ?sym.Named {
    return qualified(c, sym.Named, &c.value_names, module, name);
}

/// A section as `module` sees it, qualified the same way.
pub fn sectionNamed(c: *const Checker, module: sym.ModuleId, name: []const u8) ?sym.SectionId {
    return qualified(c, sym.SectionId, &c.section_names, module, name);
}

fn qualified(c: *const Checker, comptime V: type, names: *const sym.Names(V), module: sym.ModuleId, name: []const u8) ?V {
    const dot = std.mem.findScalar(u8, name, '.') orelse return names.find(module, name);
    if (c.moduleNamed(name[0..dot])) |other| return names.map.get(.{ .module = other, .name = name[dot + 1 ..] });
    // what a section declares within it, `quest.stage`, is named so in the section's module
    return names.find(module, name);
}

/// The id of a kind of the host's things, entered the first time a type names it.
pub fn kindOf(c: *Checker, name: []const u8, span: Span) Error!sym.KindId {
    for (c.kinds.items, 0..) |k, i| if (std.mem.eql(u8, k, name)) return sym.idOf(sym.KindId, i);
    const index = try c.grow([]const u8, &c.kinds, name, span, "kinds of things") orelse return .fromRaw(0);
    return sym.idOf(sym.KindId, index);
}

/// Whether the host's manifest allows `id` for a kind; a kind it does not list allows any.
pub fn knowsThing(c: *const Checker, kind: sym.KindId, id: []const u8) bool {
    const name = c.kinds.items[kind.raw()];
    for (c.options.things) |t| if (std.mem.eql(u8, t.kind, name)) {
        for (t.ids) |known| if (std.mem.eql(u8, known, id)) return true;
        return false;
    };
    return true;
}

/// A span as `file:line:col`, for a message that points at a second place.
/// The row `span` begins on, its words alone, without the rows under it: where what is about a statement itself is
/// placed (a choice's row, not its body).
pub fn row(c: *const Checker, span: Span) Span {
    if (span.file >= c.files.len) return span;
    return c.files[span.file].rowAt(span);
}

pub fn place(c: *const Checker, span: Span) Place {
    if (span.file >= c.files.len) return .{ .path = "?", .at = .{ .line = 0, .col = 0 } };
    const f = &c.files[span.file];
    return .{ .path = f.path, .at = f.place(span) };
}

pub const Place = struct {
    path: []const u8,
    at: syntax.Place,

    pub fn format(p: Place, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}:{d}:{d}", .{ p.path, p.at.line, p.at.col });
    }
};

/// A type as a writer reads it: "true or false", "one of stay, go".
pub fn describe(c: *const Checker, t: sym.Type) Error![]const u8 {
    return switch (t) {
        .boolean => "true or false",
        .int => "a number",
        .text => "text",
        .one_of => |e| c.arena.print("one of {s}", .{try c.valueList(e)}),
        .set_of => |e| c.arena.print("a set of {s}", .{try c.valueList(e)}),
        .ref => |k| c.arena.print("a {s}", .{c.kinds.items[k.raw()]}),
    };
}

pub fn valueList(c: *const Checker, e: sym.EnumId) Error![]const u8 {
    return std.mem.join(c.arena, ", ", c.enums.items[e.raw()].values);
}

/// The index of `name` among an enumeration's values.
pub fn valueOf(c: *const Checker, e: sym.EnumId, name: []const u8) ?u16 {
    for (c.enums.items[e.raw()].values, 0..) |v, i| {
        if (std.mem.eql(u8, v, name)) return @intCast(i); // safe: an enumeration holds at most limits.values
    }
    return null;
}

pub fn section(c: *Checker, id: sym.SectionId) *sym.Section {
    return &c.sections.items[id.raw()];
}

/// Appends to a table numbered by a 16-bit id, or says the story has too many.
pub fn grow(c: *Checker, comptime T: type, list: *std.ArrayList(T), item: T, span: Span, what: []const u8) Error!?usize {
    if (list.items.len == sym.limits.ids) {
        try c.err(span, "the story has more {s} than {d}", .{ what, sym.limits.ids });
        return null;
    }
    try list.append(c.arena, item);
    return list.items.len - 1;
}

/// A new visit count, numbered.
pub fn visit(c: *Checker, of: @FieldType(sym.Visit, "of"), span: Span) Error!sym.VisitId {
    const index = try c.grow(sym.Visit, &c.visits, .{ .of = of }, span, "visit counts") orelse return .fromRaw(0);
    return sym.idOf(sym.VisitId, index);
}

pub fn edge(c: *Checker, from: sym.SectionId, to: sym.SectionId, how: @FieldType(sym.Edge, "how")) Error!void {
    try c.edges.append(c.arena, .{ .from = from, .to = to, .how = how });
}

/// Lower case, for speakers: `A CELLIST` matches `a cellist`.
pub fn lower(c: *const Checker, s: []const u8) Error![]const u8 {
    return std.ascii.allocLowerString(c.arena, s);
}

test "a key is found where it may stand" {
    const s: Schema = .{ .keys = &.{
        .{ .name = "at", .on = .{ .line = true }, .value = .number },
        .{ .name = "at", .on = .{ .choice = true }, .value = .word, .count = .many },
    } };
    try std.testing.expectEqual(Schema.Value.word, std.meta.activeTag(s.find("at", .choice).found.value));
    try std.testing.expect(s.find("at", .section) == .elsewhere);
    try std.testing.expect(s.find("heard", .line) == .unknown);
}
