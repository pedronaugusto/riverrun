//! Line ids, written: ` ^id` at the end of every line and choice that has
//! none, through the tree that keeps every byte, so nothing else in a file
//! moves. An id once written is the line's for good: translations, recorded
//! voices and saves key on it, and it survives any edit of the words, a
//! move to another section, a rename. So an id says nothing about where its
//! line is (an id that named its section would lie after a move): it is six
//! characters, a letter then five letters or digits, lowercase, from
//! Crockford's alphabet (no i, l, o or u), which reads aloud and types back
//! without a 1 taken for an l or a 0 for an o, is one name on a file system
//! that ignores case (a voice file is named by its id), and is never read as a
//! number by a spreadsheet (a translator's sheet). There are 22 × 32⁵, about
//! 7.4 × 10⁸, of them; a two-hour story of 5,000 lines holds a few in a
//! hundred thousand.
//!
//! An id is made without a clock or chance, from a hash of the line's
//! section, part, place among its section's lines and choices, and words,
//! hashed again until it is unused anywhere in the story's files: the same
//! files in the same order are always given the same ids, and a file that
//! has them all is left as it is.

const std = @import("std");
const aegis = @import("aegis");
const river = @import("riverrun-compiler");

const syntax = river.syntax;
const ast = syntax.ast;

/// How many characters an id is, after its `^`.
pub const length = 6;
/// What an id may begin with: Crockford's letters.
pub const first = "abcdefghjkmnpqrstvwxyz";
/// What its other characters are: Crockford's base 32, lowercase.
pub const rest = "0123456789abcdefghjkmnpqrstvwxyz";

/// A line or a choice: the file it is in and its row's words, where its id goes.
pub const Place = struct { file: syntax.FileId, span: syntax.Span };

/// Every line and choice of `files` with no id, in the order written.
pub fn missing(arena: std.mem.Allocator, files: []const ast.File) error{OutOfMemory}![]const Place {
    var out: std.ArrayList(Place) = .empty;
    for (files, 0..) |*f, i| {
        var w: Walk = .{ .file = f, .ctx = .{ .missing = .{ .out = &out, .arena = arena, .file = @intCast(i) } } }; // safe: files are numbered by FileId
        try w.all();
    }
    return out.items;
}

/// The files with an id given to every line and choice that had none: each file's rows, those rows' ids added and
/// every other row as it was, with how many it was given. The other nodes of a tree are as read: print it
/// (`syntax.print`) and read it again for them. The files must have been read without an error, or a row might be
/// misread as a line.
pub const Given = struct { files: []const ast.File, added: []const u32 };

pub fn give(arena: std.mem.Allocator, files: []const ast.File) error{OutOfMemory}!Given {
    var used: std.StringHashMapUnmanaged(void) = .empty;
    for (files) |f| for (f.rows) |r| if (r.id.len > 1) try used.put(arena, r.id[1..], {});
    const out = try arena.alloc(ast.File, files.len);
    const added = try arena.alloc(u32, files.len);
    for (files, out, added) |*f, *o, *n| {
        const rows = try arena.dupe(ast.Row, f.rows);
        var w: Walk = .{ .file = f, .ctx = .{ .give = .{ .rows = rows, .used = &used, .arena = arena } } };
        try w.all();
        o.* = f.*;
        o.rows = rows;
        n.* = w.ctx.give.added;
    }
    return .{ .files = out, .added = added };
}

/// The id `attempt` for a line, from what is written of it.
pub fn make(section: []const u8, part: []const u8, ordinal: u32, words: []const u8, attempt: u32) [length]u8 {
    var h: std.hash.Wyhash = .init(attempt);
    h.update(section);
    h.update(&.{0});
    h.update(part);
    h.update(&.{0});
    h.update(std.mem.asBytes(&std.mem.nativeToLittle(u32, ordinal)));
    h.update(words);
    var bits = h.final();
    var id: [length]u8 = undefined;
    id[0] = first[bits % first.len];
    bits /= first.len;
    for (id[1..]) |*c| {
        c.* = rest[bits % rest.len];
        bits /= rest.len;
    }
    return id;
}

const Walk = struct {
    file: *const ast.File,
    ctx: union(enum) {
        missing: struct { out: *std.ArrayList(Place), arena: std.mem.Allocator, file: syntax.FileId },
        give: struct { rows: []ast.Row, used: *std.StringHashMapUnmanaged(void), arena: std.mem.Allocator, added: u32 = 0 },
    },
    section: []const u8 = "",
    part: []const u8 = "",
    /// The place of the next line or choice among its section's or part's.
    ordinal: u32 = 0,

    fn all(w: *Walk) error{OutOfMemory}!void {
        for (w.file.sections) |*s| {
            w.section = s.name.text;
            w.part = "";
            w.ordinal = 0;
            try w.stmts(s.body);
            for (s.subsections) |*p| {
                w.part = p.name.text;
                w.ordinal = 0;
                try w.stmts(p.body);
            }
        }
    }

    fn stmts(w: *Walk, list: []const ast.Stmt) error{OutOfMemory}!void {
        for (list) |*s| try w.stmt(s);
    }

    fn stmt(w: *Walk, s: *const ast.Stmt) error{OutOfMemory}!void {
        switch (s.kind) {
            .line => |*l| {
                try w.one(s);
                try w.stmts(l.effects);
            },
            .choice => |*c| {
                try w.one(s);
                try w.stmts(c.body);
            },
            .cond => |*c| {
                try w.stmts(c.body);
                try w.stmts(c.otherwise);
            },
            .gather => |g| if (g.then) |then| try w.stmt(then),
            .effect, .flow, .flow_if => {},
        }
    }

    // A line or a choice: the row it is written on keeps its id.
    fn one(w: *Walk, s: *const ast.Stmt) error{OutOfMemory}!void {
        defer w.ordinal += 1;
        const at = w.file.place(s.span).line;
        aegis.assert.invariant(at >= 1, "a statement is on a row");
        aegis.assert.invariant(at <= w.file.rows.len, "a statement is on one of its file's rows");
        const row = w.file.rows[at - 1];
        if (row.id.len > 0) return;
        switch (w.ctx) {
            // the row's words, where its id goes at their end
            .missing => |m| try m.out.append(m.arena, .{ .file = m.file, .span = .{ .file = m.file, .start = row.start + row.indent, .end = row.start + row.indent + @as(u32, @intCast(row.text.len)) } }), // safe: a row is a part of its file
            .give => |*g| {
                var attempt: u32 = 0;
                const id = while (true) : (attempt += 1) {
                    const id = make(w.section, w.part, w.ordinal, row.text, attempt);
                    if (!g.used.contains(&id)) break try g.arena.dupe(u8, &id);
                };
                try g.used.put(g.arena, id, {});
                const r = &g.rows[at - 1];
                r.before_id = 1;
                r.id = try std.mem.concat(g.arena, u8, &.{ "^", id });
                g.added += 1;
            },
        }
    }
};

test "an id is a letter then five of Crockford's base 32, made the same way every time" {
    const a = make("kitchen", "", 0, "MUM: Go.", 0);
    try std.testing.expectEqualSlices(u8, &a, &make("kitchen", "", 0, "MUM: Go.", 0));
    try std.testing.expect(std.mem.findScalar(u8, first, a[0]) != null);
    for (a[1..]) |c| try std.testing.expect(std.mem.findScalar(u8, rest, c) != null);
    try std.testing.expect(!std.mem.eql(u8, &a, &make("kitchen", "", 0, "MUM: Go.", 1)));
    try std.testing.expect(!std.mem.eql(u8, &a, &make("kitchen", "", 1, "MUM: Go.", 0)));
}

test "every line and choice is given an id at its row's end, before its comment, and nothing else moves" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var diags: syntax.Diagnostics = .{};
    defer diags.deinit(gpa);
    const text = "== a   // the start\r\nMUM: Go.   // why  \r\n  [x = 1]\n* Run. ^r1\n- (ask) * Stay.\n{ met } Wait.\n= p   when { met }   Words.";
    const tree = try syntax.parse(a, gpa, &diags, 0, "a.river", text);
    try std.testing.expectEqual(@as(usize, 0), diags.errors());
    const files: []const ast.File = &.{tree};
    try std.testing.expectEqual(@as(usize, 4), (try missing(a, files)).len);
    const given = try give(a, files);
    try std.testing.expectEqual(@as(u32, 4), given.added[0]);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try syntax.print(&out.writer, &given.files[0]);
    const r = given.files[0].rows;
    const want = try std.mem.concat(a, u8, &.{
        "== a   // the start\r\nMUM: Go. ", r[1].id, "   // why  \r\n  [x = 1]\n* Run. ^r1\n- (ask) * Stay. ", r[4].id, "\n{ met } Wait. ", r[5].id, "\n= p   when { met }   Words. ", r[6].id,
    });
    try std.testing.expectEqualStrings(want, out.written());
    // read again, every line has its id, and giving them again changes nothing
    const again = try syntax.parse(a, gpa, &diags, 0, "a.river", out.written());
    try std.testing.expectEqual(@as(usize, 0), diags.errors());
    try std.testing.expectEqual(@as(usize, 0), (try missing(a, &.{again})).len);
    try std.testing.expectEqual(@as(u32, 0), (try give(a, &.{again})).added[0]);
}

test "a new id is never one the story already has, in any of its files" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var diags: syntax.Diagnostics = .{};
    defer diags.deinit(gpa);
    // the id `make` gives this line first is written already, on another file's line
    const taken = make("a", "", 0, "Go.", 0);
    const one = try syntax.parse(a, gpa, &diags, 0, "one.river", try std.mem.concat(a, u8, &.{ "== b\nStay. ^", &taken, "\n" }));
    const two = try syntax.parse(a, gpa, &diags, 1, "two.river", "== a\nGo.\n");
    const given = try give(a, &.{ one, two });
    try std.testing.expectEqual(@as(u32, 0), given.added[0]);
    try std.testing.expectEqual(@as(u32, 1), given.added[1]);
    const second = make("a", "", 0, "Go.", 1);
    try std.testing.expectEqualStrings(&second, given.files[1].rows[1].id[1..]);
}
