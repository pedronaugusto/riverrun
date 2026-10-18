//! The reader: one `.river` file into its syntax tree.
//!
//! At indentation zero a line is a declaration (`cast:`, `extras:`,
//! `facts:`, `const:`, `extern:`), a section (`== name`), a part of one
//! (`= name`) or a statement of the section it is in. Inside, a statement's
//! body is the lines indented further than it.

const std = @import("std");
const ast = @import("ast.zig");
const source = @import("source.zig");
const lines_mod = @import("lines.zig");
const expr = @import("expr.zig");
const text_mod = @import("text.zig");

const Line = lines_mod.Line;
const Allocator = std.mem.Allocator;

pub const Error = error{OutOfMemory};
const Fail = error{ OutOfMemory, Invalid };

pub const max_depth = 32;

/// Reads `bytes` as file `file` of a story. Problems go to `diags`; what can
/// be read is returned even when some of it could not.
pub fn parseFile(arena: Allocator, gpa: Allocator, diags: *source.Diagnostics, file: source.FileId, path: []const u8, bytes: []const u8) Error!ast.File {
    const ls = lines_mod.split(arena, gpa, diags, file, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return .{ .path = path, .decls = &.{}, .sections = &.{} },
    };
    var r: Reader = .{ .arena = arena, .gpa = gpa, .diags = diags, .file = file, .lines = ls };
    return r.readFile(path);
}

const Reader = struct {
    arena: Allocator,
    gpa: Allocator,
    diags: *source.Diagnostics,
    file: source.FileId,
    lines: []const Line,
    i: usize = 0,

    fn at(r: *const Reader, l: Line, col_offset: usize) source.Span {
        return .{ .file = r.file, .line = l.number, .col = l.col + @as(u32, @intCast(col_offset)) };
    }

    fn report(r: *Reader, l: Line, comptime fmt: []const u8, args: anytype) Error!void {
        try r.diags.add(r.gpa, r.at(l, 0), .err, fmt, args);
    }

    fn readFile(r: *Reader, path: []const u8) Error!ast.File {
        var decls: std.ArrayList(ast.Decl) = .empty;
        var sections: std.ArrayList(ast.Section) = .empty;
        while (r.i < r.lines.len) {
            const l = r.lines[r.i];
            if (l.indent != 0) {
                try r.report(l, "this line is indented but belongs to nothing", .{});
                r.i += 1;
                continue;
            }
            if (try r.decl(&decls)) continue;
            if (std.mem.startsWith(u8, l.text, "==")) {
                if (try r.section()) |s| try sections.append(r.arena, s);
                continue;
            }
            try r.report(l, "a story's lines belong in a section: `== name` comes first", .{});
            r.i += 1;
        }
        return .{ .path = path, .decls = try decls.toOwnedSlice(r.arena), .sections = try sections.toOwnedSlice(r.arena) };
    }

    // ------------------------------------------------------------ declarations

    // The lines indented under the line at `r.i`, which is consumed.
    fn block(r: *Reader) []const Line {
        std.debug.assert(r.i < r.lines.len);
        const head = r.lines[r.i];
        r.i += 1;
        const start = r.i;
        while (r.i < r.lines.len and r.lines[r.i].indent > head.indent) r.i += 1;
        return r.lines[start..r.i];
    }

    fn decl(r: *Reader, decls: *std.ArrayList(ast.Decl)) Error!bool {
        const l = r.lines[r.i];
        if (std.mem.eql(u8, l.text, "cast:")) {
            try decls.append(r.arena, .{ .cast = try r.castEntries(r.block()) });
        } else if (std.mem.startsWith(u8, l.text, "extras:")) {
            r.i += 1;
            try decls.append(r.arena, .{ .extras = try r.list(l, l.text["extras:".len..], "extras:".len) });
        } else if (std.mem.eql(u8, l.text, "facts:") or std.mem.startsWith(u8, l.text, "facts (")) {
            const scope = try r.scopeOf(l);
            try decls.append(r.arena, .{ .facts = .{ .scope = scope, .entries = try r.factEntries(r.block()) } });
        } else if (std.mem.eql(u8, l.text, "const:")) {
            try decls.append(r.arena, .{ .consts = try r.constEntries(r.block()) });
        } else if (std.mem.eql(u8, l.text, "extern:")) {
            try decls.append(r.arena, .{ .externs = try r.externEntries(r.block()) });
        } else return false;
        return true;
    }

    fn scopeOf(r: *Reader, l: Line) Error!?ast.Name {
        if (std.mem.eql(u8, l.text, "facts:")) return null;
        const close = std.mem.findScalar(u8, l.text, ')') orelse {
            try r.report(l, "`facts (` needs its scope and `):`", .{});
            return null;
        };
        if (!std.mem.endsWith(u8, l.text, "):")) try r.report(l, "a facts heading ends with `):`", .{});
        return .{ .text = std.mem.trim(u8, l.text["facts (".len..close], " "), .span = r.at(l, "facts (".len) };
    }

    // `a · b · c` or `a, b, c`: names.
    fn list(r: *Reader, l: Line, text: []const u8, offset: usize) Error![]const ast.Name {
        var out: std.ArrayList(ast.Name) = .empty;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= text.len) {
            const sep: usize = if (i == text.len) 1 else if (text[i] == ',') 1 else if (std.mem.startsWith(u8, text[i..], "·")) "·".len else 0;
            if (sep == 0) {
                i += 1;
                continue;
            }
            var a = start;
            var z = i;
            while (a < z and text[a] == ' ') a += 1;
            while (z > a and text[z - 1] == ' ') z -= 1;
            if (z > a) try out.append(r.arena, .{ .text = text[a..z], .span = r.at(l, offset + a) });
            i += sep;
            start = i;
        }
        return out.toOwnedSlice(r.arena);
    }

    fn castEntries(r: *Reader, ls: []const Line) Error![]const ast.CastEntry {
        var out: std.ArrayList(ast.CastEntry) = .empty;
        for (ls) |l| {
            const sp = std.mem.findScalar(u8, l.text, ' ') orelse l.text.len;
            const id = l.text[0..sp];
            const rest = std.mem.trim(u8, l.text[sp..], " ");
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
            try out.append(r.arena, .{ .id = .{ .text = id, .span = r.at(l, 0) }, .display = rest[1..close], .relation = relation, .tags = try r.tags(l) });
        }
        return out.toOwnedSlice(r.arena);
    }

    fn factEntries(r: *Reader, ls: []const Line) Error![]const ast.Fact {
        var out: std.ArrayList(ast.Fact) = .empty;
        var k: usize = 0;
        while (k < ls.len) : (k += 1) {
            const l = ls[k];
            const colon = std.mem.findScalar(u8, l.text, ':') orelse {
                try r.report(l, "a fact is `name: type`", .{});
                continue;
            };
            // a type that ends with `,` goes on under it
            var ty: std.ArrayList(u8) = .empty;
            try ty.appendSlice(r.arena, std.mem.trim(u8, l.text[colon + 1 ..], " "));
            while (std.mem.endsWith(u8, ty.items, ",") and k + 1 < ls.len and ls[k + 1].indent > l.indent) {
                k += 1;
                try ty.append(r.arena, ' ');
                try ty.appendSlice(r.arena, ls[k].text);
            }
            var t = std.mem.trim(u8, ty.items, " ");
            const game = std.mem.endsWith(u8, t, "(game)");
            if (game) t = std.mem.trim(u8, t[0 .. t.len - "(game)".len], " ");
            const parsed = r.typeOf(l, t, colon + 1) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => continue,
            };
            try out.append(r.arena, .{ .name = .{ .text = std.mem.trim(u8, l.text[0..colon], " "), .span = r.at(l, 0) }, .type = parsed, .game = game });
        }
        return out.toOwnedSlice(r.arena);
    }

    fn typeOf(r: *Reader, l: Line, t: []const u8, col: usize) Fail!ast.Type {
        if (std.mem.eql(u8, t, "bool")) return .boolean;
        if (std.mem.eql(u8, t, "int")) return .int;
        if (std.mem.eql(u8, t, "text")) return .text;
        if (std.mem.startsWith(u8, t, "one of ")) return .{ .one_of = try r.list(l, t["one of ".len..], col) };
        if (std.mem.startsWith(u8, t, "set of ")) return .{ .set_of = try r.list(l, t["set of ".len..], col) };
        try r.report(l, "`{s}` is not a type: bool, int, text, `one of …` or `set of …`", .{t});
        return error.Invalid;
    }

    fn constEntries(r: *Reader, ls: []const Line) Error![]const ast.Const {
        var out: std.ArrayList(ast.Const) = .empty;
        for (ls) |l| {
            const eq = std.mem.findScalar(u8, l.text, '=') orelse {
                try r.report(l, "a constant is `name = value`", .{});
                continue;
            };
            const value = expr.parse(r.arena, r.gpa, r.diags, std.mem.trim(u8, l.text[eq + 1 ..], " "), r.at(l, eq + 1 + lead(l.text[eq + 1 ..]))) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => continue,
            };
            try out.append(r.arena, .{ .name = .{ .text = std.mem.trim(u8, l.text[0..eq], " "), .span = r.at(l, 0) }, .value = value.* });
        }
        return out.toOwnedSlice(r.arena);
    }

    fn externEntries(r: *Reader, ls: []const Line) Error![]const ast.Extern {
        var out: std.ArrayList(ast.Extern) = .empty;
        for (ls) |l| {
            const open = std.mem.findScalar(u8, l.text, '(') orelse {
                try r.report(l, "an extern is `name(types) -> type`, or `name(types)` for an action", .{});
                continue;
            };
            const close = std.mem.findScalarLast(u8, l.text, ')') orelse {
                try r.report(l, "`(` is not closed", .{});
                continue;
            };
            var params: std.ArrayList(ast.Type) = .empty;
            const inner = std.mem.trim(u8, l.text[open + 1 .. close], " ");
            if (inner.len > 0) {
                // a parameter is a type; `one of a, b` holds commas, so a parameter list of enumerations is one type
                const p = r.typeOf(l, inner, open + 1) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Invalid => continue,
                };
                try params.append(r.arena, p);
            }
            const after = std.mem.trim(u8, l.text[close + 1 ..], " ");
            var returns: ?ast.Type = null;
            if (std.mem.startsWith(u8, after, "->")) {
                returns = r.typeOf(l, std.mem.trim(u8, after[2..], " "), close + 3) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Invalid => continue,
                };
            } else if (after.len != 0) try r.report(l, "after the parameters comes `-> type`, or nothing", .{});
            try out.append(r.arena, .{ .name = .{ .text = std.mem.trim(u8, l.text[0..open], " "), .span = r.at(l, 0) }, .params = try params.toOwnedSlice(r.arena), .returns = returns });
        }
        return out.toOwnedSlice(r.arena);
    }

    // ------------------------------------------------------------ tags

    fn tags(r: *Reader, l: Line) Error![]const ast.Tag {
        if (l.tags.len == 0) return &.{};
        var out: std.ArrayList(ast.Tag) = .empty;
        var items = Split.init(l.tags, "·");
        while (items.next()) |raw| {
            const item = std.mem.trim(u8, raw, " ");
            if (item.len == 0) continue;
            const sp = std.mem.findScalar(u8, item, ' ') orelse item.len;
            var values: std.ArrayList([]const u8) = .empty;
            var vs = Split.init(item[sp..], ",");
            while (vs.next()) |v| {
                const value = std.mem.trim(u8, v, " ");
                if (value.len == 0) continue;
                try values.append(r.arena, if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value[1 .. value.len - 1] else value);
            }
            try out.append(r.arena, .{ .key = .{ .text = item[0..sp], .span = r.at(l, 0) }, .values = try values.toOwnedSlice(r.arena) });
        }
        return out.toOwnedSlice(r.arena);
    }

    // ------------------------------------------------------------ sections

    fn section(r: *Reader) Error!?ast.Section {
        const l = r.lines[r.i];
        std.debug.assert(std.mem.startsWith(u8, l.text, "=="));
        r.i += 1;
        const head = std.mem.trim(u8, l.text[2..], " ");
        const paren = std.mem.findScalar(u8, head, '(');
        const name = std.mem.trim(u8, head[0 .. paren orelse head.len], " ");
        if (name.len == 0 or !isName(name)) {
            try r.report(l, "a section is `== name`, its name letters, digits and `_`", .{});
            return null;
        }
        var kind: ast.Section.Kind = .scene;
        if (paren) |p| kind = try r.kindOf(l, head[p..], p);
        var body: std.ArrayList(ast.Stmt) = .empty;
        var subs: std.ArrayList(ast.Subsection) = .empty;
        while (r.i < r.lines.len) {
            const s = r.lines[r.i];
            if (s.indent == 0 and (std.mem.startsWith(u8, s.text, "==") or isDecl(s.text))) break;
            if (s.indent == 0 and std.mem.startsWith(u8, s.text, "= ")) {
                if (try r.subsection()) |sub| try subs.append(r.arena, sub);
                continue;
            }
            if (subs.items.len > 0 and s.indent == 0) {
                try r.report(s, "after a section's parts, every line belongs to a part", .{});
                r.i += 1;
                continue;
            }
            if (try r.stmt(s.indent, 0)) |st| try body.append(r.arena, st);
        }
        return .{ .name = .{ .text = name, .span = r.at(l, 3) }, .kind = kind, .tags = try r.tags(l), .body = try body.toOwnedSlice(r.arena), .subsections = try subs.toOwnedSlice(r.arena) };
    }

    fn kindOf(r: *Reader, l: Line, t: []const u8, col: usize) Error!ast.Section.Kind {
        const close = std.mem.findScalar(u8, t, ')') orelse {
            try r.report(l, "`(` is not closed", .{});
            return .scene;
        };
        const inner = std.mem.trim(u8, t[1..close], " ");
        if (std.mem.eql(u8, inner, "pool")) return .{ .pool = 1 };
        if (std.mem.startsWith(u8, inner, "pool ")) {
            const n = std.fmt.parseInt(u16, std.mem.trim(u8, inner[5..], " "), 10) catch {
                try r.report(l, "a pool gives a number of lines: `(pool 2)`", .{});
                return .{ .pool = 1 };
            };
            return .{ .pool = n };
        }
        return .{ .other = .{ .text = inner, .span = r.at(l, col + 1) } };
    }

    fn subsection(r: *Reader) Error!?ast.Subsection {
        const l = r.lines[r.i];
        std.debug.assert(std.mem.startsWith(u8, l.text, "= "));
        var t = std.mem.trim(u8, l.text[2..], " ");
        const end = blk: {
            var j: usize = 0;
            while (j < t.len and expr.isWord(t[j])) j += 1;
            break :blk j;
        };
        const name = t[0..end];
        if (name.len == 0) {
            try r.report(l, "a part is `= name`", .{});
            r.i += 1;
            return null;
        }
        t = std.mem.trim(u8, t[end..], " ");
        var when: ?ast.Expr = null;
        const off = l.text.len - t.len;
        if (std.mem.startsWith(u8, t, "when ")) {
            const open = std.mem.findScalar(u8, t, '{') orelse 0;
            const close = text_mod.matching(t, open) orelse {
                try r.report(l, "`when` takes `{{ condition }}`", .{});
                r.i += 1;
                return null;
            };
            when = if (expr.parse(r.arena, r.gpa, r.diags, std.mem.trim(u8, t[open + 1 .. close], " "), r.at(l, off + open + 1 + lead(t[open + 1 .. close])))) |e| e.* else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => null,
            };
            t = std.mem.trim(u8, t[close + 1 ..], " ");
        }
        var body: std.ArrayList(ast.Stmt) = .empty;
        if (t.len > 0) {
            // a candidate written on its one line
            const inline_line: Line = .{ .number = l.number, .indent = l.indent, .text = t, .tags = l.tags, .col = l.col + @as(u32, @intCast(l.text.len - t.len)) };
            if (try r.stmtOf(inline_line, &.{})) |st| try body.append(r.arena, st);
            r.i += 1;
        } else {
            r.i += 1;
            const base = if (r.i < r.lines.len) r.lines[r.i].indent else 0;
            if (base > 0) while (r.i < r.lines.len and r.lines[r.i].indent >= base) {
                if (try r.stmt(base, 1)) |st| try body.append(r.arena, st);
            };
        }
        return .{ .name = .{ .text = name, .span = r.at(l, 2) }, .when = when, .tags = if (t.len > 0) &.{} else try r.tags(l), .body = try body.toOwnedSlice(r.arena) };
    }

    // ------------------------------------------------------------ statements

    // The statement at `r.i`, at indentation `indent`, with its body.
    fn stmt(r: *Reader, indent: u32, depth: usize) Error!?ast.Stmt {
        std.debug.assert(r.i < r.lines.len);
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
        var children: std.ArrayList(ast.Stmt) = .empty;
        if (r.i < r.lines.len and r.lines[r.i].indent > indent) {
            const base = r.lines[r.i].indent;
            while (r.i < r.lines.len and r.lines[r.i].indent >= base) {
                if (try r.stmt(base, depth + 1)) |st| try children.append(r.arena, st);
            }
        }
        return r.stmtOf(l, try children.toOwnedSlice(r.arena));
    }

    fn stmtOf(r: *Reader, l: Line, body: []const ast.Stmt) Error!?ast.Stmt {
        const kind = r.kindOfStmt(l, body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return null,
        };
        return .{ .span = r.at(l, 0), .tags = try r.tags(l), .kind = kind };
    }

    fn kindOfStmt(r: *Reader, l: Line, body: []const ast.Stmt) Fail!@FieldType(ast.Stmt, "kind") {
        const t = l.text;
        if (std.mem.startsWith(u8, t, "->>")) return r.leaf(l, body, .{ .flow = .{ .call = try r.target(l, t[3..], 3) } });
        if (std.mem.startsWith(u8, t, "->")) return r.leaf(l, body, .{ .flow = .{ .jump = try r.target(l, t[2..], 2) } });
        if (std.mem.eql(u8, t, "<-")) return r.leaf(l, body, .{ .flow = .ret });
        if (std.mem.startsWith(u8, t, "~ ")) return r.leaf(l, body, .{ .effect = try r.effect(l, t[2..]) });
        if (std.mem.startsWith(u8, t, "* ") or std.mem.startsWith(u8, t, "+ ")) return .{ .choice = try r.choice(l, body) };
        if (std.mem.eql(u8, t, "-") or std.mem.startsWith(u8, t, "- ")) return .{ .gather = try r.gather(l, body) };
        if (t[0] == '{') {
            const close = text_mod.matching(t, 0) orelse {
                try r.report(l, "`{{` is not closed", .{});
                return error.Invalid;
            };
            if (!text_mod.choosesWords(t, 0, close)) {
                const cond = try expr.parse(r.arena, r.gpa, r.diags, std.mem.trim(u8, t[1..close], " "), r.at(l, 1 + lead(t[1..close])));
                const rest = std.mem.trim(u8, t[close + 1 ..], " ");
                if (rest.len == 0) return .{ .cond = .{ .cond = cond.*, .body = body } };
                const inner: Line = .{ .number = l.number, .indent = l.indent, .text = rest, .tags = "", .col = l.col + @as(u32, @intCast(t.len - rest.len)) };
                const one = try r.arena.alloc(ast.Stmt, 1);
                one[0] = .{ .span = r.at(inner, 0), .tags = &.{}, .kind = try r.kindOfStmt(inner, body) };
                return .{ .cond = .{ .cond = cond.*, .body = one } };
            }
            if (close == t.len - 1 and std.mem.find(u8, t, "->") != null) return r.leaf(l, body, .{ .flow_if = try r.flowIf(l, t[1..close]) });
        }
        for (body) |child| if (child.kind != .effect) {
            try r.diags.add(r.gpa, child.span, .err, "only effects can be indented under a line: they happen when it is said", .{});
            return error.Invalid;
        };
        var ln = try r.line(l);
        ln.effects = body;
        return .{ .line = ln };
    }

    // A statement that takes no body.
    fn leaf(r: *Reader, l: Line, body: []const ast.Stmt, kind: @FieldType(ast.Stmt, "kind")) Fail!@FieldType(ast.Stmt, "kind") {
        if (body.len > 0) {
            try r.report(l, "nothing can be indented under this line", .{});
            return error.Invalid;
        }
        return kind;
    }

    fn target(r: *Reader, l: Line, t: []const u8, col: usize) Fail!ast.Name {
        const name = std.mem.trim(u8, t, " ");
        if (!isName(name)) {
            try r.report(l, "`{s}` is not a section to go to", .{name});
            return error.Invalid;
        }
        return .{ .text = name, .span = r.at(l, col + 1) };
    }

    fn effect(r: *Reader, l: Line, t: []const u8) Fail!ast.Effect {
        if (std.mem.find(u8, t, "+=")) |k| return .{ .add = .{ .fact = try r.word(l, t[0..k], 2), .item = try r.word(l, t[k + 2 ..], k + 4) } };
        if (std.mem.find(u8, t, "-=")) |k| return .{ .remove = .{ .fact = try r.word(l, t[0..k], 2), .item = try r.word(l, t[k + 2 ..], k + 4) } };
        if (std.mem.findScalar(u8, t, '=')) |k| {
            const value = try expr.parse(r.arena, r.gpa, r.diags, std.mem.trim(u8, t[k + 1 ..], " "), r.at(l, k + 3 + lead(t[k + 1 ..])));
            return .{ .set = .{ .fact = try r.word(l, t[0..k], 2), .value = value.* } };
        }
        const call = try expr.parse(r.arena, r.gpa, r.diags, std.mem.trim(u8, t, " "), r.at(l, 2 + lead(t)));
        if (call.kind != .call) {
            try r.report(l, "an effect is `fact = value`, `set += item`, `set -= item` or `action(…)`", .{});
            return error.Invalid;
        }
        return .{ .call = call.kind.call };
    }

    fn word(r: *Reader, l: Line, t: []const u8, col: usize) Fail!ast.Name {
        const w = std.mem.trim(u8, t, " ");
        if (!isName(w)) {
            try r.report(l, "`{s}` is not a name", .{w});
            return error.Invalid;
        }
        return .{ .text = w, .span = r.at(l, col + lead(t)) };
    }

    fn choice(r: *Reader, l: Line, body: []const ast.Stmt) Fail!ast.Choice {
        var t = std.mem.trim(u8, l.text[2..], " ");
        var cond: ?ast.Expr = null;
        if (t.len > 0 and t[0] == '{') {
            const close = text_mod.matching(t, 0) orelse {
                try r.report(l, "`{{` is not closed", .{});
                return error.Invalid;
            };
            if (!text_mod.choosesWords(t, 0, close)) {
                cond = (try expr.parse(r.arena, r.gpa, r.diags, std.mem.trim(u8, t[1..close], " "), r.at(l, l.text.len - t.len + 1 + lead(t[1..close])))).*;
                t = std.mem.trim(u8, t[close + 1 ..], " ");
            }
        }
        const text = try text_mod.parse(r.arena, r.gpa, r.diags, t, r.at(l, l.text.len - t.len));
        return .{ .sticky = l.text[0] == '+', .cond = cond, .text = text, .body = body };
    }

    fn gather(r: *Reader, l: Line, body: []const ast.Stmt) Fail!ast.Gather {
        var t = std.mem.trim(u8, l.text[1..], " ");
        var label: ?ast.Name = null;
        if (t.len > 0 and t[0] == '(') {
            const close = std.mem.findScalar(u8, t, ')') orelse {
                try r.report(l, "`(` is not closed", .{});
                return error.Invalid;
            };
            label = try r.word(l, t[1..close], 3);
            t = std.mem.trim(u8, t[close + 1 ..], " ");
        }
        if (t.len == 0) {
            if (body.len > 0) {
                try r.report(l, "nothing can be indented under a gather", .{});
                return error.Invalid;
            }
            return .{ .label = label, .then = null };
        }
        const inner: Line = .{ .number = l.number, .indent = l.indent, .text = t, .tags = "", .col = l.col + @as(u32, @intCast(l.text.len - t.len)) };
        const then = try r.arena.create(ast.Stmt);
        then.* = .{ .span = r.at(inner, 0), .tags = &.{}, .kind = try r.kindOfStmt(inner, body) };
        return .{ .label = label, .then = then };
    }

    fn flowIf(r: *Reader, l: Line, inner: []const u8) Fail!ast.FlowIf {
        const colon = std.mem.findScalar(u8, inner, ':') orelse unreachable; // choosesWords said so
        const bar = std.mem.findScalar(u8, inner, '|') orelse {
            try r.report(l, "a flow chosen by a condition is `{{ condition: -> a | -> b }}`", .{});
            return error.Invalid;
        };
        const cond = try expr.parse(r.arena, r.gpa, r.diags, std.mem.trim(u8, inner[0..colon], " "), r.at(l, 1 + lead(inner[0..colon])));
        return .{ .cond = cond.*, .then = try r.flowOf(l, inner[colon + 1 .. bar]), .otherwise = try r.flowOf(l, inner[bar + 1 ..]) };
    }

    fn flowOf(r: *Reader, l: Line, t: []const u8) Fail!ast.Flow {
        const s = std.mem.trim(u8, t, " ");
        if (std.mem.startsWith(u8, s, "->>")) return .{ .call = try r.target(l, s[3..], 0) };
        if (std.mem.startsWith(u8, s, "->")) return .{ .jump = try r.target(l, s[2..], 0) };
        if (std.mem.eql(u8, s, "<-")) return .ret;
        try r.report(l, "`{s}` is not a flow: `-> name`, `->> name` or `<-`", .{s});
        return error.Invalid;
    }

    fn line(r: *Reader, l: Line) Fail!ast.Line {
        const t = l.text;
        var speaker: ?ast.Name = null;
        var rest = t;
        if (speakerEnd(t)) |end| {
            speaker = .{ .text = t[0..end], .span = r.at(l, 0) };
            rest = std.mem.trim(u8, t[end + 1 ..], " ");
        }
        return .{ .speaker = speaker, .text = try text_mod.parse(r.arena, r.gpa, r.diags, rest, r.at(l, t.len - rest.len)), .effects = &.{} };
    }
};

/// A speaker is capitals, digits, `_` and spaces, then `:` and a space: `DAD: Go.`, `A CELLIST: …`.
pub fn speakerEnd(t: []const u8) ?usize {
    if (t.len < 2 or !std.ascii.isUpper(t[0])) return null;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (c == ':') {
            if (i + 1 < t.len and t[i + 1] != ' ') return null;
            return if (t[i - 1] == ' ') null else i;
        }
        if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_' or c == ' ')) return null;
    }
    return null;
}

// The spaces before what trimming keeps: where trimmed text starts.
fn lead(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == ' ') n += 1;
    return n;
}

fn isName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!expr.isWord(c)) return false;
    return true;
}

fn isDecl(t: []const u8) bool {
    return std.mem.eql(u8, t, "cast:") or std.mem.startsWith(u8, t, "extras:") or std.mem.eql(u8, t, "facts:") or
        std.mem.startsWith(u8, t, "facts (") or std.mem.eql(u8, t, "const:") or std.mem.eql(u8, t, "extern:");
}

// Splits on a separator outside quotes.
const Split = struct {
    s: []const u8,
    sep: []const u8,
    i: usize = 0,
    done: bool = false,

    fn init(s: []const u8, sep: []const u8) Split {
        return .{ .s = s, .sep = sep };
    }

    fn next(p: *Split) ?[]const u8 {
        if (p.done) return null;
        var quoted = false;
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

test "a speaker is capitals before a colon" {
    try std.testing.expectEqual(@as(?usize, 3), speakerEnd("DAD: Go."));
    try std.testing.expectEqual(@as(?usize, 9), speakerEnd("A CELLIST: She stopped us."));
    try std.testing.expectEqual(@as(?usize, null), speakerEnd("22:31. The bus stop is four minutes away."));
    try std.testing.expectEqual(@as(?usize, null), speakerEnd("Royal College of Music, 1958: “…”"));
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
        \\== kitchen_1985                # talk
        \\DAD: Go.
        \\- (ask)
        \\* { carried has play } You could still play, Dad.   # known play
        \\  DAD: Who'd listen?
        \\  -> ask
        \\* Pick up the case.
        \\  -> fork_1985
    ;
    const f = try parseFile(arena.allocator(), gpa, &diags, 0, "kitchen.river", story);
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
    try std.testing.expectEqual(@as(usize, 2), f.decls.len);
    try std.testing.expectEqual(@as(usize, 3), f.decls[1].facts.entries[0].type.set_of.len);
    const s = f.sections[0];
    try std.testing.expectEqualStrings("kitchen_1985", s.name.text);
    try std.testing.expectEqualStrings("talk", s.tags[0].key.text);
    try std.testing.expectEqual(@as(usize, 4), s.body.len);
    const c = s.body[2].kind.choice;
    try std.testing.expect(c.cond != null);
    try std.testing.expectEqual(@as(usize, 2), c.body.len);
    try std.testing.expectEqualStrings("known", s.body[2].tags[0].key.text);
}

test "a span points where the words start, past the spaces trimmed" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    const story =
        \\== a
        \\{ met }  Go.
        \\~ carried += play
        \\* {  met } Stay.
        \\  -> end
    ;
    const f = try parseFile(arena.allocator(), gpa, &diags, 0, "a.river", story);
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
    const body = f.sections[0].body;
    try std.testing.expectEqual(@as(u32, 3), body[0].kind.cond.cond.span.col);
    try std.testing.expectEqual(@as(u32, 3), body[1].kind.effect.add.fact.span.col);
    try std.testing.expectEqual(@as(u32, 14), body[1].kind.effect.add.item.span.col);
    try std.testing.expectEqual(@as(u32, 6), body[2].kind.choice.cond.?.span.col);
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
