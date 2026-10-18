//! Expressions: the conditions on lines and choices, the values of effects.
//!
//!     expr   = or
//!     or     = and { "or" and }
//!     and    = not { "and" not }
//!     not    = "not" not | rel
//!     rel    = atom [ ( "=" | "!=" | "<" | "<=" | ">" | ">=" | "has" | "hasnt" ) atom ]
//!     atom   = name [ "(" [ expr { "," expr } ] ")" ] | int | string | "true" | "false" | "(" expr ")"
//!
//! There is no arithmetic and nothing that loops: a story asks and the host
//! computes, through the queries it declares.

const std = @import("std");
const ast = @import("ast.zig");
const source = @import("source.zig");

pub const max_depth = 32;

pub const Error = error{ OutOfMemory, Invalid };

/// Reads `text`, which sits at `at` in its file, into an expression in `arena`.
/// A problem is reported to `diags` and returns `error.Invalid`.
pub fn parse(arena: std.mem.Allocator, gpa: std.mem.Allocator, diags: *source.Diagnostics, text: []const u8, at: source.Span) Error!*const ast.Expr {
    var p: Parser = .{ .arena = arena, .gpa = gpa, .diags = diags, .text = text, .at = at };
    const e = try p.orExpr(0);
    p.space();
    if (p.i != p.text.len) return p.fail("unexpected `{s}` after the expression", .{p.text[p.i..]});
    return e;
}

const Parser = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    diags: *source.Diagnostics,
    text: []const u8,
    at: source.Span,
    i: usize = 0,

    fn span(p: *const Parser) source.Span {
        return .{ .file = p.at.file, .line = p.at.line, .col = p.at.col + @as(u32, @intCast(p.i)) };
    }

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        try p.diags.add(p.gpa, p.span(), .err, fmt, args);
        return error.Invalid;
    }

    fn space(p: *Parser) void {
        while (p.i < p.text.len and p.text[p.i] == ' ') p.i += 1;
    }

    fn node(p: *Parser, at: source.Span, kind: @FieldType(ast.Expr, "kind")) Error!*const ast.Expr {
        const e = try p.arena.create(ast.Expr);
        e.* = .{ .span = at, .kind = kind };
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

    fn orExpr(p: *Parser, depth: usize) Error!*const ast.Expr {
        if (depth > max_depth) return p.fail("the expression nests deeper than {d}", .{max_depth});
        var lhs = try p.andExpr(depth + 1);
        while (true) {
            if (!p.keyword("or")) return lhs;
            lhs = try p.node(lhs.span, .{ .binary = .{ .op = .@"or", .lhs = lhs, .rhs = try p.andExpr(depth + 1) } });
        }
    }

    fn andExpr(p: *Parser, depth: usize) Error!*const ast.Expr {
        var lhs = try p.notExpr(depth + 1);
        while (true) {
            if (!p.keyword("and")) return lhs;
            lhs = try p.node(lhs.span, .{ .binary = .{ .op = .@"and", .lhs = lhs, .rhs = try p.notExpr(depth + 1) } });
        }
    }

    fn notExpr(p: *Parser, depth: usize) Error!*const ast.Expr {
        if (depth > max_depth) return p.fail("the expression nests deeper than {d}", .{max_depth});
        const at = p.span();
        if (p.keyword("not")) return p.node(at, .{ .not = try p.notExpr(depth + 1) });
        return p.relExpr(depth + 1);
    }

    fn relExpr(p: *Parser, depth: usize) Error!*const ast.Expr {
        const lhs = try p.atom(depth + 1);
        p.space();
        const op: ?ast.Expr.Op = if (p.eat("!=")) .ne else if (p.eat("<=")) .le else if (p.eat(">=")) .ge else if (p.eat("<")) .lt else if (p.eat(">")) .gt else if (p.eat("=")) .eq else if (p.keyword("hasnt")) .hasnt else if (p.keyword("has")) .has else null;
        const o = op orelse return lhs;
        // an expression is placed where it starts, so a diagnostic about it points at its first word
        return p.node(lhs.span, .{ .binary = .{ .op = o, .lhs = lhs, .rhs = try p.atom(depth + 1) } });
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
        const at = p.span();
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
            return p.node(at, .{ .call = .{ .name = .{ .text = word, .span = at }, .args = try args.toOwnedSlice(p.arena) } });
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
    const e = parse(arena.allocator(), std.testing.allocator, &diags, text, .{ .file = 0, .line = 1, .col = 1 }) catch |err| switch (err) {
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

test "ints are ordered, and an expression is placed where it starts" {
    var r = try testParse("since(asked, day) >= 3 and hour < 6");
    defer r.arena.deinit();
    defer r.diags.deinit(std.testing.allocator);
    const e = r.expr.?;
    try std.testing.expectEqual(ast.Expr.Op.@"and", e.kind.binary.op);
    try std.testing.expectEqual(ast.Expr.Op.ge, e.kind.binary.lhs.kind.binary.op);
    try std.testing.expectEqual(ast.Expr.Op.lt, e.kind.binary.rhs.kind.binary.op);
    try std.testing.expectEqual(@as(u32, 1), e.span.col);
    try std.testing.expectEqual(@as(u32, 28), e.kind.binary.rhs.span.col);
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

test "any bytes are read or refused, never crash" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [512]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            var diags: source.Diagnostics = .{};
            defer diags.deinit(std.testing.allocator);
            _ = parse(arena.allocator(), std.testing.allocator, &diags, bytes, .{ .file = 0, .line = 1, .col = 1 }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
        }
    }.one, .{});
}
