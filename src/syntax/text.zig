//! Text: what a line or a choice says. Literal runs, `{fact}` for a value,
//! and `{ condition: these words | those words }` for words chosen by a
//! condition. `\{` and `\}` are braces themselves.

const std = @import("std");
const ast = @import("ast.zig");
const source = @import("source.zig");
const expr = @import("expr.zig");

pub const Error = expr.Error;

pub fn parse(arena: std.mem.Allocator, gpa: std.mem.Allocator, diags: *source.Diagnostics, text: []const u8, at: source.Span) Error!ast.Text {
    var pieces: std.ArrayList(ast.Piece) = .empty;
    var lit: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\\' and i + 1 < text.len and (text[i + 1] == '{' or text[i + 1] == '}')) {
            try lit.append(arena, text[i + 1]);
            i += 2;
            continue;
        }
        if (c == '}') {
            try diags.add(gpa, shift(at, i), .err, "`}}` has no `{{` before it", .{});
            return error.Invalid;
        }
        if (c != '{') {
            try lit.append(arena, c);
            i += 1;
            continue;
        }
        const close = matching(text, i) orelse {
            try diags.add(gpa, shift(at, i), .err, "`{{` is not closed", .{});
            return error.Invalid;
        };
        if (lit.items.len > 0) {
            try pieces.append(arena, .{ .literal = try lit.toOwnedSlice(arena) });
        }
        try pieces.append(arena, try braced(arena, gpa, diags, text[i + 1 .. close], shift(at, i + 1)));
        i = close + 1;
    }
    if (lit.items.len > 0) try pieces.append(arena, .{ .literal = try lit.toOwnedSlice(arena) });
    return pieces.toOwnedSlice(arena);
}

// What is between braces: `cond: a | b`, or a value.
fn braced(arena: std.mem.Allocator, gpa: std.mem.Allocator, diags: *source.Diagnostics, inner: []const u8, at: source.Span) Error!ast.Piece {
    if (std.mem.findScalar(u8, inner, ':')) |colon| {
        const cond = try expr.parse(arena, gpa, diags, std.mem.trim(u8, inner[0..colon], " "), at);
        const rest = inner[colon + 1 ..];
        const bar = std.mem.findScalar(u8, rest, '|');
        const a = std.mem.trim(u8, if (bar) |b| rest[0..b] else rest, " ");
        const b = if (bar) |x| std.mem.trim(u8, rest[x + 1 ..], " ") else "";
        return .{ .choose = .{
            .cond = cond.*,
            .then = try parse(arena, gpa, diags, a, shift(at, colon + 1)),
            .otherwise = try parse(arena, gpa, diags, b, shift(at, colon + 1 + (bar orelse 0))),
        } };
    }
    return .{ .value = (try expr.parse(arena, gpa, diags, std.mem.trim(u8, inner, " "), at)).* };
}

/// The index of the `}` that closes the `{` at `open`, braces nesting.
pub fn matching(text: []const u8, open: usize) ?usize {
    std.debug.assert(text[open] == '{');
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\\' => i += 1,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Whether the braces at `open` hold words chosen by a condition (`cond: …`) rather than a condition.
pub fn choosesWords(text: []const u8, open: usize, close: usize) bool {
    return std.mem.findScalar(u8, text[open + 1 .. close], ':') != null;
}

fn shift(at: source.Span, by: usize) source.Span {
    return .{ .file = at.file, .line = at.line, .col = at.col + @as(u32, @intCast(by)) };
}

test "text holds literals, values and words chosen by a condition" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    const t = try parse(arena.allocator(), std.testing.allocator, &diags, "Frank died at {dies_at}. { life = go: You came all this way. | You came. }", .{ .file = 0, .line = 1, .col = 1 });
    try std.testing.expectEqual(@as(usize, 4), t.len);
    try std.testing.expectEqualStrings("Frank died at ", t[0].literal);
    try std.testing.expectEqualStrings("dies_at", t[1].value.kind.name);
    try std.testing.expectEqualStrings("You came all this way.", t[3].choose.then[0].literal);
    try std.testing.expectEqualStrings("You came.", t[3].choose.otherwise[0].literal);
}

test "an unclosed brace is reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), std.testing.allocator, &diags, "She {waits", .{ .file = 0, .line = 1, .col = 1 }));
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
            _ = parse(arena.allocator(), std.testing.allocator, &diags, bytes, .{ .file = 0, .line = 1, .col = 1 }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
        }
    }.one, .{});
}
