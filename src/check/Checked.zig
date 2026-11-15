//! A story as the checker resolved it: its symbols by id, and side tables
//! from the nodes of its syntax tree to what they mean. The tree is left as
//! the reader made it and must outlive this; a node is found in a side table
//! by its address in that tree. The compiler reads this, and refuses it
//! while the diagnostics hold an error.

const std = @import("std");
const syntax = @import("../syntax.zig");
const sym = @import("symbols.zig");

const Checked = @This();
const ast = syntax.ast;

arena: *std.heap.ArenaAllocator,
files: []const ast.File,

speakers: []const sym.Speaker,
facts: []const sym.Fact,
consts: []const sym.Const,
externs: []const sym.Extern,
enums: []const sym.Enum,
/// The kinds of the host's things, by `KindId`.
kinds: []const []const u8,
/// Each module's name, by `ModuleId`; the root's is empty.
modules: []const []const u8,
/// The story's version, which migration rules count from; 0 when none is declared.
version: u32 = 0,
/// The kinds packages registered, in the options' order: a builtin names one by its place here.
registered: []const sym.Registered,
sections: []const sym.Section,
labels: []const sym.Label,
visits: []const sym.Visit,
/// Where the story starts: the host's entries, or every section nothing else leads to; and every section of a
/// registered kind, which its package runs.
entries: []const sym.SectionId,
/// Every flow between sections, for tools that draw the graph.
edges: []const sym.Edge,

speaker_names: sym.Names(sym.SpeakerId),
value_names: sym.Names(sym.Named),
section_names: sym.Names(sym.SectionId),

/// Speakers, effects' facts and items, calls' queries and actions, and flows' targets.
names: std.AutoHashMapUnmanaged(*const ast.Name, sym.Ref),
/// Every expression's type, and what a name or a call in it means.
exprs: std.AutoHashMapUnmanaged(*const ast.Expr, sym.Typed),
/// Every line's and choice's id, by its statement.
lines: std.AutoHashMapUnmanaged(*const ast.Stmt, sym.LineId),
/// The sections a tag's values name, where the schema types them so.
tags: std.AutoHashMapUnmanaged(*const ast.Tag, []const sym.SectionId),
/// The tags whose values are words a player reads (a quest's title), which go into the string table.
text_tags: std.AutoHashMapUnmanaged(*const ast.Tag, void),
/// A line's tags where it has a delivery: the delivery, a tag of the host's key, then the line's own.
line_tags: std.AutoHashMapUnmanaged(*const ast.Stmt, []const ast.Tag),
/// A narration row that begins with a value, `{name(to)} has the parcel.`: read as a condition on its row, and,
/// the braces holding a value a line can say, a line that says it first. By the condition's statement: the line's
/// words, the value first.
value_first: std.AutoHashMapUnmanaged(*const ast.Stmt, ast.Text),

pub fn deinit(c: *Checked) void {
    const gpa = c.arena.child_allocator;
    c.arena.deinit();
    gpa.destroy(c.arena);
    c.* = undefined;
}

/// A line's or a choice's tags as the host is given them: a delivery among them, as a tag.
pub fn tagsOf(c: *const Checked, s: *const ast.Stmt) []const ast.Tag {
    return c.line_tags.get(s) orelse s.tags;
}

/// A section by name, as the root module sees it.
pub fn section(c: *const Checked, name: []const u8) ?sym.SectionId {
    return c.section_names.find(sym.root, name);
}

/// A fact by name, as the root module sees it.
pub fn fact(c: *const Checked, name: []const u8) ?sym.FactId {
    const named = c.value_names.find(sym.root, name) orelse return null;
    return if (named == .fact) named.fact else null;
}

/// A speaker by what a line writes, `DAD` or `A CELLIST`, as the root module sees it.
pub fn speaker(c: *const Checked, written: []const u8) ?sym.SpeakerId {
    var buf: [256]u8 = undefined;
    if (written.len > buf.len) return null;
    return c.speaker_names.find(sym.root, std.ascii.lowerString(&buf, written));
}
