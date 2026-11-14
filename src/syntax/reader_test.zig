//! The reader's promises over any input: every file reads to a tree or to
//! diagnostics, never a crash; the tree prints the file back byte for byte;
//! every node's range lies inside its parent's and apart from its siblings',
//! the root's is the whole file and every diagnostic's lies inside it; and
//! every name in the tree is the range its word is written in.
const std = @import("std");
const shakedown = @import("shakedown");
const ast = @import("ast.zig");
const source = @import("source.zig");
const parse = @import("parse.zig");
const print = @import("print.zig");
const lines = @import("lines.zig");

const testing = std.testing;
const gen = shakedown.gen;
const Span = source.Span;

/// Checks every name and leading word of an expression in `value` against
/// the text in its range. A line's id is the tag `id`, its key the `^`.
fn visit(comptime T: type, value: T, text: []const u8) error{TestUnexpectedResult}!void {
    if (T == ast.Name) return expectAt(text, value.span, value.text, .whole);
    if (T == ast.Tag and std.mem.eql(u8, value.key.text, "id")) return expectAt(text, value.key.span, "^", .whole);
    if (T == ast.Expr) switch (value.kind) {
        .name => |n| try expectAt(text, value.span, n, .whole),
        .call => |c| try expectAt(text, value.span, c.name.text, .starts),
        .boolean => |b| try expectAt(text, value.span, if (b) "true" else "false", .whole),
        else => {},
    };
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.field_names, s.field_types) |name, F| try visit(F, @field(value, name), text),
        .@"union" => |u| if (u.tag_type != null) switch (value) {
            inline else => |payload| try visit(@TypeOf(payload), payload, text),
        },
        .pointer => |p| switch (p.size) {
            .one => if (p.child != u8) try visit(p.child, value.*, text),
            .slice => if (p.child != u8) for (value) |item| try visit(p.child, item, text),
            else => {},
        },
        .optional => |o| if (value) |v| try visit(o.child, v, text),
        else => {},
    }
}

fn expectAt(text: []const u8, span: Span, word: []const u8, how: enum { whole, starts }) error{TestUnexpectedResult}!void {
    const ok = span.start <= span.end and span.end <= text.len and switch (how) {
        .whole => std.mem.eql(u8, text[span.start..span.end], word),
        .starts => std.mem.startsWith(u8, text[span.start..span.end], word),
    };
    if (!ok) {
        std.debug.print("`{s}` placed at {d}..{d}, where the text reads `{s}`\n", .{ word, span.start, span.end, text[@min(span.start, text.len)..@min(@max(span.start, span.end), text.len)] });
        return error.TestUnexpectedResult;
    }
}

/// Checks that each node under `value` lies inside `parent` and that the nodes beside one another, `siblings`, do
/// not overlap. A node is a value with a `span`, or a span of its own (a tag's values). A field named `x_span` is
/// where field `x` is written: it is a node beside the others, and what `x` holds lies inside it.
fn nest(comptime T: type, value: T, parent: Span, siblings: *std.ArrayList(Span), a: std.mem.Allocator) error{ OutOfMemory, TestUnexpectedResult }!void {
    if (T == Span) return placeIn(value, parent, siblings, a);
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (@hasField(T, "span") and @FieldType(T, "span") == Span) {
                try placeIn(value.span, parent, siblings, a);
                var own: std.ArrayList(Span) = .empty;
                try fields(T, value, value.span, &own, a);
                return apart(own.items);
            }
            try fields(T, value, parent, siblings, a);
        },
        .@"union" => |u| if (u.tag_type != null) switch (value) {
            inline else => |payload| try nest(@TypeOf(payload), payload, parent, siblings, a),
        },
        .pointer => |p| switch (p.size) {
            .one => if (p.child != u8) try nest(p.child, value.*, parent, siblings, a),
            .slice => if (p.child != u8) for (value) |item| try nest(p.child, item, parent, siblings, a),
            else => {},
        },
        .optional => |o| if (value) |v| try nest(o.child, v, parent, siblings, a),
        else => {},
    }
}

// The fields of a struct nested in `parent` beside `siblings`, its own `span` aside, each `x` inside its `x_span`
// where it has one.
fn fields(comptime T: type, value: T, parent: Span, siblings: *std.ArrayList(Span), a: std.mem.Allocator) error{ OutOfMemory, TestUnexpectedResult }!void {
    const s = @typeInfo(T).@"struct";
    inline for (s.field_names, s.field_types) |name, F| {
        if (comptime std.mem.eql(u8, name, "span") or std.mem.endsWith(u8, name, "_span")) continue;
        const where: ?Span = if (comptime @hasField(T, name ++ "_span")) @field(value, name ++ "_span") else null;
        if (where) |w| {
            try placeIn(w, parent, siblings, a);
            var inside: std.ArrayList(Span) = .empty;
            try nest(F, @field(value, name), w, &inside, a);
            try apart(inside.items);
        } else try nest(F, @field(value, name), parent, siblings, a);
    }
    // a range whose value holds nothing to nest, `{ else }`'s braces
    inline for (s.field_names) |name| {
        if (comptime !std.mem.endsWith(u8, name, "_span") or @hasField(T, name[0 .. name.len - "_span".len])) continue;
        const where: ?Span = @field(value, name);
        if (where) |w| try placeIn(w, parent, siblings, a);
    }
}

fn placeIn(span: Span, parent: Span, siblings: *std.ArrayList(Span), a: std.mem.Allocator) error{ OutOfMemory, TestUnexpectedResult }!void {
    if (span.start > span.end or !parent.holds(span)) {
        std.debug.print("a node at {d}..{d} is outside its parent at {d}..{d}\n", .{ span.start, span.end, parent.start, parent.end });
        return error.TestUnexpectedResult;
    }
    try siblings.append(a, span);
}

fn apart(spans: []Span) error{TestUnexpectedResult}!void {
    if (spans.len < 2) return;
    std.mem.sort(Span, spans, {}, struct {
        fn less(_: void, x: Span, y: Span) bool {
            return x.start < y.start or (x.start == y.start and x.end < y.end);
        }
    }.less);
    for (spans[1..], 1..) |s, i| if (spans[i - 1].end > s.start) {
        std.debug.print("nodes beside one another overlap: {d}..{d} and {d}..{d}\n", .{ spans[i - 1].start, spans[i - 1].end, s.start, s.end });
        return error.TestUnexpectedResult;
    };
}

/// The spans property over a file read from `text`: every node inside its parent and apart from its siblings, the
/// root the whole input, every diagnostic inside the input.
fn expectSpans(a: std.mem.Allocator, file: ast.File, diags: *const source.Diagnostics, text: []const u8) !void {
    try testing.expectEqual(Span{ .file = 0, .start = 0, .end = @intCast(text.len) }, file.span);
    var top: std.ArrayList(Span) = .empty;
    try nest(ast.File, file, file.span, &top, a);
    for (diags.list.items) |d| {
        try testing.expectEqual(@as(source.FileId, 0), d.span.file);
        try testing.expect(d.span.start <= d.span.end and d.span.end <= text.len);
    }
}

/// The print-back property over a file read from `text`: printed, its tree is `text`, unless the reader refused
/// the file whole, and then it said so.
fn expectPrintBack(file: ast.File, diags: *const source.Diagnostics, text: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try print.print(&out.writer, &file);
    if (std.mem.eql(u8, out.written(), text)) return;
    const refused = !std.unicode.utf8ValidateSlice(text) or text.len > lines.max_bytes;
    if (refused and diags.errors() > 0) return;
    std.debug.print("read:    {any}\nprinted: {any}\n", .{ text, out.written() });
    return error.TestUnexpectedResult;
}

fn spaces(s: *shakedown.Source, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    for (0..gen.intRange(s, usize, 0, 3)) |_| try out.append(a, ' ');
}

/// A story of sections, conditions, lines, choices, brackets and flows, with spaces where a writer may leave
/// them.
fn story(s: *shakedown.Source, a: std.mem.Allocator) ![]const u8 {
    const words = [_][]const u8{ "alpha", "beta", "seen", "night", "kept" };
    var out: std.ArrayList(u8) = .empty;
    for (0..gen.intRange(s, usize, 1, 3)) |n| {
        try out.print(a, "== part_{d}", .{n});
        if (gen.boolean(s)) try out.appendSlice(a, " (pool 2)");
        try out.append(a, '\n');
        if (gen.boolean(s)) try out.print(a, "  [card] [count {d}]\n", .{n});
        for (0..gen.intRange(s, usize, 1, 6)) |_| switch (gen.intRange(s, u8, 0, 7)) {
            0 => {
                try out.append(a, '{');
                try spaces(s, &out, a);
                try out.appendSlice(a, gen.oneOf(s, []const u8, &words));
                try spaces(s, &out, a);
                try out.appendSlice(a, "}\n  A line said.\n");
            },
            1 => {
                try out.print(a, "[{s} =", .{gen.oneOf(s, []const u8, &words)});
                try spaces(s, &out, a);
                try out.appendSlice(a, gen.oneOf(s, []const u8, &.{ "true", "false", "3", "other" }));
                try out.append(a, ']');
                try spaces(s, &out, a);
                try out.print(a, "[{s} += {s}]\n", .{ gen.oneOf(s, []const u8, &words), gen.oneOf(s, []const u8, &words) });
            },
            2 => {
                try out.append(a, '[');
                try spaces(s, &out, a);
                try out.print(a, "{s}({s})]\n", .{ gen.oneOf(s, []const u8, &.{ "rest", "wait" }), gen.oneOf(s, []const u8, &words) });
            },
            3 => {
                try out.appendSlice(a, gen.oneOf(s, []const u8, &.{ "MUM: Something said.", "DAD (quietly): Go.", "Narration, {alpha}." }));
                if (gen.boolean(s)) {
                    try spaces(s, &out, a);
                    try out.print(a, " ^k{d}", .{gen.intRange(s, u8, 0, 9)});
                }
                try out.append(a, '\n');
                if (gen.boolean(s)) try out.print(a, "  [at 2.5] [heard {s}, {s}]\n", .{ gen.oneOf(s, []const u8, &words), gen.oneOf(s, []const u8, &words) });
                if (gen.boolean(s)) try out.print(a, "  [{s} -= 1]\n", .{gen.oneOf(s, []const u8, &words)});
            },
            4 => {
                try out.print(a, "* {{ {s} }} Choose it.\n  [side go]\n  -> part_0 ->\n", .{gen.oneOf(s, []const u8, &words)});
            },
            5 => try out.appendSlice(a, gen.oneOf(s, []const u8, &.{ "-> end\n", "<-\n", "- (back) Home.\n", "{ alpha: -> part_0 | <- }\n" })),
            else => try out.appendSlice(a, "MUM: Something said.\n"),
        };
    }
    return out.items;
}

/// A story laid out as writers lay them out: comments on rows and rows of comments, blank rows with and without
/// spaces, brackets, ids, spaces at rows' ends, LF and CRLF, a byte-order mark, and no newline at the end.
fn laidOut(s: *shakedown.Source, a: std.mem.Allocator) ![]const u8 {
    const rows = [_][]const u8{
        "cast:",
        "  mum   \"Mum\"   — her mother",
        "    [gender feminine]",
        "extras: a cellist, the youngest",
        "facts (life):",
        "  spot: one of stairs, piano,",
        "        door",
        "  met: bool   (game)",
        "== kitchen (pool 2)",
        "  [talk] [picture \"a · b // c\"]",
        "MUM: Go.",
        "  [met = true]",
        "- (ask)",
        "* { met } Stay.",
        "  [side go]",
        "  -> ask",
        "+ Run. ^r1",
        "{ met } Go. ^k7f3a2",
        "{ met }",
        "  He waits.",
        "{ else }",
        "  -> end",
        "- (back) Home.",
        "  [pause 0.5]",
        "{ met: -> kitchen | -> end }",
        "-> kitchen ->",
        "ASTRO (laughing manically): Not {n as one: once | other: twice}.",
        "\\[sic\\] she said.",
        "= candidate   when { met }",
        "  [weight 2]",
        "= inline   when { met }   Words. ^w1",
        "  [pause 1] [met = true]",
        "<-",
    };
    var out: std.ArrayList(u8) = .empty;
    if (gen.intRange(s, u8, 0, 7) == 0) try out.appendSlice(a, source.byte_order_mark);
    const crlf = gen.intRange(s, u8, 0, 3) == 0;
    const n = gen.intRange(s, usize, 1, rows.len);
    const from = gen.intRange(s, usize, 0, rows.len - n);
    for (rows[from .. from + n], 0..) |row, i| {
        switch (gen.intRange(s, u8, 0, 7)) {
            0 => try out.appendSlice(a, "// a writer's note\n"),
            1 => {
                try spaces(s, &out, a);
                try out.append(a, '\n');
            },
            else => {},
        }
        try out.appendSlice(a, row);
        if (gen.intRange(s, u8, 0, 3) == 0) {
            try spaces(s, &out, a);
            try out.appendSlice(a, " // why");
        }
        try spaces(s, &out, a);
        const last = i + 1 == n;
        if (last and gen.boolean(s)) break;
        try out.appendSlice(a, if (crlf or gen.intRange(s, u8, 0, 9) == 0) "\r\n" else "\n");
    }
    return out.items;
}

test "any story reads with every name the range its word is written in" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            const text = if (gen.boolean(case.source)) try story(case.source, a) else try laidOut(case.source, a);
            var diags: source.Diagnostics = .{};
            defer diags.deinit(testing.allocator);
            const file = try parse.parseFile(a, testing.allocator, &diags, 0, "story.river", text);
            visit(ast.File, file, text) catch |err| {
                std.debug.print("{s}\n", .{text});
                return err;
            };
        }
    }.one, .{ .cases = 2000, .seed = 0x225bc });
}

/// What the properties over any bytes read: a story of either kind, its bytes changed, cut and spliced with the
/// seeds.
fn anyBytes(s: *shakedown.Source, a: std.mem.Allocator, buffer: []u8) ![]const u8 {
    const seed = if (gen.boolean(s)) try story(s, a) else try laidOut(s, a);
    return gen.mutated(s, buffer, &.{
        seed,
        "== a\n{ x }\n  [y = 1]\n-> a\n",
        "cast:\n  mum: Mum\n    [role] [x = 1]\n",
        "== q\n= a   when { met }\n  * Run.\n= b   when { a > 1 }   -> q\n",
        "extern:\n  f(x: int) -> int (action) (reads s)\n  g()\n",
        "== q\n  * Run.\n    [stage]\n    [x = 1]\n",
        "\u{FEFF}== q   // the start\r\n\r\n  \r\n- (x) * Go. ^a1  \r\n{ a } -> q",
        "== a\n  [t \"q] //\" x] [u]\nASTRO (manic): Hi. ^k\n  [cut(x)] [a · b] [id k]\n~ x\n->> y\n{n -> one: a}\n",
    });
}

test "any bytes read to a tree that prints them back, or are refused whole and said to be" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            var buffer: [512]u8 = undefined;
            const text = try anyBytes(case.source, a, &buffer);
            var diags: source.Diagnostics = .{};
            defer diags.deinit(testing.allocator);
            const file = try parse.parseFile(a, testing.allocator, &diags, 0, "story.river", text);
            try expectPrintBack(file, &diags, text);
        }
    }.one, .{ .cases = 3000, .seed = 0x9e1b });
}

test "any bytes read to a tree whose every node lies inside its parent and apart from its siblings" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            var buffer: [512]u8 = undefined;
            const text = try anyBytes(case.source, a, &buffer);
            var diags: source.Diagnostics = .{};
            defer diags.deinit(testing.allocator);
            const file = try parse.parseFile(a, testing.allocator, &diags, 0, "story.river", text);
            try testing.expect(diags.list.items.len <= source.max_diagnostics + 1);
            expectSpans(a, file, &diags, text) catch |err| {
                std.debug.print("{any}\n", .{text});
                return err;
            };
        }
    }.one, .{ .cases = 3000, .seed = 0xb17e5 });
}

test "a file's layout prints back: comments, blank rows, spaces, CRLF, a byte-order mark, no final newline" {
    const gpa = testing.allocator;
    const texts = [_][]const u8{
        "",
        "\n",
        "\u{FEFF}",
        "\u{FEFF}== a\r\n-> end",
        "// only a comment",
        "== a   // why   \r\n\r\n   \nMUM: Go.   ^k1   // note  \n  [at 2]  [x = 1]  \n",
        "== a\n{ met } Go. ^k2\n- (ask) * Run. ^r2\n  [side go]\n",
        "== a\n  [title \"a ] // b\"]   // c\r\nDAD (quietly): \\[x\\] \\^k ^k3\n",
        "== p (pool)\n= one   when { met }   Words. ^w1\n  [pause 1] [met = true]\n= two\n  [weight 2]\n  Two.\n",
    };
    for (texts) |text| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var diags: source.Diagnostics = .{};
        defer diags.deinit(gpa);
        const file = try parse.parseFile(arena.allocator(), gpa, &diags, 0, "a.river", text);
        try expectPrintBack(file, &diags, text);
        try expectSpans(arena.allocator(), file, &diags, text);
    }
}

test "every node of the proof lies inside its parent and apart from its siblings, and every name is its word" {
    inline for (.{ "cast", "1969", "1985", "1998", "years", "wake", "back", "rest" }) |name| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var diags: source.Diagnostics = .{};
        defer diags.deinit(testing.allocator);
        const text = @embedFile("testdata/proof/" ++ name ++ ".river");
        const file = try parse.parseFile(arena.allocator(), testing.allocator, &diags, 0, name ++ ".river", text);
        try expectSpans(arena.allocator(), file, &diags, text);
        try visit(ast.File, file, text);
    }
}

test "a place is a line and a column worked out from a range, by rows, a byte-order mark aside" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: source.Diagnostics = .{};
    defer diags.deinit(gpa);
    const text = "\u{FEFF}== a\r\n// note\nDAD: Go.\n  [x = 1]";
    const file = try parse.parseFile(arena.allocator(), gpa, &diags, 0, "a.river", text);
    try testing.expectEqual(source.Place{ .line = 1, .col = 4 }, file.place(file.sections[0].name.span));
    try testing.expectEqual(source.Place{ .line = 3, .col = 1 }, file.place(file.sections[0].body[0].span));
    try testing.expectEqual(source.Place{ .line = 4, .col = 3 }, file.place(file.sections[0].body[0].kind.line.effects[0].span));
}

test "a part's `when` with no braces, a word after an extern's marks and a row of tags alone are read, not trapped" {
    const cases = [_]struct { text: []const u8, refused: bool }{
        .{ .text = "== q\n= a   when met\n", .refused = true },
        .{ .text = "== q\n= a   when { met\n", .refused = true },
        .{ .text = "extern:\n  f() -> int (action) x\n", .refused = true },
        .{ .text = "== q\n  * Run.\n    [stage]\n", .refused = false },
        .{ .text = "== q\n{ a | b: -> q }\n", .refused = true },
    };
    for (cases) |case| {
        var state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer state.deinit();
        var diags: source.Diagnostics = .{};
        defer diags.deinit(testing.allocator);
        _ = try parse.parseFile(state.allocator(), testing.allocator, &diags, 0, "story.river", case.text);
        if (case.refused) try testing.expect(diags.errors() > 0);
    }
}
