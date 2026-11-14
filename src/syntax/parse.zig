//! The reader: one `.river` file into its syntax tree.
//!
//! At indentation zero a row is a declaration (`cast:`, `extras:`,
//! `facts:`, `const:`, `extern:`), a section (`== name`), a part of one
//! (`= name`) or a statement of the section it is in. A `facts:` block
//! straight under a section's heading is the section's own. Inside, a
//! statement's body is the rows indented further than it.
//!
//! A row whose words begin with `[` is a row of brackets: each bracket a tag
//! or an effect. The rows of brackets first under a heading, a line, a choice
//! or a cast entry are its: its tags, and its effects. Anywhere else a row of
//! brackets is a step of effects, and a tag there is refused.

const std = @import("std");
const ast = @import("ast.zig");
const source = @import("source.zig");
const lines_mod = @import("lines.zig");
const expr = @import("expr.zig");
const text_mod = @import("text.zig");
const aegis = @import("aegis");

const Line = lines_mod.Line;
const Placed = source.Placed;
const Allocator = std.mem.Allocator;

pub const Error = error{OutOfMemory};
const Fail = error{ OutOfMemory, Invalid };

pub const max_depth = 32;

/// Reads `bytes` as file `file` of a story. Problems go to `diags`; what can
/// be read is returned even when some of it could not. The tree keeps every
/// row of the file, so it prints back as it was read.
pub fn parseFile(arena: Allocator, gpa: Allocator, diags: *source.Diagnostics, file: source.FileId, path: []const u8, bytes: []const u8) Error!ast.File {
    const whole: source.Span = .{ .file = file, .start = 0, .end = @intCast(@min(bytes.len, std.math.maxInt(u32))) };
    const split = lines_mod.split(arena, gpa, diags, file, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return .{ .path = path, .span = whole, .decls = &.{}, .sections = &.{} },
    };
    var r: Reader = .{ .arena = arena, .gpa = gpa, .diags = diags, .file = file, .lines = split.lines };
    var f = try r.readFile(path);
    f.span = whole;
    f.bom = split.bom;
    f.rows = split.rows;
    return f;
}

/// What is indented under a row, as it is read: its statements, and the tags of the rows of brackets that come
/// first, which are the row's.
const Body = struct {
    stmts: std.ArrayList(ast.Stmt) = .empty,
    tags: std.ArrayList(ast.Tag) = .empty,
    /// Whether every row read so far is a row of brackets, whose tags are the owner's.
    leading: bool,

    fn under(b: *const Body) Under {
        return .{ .stmts = b.stmts.items, .tags = b.tags.items };
    }
};

/// What a row has under it, read.
const Under = struct {
    stmts: []const ast.Stmt = &.{},
    tags: []const ast.Tag = &.{},

    fn empty(u: Under) bool {
        return u.stmts.len == 0 and u.tags.len == 0;
    }

    // Where the last of it ends, if anything is under the row.
    fn end(u: Under) ?u32 {
        var e: ?u32 = null;
        if (u.stmts.len > 0) e = u.stmts[u.stmts.len - 1].span.end;
        if (u.tags.len > 0) e = @max(e orelse 0, u.tags[u.tags.len - 1].span.end);
        return e;
    }
};

/// A bracket: a tag, or an effect.
const Item = union(enum) { tag: ast.Tag, effect: ast.Stmt };

const Reader = struct {
    arena: Allocator,
    gpa: Allocator,
    diags: *source.Diagnostics,
    file: source.FileId,
    lines: []const Line,
    i: usize = 0,
    /// The ids a line or a choice has taken, by where each starts; any other is refused once the file is read.
    taken: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn name(r: *const Reader, p: Placed) ast.Name {
        return .{ .text = p.text, .span = p.span(r.file) };
    }

    // From the start of line `first` to the end of line `last`'s words and id.
    fn over(r: *const Reader, first: Line, last: Line) source.Span {
        return first.span(r.file).join(last.span(r.file));
    }

    // From the start of `l` to the end of the last of `under`, the lines read under it.
    fn under(r: *const Reader, l: Line, lines: []const Line) source.Span {
        return if (lines.len == 0) l.span(r.file) else r.over(l, lines[lines.len - 1]);
    }

    fn report(r: *Reader, l: Line, comptime fmt: []const u8, args: anytype) Error!void {
        try r.diags.add(r.gpa, l.span(r.file), .err, fmt, args);
    }

    fn reportAt(r: *Reader, span: source.Span, comptime fmt: []const u8, args: anytype) Error!void {
        try r.diags.add(r.gpa, span, .err, fmt, args);
    }

    fn readFile(r: *Reader, path: []const u8) Error!ast.File {
        var decls: std.ArrayList(ast.Decl) = .empty;
        var sections: std.ArrayList(ast.Section) = .empty;
        const module = try r.moduleOf();
        while (r.i < r.lines.len) {
            const l = r.lines[r.i];
            if (l.indent != 0) {
                try r.report(l, "this line is indented but belongs to nothing", .{});
                r.i += 1;
                continue;
            }
            if (try r.decl(&decls)) continue;
            if (std.mem.startsWith(u8, l.text.text, "==")) {
                if (try r.section()) |s| try sections.append(r.arena, s);
                continue;
            }
            try r.report(l, "a story's lines belong in a section: `== name` comes first", .{});
            r.i += 1;
        }
        for (r.lines) |l| if (l.id.text.len > 0 and !r.taken.contains(l.id.at)) {
            try r.reportAt(l.id.span(r.file), "an id ends a line or a choice: `{s}` stands at the end of neither", .{l.id.text});
        };
        return .{ .path = path, .span = .none, .module = module, .decls = try decls.toOwnedSlice(r.arena), .sections = try sections.toOwnedSlice(r.arena) };
    }

    // `module name`, if the file's first line says so.
    fn moduleOf(r: *Reader) Error!?ast.Name {
        if (r.i >= r.lines.len or !std.mem.startsWith(u8, r.lines[r.i].text.text, "module ")) return null;
        const l = r.lines[r.i];
        r.i += 1;
        const n = l.text.from("module ".len).trim();
        if (!isName(n.text)) {
            try r.report(l, "a module is `module name`, its name letters, digits and `_`", .{});
            return null;
        }
        return r.name(n);
    }

    // ------------------------------------------------------------ declarations

    // The lines indented under the line at `r.i`, which is consumed.
    fn block(r: *Reader) []const Line {
        aegis.assert.invariant(r.i < r.lines.len, "the caller stands on a line");
        const head = r.lines[r.i];
        r.i += 1;
        const start = r.i;
        while (r.i < r.lines.len and r.lines[r.i].indent > head.indent) r.i += 1;
        return r.lines[start..r.i];
    }

    fn decl(r: *Reader, decls: *std.ArrayList(ast.Decl)) Error!bool {
        const l = r.lines[r.i];
        const t = l.text.text;
        if (std.mem.eql(u8, t, "cast:")) {
            const ls = r.block();
            try decls.append(r.arena, .{ .span = r.under(l, ls), .kind = .{ .cast = try r.castEntries(ls) } });
        } else if (std.mem.startsWith(u8, t, "extras:")) {
            r.i += 1;
            try decls.append(r.arena, .{ .span = l.span(r.file), .kind = .{ .extras = try r.list(l.text.from("extras:".len)) } });
        } else if (isFacts(t)) {
            const facts = try r.factsBlock();
            try decls.append(r.arena, .{ .span = facts.span, .kind = .{ .facts = facts } });
        } else if (std.mem.eql(u8, t, "const:")) {
            const ls = r.block();
            try decls.append(r.arena, .{ .span = r.under(l, ls), .kind = .{ .consts = try r.constEntries(ls) } });
        } else if (std.mem.eql(u8, t, "extern:")) {
            const ls = r.block();
            try decls.append(r.arena, .{ .span = r.under(l, ls), .kind = .{ .externs = try r.externEntries(ls) } });
        } else if (std.mem.startsWith(u8, t, "version:")) {
            r.i += 1;
            const n = std.fmt.parseInt(u32, std.mem.trim(u8, t["version:".len..], " "), 10) catch {
                try r.report(l, "a story's version is a whole number: `version: 3`", .{});
                return true;
            };
            if (n == 0) try r.report(l, "a story's version counts from 1", .{});
            try decls.append(r.arena, .{ .span = l.span(r.file), .kind = .{ .version = n } });
        } else return false;
        return true;
    }

    // `facts:` or `facts (scope):` at `r.i`, and the facts under it.
    fn factsBlock(r: *Reader) Error!ast.Facts {
        const l = r.lines[r.i];
        const scope = try r.scopeOf(l);
        const ls = r.block();
        return .{ .span = r.under(l, ls), .scope = if (scope) |s| s.name else null, .scope_span = if (scope) |s| s.span else null, .entries = try r.factEntries(ls) };
    }

    fn scopeOf(r: *Reader, l: Line) Error!?struct { name: ast.Name, span: source.Span } {
        const t = l.text.text;
        if (std.mem.eql(u8, t, "facts:")) return null;
        const close = std.mem.findScalar(u8, t, ')') orelse {
            try r.report(l, "`facts (` needs its scope and `):`", .{});
            return null;
        };
        if (!std.mem.endsWith(u8, t, "):")) try r.report(l, "a facts heading ends with `):`", .{});
        return .{ .name = r.name(l.text.cut("facts (".len, close).trim()), .span = l.text.cut("facts ".len, close + 1).span(r.file) };
    }

    // `a, b, c`: names.
    fn list(r: *Reader, words: Placed) Error![]const ast.Name {
        var out: std.ArrayList(ast.Name) = .empty;
        try r.listInto(&out, words);
        return out.toOwnedSlice(r.arena);
    }

    fn listInto(r: *Reader, out: *std.ArrayList(ast.Name), words: Placed) Error!void {
        const text = words.text;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= text.len) {
            const dot = i < text.len and std.mem.startsWith(u8, text[i..], "·");
            if (dot) try r.reportAt(words.cut(i, i + "·".len).span(r.file), "`·` is gone: separate a list with commas", .{});
            const sep: usize = if (i == text.len) 1 else if (text[i] == ',') 1 else if (dot) "·".len else 0;
            if (sep == 0) {
                i += 1;
                continue;
            }
            const item = words.cut(start, i).trim();
            if (item.text.len > 0) try out.append(r.arena, r.name(item));
            i += sep;
            start = i;
        }
    }

    // Each entry, `id "Name" — who they are`, and the rows of brackets under it, its tags.
    fn castEntries(r: *Reader, ls: []const Line) Error![]const ast.CastEntry {
        var out: std.ArrayList(ast.CastEntry) = .empty;
        var k: usize = 0;
        while (k < ls.len) {
            const l = ls[k];
            k += 1;
            var tags: std.ArrayList(ast.Tag) = .empty;
            var last = l;
            while (k < ls.len and ls[k].indent > l.indent) : (k += 1) {
                last = ls[k];
                if (!isBrackets(ls[k].text.text)) {
                    try r.report(ls[k], "under a cast entry stand its tags, in brackets: `[gender feminine]`", .{});
                    continue;
                }
                for (try r.brackets(ls[k])) |item| switch (item) {
                    .tag => |t| try tags.append(r.arena, t),
                    .effect => |s| try r.reportAt(s.span, "a cast entry takes tags, never effects", .{}),
                };
            }
            if (isBrackets(l.text.text)) {
                try r.report(l, "a cast entry's tags stand on a row indented under it", .{});
                continue;
            }
            const t = l.text;
            const sp = std.mem.findScalar(u8, t.text, ' ') orelse t.text.len;
            const rest = t.from(sp).trim().text;
            if (rest.len < 2 or rest[0] != '"') {
                try r.report(l, "a cast entry is `id \"Name\"`, with an optional `— who they are`", .{});
                continue;
            }
            const close = std.mem.findScalarPos(u8, rest, 1, '"') orelse {
                try r.report(l, "the name is not closed with `\"`", .{});
                continue;
            };
            const after = std.mem.trim(u8, rest[close + 1 ..], " ");
            const relation: ?[]const u8 = if (std.mem.startsWith(u8, after, "—")) std.mem.trim(u8, after["—".len..], " ") else if (after.len == 0) null else blk: {
                try r.report(l, "after the name comes `— who they are`, or nothing", .{});
                break :blk null;
            };
            try out.append(r.arena, .{ .span = r.over(l, last), .id = r.name(t.to(sp)), .display = rest[1..close], .relation = relation, .tags = try tags.toOwnedSlice(r.arena) });
        }
        return out.toOwnedSlice(r.arena);
    }

    fn factEntries(r: *Reader, ls: []const Line) Error![]const ast.Fact {
        var out: std.ArrayList(ast.Fact) = .empty;
        var k: usize = 0;
        while (k < ls.len) : (k += 1) {
            const l = ls[k];
            const colon = std.mem.findScalar(u8, l.text.text, ':') orelse {
                try r.report(l, "a fact is `name: type`", .{});
                continue;
            };
            // a type that ends with `,` goes on, on the lines under it
            var segments: std.ArrayList(Placed) = .empty;
            try segments.append(r.arena, l.text.from(colon + 1).trim());
            while (std.mem.endsWith(u8, segments.items[segments.items.len - 1].text, ",") and k + 1 < ls.len and ls[k + 1].indent > l.indent) {
                k += 1;
                try segments.append(r.arena, ls[k].text);
            }
            const last = &segments.items[segments.items.len - 1];
            // the marks after a type, in any order; a clock is the game's too, since only the game advances it
            var game = false;
            var clock = false;
            var moment = false;
            var role = false;
            var marks: std.ArrayList(source.Span) = .empty;
            while (true) {
                const m = takeMark(last, "(game)") orelse takeMark(last, "(clock)") orelse takeMark(last, "(moment)") orelse takeMark(last, "(role)") orelse break;
                switch (m.text[1]) {
                    'g' => game = true,
                    'c' => clock = true,
                    'm' => moment = true,
                    else => role = true,
                }
                try marks.insert(r.arena, 0, m.span(r.file));
            }
            const head = l.text.to(colon).trim();
            const n = if (std.mem.findScalar(u8, head.text, '(')) |p| head.to(p).trim() else head;
            if (text_mod.alternativesOf(n.text) != null) {
                try r.report(l, "`{s}` names alternatives in text, so it cannot name a fact", .{n.text});
                continue;
            }
            const bounds = if (segments.items.len > 1) null else r.boundsOf(l, last) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => continue,
            };
            const parsed = r.typeOf(l, segments.items[0], segments.items[1..]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => continue,
            };
            const key = r.keyOf(l, head) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => continue,
            };
            const typed = segments.items[0].span(r.file).join(last.span(r.file));
            try out.append(r.arena, .{
                .span = r.over(l, ls[k]),
                .name = r.name(n),
                .key = if (key) |x| x.type else null,
                .key_span = if (key) |x| x.span else null,
                .type = parsed,
                .type_span = typed,
                .bounds = bounds,
                .game = game or clock,
                .clock = clock,
                .moment = moment,
                .role = role,
                .marks = try marks.toOwnedSlice(r.arena),
            });
        }
        return out.toOwnedSlice(r.arena);
    }

    // What a fact is kept per, from `name(key)`: a kind of the host's things, `opinion(person)`, or an
    // enumeration's values, `mood(one of calm, angry)`; null for a fact with one value.
    fn keyOf(r: *Reader, l: Line, head: Placed) Fail!?struct { type: ast.Type, span: source.Span } {
        const open = std.mem.findScalar(u8, head.text, '(') orelse return null;
        if (!std.mem.endsWith(u8, head.text, ")")) {
            try r.report(l, "a fact kept per thing is `name(kind): type`", .{});
            return error.Invalid;
        }
        const inner = head.cut(open + 1, head.text.len - 1).trim();
        if (std.mem.startsWith(u8, inner.text, "one of ")) return .{ .type = try r.typeOf(l, inner, &.{}), .span = inner.span(r.file) };
        if (!isName(inner.text)) {
            try r.report(l, "`{s}` is not what a fact is kept per: a kind of the host's things, or `one of …`", .{inner.text});
            return error.Invalid;
        }
        return .{ .type = .{ .ref = r.name(inner) }, .span = inner.span(r.file) };
    }

    // `int from -100 to 100`: the bounds taken off the type, which is left `int`.
    fn boundsOf(r: *Reader, l: Line, t: *Placed) Fail!?ast.Bounds {
        if (!std.mem.startsWith(u8, t.text, "int from ")) return null;
        const rest = t.text["int from ".len..];
        const to = std.mem.find(u8, rest, " to ") orelse {
            try r.report(l, "a bounded int is `int from least to most`", .{});
            return error.Invalid;
        };
        const min = std.fmt.parseInt(i64, std.mem.trim(u8, rest[0..to], " "), 10) catch null;
        const max = std.fmt.parseInt(i64, std.mem.trim(u8, rest[to + " to ".len ..], " "), 10) catch null;
        if (min == null or max == null) {
            try r.report(l, "a bounded int's least and most are numbers: `int from -100 to 100`", .{});
            return error.Invalid;
        }
        if (min.? > max.?) {
            try r.report(l, "a bounded int's least, {d}, is past its most, {d}", .{ min.?, max.? });
            return error.Invalid;
        }
        const span = t.from("int".len).trim().span(r.file);
        t.* = t.to("int".len);
        return .{ .span = span, .min = min.?, .max = max.? };
    }

    // A type, `t`; a list's names go on in `more`, the lines under it.
    fn typeOf(r: *Reader, l: Line, t: Placed, more: []const Placed) Fail!ast.Type {
        const list_of = std.mem.startsWith(u8, t.text, "one of ") or std.mem.startsWith(u8, t.text, "set of ");
        if (list_of) {
            var names: std.ArrayList(ast.Name) = .empty;
            try r.listInto(&names, t.from("one of ".len));
            for (more) |m| try r.listInto(&names, m);
            const all = try names.toOwnedSlice(r.arena);
            return if (t.text[0] == 'o') .{ .one_of = all } else .{ .set_of = all };
        }
        if (more.len == 0) {
            if (std.mem.eql(u8, t.text, "bool")) return .boolean;
            if (std.mem.eql(u8, t.text, "int")) return .int;
            if (std.mem.eql(u8, t.text, "text")) return .text;
            if (std.mem.startsWith(u8, t.text, "ref of ")) {
                const kind = t.from("ref of ".len).trim();
                if (isName(kind.text)) return .{ .ref = r.name(kind) };
            }
        }
        try r.report(l, "`{s}` is not a type: bool, int, text, `one of …`, `set of …` or `ref of kind`", .{t.text});
        return error.Invalid;
    }

    fn constEntries(r: *Reader, ls: []const Line) Error![]const ast.Const {
        var out: std.ArrayList(ast.Const) = .empty;
        for (ls) |l| {
            const eq = std.mem.findScalar(u8, l.text.text, '=') orelse {
                try r.report(l, "a constant is `name = value`", .{});
                continue;
            };
            const value = expr.parse(r.arena, r.gpa, r.diags, r.file, l.text.from(eq + 1).trim()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => continue,
            };
            try out.append(r.arena, .{ .span = l.span(r.file), .name = r.name(l.text.to(eq).trim()), .value = value.* });
        }
        return out.toOwnedSlice(r.arena);
    }

    fn externEntries(r: *Reader, ls: []const Line) Error![]const ast.Extern {
        var out: std.ArrayList(ast.Extern) = .empty;
        for (ls) |l| {
            if (r.externOf(l)) |e| try out.append(r.arena, e) else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => {},
            }
        }
        return out.toOwnedSlice(r.arena);
    }

    // `name(params) [-> type] [(action)] [(reads family(keys))]`
    fn externOf(r: *Reader, l: Line) Fail!ast.Extern {
        const t = l.text;
        const open = std.mem.findScalar(u8, t.text, '(') orelse {
            try r.report(l, "an extern is `name(params) -> type`, or `name(params)` for an action", .{});
            return error.Invalid;
        };
        const close = parenClose(t.text, open) orelse {
            try r.report(l, "`(` is not closed", .{});
            return error.Invalid;
        };
        const ps = try r.paramsOf(l, t.cut(open + 1, close));
        var after = t.from(close + 1).trim();
        // what comes after the return type: `(action)`, `(reads …)`
        const marks_at = std.mem.find(u8, after.text, " (") orelse if (std.mem.startsWith(u8, after.text, "(")) @as(usize, 0) else after.text.len;
        var marks = after.from(marks_at).trim();
        after = after.to(marks_at).trim();
        var returns: ?ast.Type = null;
        var returns_span: ?source.Span = null;
        if (std.mem.startsWith(u8, after.text, "->")) {
            const returned = after.from(2).trim();
            returns = try r.typeOf(l, returned, &.{});
            returns_span = returned.span(r.file);
        } else if (after.text.len != 0) {
            try r.report(l, "after the parameters comes `-> type`, or nothing", .{});
            return error.Invalid;
        }
        var e: ast.Extern = .{ .span = l.span(r.file), .name = r.name(t.to(open).trim()), .params = ps, .returns = returns, .returns_span = returns_span };
        while (marks.text.len > 0) {
            if (marks.text[0] != '(') {
                try r.report(l, "after the parameters and the type come marks, each `(action)` or `(reads stamp)`, or nothing", .{});
                return error.Invalid;
            }
            const end = parenClose(marks.text, 0) orelse {
                try r.report(l, "`(` is not closed", .{});
                return error.Invalid;
            };
            const mark = marks.cut(1, end).trim();
            const whole = marks.to(end + 1).span(r.file);
            if (std.mem.eql(u8, mark.text, "action")) {
                if (returns == null) try r.report(l, "`(action)` marks an action with an outcome: it needs `-> type`", .{});
                e.action = true;
                e.action_span = whole;
            } else if (std.mem.startsWith(u8, mark.text, "reads ")) {
                e.reads = try r.stamp(l, mark.from("reads ".len).trim());
                e.reads_span = whole;
            } else {
                try r.report(l, "`({s})` is not a mark: `(action)` or `(reads stamp)`", .{mark.text});
                return error.Invalid;
            }
            marks = marks.from(end + 1).trim();
        }
        return e;
    }

    // Parameters: `type` alone, or `name: type, name: type`. A comma starts a new parameter only before `name:`,
    // so `one of a, b` keeps its commas.
    fn paramsOf(r: *Reader, l: Line, inner: Placed) Fail![]const ast.Param {
        var out: std.ArrayList(ast.Param) = .empty;
        const text = inner.text;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            if (i < text.len and !(text[i] == ',' and namesParam(text[i + 1 ..]))) continue;
            const piece = inner.cut(start, i).trim();
            if (piece.text.len == 0) {
                if (i < text.len or out.items.len > 0) try r.report(l, "a parameter is missing", .{});
                start = i + 1;
                continue;
            }
            var n: ?ast.Name = null;
            var ty = piece;
            if (std.mem.findScalar(u8, piece.text, ':')) |colon| {
                n = try r.word(l, piece.to(colon));
                ty = piece.from(colon + 1).trim();
            }
            try out.append(r.arena, .{ .span = piece.span(r.file), .name = n, .type = try r.typeOf(l, ty, &.{}), .type_span = ty.span(r.file) });
            start = i + 1;
        }
        return out.toOwnedSlice(r.arena);
    }

    // `family(key, key)` or `family`
    fn stamp(r: *Reader, l: Line, t: Placed) Fail!ast.Stamp {
        const open = std.mem.findScalar(u8, t.text, '(') orelse return .{ .span = t.span(r.file), .family = try r.word(l, t), .keys = &.{} };
        if (!std.mem.endsWith(u8, t.text, ")")) {
            try r.report(l, "a stamp is `family` or `family(parameter, …)`", .{});
            return error.Invalid;
        }
        return .{ .span = t.span(r.file), .family = try r.word(l, t.to(open)), .keys = try r.list(t.cut(open + 1, t.text.len - 1)) };
    }

    // ------------------------------------------------------------ brackets

    // The brackets of a row of them: each a tag or an effect, the row nothing else.
    fn brackets(r: *Reader, l: Line) Error![]const Item {
        var out: std.ArrayList(Item) = .empty;
        var rest = l.text;
        while (true) {
            rest = rest.trim();
            if (rest.text.len == 0) break;
            if (rest.text[0] != '[') {
                try r.reportAt(rest.span(r.file), "a row of brackets holds brackets alone: `{s}` is in none", .{rest.text});
                break;
            }
            const close = bracketClose(rest.text) orelse {
                try r.reportAt(rest.to(1).span(r.file), "`[` is not closed", .{});
                break;
            };
            if (try r.bracket(l, rest.to(close + 1))) |item| try out.append(r.arena, item);
            rest = rest.from(close + 1);
        }
        return out.toOwnedSlice(r.arena);
    }

    // One bracket, `[` to `]`: a tag, `[key value, value]`, or an effect, `[fact = value]` or `[action(…)]`.
    fn bracket(r: *Reader, l: Line, whole: Placed) Error!?Item {
        const inner = whole.cut(1, whole.text.len - 1).trim();
        if (dotAt(inner.text)) |at| {
            try r.reportAt(inner.cut(at, at + "·".len).span(r.file), "one tag to a bracket: `[a 1] [b 2]`, never `·`", .{});
            return null;
        }
        var n: usize = 0;
        while (n < inner.text.len and (expr.isWord(inner.text[n]) or inner.text[n] == '.')) n += 1;
        if (n == 0) {
            try r.reportAt(whole.span(r.file), "a bracket holds a tag, `[key value]`, or an effect, `[fact = value]` or `[action(…)]`", .{});
            return null;
        }
        const after = inner.from(n);
        const told = after.trim().text;
        const tells = (after.text.len > 0 and after.text[0] == '(') or std.mem.startsWith(u8, told, "+=") or std.mem.startsWith(u8, told, "-=") or
            (std.mem.startsWith(u8, told, "=") and !std.mem.startsWith(u8, told, "=="));
        if (tells) {
            const inside: Line = .{ .indent = l.indent, .text = inner, .id = inner.cut(0, 0) };
            const e = r.effect(inside, inner) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => return null,
            };
            return .{ .effect = .{ .span = whole.span(r.file), .tags = &.{}, .kind = .{ .effect = e } } };
        }
        const key = inner.to(n);
        if (!isName(key.text)) {
            try r.reportAt(key.span(r.file), "`{s}` is not a tag's key: a key is letters, digits and `_`", .{key.text});
            return null;
        }
        if (std.mem.eql(u8, key.text, "id")) {
            try r.reportAt(whole.span(r.file), "a line's id is `^{s}` at the end of its row, never `[id …]`", .{after.trim().text});
            return null;
        }
        var values: std.ArrayList([]const u8) = .empty;
        var spans: std.ArrayList(source.Span) = .empty;
        var vs = Split.init(after.text, ",");
        while (vs.next()) |v| {
            var value = after.cut(vs.last, vs.last + v.len).trim();
            if (value.text.len == 0) continue;
            const quoted = value.text.len >= 2 and value.text[0] == '"' and value.text[value.text.len - 1] == '"';
            if (quoted) value = value.cut(1, value.text.len - 1);
            try values.append(r.arena, value.text);
            try spans.append(r.arena, value.span(r.file));
        }
        return .{ .tag = .{ .span = whole.span(r.file), .key = r.name(key), .values = try values.toOwnedSlice(r.arena), .spans = try spans.toOwnedSlice(r.arena) } };
    }

    // The row of brackets at `r.i`, read into `body`: its tags are the owner's while every row before it was a row
    // of brackets too, and its effects are steps.
    fn bracketRow(r: *Reader, body: *Body) Error!void {
        const l = r.lines[r.i];
        const nested = r.block();
        if (nested.len > 0) try r.reportAt(r.over(nested[0], nested[nested.len - 1]), "nothing is indented under a row of brackets", .{});
        for (try r.brackets(l)) |item| switch (item) {
            .tag => |t| if (body.leading) try body.tags.append(r.arena, t) else try r.misplaced(t),
            .effect => |s| try body.stmts.append(r.arena, s),
        };
    }

    // A tag where nothing it could describe stands.
    fn misplaced(r: *Reader, t: ast.Tag) Error!void {
        try r.reportAt(t.span, "`[{s}]` is a tag, and a tag belongs to what it describes: indent it under that line, choice or heading", .{t.key.text});
    }

    // A line's or a choice's id, the first of its tags, and the line's own.
    fn idTag(r: *Reader, l: Line) Error!?ast.Tag {
        if (l.id.text.len == 0) return null;
        try r.taken.put(r.arena, l.id.at, {});
        const value = l.id.from(1);
        return .{
            .span = l.id.span(r.file),
            .key = .{ .text = "id", .span = l.id.to(1).span(r.file) },
            .values = try r.arena.dupe([]const u8, &.{value.text}),
            .spans = try r.arena.dupe(source.Span, &.{value.span(r.file)}),
        };
    }

    // ------------------------------------------------------------ sections

    fn section(r: *Reader) Error!?ast.Section {
        const l = r.lines[r.i];
        aegis.assert.invariant(std.mem.startsWith(u8, l.text.text, "=="), "the caller met the section's `==` line");
        r.i += 1;
        const head = l.text.from(2).trim();
        const paren = std.mem.findScalar(u8, head.text, '(');
        const n = head.to(paren orelse head.text.len).trim();
        if (n.text.len == 0 or !isName(n.text)) {
            try r.report(l, "a section is `== name`, its name letters, digits and `_`", .{});
            return null;
        }
        var kind: ast.Section.Kind = .scene;
        var kind_span: ?source.Span = null;
        if (paren) |p| {
            kind = try r.kindOf(l, head.from(p));
            if (std.mem.findScalarPos(u8, head.text, p, ')')) |close| kind_span = head.cut(p, close + 1).span(r.file);
        }
        // its tags, in brackets on the rows under its heading
        var heading: Body = .{ .leading = true };
        while (r.i < r.lines.len and r.lines[r.i].indent > 0 and isBrackets(r.lines[r.i].text.text)) try r.bracketRow(&heading);
        for (heading.stmts.items) |s| {
            try r.reportAt(s.span, "a section's heading takes tags: an effect is a step, written at the section's level", .{});
        }
        // the section's own facts come next
        var own: std.ArrayList(ast.Facts) = .empty;
        while (r.i < r.lines.len and r.lines[r.i].indent == 0 and isFacts(r.lines[r.i].text.text)) {
            try own.append(r.arena, try r.factsBlock());
        }
        var body: Body = .{ .leading = false };
        var subs: std.ArrayList(ast.Subsection) = .empty;
        while (r.i < r.lines.len) {
            const s = r.lines[r.i];
            if (s.indent == 0 and (std.mem.startsWith(u8, s.text.text, "==") or isDecl(s.text.text))) break;
            if (s.indent == 0 and std.mem.startsWith(u8, s.text.text, "= ")) {
                if (try r.subsection()) |sub| try subs.append(r.arena, sub);
                continue;
            }
            if (subs.items.len > 0 and s.indent == 0) {
                try r.report(s, "after a section's parts, every line belongs to a part", .{});
                r.i += 1;
                continue;
            }
            try r.into(&body, s.indent, 0);
        }
        return .{
            .span = r.over(l, r.lines[r.i - 1]),
            .name = r.name(n),
            .kind = kind,
            .kind_span = kind_span,
            .tags = try heading.tags.toOwnedSlice(r.arena),
            .facts = try own.toOwnedSlice(r.arena),
            .body = try body.stmts.toOwnedSlice(r.arena),
            .subsections = try subs.toOwnedSlice(r.arena),
        };
    }

    fn kindOf(r: *Reader, l: Line, t: Placed) Error!ast.Section.Kind {
        const close = std.mem.findScalar(u8, t.text, ')') orelse {
            try r.report(l, "`(` is not closed", .{});
            return .scene;
        };
        const inner = t.cut(1, close).trim();
        if (std.mem.eql(u8, inner.text, "pool")) return .{ .pool = 1 };
        if (std.mem.eql(u8, inner.text, "rules")) return .rules;
        if (std.mem.startsWith(u8, inner.text, "pool ")) {
            const n = std.fmt.parseInt(u16, std.mem.trim(u8, inner.text[5..], " "), 10) catch {
                try r.report(l, "a pool gives a number of lines: `(pool 2)`", .{});
                return .{ .pool = 1 };
            };
            return .{ .pool = n };
        }
        return .{ .other = r.name(inner) };
    }

    fn subsection(r: *Reader) Error!?ast.Subsection {
        const l = r.lines[r.i];
        aegis.assert.invariant(std.mem.startsWith(u8, l.text.text, "= "), "the caller met the subsection's `= ` line");
        var t = l.text.from(2).trim();
        const end = blk: {
            var j: usize = 0;
            while (j < t.text.len and expr.isWord(t.text[j])) j += 1;
            break :blk j;
        };
        const n = t.to(end);
        if (n.text.len == 0) {
            try r.report(l, "a part is `= name`", .{});
            _ = r.block();
            return null;
        }
        t = t.from(end).trim();
        var when: ?ast.Expr = null;
        var when_span: ?source.Span = null;
        if (std.mem.startsWith(u8, t.text, "when ")) {
            // the braces: none, or one not closed, is no condition
            const braces: ?[2]usize = found: {
                const o = std.mem.findScalar(u8, t.text, '{') orelse break :found null;
                break :found .{ o, text_mod.matching(t.text, o) orelse break :found null };
            };
            const open, const close = braces orelse {
                try r.report(l, "`when` takes `{{ condition }}`", .{});
                _ = r.block();
                return null;
            };
            when = if (expr.parse(r.arena, r.gpa, r.diags, r.file, t.cut(open + 1, close).trim())) |e| e.* else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => null,
            };
            when_span = t.cut(open, close + 1).span(r.file);
            t = t.from(close + 1).trim();
        }
        r.i += 1;
        var body: Body = .{ .leading = true };
        if (r.i < r.lines.len and r.lines[r.i].indent > l.indent) {
            const base = r.lines[r.i].indent;
            while (r.i < r.lines.len and r.lines[r.i].indent >= base) try r.into(&body, base, 1);
        }
        var stmts = body.stmts.items;
        var tags = body.tags.items;
        if (t.text.len > 0) {
            // a candidate written on its one row, which has the row's id and what is under the row
            const one = try r.arena.alloc(ast.Stmt, 1);
            const inline_line: Line = .{ .indent = l.indent, .text = t, .id = l.id };
            stmts = if (try r.stmtOf(inline_line, body.under())) |st| blk: {
                one[0] = st;
                break :blk one;
            } else &.{};
            tags = &.{};
        }
        return .{
            .span = r.over(l, r.lines[r.i - 1]),
            .name = r.name(n),
            .when = when,
            .when_span = when_span,
            .tags = tags,
            .body = stmts,
        };
    }

    // ------------------------------------------------------------ statements

    // The row at `r.i` read into `body`: a row of brackets, or a statement; `{ else }` joins the `{ condition }`
    // block before it.
    fn into(r: *Reader, body: *Body, indent: u32, depth: usize) Error!void {
        const l = r.lines[r.i];
        if (l.indent == indent and isBrackets(l.text.text)) return r.bracketRow(body);
        body.leading = false;
        const is_else = l.indent == indent and isElse(l.text.text);
        const st = try r.stmt(indent, depth) orelse return;
        if (!is_else) return body.stmts.append(r.arena, st);
        const items = body.stmts.items;
        const last = if (items.len > 0) &items[items.len - 1] else null;
        if (last == null or last.?.kind != .cond or last.?.kind.cond.body.len == 0 or last.?.kind.cond.else_span != null or last.?.kind.cond.on_row) {
            return r.report(l, "`{{ else }}` follows a `{{ condition }}` block, at its indentation", .{});
        }
        last.?.kind.cond.otherwise = st.kind.cond.body;
        last.?.kind.cond.else_span = st.kind.cond.cond_span;
        last.?.span = last.?.span.join(st.span);
    }

    // The statement at `r.i`, at indentation `indent`, with what is under it.
    fn stmt(r: *Reader, indent: u32, depth: usize) Error!?ast.Stmt {
        aegis.assert.invariant(r.i < r.lines.len, "the caller stands on a line");
        const l = r.lines[r.i];
        if (l.indent != indent) {
            try r.report(l, "this line's indentation matches nothing above it", .{});
            r.i += 1;
            return null;
        }
        if (depth > max_depth) {
            try r.report(l, "the story nests deeper than {d}", .{max_depth});
            _ = r.block();
            return null;
        }
        r.i += 1;
        var body: Body = .{ .leading = true };
        if (r.i < r.lines.len and r.lines[r.i].indent > indent) {
            const base = r.lines[r.i].indent;
            while (r.i < r.lines.len and r.lines[r.i].indent >= base) {
                try r.into(&body, base, depth + 1);
            }
        }
        return r.stmtOf(l, body.under());
    }

    fn stmtOf(r: *Reader, l: Line, under_row: Under) Error!?ast.Stmt {
        return r.stmtFrom(l, under_row) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return null,
        };
    }

    // The statement on `l`, with what is under it. A line or a choice has its id and the tags first under it; a
    // statement written after a condition or a gather on the row has them, and the condition or the gather none.
    fn stmtFrom(r: *Reader, l: Line, under_row: Under) Fail!ast.Stmt {
        const kind = try r.kindOfStmt(l, under_row);
        const owns = kind == .line or kind == .choice;
        const end = @max(l.span(r.file).end, under_row.end() orelse 0);
        const span: source.Span = .{ .file = r.file, .start = l.text.at, .end = end };
        if (!owns) return .{ .span = span, .tags = &.{}, .kind = kind };
        var tags: std.ArrayList(ast.Tag) = .empty;
        if (try r.idTag(l)) |id| try tags.append(r.arena, id);
        try tags.appendSlice(r.arena, under_row.tags);
        return .{ .span = span, .tags = try tags.toOwnedSlice(r.arena), .kind = kind };
    }

    fn kindOfStmt(r: *Reader, l: Line, under_row: Under) Fail!@FieldType(ast.Stmt, "kind") {
        const t = l.text;
        if (std.mem.startsWith(u8, t.text, "->") or std.mem.eql(u8, t.text, "<-")) return r.leaf(l, under_row, .{ .flow = try r.flowOf(l, t) });
        if (t.text.len > 0 and t.text[0] == '~') {
            try r.report(l, "`~` is gone: an effect is written in brackets, `[{s}]`", .{std.mem.trim(u8, t.text[1..], " ")});
            return error.Invalid;
        }
        if (std.mem.startsWith(u8, t.text, "* ") or std.mem.startsWith(u8, t.text, "+ ")) return .{ .choice = try r.choice(l, under_row) };
        if (std.mem.eql(u8, t.text, "-") or std.mem.startsWith(u8, t.text, "- ")) return .{ .gather = try r.gather(l, under_row) };
        if (t.text.len > 0 and t.text[0] == '{') {
            const close = text_mod.matching(t.text, 0) orelse {
                try r.report(l, "`{{` is not closed", .{});
                return error.Invalid;
            };
            const braces = t.to(close + 1).span(r.file);
            if (isElse(t.text)) return .{ .cond = .{ .cond = .{ .span = t.span(r.file), .kind = .{ .boolean = true } }, .cond_span = braces, .body = try r.gated(under_row) } };
            if (!text_mod.choosesWords(t.text, 0, close)) {
                const cond = try expr.parse(r.arena, r.gpa, r.diags, r.file, t.cut(1, close).trim());
                const rest = t.from(close + 1).trim();
                if (rest.text.len == 0) return .{ .cond = .{ .cond = cond.*, .cond_span = braces, .body = try r.gated(under_row) } };
                const inner: Line = .{ .indent = l.indent, .text = rest, .id = l.id };
                const one = try r.arena.alloc(ast.Stmt, 1);
                one[0] = try r.stmtFrom(inner, under_row);
                return .{ .cond = .{ .cond = cond.*, .cond_span = braces, .body = one, .on_row = true } };
            }
            if (close == t.text.len - 1 and std.mem.find(u8, t.text, "->") != null) return r.leaf(l, under_row, .{ .flow_if = try r.flowIf(l, t.cut(1, close), braces) });
        }
        for (under_row.stmts) |child| if (child.kind != .effect) {
            try r.diags.add(r.gpa, child.span, .err, "only brackets can be indented under a line: its tags, and its effects, which happen when it is said", .{});
            return error.Invalid;
        };
        var ln = try r.line(l);
        ln.effects = under_row.stmts;
        return .{ .line = ln };
    }

    // What a condition gates: the statements under it; a tag there describes nothing.
    fn gated(r: *Reader, under_row: Under) Error![]const ast.Stmt {
        for (under_row.tags) |t| try r.misplaced(t);
        return under_row.stmts;
    }

    // A statement that takes nothing under it.
    fn leaf(r: *Reader, l: Line, under_row: Under, kind: @FieldType(ast.Stmt, "kind")) Fail!@FieldType(ast.Stmt, "kind") {
        if (!under_row.empty()) {
            try r.report(l, "nothing can be indented under this line", .{});
            return error.Invalid;
        }
        return kind;
    }

    fn target(r: *Reader, l: Line, t: Placed) Fail!ast.Name {
        const n = t.trim();
        if (!isQualified(n.text)) {
            try r.report(l, "`{s}` is not a section to go to", .{n.text});
            return error.Invalid;
        }
        return r.name(n);
    }

    fn effect(r: *Reader, l: Line, t: Placed) Fail!ast.Effect {
        const span = t.span(r.file);
        if (std.mem.find(u8, t.text, "+=")) |k| return .{ .add = try r.change(l, t, k) };
        if (std.mem.find(u8, t.text, "-=")) |k| return .{ .remove = try r.change(l, t, k) };
        if (std.mem.findScalar(u8, t.text, '=')) |k| {
            const value = try expr.parse(r.arena, r.gpa, r.diags, r.file, t.from(k + 1).trim());
            const w = try r.written(l, t.to(k));
            return .{ .set = .{ .span = span, .fact = w.fact, .key = w.key, .value = value.* } };
        }
        const call = try expr.parse(r.arena, r.gpa, r.diags, r.file, t.trim());
        if (call.kind != .call) {
            try r.report(l, "an effect is `[fact = value]`, `[set += item]`, `[set -= item]` or `[action(…)]`", .{});
            return error.Invalid;
        }
        return .{ .call = call.kind.call };
    }

    // `fact += amount` or `fact -= amount`, the operator at `k`: an item's name or a number, and nothing more.
    fn change(r: *Reader, l: Line, t: Placed, k: usize) Fail!ast.Change {
        const amount = try expr.parse(r.arena, r.gpa, r.diags, r.file, t.from(k + 2).trim());
        if (amount.kind != .name and amount.kind != .int) {
            try r.diags.add(r.gpa, amount.span, .err, "`+=` and `-=` take an item, a number or a constant, never an expression", .{});
            return error.Invalid;
        }
        const dest = try r.written(l, t.to(k));
        return .{ .span = t.span(r.file), .fact = dest.fact, .key = dest.key, .amount = amount.* };
    }

    // What an effect writes: a fact, or a fact kept per thing and the key it writes, `opinion(wife)`.
    fn written(r: *Reader, l: Line, t: Placed) Fail!struct { fact: ast.Name, key: ?*const ast.Expr } {
        const w = t.trim();
        const open = std.mem.findScalar(u8, w.text, '(') orelse return .{ .fact = try r.fact(l, w), .key = null };
        if (!std.mem.endsWith(u8, w.text, ")")) {
            try r.report(l, "a fact kept per thing is written `name(key)`", .{});
            return error.Invalid;
        }
        const key = try expr.parse(r.arena, r.gpa, r.diags, r.file, w.cut(open + 1, w.text.len - 1).trim());
        return .{ .fact = try r.fact(l, w.to(open)), .key = key };
    }

    // The fact an effect writes, which another module's may be: `harbour.met`.
    fn fact(r: *Reader, l: Line, t: Placed) Fail!ast.Name {
        const w = t.trim();
        if (!isQualified(w.text)) {
            try r.report(l, "`{s}` is not a fact's name", .{w.text});
            return error.Invalid;
        }
        return r.name(w);
    }

    fn word(r: *Reader, l: Line, t: Placed) Fail!ast.Name {
        const w = t.trim();
        if (!isName(w.text)) {
            try r.report(l, "`{s}` is not a name", .{w.text});
            return error.Invalid;
        }
        return r.name(w);
    }

    fn choice(r: *Reader, l: Line, under_row: Under) Fail!ast.Choice {
        if (l.id.text.len > 0) try r.taken.put(r.arena, l.id.at, {});
        var t = l.text.from(2).trim();
        var cond: ?ast.Expr = null;
        var cond_span: ?source.Span = null;
        if (t.text.len > 0 and t.text[0] == '{') {
            const close = text_mod.matching(t.text, 0) orelse {
                try r.report(l, "`{{` is not closed", .{});
                return error.Invalid;
            };
            if (!text_mod.choosesWords(t.text, 0, close)) {
                cond = (try expr.parse(r.arena, r.gpa, r.diags, r.file, t.cut(1, close).trim())).*;
                cond_span = t.to(close + 1).span(r.file);
                t = t.from(close + 1).trim();
            }
        }
        const text = try text_mod.parse(r.arena, r.gpa, r.diags, r.file, t);
        return .{ .sticky = l.text.text[0] == '+', .cond = cond, .cond_span = cond_span, .text = text, .body = under_row.stmts };
    }

    fn gather(r: *Reader, l: Line, under_row: Under) Fail!ast.Gather {
        var t = l.text.from(1).trim();
        var label: ?ast.Name = null;
        var label_span: ?source.Span = null;
        if (t.text.len > 0 and t.text[0] == '(') {
            const close = std.mem.findScalar(u8, t.text, ')') orelse {
                try r.report(l, "`(` is not closed", .{});
                return error.Invalid;
            };
            label = try r.word(l, t.cut(1, close));
            label_span = t.to(close + 1).span(r.file);
            t = t.from(close + 1).trim();
        }
        if (t.text.len == 0) {
            if (!under_row.empty()) {
                try r.report(l, "nothing can be indented under a gather", .{});
                return error.Invalid;
            }
            return .{ .label = label, .label_span = label_span, .then = null };
        }
        const then = try r.arena.create(ast.Stmt);
        then.* = try r.stmtFrom(.{ .indent = l.indent, .text = t, .id = l.id }, under_row);
        return .{ .label = label, .label_span = label_span, .then = then };
    }

    fn flowIf(r: *Reader, l: Line, inner: Placed, braces: source.Span) Fail!ast.FlowIf {
        const colon = std.mem.findScalar(u8, inner.text, ':') orelse unreachable; // choosesWords said so
        const bar = std.mem.findScalarPos(u8, inner.text, colon, '|') orelse {
            try r.report(l, "a flow chosen by a condition is `{{ condition: -> a | -> b }}`", .{});
            return error.Invalid;
        };
        const cond = try expr.parse(r.arena, r.gpa, r.diags, r.file, inner.to(colon).trim());
        return .{ .span = braces, .cond = cond.*, .then = try r.flowOf(l, inner.cut(colon + 1, bar)), .otherwise = try r.flowOf(l, inner.from(bar + 1)) };
    }

    // `-> name`, `-> name ->` or `<-`.
    fn flowOf(r: *Reader, l: Line, t: Placed) Fail!ast.Flow {
        const s = t.trim();
        const span = s.span(r.file);
        if (std.mem.eql(u8, s.text, "<-")) return .{ .span = span, .kind = .ret };
        if (std.mem.startsWith(u8, s.text, "->>")) {
            try r.reportAt(span, "`->>` is gone: a call is `-> {s} ->`", .{std.mem.trim(u8, s.text[3..], " ")});
            return error.Invalid;
        }
        if (!std.mem.startsWith(u8, s.text, "->")) {
            try r.report(l, "`{s}` is not a flow: `-> name`, `-> name ->` or `<-`", .{s.text});
            return error.Invalid;
        }
        const rest = s.from(2).trim();
        if (std.mem.endsWith(u8, rest.text, "->")) return .{ .span = span, .kind = .{ .call = try r.target(l, rest.to(rest.text.len - 2)) } };
        return .{ .span = span, .kind = .{ .jump = try r.target(l, rest) } };
    }

    fn line(r: *Reader, l: Line) Fail!ast.Line {
        if (l.id.text.len > 0) try r.taken.put(r.arena, l.id.at, {});
        const t = l.text;
        if (t.text.len > 0 and t.text[0] == '[') {
            try r.report(l, "brackets stand on a row of their own, under what they belong to; `\\[` writes the mark", .{});
            return error.Invalid;
        }
        var ln: ast.Line = .{ .speaker = null, .text = &.{}, .effects = &.{} };
        var rest = t;
        if (speakerOf(t.text)) |sp| {
            ln.speaker = r.name(t.to(sp.name));
            if (sp.delivery) |d| {
                const words = t.cut(d[0] + 1, d[1]).trim();
                if (words.text.len == 0) {
                    try r.reportAt(t.cut(d[0], d[1] + 1).span(r.file), "a delivery says how the line is said: `NAME (quietly):`", .{});
                    return error.Invalid;
                }
                ln.delivery = .{ .span = t.cut(d[0], d[1] + 1).span(r.file), .words = r.name(words) };
            }
            rest = t.from(sp.colon + 1).trim();
        }
        ln.text = try text_mod.parse(r.arena, r.gpa, r.diags, r.file, rest);
        return ln;
    }
};

// Takes `m` off the end of `t`, if it is there, and gives where it was.
fn takeMark(t: *Placed, m: []const u8) ?Placed {
    if (!std.mem.endsWith(u8, t.text, m)) return null;
    const mark = t.from(t.text.len - m.len);
    t.* = t.to(t.text.len - m.len).trim();
    return mark;
}

// The `)` that closes the `(` at `open`.
fn parenClose(t: []const u8, open: usize) ?usize {
    aegis.assert.invariant(t[open] == '(', "`open` is a `(`");
    var depth: usize = 0;
    for (t[open..], open..) |c, i| switch (c) {
        '(' => depth += 1,
        ')' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        else => {},
    };
    return null;
}

// The `]` that closes the bracket `t` begins with, outside quotes.
fn bracketClose(t: []const u8) ?usize {
    var quoted = false;
    for (t, 0..) |c, i| {
        if (c == '"') quoted = !quoted;
        if (!quoted and c == ']') return i;
    }
    return null;
}

// Where a `·` outside quotes is, if one is.
fn dotAt(t: []const u8) ?usize {
    var quoted = false;
    for (t, 0..) |c, i| {
        if (c == '"') quoted = !quoted;
        if (!quoted and std.mem.startsWith(u8, t[i..], "·")) return i;
    }
    return null;
}

// Whether what follows a comma names a parameter: `name:`.
fn namesParam(t: []const u8) bool {
    const s = std.mem.trimStart(u8, t, " ");
    var n: usize = 0;
    while (n < s.len and expr.isWord(s[n])) n += 1;
    return n > 0 and n < s.len and s[n] == ':';
}

/// A speaker before a line's words: where its name ends, its delivery's parentheses if it has one, and its colon.
pub const Speaker = struct { name: usize, delivery: ?[2]usize = null, colon: usize };

/// A speaker is capitals, digits, `_` and spaces, then `:` and a space: `DAD: Go.`, `A CELLIST: …`; a delivery in
/// parentheses may stand between the name and the colon, `DAD (quietly): …`.
pub fn speakerOf(t: []const u8) ?Speaker {
    if (t.len < 2 or !std.ascii.isUpper(t[0])) return null;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (c == ':') {
            if (!colonEnds(t, i) or t[i - 1] == ' ') return null;
            return .{ .name = i, .colon = i };
        }
        if (c == '(') {
            const name = std.mem.trimEnd(u8, t[0..i], " ").len;
            const close = std.mem.findScalarPos(u8, t, i, ')') orelse return null;
            if (close + 1 >= t.len or t[close + 1] != ':' or !colonEnds(t, close + 1)) return null;
            if (std.mem.findScalar(u8, t[i + 1 .. close], '(') != null) return null;
            return .{ .name = name, .delivery = .{ i, close }, .colon = close + 1 };
        }
        if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_' or c == ' ')) return null;
    }
    return null;
}

// Whether the `:` at `i` ends a speaker: a space or the end after it.
fn colonEnds(t: []const u8, i: usize) bool {
    return i + 1 == t.len or t[i + 1] == ' ';
}

fn isElse(t: []const u8) bool {
    if (t.len < 2 or t[0] != '{' or t[t.len - 1] != '}') return false;
    return std.mem.eql(u8, std.mem.trim(u8, t[1 .. t.len - 1], " "), "else");
}

// A row of brackets: its words begin with `[`.
fn isBrackets(t: []const u8) bool {
    return t.len > 0 and t[0] == '[';
}

// A name, or `module.name`.
fn isQualified(s: []const u8) bool {
    const dot = std.mem.findScalar(u8, s, '.') orelse return isName(s);
    return isName(s[0..dot]) and isName(s[dot + 1 ..]);
}

fn isName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!expr.isWord(c)) return false;
    return true;
}

fn isFacts(t: []const u8) bool {
    return std.mem.eql(u8, t, "facts:") or std.mem.startsWith(u8, t, "facts (");
}

fn isDecl(t: []const u8) bool {
    return std.mem.eql(u8, t, "cast:") or std.mem.startsWith(u8, t, "extras:") or std.mem.eql(u8, t, "facts:") or
        std.mem.startsWith(u8, t, "facts (") or std.mem.eql(u8, t, "const:") or std.mem.eql(u8, t, "extern:") or
        std.mem.startsWith(u8, t, "version:");
}

// Splits on a separator outside quotes.
const Split = struct {
    s: []const u8,
    sep: []const u8,
    i: usize = 0,
    /// Where the piece `next` last gave starts.
    last: usize = 0,
    done: bool = false,

    fn init(s: []const u8, sep: []const u8) Split {
        return .{ .s = s, .sep = sep };
    }

    fn next(p: *Split) ?[]const u8 {
        if (p.done) return null;
        var quoted = false;
        p.last = p.i;
        var j = p.i;
        while (j < p.s.len) {
            if (p.s[j] == '"') quoted = !quoted;
            if (!quoted and std.mem.startsWith(u8, p.s[j..], p.sep)) {
                const out = p.s[p.i..j];
                p.i = j + p.sep.len;
                return out;
            }
            j += 1;
        }
        p.done = true;
        return p.s[p.i..];
    }
};

test "a speaker is capitals before a colon, a delivery in parentheses between" {
    try std.testing.expectEqual(@as(usize, 3), speakerOf("DAD: Go.").?.name);
    try std.testing.expectEqual(@as(usize, 9), speakerOf("A CELLIST: She stopped us.").?.colon);
    try std.testing.expectEqual(@as(?Speaker, null), speakerOf("22:31. The bus stop is four minutes away."));
    try std.testing.expectEqual(@as(?Speaker, null), speakerOf("Royal College of Music, 1958: “…”"));
    const astro = speakerOf("ASTRO (laughing manically): Not even close.").?;
    try std.testing.expectEqual(@as(usize, 5), astro.name);
    try std.testing.expectEqual([2]usize{ 6, 25 }, astro.delivery.?);
    try std.testing.expectEqual(@as(usize, 26), astro.colon);
    // capitals and words in parentheses, with no colon after them, are narration
    try std.testing.expectEqual(@as(?Speaker, null), speakerOf("NASA (the agency) said nothing."));
}

test "a small story reads into sections, statements and tags" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    const story =
        \\cast:
        \\  dad  "Dad"  — Frank, her father
        \\facts (player):
        \\  carried: set of play, gave,
        \\           hands
        \\== kitchen_1985
        \\  [talk]
        \\DAD: Go.
        \\- (ask)
        \\* { carried has play } You could still play, Dad.
        \\  [known play]
        \\  DAD: Who'd listen?
        \\  -> ask
        \\* Pick up the case.
        \\  -> fork_1985
    ;
    const f = try parseFile(arena.allocator(), gpa, &diags, 0, "kitchen.river", story);
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
    try std.testing.expectEqual(@as(usize, 2), f.decls.len);
    try std.testing.expectEqual(@as(usize, 3), f.decls[1].kind.facts.entries[0].type.set_of.len);
    try expectWritten(story, f.decls[1].kind.facts.entries[0].type.set_of[2].span, "hands");
    const s = f.sections[0];
    try std.testing.expectEqualStrings("kitchen_1985", s.name.text);
    try std.testing.expectEqualStrings("talk", s.tags[0].key.text);
    try std.testing.expectEqual(@as(usize, 4), s.body.len);
    const c = s.body[2].kind.choice;
    try std.testing.expect(c.cond != null);
    try std.testing.expectEqual(@as(usize, 2), c.body.len);
    try std.testing.expectEqualStrings("known", s.body[2].tags[0].key.text);
}

// `span` is where `words` are written in `text`.
fn expectWritten(text: []const u8, span: source.Span, words: []const u8) !void {
    try std.testing.expectEqualStrings(words, text[span.start..span.end]);
}

test "a span is the range its words are written in, past the spaces trimmed" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    const story =
        \\== a
        \\{ met }  Go.
        \\[carried += play]
        \\* {  met } Stay.
        \\  -> end
    ;
    const f = try parseFile(arena.allocator(), gpa, &diags, 0, "a.river", story);
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
    const body = f.sections[0].body;
    try expectWritten(story, body[0].kind.cond.cond.span, "met");
    try expectWritten(story, body[0].kind.cond.body[0].span, "Go.");
    try expectWritten(story, body[1].kind.effect.add.fact.span, "carried");
    try expectWritten(story, body[1].kind.effect.add.amount.span, "play");
    try expectWritten(story, body[2].kind.choice.cond.?.span, "met");
    try expectWritten(story, body[2].span, "* {  met } Stay.\n  -> end");
}

test "a module, clocks, refs and the host's vocabulary with outcomes and stamps" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    const story =
        \\module harbour
        \\facts (world):
        \\  day:    int              (clock)
        \\  target: ref of person
        \\extern:
        \\  lived(one of stay, go) -> bool
        \\  count(kind: ref of item_kind) -> int   (reads stock(kind))
        \\  persuade(who: ref of person, against: int) -> one of yes, no   (action)
        \\  take(kind: ref of item_kind, n: int)
        \\== a
        \\  [pool wake_night] [then dawn]
        \\-> end
    ;
    const f = try parseFile(arena.allocator(), gpa, &diags, 0, "harbour.river", story);
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
    try std.testing.expectEqualStrings("harbour", f.module.?.text);
    const day = f.decls[0].kind.facts.entries[0];
    try std.testing.expect(day.clock and day.game);
    try std.testing.expectEqualStrings("person", f.decls[0].kind.facts.entries[1].type.ref.text);
    const ext = f.decls[1].kind.externs;
    try std.testing.expectEqual(@as(usize, 1), ext[0].params.len);
    try std.testing.expectEqual(@as(usize, 2), ext[0].params[0].type.one_of.len);
    try std.testing.expectEqualStrings("kind", ext[1].params[0].name.?.text);
    try std.testing.expectEqualStrings("stock", ext[1].reads.?.family.text);
    try std.testing.expectEqualStrings("kind", ext[1].reads.?.keys[0].text);
    try std.testing.expect(ext[2].action and ext[2].returns != null and ext[2].params.len == 2);
    try std.testing.expect(!ext[3].action and ext[3].returns == null and ext[3].params.len == 2);
    try expectWritten(story, ext[1].reads.?.span, "stock(kind)");
    try expectWritten(story, ext[2].params[1].span, "against: int");
    // a tag's span is where it is written, its key's where the key is, and each value's where it is
    try expectWritten(story, f.sections[0].tags[0].span, "[pool wake_night]");
    try expectWritten(story, f.sections[0].tags[1].key.span, "then");
    try expectWritten(story, f.sections[0].tags[0].at(0), "wake_night");
    try expectWritten(story, f.sections[0].tags[1].at(0), "dawn");
}

test "a tag's values are placed where they are written, inside their quotes" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    const story = "== a\n  [heard piano,  door] [title \"Who · was he?\"]\n-> end";
    const f = try parseFile(arena.allocator(), gpa, &diags, 0, "a.river", story);
    const tags = f.sections[0].tags;
    try std.testing.expectEqualStrings("door", tags[0].values[1]);
    try expectWritten(story, tags[0].at(0), "piano");
    try expectWritten(story, tags[0].at(1), "door");
    try std.testing.expectEqualStrings("Who · was he?", tags[1].values[0]);
    try expectWritten(story, tags[1].at(0), "Who · was he?");
    try expectWritten(story, tags[1].span, "[title \"Who · was he?\"]");
}

test "a section's own facts come straight under its heading, its roles marked" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    const story =
        \\== the_stranger (quest)
        \\facts:
        \\  stranger: ref of person   (role)
        \\facts (player):
        \\  asked: set of margaret, tom
        \\= noticed
        \\facts:
        \\  later: bool
    ;
    const f = try parseFile(arena.allocator(), gpa, &diags, 0, "a.river", story);
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
    const s = f.sections[0];
    try std.testing.expectEqual(@as(usize, 2), s.facts.len);
    try std.testing.expect(s.facts[0].entries[0].role and !s.facts[0].entries[0].game);
    try std.testing.expectEqualStrings("player", s.facts[1].scope.?.text);
    // after a part, a facts block is the story's own again
    try std.testing.expectEqual(@as(usize, 1), f.decls.len);
}

test "an int changes by a number or a constant, never by an expression" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    const story =
        \\== a
        \\[ryuji_points += 2]
        \\[ryuji_points -= penalty]
        \\[ryuji_points += 2 and 3]
        \\-> end
    ;
    const f = try parseFile(arena.allocator(), gpa, &diags, 0, "a.river", story);
    const body = f.sections[0].body;
    try std.testing.expectEqual(@as(i64, 2), body[0].kind.effect.add.amount.kind.int);
    try std.testing.expectEqualStrings("penalty", body[1].kind.effect.remove.amount.kind.name);
    try std.testing.expectEqual(@as(usize, 1), diags.errors());
}

test "else follows a condition block, and nothing else" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    const story =
        \\== a
        \\{ met }
        \\  STRANGER: Same hands.
        \\{ else }
        \\  He doesn't look up.
        \\  -> end
        \\{ met } Go.
        \\{ else }
        \\  Stay.
    ;
    const f = try parseFile(arena.allocator(), gpa, &diags, 0, "a.river", story);
    const body = f.sections[0].body;
    try std.testing.expectEqual(@as(usize, 2), body.len);
    try std.testing.expectEqual(@as(usize, 1), body[0].kind.cond.body.len);
    try std.testing.expectEqual(@as(usize, 2), body[0].kind.cond.otherwise.len);
    // an else after a condition written on its line is refused
    try std.testing.expectEqual(@as(usize, 1), diags.errors());
}

test "any bytes are read or refused, never crash" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [512]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var diags: source.Diagnostics = .{};
            defer diags.deinit(std.testing.allocator);
            // a file always reads: what is wrong goes to the diagnostics, and only memory can fail
            _ = try parseFile(arena.allocator(), std.testing.allocator, &diags, 0, "fuzz.river", bytes);
        }
    }.one, .{});
}

test "each mark design B refuses is reported where it is written, naming the form it means" {
    const cases = [_]struct { text: []const u8, line: u32, col: u32, message: []const u8 }{
        .{ .text = "== a\n~ x = 1\n", .line = 2, .col = 1, .message = "`~` is gone: an effect is written in brackets, `[x = 1]`" },
        .{ .text = "== a\n->> b\n", .line = 2, .col = 1, .message = "`->>` is gone: a call is `-> b ->`" },
        .{ .text = "== a\n{ x: ->> b | -> c }\n", .line = 2, .col = 6, .message = "`->>` is gone: a call is `-> b ->`" },
        .{ .text = "== a\nGo.   # pause 0.3\n", .line = 2, .col = 7, .message = "`#` tags are gone: write `[key value]` on a row under the line, or `\\#` for the mark" },
        .{ .text = "== a\n{n -> one: x | other: y}.\n", .line = 2, .col = 4, .message = "a selection is `{n as one: … | other: …}`: `as`, not `->`" },
        .{ .text = "extras: a · b\n", .line = 1, .col = 11, .message = "`·` is gone: separate a list with commas" },
        .{ .text = "== a\n  [a 1 · b 2]\n", .line = 2, .col = 8, .message = "one tag to a bracket: `[a 1] [b 2]`, never `·`" },
        .{ .text = "== a\nGo.\n  [id k1]\n", .line = 3, .col = 3, .message = "a line's id is `^k1` at the end of its row, never `[id …]`" },
        .{ .text = "== a\n  [x\n", .line = 2, .col = 3, .message = "`[` is not closed" },
        .{ .text = "== a\n  [a] b\n", .line = 2, .col = 7, .message = "a row of brackets holds brackets alone: `b` is in none" },
        .{ .text = "== a\n  []\n", .line = 2, .col = 3, .message = "a bracket holds a tag, `[key value]`, or an effect, `[fact = value]` or `[action(…)]`" },
        .{ .text = "== a\n  [a.b c]\n", .line = 2, .col = 4, .message = "`a.b` is not a tag's key: a key is letters, digits and `_`" },
        .{ .text = "== a\n  [t]\n    [u]\n", .line = 3, .col = 5, .message = "nothing is indented under a row of brackets" },
        .{ .text = "== a\n[t]\n", .line = 2, .col = 1, .message = "`[t]` is a tag, and a tag belongs to what it describes: indent it under that line, choice or heading" },
        .{ .text = "== a\n{ x }\n  [t]\n  Go.\n", .line = 3, .col = 3, .message = "`[t]` is a tag, and a tag belongs to what it describes: indent it under that line, choice or heading" },
        .{ .text = "== a\n* Go.\n  Hi.\n  [t]\n", .line = 4, .col = 3, .message = "`[t]` is a tag, and a tag belongs to what it describes: indent it under that line, choice or heading" },
        .{ .text = "== a\n  [x = 1]\n", .line = 2, .col = 3, .message = "a section's heading takes tags: an effect is a step, written at the section's level" },
        .{ .text = "== a\nGo.\n  -> end\n", .line = 3, .col = 3, .message = "only brackets can be indented under a line: its tags, and its effects, which happen when it is said" },
        .{ .text = "== a\n{ x } [y = 1]\n", .line = 2, .col = 7, .message = "brackets stand on a row of their own, under what they belong to; `\\[` writes the mark" },
        .{ .text = "== a\nDAD (): Go.\n", .line = 2, .col = 5, .message = "a delivery says how the line is said: `NAME (quietly):`" },
        .{ .text = "== a ^k1\n", .line = 1, .col = 6, .message = "an id ends a line or a choice: `^k1` stands at the end of neither" },
        .{ .text = "== a\n-> b ^k1\n", .line = 2, .col = 6, .message = "an id ends a line or a choice: `^k1` stands at the end of neither" },
        .{ .text = "cast:\n  mum  \"Mum\"\n    hello\n", .line = 3, .col = 5, .message = "under a cast entry stand its tags, in brackets: `[gender feminine]`" },
        .{ .text = "cast:\n  mum  \"Mum\"\n    [x = 1]\n", .line = 3, .col = 5, .message = "a cast entry takes tags, never effects" },
        .{ .text = "cast:\n  [voice]\n", .line = 2, .col = 3, .message = "a cast entry's tags stand on a row indented under it" },
        .{ .text = "== a\n[x]\n- (ask)\n  [t]\n", .line = 3, .col = 1, .message = "nothing can be indented under a gather" },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diags: source.Diagnostics = .{};
        defer diags.deinit(std.testing.allocator);
        const f = try parseFile(arena.allocator(), std.testing.allocator, &diags, 0, "a.river", case.text);
        const found = for (diags.list.items) |d| {
            const at = f.place(d.span);
            if (at.line == case.line and at.col == case.col and std.mem.eql(u8, d.message, case.message)) break true;
        } else false;
        if (!found) {
            std.debug.print("wanted {d}:{d}: {s}\n", .{ case.line, case.col, case.message });
            for (diags.list.items) |d| std.debug.print("  have {d}:{d}: {s}\n", .{ f.place(d.span).line, f.place(d.span).col, d.message });
            return error.TestMissingDiagnostic;
        }
    }
}

test "a row of brackets under a line, a choice and a heading is theirs: tags, then effects in order" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    const story =
        \\cast:
        \\  marta  "Marta"   — the merchant
        \\    [gender feminine] [voice]
        \\== a (pool 2)
        \\  [card]
        \\  [count 2]
        \\= one   when { met }   MARTA (quietly): Go. ^k1
        \\  [at 2] [met = false]
        \\  [pause 1]
        \\= two
        \\  [weight 3]
        \\  [met = true]
        \\  * Run. ^k2
        \\    [side go]
        \\    [met = true]
        \\    -> one ->
        \\    [met = false]
        \\  <-
    ;
    const f = try parseFile(arena.allocator(), gpa, &diags, 0, "a.river", story);
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
    try std.testing.expectEqual(@as(usize, 2), f.decls[0].kind.cast[0].tags.len);
    const s = f.sections[0];
    try std.testing.expectEqual(@as(usize, 2), s.tags.len);
    try expectWritten(story, s.kind_span.?, "(pool 2)");
    // a candidate on one row: what is under the row is its line's
    const one = s.subsections[0];
    try std.testing.expectEqual(@as(usize, 0), one.tags.len);
    try expectWritten(story, one.when_span.?, "{ met }");
    const line = one.body[0];
    try std.testing.expectEqualStrings("id", line.tags[0].key.text);
    try expectWritten(story, line.tags[0].span, "^k1");
    try expectWritten(story, line.tags[0].at(0), "k1");
    try std.testing.expectEqualStrings("at", line.tags[1].key.text);
    try std.testing.expectEqualStrings("pause", line.tags[2].key.text);
    try std.testing.expectEqual(@as(usize, 1), line.kind.line.effects.len);
    try expectWritten(story, line.kind.line.effects[0].span, "[met = false]");
    try expectWritten(story, line.kind.line.effects[0].kind.effect.span(), "met = false");
    try expectWritten(story, line.kind.line.delivery.?.span, "(quietly)");
    try expectWritten(story, line.kind.line.delivery.?.words.span, "quietly");
    try std.testing.expectEqualStrings("MARTA", line.kind.line.speaker.?.text);
    // a part's: its tags, its effects its first step
    const two = s.subsections[1];
    try std.testing.expectEqualStrings("weight", two.tags[0].key.text);
    try std.testing.expect(two.body[0].kind == .effect);
    const run = two.body[1];
    try std.testing.expectEqual(@as(usize, 2), run.tags.len);
    try std.testing.expectEqual(@as(usize, 3), run.kind.choice.body.len);
    try std.testing.expect(run.kind.choice.body[1].kind.flow.kind == .call);
    try expectWritten(story, run.kind.choice.body[1].kind.flow.span, "-> one ->");
    try std.testing.expectEqualStrings("one", run.kind.choice.body[1].kind.flow.kind.call.text);
}
