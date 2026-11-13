//! Text: what a line or a choice says. Literal runs, `{fact}` for a value,
//! `{ condition: these words | those words }` for words chosen by a
//! condition, and `{seq: a | b | c}`, `{cycle: …}`, `{once: …}` and
//! `{shuffle: …}` for alternatives, and `{ count -> one: pelt | other: pelts }`
//! for words chosen by a plural category or a gender. `\{` and `\}` are
//! braces themselves.

const std = @import("std");
const ast = @import("ast.zig");
const source = @import("source.zig");
const expr = @import("expr.zig");
const aegis = @import("aegis");

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

// What is between braces: a selection, alternatives, `cond: a | b`, or a value.
fn braced(arena: std.mem.Allocator, gpa: std.mem.Allocator, diags: *source.Diagnostics, inner: []const u8, at: source.Span) Error!ast.Piece {
    if (arrowAt(inner)) |arrow| return selected(arena, gpa, diags, inner, arrow, at);
    if (std.mem.findScalar(u8, inner, ':')) |colon| {
        if (alternativesOf(std.mem.trim(u8, inner[0..colon], " "))) |kind| {
            var options: std.ArrayList(ast.Text) = .empty;
            var start = colon + 1;
            var depth: usize = 0;
            for (inner[colon + 1 ..], colon + 1..) |c, i| switch (c) {
                '{' => depth += 1,
                '}' => depth -|= 1,
                '|' => if (depth == 0) {
                    try options.append(arena, try parse(arena, gpa, diags, std.mem.trim(u8, inner[start..i], " "), shift(at, start)));
                    start = i + 1;
                },
                else => {},
            };
            try options.append(arena, try parse(arena, gpa, diags, std.mem.trim(u8, inner[start..], " "), shift(at, start)));
            return .{ .alternatives = .{ .kind = kind, .options = try options.toOwnedSlice(arena) } };
        }
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

// Where `->` opens a selection: before any `:` or `|`, outside braces.
fn arrowAt(inner: []const u8) ?usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i + 1 < inner.len) : (i += 1) switch (inner[i]) {
        '{' => depth += 1,
        '}' => depth -|= 1,
        ':', '|' => if (depth == 0) return null,
        '-' => if (depth == 0 and inner[i + 1] == '>') return i,
        else => {},
    };
    return null;
}

// `operand -> label: words | label: words`
fn selected(arena: std.mem.Allocator, gpa: std.mem.Allocator, diags: *source.Diagnostics, inner: []const u8, arrow: usize, at: source.Span) Error!ast.Piece {
    const operand = try expr.parse(arena, gpa, diags, std.mem.trim(u8, inner[0..arrow], " "), at);
    var branches: std.ArrayList(ast.Branch) = .empty;
    var start = arrow + 2;
    var depth: usize = 0;
    var i = start;
    while (i <= inner.len) : (i += 1) {
        const end = i == inner.len;
        if (!end) switch (inner[i]) {
            '{' => depth += 1,
            '}' => depth -|= 1,
            else => {},
        };
        if (!end and !(inner[i] == '|' and depth == 0)) continue;
        try branches.append(arena, try branch(arena, gpa, diags, inner[start..i], shift(at, start)));
        start = i + 1;
    }
    return .{ .select = .{ .operand = operand.*, .branches = try branches.toOwnedSlice(arena) } };
}

// `label: words`
fn branch(arena: std.mem.Allocator, gpa: std.mem.Allocator, diags: *source.Diagnostics, raw: []const u8, at: source.Span) Error!ast.Branch {
    const colon = std.mem.findScalar(u8, raw, ':') orelse {
        try diags.add(gpa, at, .err, "a branch of a selection is `label: words`: `one: pelt`, `feminine: she`", .{});
        return error.Invalid;
    };
    const label = std.mem.trim(u8, raw[0..colon], " ");
    var lead: usize = 0;
    while (lead < raw.len and raw[lead] == ' ') lead += 1;
    if (label.len == 0) {
        try diags.add(gpa, at, .err, "a branch of a selection is `label: words`: `one: pelt`, `feminine: she`", .{});
        return error.Invalid;
    }
    return .{ .label = .{ .text = label, .span = shift(at, lead) }, .text = try parse(arena, gpa, diags, std.mem.trim(u8, raw[colon + 1 ..], " "), shift(at, colon + 1)) };
}

/// The alternatives a word before `:` names, if it names one: these four words are the language's.
pub fn alternativesOf(word: []const u8) ?ast.Alternatives {
    inline for (.{ "seq", "cycle", "once", "shuffle" }, .{ ast.Alternatives.seq, .cycle, .once, .shuffle }) |w, k| {
        if (std.mem.eql(u8, word, w)) return k;
    }
    return null;
}

/// The index of the `}` that closes the `{` at `open`, braces nesting.
pub fn matching(text: []const u8, open: usize) ?usize {
    aegis.assert.invariant(text[open] == '{', "`open` is a `{`");
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

test "alternatives hold their options, braces nesting inside them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    const t = try parse(arena.allocator(), std.testing.allocator, &diags, "Margaret {cycle: counts | hums | counts {hour}} again.", .{ .file = 0, .line = 1, .col = 1 });
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
    const alt = t[1].alternatives;
    try std.testing.expectEqual(ast.Alternatives.cycle, alt.kind);
    try std.testing.expectEqual(@as(usize, 3), alt.options.len);
    try std.testing.expectEqualStrings("hums", alt.options[1][0].literal);
    try std.testing.expectEqualStrings("hour", alt.options[2][1].value.kind.name);
}

test "a selection labels its branches by category" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    const t = try parse(arena.allocator(), std.testing.allocator, &diags, "{count(pelt) -> one: a pelt | other: {count(pelt)} pelts} left.", .{ .file = 0, .line = 1, .col = 1 });
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
    const sel = t[0].select;
    try std.testing.expectEqualStrings("count", sel.operand.kind.call.name.text);
    try std.testing.expectEqual(@as(usize, 2), sel.branches.len);
    try std.testing.expectEqualStrings("other", sel.branches[1].label.text);
    try std.testing.expectEqualStrings(" pelts", sel.branches[1].text[1].literal);
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
