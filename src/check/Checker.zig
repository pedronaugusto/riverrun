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
    /// Kinds of section besides scenes and pools that the host registers: `quest`.
    kinds: []const []const u8 = &.{},
    width: Width = .{},
};

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

speaker_names: sym.Names(sym.SpeakerId) = .{},
value_names: sym.Names(sym.Named) = .{},
section_names: sym.Names(sym.SectionId) = .{},

names: std.AutoHashMapUnmanaged(*const ast.Name, sym.Ref) = .empty,
exprs: std.AutoHashMapUnmanaged(*const ast.Expr, sym.Typed) = .empty,
lines: std.AutoHashMapUnmanaged(*const ast.Stmt, sym.LineId) = .empty,
tags: std.AutoHashMapUnmanaged(*const ast.Tag, []const sym.SectionId) = .empty,
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

/// The module a file's names belong to. Every file is in the root module until the reader reads `module`.
pub fn moduleOf(c: *const Checker, file: syntax.FileId) sym.ModuleId {
    std.debug.assert(file < c.files.len);
    return sym.root;
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
