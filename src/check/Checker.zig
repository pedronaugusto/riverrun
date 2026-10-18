//! The checker while it works through a story: the tables it fills, the
//! side tables of what each node means, and where it reports. The passes
//! are functions over it, in the order `check` runs them.

const std = @import("std");
const syntax = @import("../syntax.zig");
const sym = @import("symbols.zig");
const Schema = @import("schema.zig").Schema;

const Checker = @This();
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
    width: Width = .{},
    /// The host's things by kind, the ids a story may name: `item_kind` holds `wolf_pelt`. A kind not listed is
    /// carried unchecked, so a host without a manifest still compiles.
    things: []const Things = &.{},
};

pub const Things = struct { kind: []const u8, ids: []const []const u8 };

/// A kind of section a package registers, `(quest)`: the vocabulary it adds to the language, never grammar.
pub const Kind = struct {
    name: []const u8,
    /// The tags its sections, parts, lines and choices may carry, checked before the host's.
    schema: ?*const Schema = null,
    /// Functions its sections' conditions may call, which the package evaluates: `since(stage, fact)`.
    builtins: []const Builtin = &.{},

    pub fn builtin(k: Kind, name: []const u8) ?u16 {
        for (k.builtins, 0..) |b, i| if (std.mem.eql(u8, b.name, name)) return @intCast(i); // safe: a kind has few builtins
        return null;
    }
};

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
    std.debug.assert(file < c.files.len);
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
    const other = c.moduleNamed(name[0..dot]) orelse return null;
    return names.map.get(.{ .module = other, .name = name[dot + 1 ..] });
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
pub fn place(c: *const Checker, span: Span) Place {
    return .{ .path = if (span.file < c.files.len) c.files[span.file].path else "?", .span = span };
}

pub const Place = struct {
    path: []const u8,
    span: Span,

    pub fn format(p: Place, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}:{d}:{d}", .{ p.path, p.span.line, p.span.col });
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
