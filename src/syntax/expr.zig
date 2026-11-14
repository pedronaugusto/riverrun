//! Expressions: the conditions on lines and choices, the values of effects.
//!
//!     expr   = or
//!     or     = and { "or" and }
//!     and    = not { "and" not }
//!     not    = "not" not | rel
//!     rel    = sum [ ( "=" | "!=" | "<" | "<=" | ">" | ">=" | "has" | "hasnt" ) sum ]
//!     sum    = atom { ( "+" | "-" ) atom }
//!     atom   = name [ "(" [ expr { "," expr } ] ")" ] | int | string | "true" | "false" | "(" expr ")"
//!
//! A sum binds tighter than a comparison and runs left to right: a story
//! counts its own state. There is no multiplication, division or remainder
//! and nothing that loops: a formula is the game's, asked for by name through
//! the queries it declares. A chain (`a and b and c`, `a + b - c`) holds at
//! most `max_depth` links, as an expression nests at most `max_depth` deep,
//! and a chain past it is reported over the chain: the tree is left-deep
//! along a chain, so a tree is never deeper than `max_depth` links at each of
//! `max_depth` levels, and nothing that walks it (checker, compiler, a
//! package) recurses further, however long a row is.

const std = @import("std");
const ast = @import("ast.zig");
const source = @import("source.zig");

pub const max_depth = 32;

pub const Error = error{ OutOfMemory, Invalid };

/// Reads `words`, of file `file`, into an expression in `arena`. A problem is reported to `diags` and returns
/// `error.Invalid`. Each node's span is the range it is written in, an operator's from its left side to its right.
pub fn parse(arena: std.mem.Allocator, gpa: std.mem.Allocator, diags: *source.Diagnostics, file: source.FileId, words: source.Placed) Error!*const ast.Expr {
    var p: Parser = .{ .arena = arena, .gpa = gpa, .diags = diags, .file = file, .text = words.text, .at = words.at };
    const e = try p.orExpr(0);
    p.space();
    if (p.i != p.text.len) return p.fail("unexpected `{s}` after the expression", .{p.text[p.i..]});
    return e;
}

const Parser = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    diags: *source.Diagnostics,
    file: source.FileId,
    text: []const u8,
    /// Where `text` starts in its file.
    at: u32,
    i: usize = 0,

    // Where the parser stands in the file.
    fn here(p: *const Parser) u32 {
        return p.at + @as(u32, @intCast(p.i)); // safe: the text is a part of a file of at most lines.max_bytes
    }

    // A problem with what is left, from where the parser stands; with nothing left, with what was written.
    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        const end = p.at + @as(u32, @intCast(p.text.len)); // safe: as `here`
        const start = if (p.here() < end) p.here() else p.at;
        try p.diags.add(p.gpa, .{ .file = p.file, .start = start, .end = end }, .err, fmt, args);
        return error.Invalid;
    }

    fn space(p: *Parser) void {
        while (p.i < p.text.len and p.text[p.i] == ' ') p.i += 1;
    }

    // A node from `start` to where the parser stands, past all it is made of.
    fn node(p: *Parser, start: u32, kind: @FieldType(ast.Expr, "kind")) Error!*const ast.Expr {
        const e = try p.arena.create(ast.Expr);
        e.* = .{ .span = .{ .file = p.file, .start = start, .end = p.here() }, .kind = kind };
        return e;
    }

    // A word if one starts here, without consuming it.
    // A name, `module.name` qualified, without consuming it.
    fn peekWord(p: *Parser) []const u8 {
        p.space();
        var j = p.i;
        while (j < p.text.len and (isWord(p.text[j]) or (p.text[j] == '.' and j > p.i and j + 1 < p.text.len and isWord(p.text[j + 1])))) j += 1;
        return p.text[p.i..j];
    }

    fn keyword(p: *Parser, word: []const u8) bool {
        const w = p.peekWord();
        if (!std.mem.eql(u8, w, word)) return false;
        p.i += w.len;
        return true;
    }

    // A chain past `max_depth`, reported from where it begins to the end of what was written.
    fn tooLong(p: *Parser, start: u32, comptime links: []const u8) Error {
        const end = p.at + @as(u32, @intCast(p.text.len)); // safe: as `here`
        try p.diags.add(p.gpa, .{ .file = p.file, .start = start, .end = end }, .err, "this chain is longer than an expression holds: " ++ links ++ " join at most {d} links in one chain", .{max_depth});
        return error.Invalid;
    }

    fn orExpr(p: *Parser, depth: usize) Error!*const ast.Expr {
        if (depth > max_depth) return p.fail("the expression nests deeper than {d}", .{max_depth});
        var lhs = try p.andExpr(depth + 1);
        var links: usize = 0;
        while (true) {
            if (!p.keyword("or")) return lhs;
            links += 1;
            if (links > max_depth) return p.tooLong(lhs.span.start, "`or`");
            lhs = try p.node(lhs.span.start, .{ .binary = .{ .op = .@"or", .lhs = lhs, .rhs = try p.andExpr(depth + 1) } });
        }
    }

    fn andExpr(p: *Parser, depth: usize) Error!*const ast.Expr {
        var lhs = try p.notExpr(depth + 1);
        var links: usize = 0;
        while (true) {
            if (!p.keyword("and")) return lhs;
            links += 1;
            if (links > max_depth) return p.tooLong(lhs.span.start, "`and`");
            lhs = try p.node(lhs.span.start, .{ .binary = .{ .op = .@"and", .lhs = lhs, .rhs = try p.notExpr(depth + 1) } });
        }
    }

    fn notExpr(p: *Parser, depth: usize) Error!*const ast.Expr {
        if (depth > max_depth) return p.fail("the expression nests deeper than {d}", .{max_depth});
        p.space();
        const at = p.here();
        if (p.keyword("not")) return p.node(at, .{ .not = try p.notExpr(depth + 1) });
        return p.relExpr(depth + 1);
    }

    fn relExpr(p: *Parser, depth: usize) Error!*const ast.Expr {
        const lhs = try p.sumExpr(depth + 1);
        p.space();
        const op: ?ast.Expr.Op = if (p.eat("!=")) .ne else if (p.eat("<=")) .le else if (p.eat(">=")) .ge else if (p.eat("<")) .lt else if (p.eat(">")) .gt else if (p.eat("=")) .eq else if (p.keyword("hasnt")) .hasnt else if (p.keyword("has")) .has else null;
        const o = op orelse return lhs;
        return p.node(lhs.span.start, .{ .binary = .{ .op = o, .lhs = lhs, .rhs = try p.sumExpr(depth + 1) } });
    }

    // Atoms added and subtracted, left to right, at most `max_depth` links.
    fn sumExpr(p: *Parser, depth: usize) Error!*const ast.Expr {
        var lhs = try p.atom(depth + 1);
        var links: usize = 0;
        while (true) {
            p.space();
            if (p.i == p.text.len) return lhs;
            const op: ast.Expr.Op = switch (p.text[p.i]) {
                '+' => .add,
                '-' => if (p.i + 1 < p.text.len and p.text[p.i + 1] == '>') return lhs else .sub,
                '*', '/', '%' => return p.formula(),
                else => return lhs,
            };
            p.i += 1;
            links += 1;
            if (links > max_depth) return p.tooLong(lhs.span.start, "`+` and `-`");
            lhs = try p.node(lhs.span.start, .{ .binary = .{ .op = op, .lhs = lhs, .rhs = try p.atom(depth + 1) } });
        }
    }

    // `*`, `/` or `%` where a sum would go on: the boundary of what a story computes.
    fn formula(p: *Parser) Error {
        const at = p.here();
        const what = switch (p.text[p.i]) {
            '*' => "`*` multiplies",
            '/' => "`/` divides",
            else => "`%` takes a remainder",
        };
        try p.diags.add(p.gpa, .{ .file = p.file, .start = at, .end = at + 1 }, .err, "{s}, and a formula is the game's: a story adds and subtracts, and asks the game by name, through a query in `extern:`", .{what});
        return error.Invalid;
    }

    fn eat(p: *Parser, s: []const u8) bool {
        p.space();
        if (!std.mem.startsWith(u8, p.text[p.i..], s)) return false;
        p.i += s.len;
        return true;
    }

    fn atom(p: *Parser, depth: usize) Error!*const ast.Expr {
        if (depth > max_depth) return p.fail("the expression nests deeper than {d}", .{max_depth});
        p.space();
        const at = p.here();
        if (p.i == p.text.len) return p.fail("an expression is missing here", .{});
        const c = p.text[p.i];
        if (c == '(') {
            p.i += 1;
            const e = try p.orExpr(depth + 1);
            if (!p.eat(")")) return p.fail("`(` is not closed", .{});
            return e;
        }
        if (c == '"') {
            const end = std.mem.findScalarPos(u8, p.text, p.i + 1, '"') orelse return p.fail("the text is not closed with `\"`", .{});
            const s = p.text[p.i + 1 .. end];
            p.i = end + 1;
            return p.node(at, .{ .string = s });
        }
        if (std.ascii.isDigit(c) or (c == '-' and p.i + 1 < p.text.len and std.ascii.isDigit(p.text[p.i + 1]))) {
            var j = p.i + 1;
            while (j < p.text.len and std.ascii.isDigit(p.text[j])) j += 1;
            const n = std.fmt.parseInt(i64, p.text[p.i..j], 10) catch return p.fail("`{s}` is not a number riverrun can hold", .{p.text[p.i..j]});
            p.i = j;
            return p.node(at, .{ .int = n });
        }
        const word = p.peekWord();
        if (word.len == 0 and c == '-') return p.fail("`-` stands between two values: a number may be written `-3`, and `0 - x` takes `x` from nothing", .{});
        if (word.len == 0) return p.fail("`{c}` cannot start an expression", .{c});
        p.i += word.len;
        if (std.mem.eql(u8, word, "true")) return p.node(at, .{ .boolean = true });
        if (std.mem.eql(u8, word, "false")) return p.node(at, .{ .boolean = false });
        if (p.i < p.text.len and p.text[p.i] == '(') {
            p.i += 1;
            var args: std.ArrayList(ast.Expr) = .empty;
            if (!p.eat(")")) {
                while (true) {
                    try args.append(p.arena, (try p.orExpr(depth + 1)).*);
                    if (p.eat(")")) break;
                    if (!p.eat(",")) return p.fail("expected `,` or `)` in the call to `{s}`", .{word});
                }
            }
            const name: ast.Name = .{ .text = word, .span = .{ .file = p.file, .start = at, .end = at + @as(u32, @intCast(word.len)) } }; // safe: as `here`
            return p.node(at, .{ .call = .{ .span = .{ .file = p.file, .start = at, .end = p.here() }, .name = name, .args = try args.toOwnedSlice(p.arena) } });
        }
        return p.node(at, .{ .name = word });
    }
};

pub fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// ---------------------------------------------------------------- tests

fn testParse(text: []const u8) !struct { arena: std.heap.ArenaAllocator, diags: source.Diagnostics, expr: ?*const ast.Expr } {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var diags: source.Diagnostics = .{};
    const e = parse(arena.allocator(), std.testing.allocator, &diags, 0, .{ .text = text, .at = 0 }) catch |err| switch (err) {
        error.Invalid => null,
        else => return err,
    };
    return .{ .arena = arena, .diags = diags, .expr = e };
}

test "conditions bind as they read: not, then has and =, then and, then or" {
    var r = try testParse("not lived(stay) and kept has dad or life = go");
    defer r.arena.deinit();
    defer r.diags.deinit(std.testing.allocator);
    const e = r.expr.?;
    try std.testing.expectEqual(ast.Expr.Op.@"or", e.kind.binary.op);
    const left = e.kind.binary.lhs;
    try std.testing.expectEqual(ast.Expr.Op.@"and", left.kind.binary.op);
    try std.testing.expect(left.kind.binary.lhs.kind == .not);
    try std.testing.expectEqualStrings("lived", left.kind.binary.lhs.kind.not.kind.call.name.text);
    try std.testing.expectEqual(ast.Expr.Op.has, left.kind.binary.rhs.kind.binary.op);
}

test "a broken expression is reported where it breaks" {
    var r = try testParse("kept has (dad");
    defer r.arena.deinit();
    defer r.diags.deinit(std.testing.allocator);
    try std.testing.expect(r.expr == null);
    try std.testing.expectEqual(@as(usize, 1), r.diags.errors());
}

test "ints are ordered, and an expression is placed where it is written" {
    var r = try testParse("since(asked, day) >= 3 and hour < 6");
    defer r.arena.deinit();
    defer r.diags.deinit(std.testing.allocator);
    const e = r.expr.?;
    try std.testing.expectEqual(ast.Expr.Op.@"and", e.kind.binary.op);
    try std.testing.expectEqual(ast.Expr.Op.ge, e.kind.binary.lhs.kind.binary.op);
    try std.testing.expectEqual(ast.Expr.Op.lt, e.kind.binary.rhs.kind.binary.op);
    try std.testing.expectEqual(source.Span{ .file = 0, .start = 0, .end = 35 }, e.span);
    try std.testing.expectEqual(source.Span{ .file = 0, .start = 27, .end = 35 }, e.kind.binary.rhs.span);
    try std.testing.expectEqual(source.Span{ .file = 0, .start = 0, .end = 5 }, e.kind.binary.lhs.kind.binary.lhs.kind.call.name.span);
}

test "a name may be qualified by its module" {
    var r = try testParse("harbour.met and not harbour.seen_by(tom)");
    defer r.arena.deinit();
    defer r.diags.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("harbour.met", r.expr.?.kind.binary.lhs.kind.name);
    try std.testing.expectEqualStrings("harbour.seen_by", r.expr.?.kind.binary.rhs.kind.not.kind.call.name.text);
}

test "hasnt is not has followed by nt" {
    var r = try testParse("kept hasnt ruth");
    defer r.arena.deinit();
    defer r.diags.deinit(std.testing.allocator);
    try std.testing.expectEqual(ast.Expr.Op.hasnt, r.expr.?.kind.binary.op);
}

test "a sum binds tighter than a comparison and runs left to right; parentheses group" {
    var r = try testParse("a - b + c >= d - (e + f) and x");
    defer r.arena.deinit();
    defer r.diags.deinit(std.testing.allocator);
    const ge = r.expr.?.kind.binary.lhs;
    try std.testing.expectEqual(ast.Expr.Op.ge, ge.kind.binary.op);
    // (a - b) + c
    const left = ge.kind.binary.lhs;
    try std.testing.expectEqual(ast.Expr.Op.add, left.kind.binary.op);
    try std.testing.expectEqual(ast.Expr.Op.sub, left.kind.binary.lhs.kind.binary.op);
    try std.testing.expectEqualStrings("c", left.kind.binary.rhs.kind.name);
    try std.testing.expectEqual(source.Span{ .file = 0, .start = 0, .end = 9 }, left.span);
    // d - (e + f)
    const right = ge.kind.binary.rhs;
    try std.testing.expectEqual(ast.Expr.Op.sub, right.kind.binary.op);
    try std.testing.expectEqual(ast.Expr.Op.add, right.kind.binary.rhs.kind.binary.op);
    try std.testing.expectEqual(source.Span{ .file = 0, .start = 13, .end = 24 }, right.span);
}

test "a number may be negative, and a minus stands between two values" {
    var r = try testParse("a-3 = -2 + b");
    defer r.arena.deinit();
    defer r.diags.deinit(std.testing.allocator);
    const eq = r.expr.?.kind.binary;
    try std.testing.expectEqual(ast.Expr.Op.sub, eq.lhs.kind.binary.op);
    try std.testing.expectEqual(@as(i64, 3), eq.lhs.kind.binary.rhs.kind.int);
    try std.testing.expectEqual(@as(i64, -2), eq.rhs.kind.binary.lhs.kind.int);
    var neg = try testParse("-a > 0");
    defer neg.arena.deinit();
    defer neg.diags.deinit(std.testing.allocator);
    try std.testing.expect(neg.expr == null);
    try std.testing.expect(std.mem.startsWith(u8, neg.diags.list.items[0].message, "`-` stands between two values"));
}

test "`*`, `/` and `%` are refused where they stand, naming the game as what computes them" {
    for ([_][]const u8{ "price * 2 > coins", "coins >= price / 100", "day % 7 = 0" }, [_]u32{ 6, 15, 4 }, [_][]const u8{ "`*` multiplies", "`/` divides", "`%` takes a remainder" }) |text, at, starts| {
        var r = try testParse(text);
        defer r.arena.deinit();
        defer r.diags.deinit(std.testing.allocator);
        try std.testing.expect(r.expr == null);
        const d = r.diags.list.items[0];
        try std.testing.expectEqual(source.Span{ .file = 0, .start = at, .end = at + 1 }, d.span);
        try std.testing.expect(std.mem.startsWith(u8, d.message, starts));
        try std.testing.expect(std.mem.find(u8, d.message, "asks the game by name") != null);
    }
}

test "a chain of `+`, `and` or `or` is as long as the nesting allows, and one past it is reported over the chain" {
    for ([_][]const u8{ " + ", " and ", " or " }) |link| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(std.testing.allocator);
        // a hundred thousand links: refused, the tree never built that deep
        for (0..100_000) |i| {
            if (i > 0) try text.appendSlice(std.testing.allocator, link);
            try text.append(std.testing.allocator, 'a');
        }
        var r = try testParse(text.items);
        defer r.arena.deinit();
        defer r.diags.deinit(std.testing.allocator);
        try std.testing.expect(r.expr == null);
        const d = r.diags.list.items[0];
        try std.testing.expectEqual(source.Span{ .file = 0, .start = 0, .end = @intCast(text.items.len) }, d.span);
        try std.testing.expect(std.mem.startsWith(u8, d.message, "this chain is longer than an expression holds"));
        // as many links as a chain holds read
        var short = try testParse(text.items[0 .. max_depth * (link.len + 1) + 1]);
        defer short.arena.deinit();
        defer short.diags.deinit(std.testing.allocator);
        try std.testing.expect(short.expr != null);
    }
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
            _ = parse(arena.allocator(), std.testing.allocator, &diags, 0, .{ .text = bytes, .at = 0 }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
        }
    }.one, .{});
}
