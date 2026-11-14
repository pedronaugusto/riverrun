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

/// Reads `words`, of file `file`, into its pieces, each placed where it is written.
pub fn parse(arena: std.mem.Allocator, gpa: std.mem.Allocator, diags: *source.Diagnostics, file: source.FileId, words: source.Placed) Error!ast.Text {
    const text = words.text;
    var pieces: std.ArrayList(ast.Piece) = .empty;
    var lit: std.ArrayList(u8) = .empty;
    // where the literal run being gathered starts
    var run: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\\' and i + 1 < text.len and (text[i + 1] == '{' or text[i + 1] == '}')) {
            try lit.append(arena, text[i + 1]);
            i += 2;
            continue;
        }
        if (c == '}') {
            try diags.add(gpa, words.cut(i, i + 1).span(file), .err, "`}}` has no `{{` before it", .{});
            return error.Invalid;
        }
        if (c != '{') {
            try lit.append(arena, c);
            i += 1;
            continue;
        }
        const close = matching(text, i) orelse {
            try diags.add(gpa, words.cut(i, i + 1).span(file), .err, "`{{` is not closed", .{});
            return error.Invalid;
        };
        if (lit.items.len > 0) {
            try pieces.append(arena, .{ .span = words.cut(run, i).span(file), .kind = .{ .literal = try lit.toOwnedSlice(arena) } });
        }
        try pieces.append(arena, .{ .span = words.cut(i, close + 1).span(file), .kind = try braced(arena, gpa, diags, file, words.cut(i + 1, close)) });
        i = close + 1;
        run = i;
    }
    if (lit.items.len > 0) try pieces.append(arena, .{ .span = words.cut(run, text.len).span(file), .kind = .{ .literal = try lit.toOwnedSlice(arena) } });
    return pieces.toOwnedSlice(arena);
}

// What is between braces: a selection, alternatives, `cond: a | b`, or a value.
fn braced(arena: std.mem.Allocator, gpa: std.mem.Allocator, diags: *source.Diagnostics, file: source.FileId, inner: source.Placed) Error!ast.Piece.Kind {
    if (arrowAt(inner.text)) |arrow| return selected(arena, gpa, diags, file, inner, arrow);
    if (std.mem.findScalar(u8, inner.text, ':')) |colon| {
        if (alternativesOf(std.mem.trim(u8, inner.text[0..colon], " "))) |kind| {
            var options: std.ArrayList(ast.Text) = .empty;
            var start = colon + 1;
            var depth: usize = 0;
            for (inner.text[colon + 1 ..], colon + 1..) |c, i| switch (c) {
                '{' => depth += 1,
                '}' => depth -|= 1,
                '|' => if (depth == 0) {
                    try options.append(arena, try parse(arena, gpa, diags, file, inner.cut(start, i).trim()));
                    start = i + 1;
                },
                else => {},
            };
            try options.append(arena, try parse(arena, gpa, diags, file, inner.from(start).trim()));
            return .{ .alternatives = .{ .kind = kind, .options = try options.toOwnedSlice(arena) } };
        }
        const cond = try expr.parse(arena, gpa, diags, file, inner.to(colon).trim());
        const rest = inner.from(colon + 1);
        const bar = std.mem.findScalar(u8, rest.text, '|');
        const a = if (bar) |b| rest.to(b) else rest;
        const b = if (bar) |x| rest.from(x + 1) else rest.from(rest.text.len);
        return .{ .choose = .{
            .cond = cond.*,
            .then = try parse(arena, gpa, diags, file, a.trim()),
            .otherwise = try parse(arena, gpa, diags, file, b.trim()),
        } };
    }
    return .{ .value = (try expr.parse(arena, gpa, diags, file, inner.trim())).* };
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
fn selected(arena: std.mem.Allocator, gpa: std.mem.Allocator, diags: *source.Diagnostics, file: source.FileId, inner: source.Placed, arrow: usize) Error!ast.Piece.Kind {
    const operand = try expr.parse(arena, gpa, diags, file, inner.to(arrow).trim());
    var branches: std.ArrayList(ast.Branch) = .empty;
    var start = arrow + 2;
    var depth: usize = 0;
    var i = start;
    while (i <= inner.text.len) : (i += 1) {
        const end = i == inner.text.len;
        if (!end) switch (inner.text[i]) {
            '{' => depth += 1,
            '}' => depth -|= 1,
            else => {},
        };
        if (!end and !(inner.text[i] == '|' and depth == 0)) continue;
        try branches.append(arena, try branch(arena, gpa, diags, file, inner.cut(start, i)));
        start = i + 1;
    }
    return .{ .select = .{ .operand = operand.*, .branches = try branches.toOwnedSlice(arena) } };
}

// `label: words`
fn branch(arena: std.mem.Allocator, gpa: std.mem.Allocator, diags: *source.Diagnostics, file: source.FileId, raw: source.Placed) Error!ast.Branch {
    const whole = raw.trim();
    const colon = std.mem.findScalar(u8, whole.text, ':') orelse {
        try diags.add(gpa, whole.span(file), .err, "a branch of a selection is `label: words`: `one: pelt`, `feminine: she`", .{});
        return error.Invalid;
    };
    const label = whole.to(colon).trim();
    if (label.text.len == 0) {
        try diags.add(gpa, whole.span(file), .err, "a branch of a selection is `label: words`: `one: pelt`, `feminine: she`", .{});
        return error.Invalid;
    }
    return .{
        .span = whole.span(file),
        .label = .{ .text = label.text, .span = label.span(file) },
        .text = try parse(arena, gpa, diags, file, whole.from(colon + 1).trim()),
    };
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

test "text holds literals, values and words chosen by a condition" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    const t = try parse(arena.allocator(), std.testing.allocator, &diags, 0, .{ .text = "Frank died at {dies_at}. { life = go: You came all this way. | You came. }", .at = 0 });
    try std.testing.expectEqual(@as(usize, 4), t.len);
    try std.testing.expectEqualStrings("Frank died at ", t[0].kind.literal);
    try std.testing.expectEqualStrings("dies_at", t[1].kind.value.kind.name);
    try std.testing.expectEqualStrings("You came all this way.", t[3].kind.choose.then[0].kind.literal);
    try std.testing.expectEqualStrings("You came.", t[3].kind.choose.otherwise[0].kind.literal);
}

test "alternatives hold their options, braces nesting inside them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    const t = try parse(arena.allocator(), std.testing.allocator, &diags, 0, .{ .text = "Margaret {cycle: counts | hums | counts {hour}} again.", .at = 0 });
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
    const alt = t[1].kind.alternatives;
    try std.testing.expectEqual(ast.Alternatives.cycle, alt.kind);
    try std.testing.expectEqual(@as(usize, 3), alt.options.len);
    try std.testing.expectEqualStrings("hums", alt.options[1][0].kind.literal);
    try std.testing.expectEqualStrings("hour", alt.options[2][1].kind.value.kind.name);
}

test "a selection labels its branches by category" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    const t = try parse(arena.allocator(), std.testing.allocator, &diags, 0, .{ .text = "{count(pelt) -> one: a pelt | other: {count(pelt)} pelts} left.", .at = 0 });
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
    const sel = t[0].kind.select;
    try std.testing.expectEqualStrings("count", sel.operand.kind.call.name.text);
    try std.testing.expectEqual(@as(usize, 2), sel.branches.len);
    try std.testing.expectEqualStrings("other", sel.branches[1].label.text);
    try std.testing.expectEqualStrings(" pelts", sel.branches[1].text[1].kind.literal);
}

test "an unclosed brace is reported" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(std.testing.allocator);
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), std.testing.allocator, &diags, 0, .{ .text = "She {waits", .at = 0 }));
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
            _ = parse(arena.allocator(), std.testing.allocator, &diags, 0, .{ .text = bytes, .at = 0 }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
        }
    }.one, .{});
}
