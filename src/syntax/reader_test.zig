//! The reader's promises over any input: every file reads to a tree or to
//! diagnostics, never a crash; every diagnostic names a line and column that
//! are in the file; and every name and expression in the tree is placed
//! where its word starts, however many spaces stand before it.
const std = @import("std");
const shakedown = @import("shakedown");
const ast = @import("ast.zig");
const source = @import("source.zig");
const parse = @import("parse.zig");

const testing = std.testing;
const gen = shakedown.gen;

/// The file's lines, as the reader numbers them.
fn lineOf(text: []const u8, number: u32) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: u32 = 1;
    while (it.next()) |l| : (n += 1) if (n == number) return l;
    return null;
}

/// Checks every name and leading word of an expression in `value` against
/// the text at its span.
fn visit(comptime T: type, value: T, text: []const u8) error{TestUnexpectedResult}!void {
    if (T == ast.Name) return expectAt(text, value.span, value.text);
    if (T == ast.Expr) switch (value.kind) {
        .name => |n| try expectAt(text, value.span, n),
        .call => |c| try expectAt(text, value.span, c.name.text),
        .boolean => |b| try expectAt(text, value.span, if (b) "true" else "false"),
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

fn expectAt(text: []const u8, span: source.Span, word: []const u8) error{TestUnexpectedResult}!void {
    if (span.line == 0) return;
    const line = lineOf(text, span.line) orelse return error.TestUnexpectedResult;
    const col: usize = span.col - 1;
    if (col > line.len or !std.mem.startsWith(u8, line[col..], word)) {
        std.debug.print("`{s}` placed at {d}:{d}, where the line reads `{s}`\n", .{ word, span.line, span.col, line[@min(col, line.len)..] });
        return error.TestUnexpectedResult;
    }
}

fn spaces(s: *shakedown.Source, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    for (0..gen.intRange(s, usize, 0, 3)) |_| try out.append(a, ' ');
}

/// A story of sections, conditions and effects, with spaces where a writer
/// may leave them.
fn story(s: *shakedown.Source, a: std.mem.Allocator) ![]const u8 {
    const words = [_][]const u8{ "alpha", "beta", "seen", "night", "kept" };
    var out: std.ArrayList(u8) = .empty;
    for (0..gen.intRange(s, usize, 1, 3)) |n| {
        try out.print(a, "== part_{d}\n", .{n});
        for (0..gen.intRange(s, usize, 1, 5)) |_| switch (gen.intRange(s, u8, 0, 4)) {
            0 => {
                try out.append(a, '{');
                try spaces(s, &out, a);
                try out.appendSlice(a, gen.oneOf(s, []const u8, &words));
                try spaces(s, &out, a);
                try out.appendSlice(a, "}\n  A line said.\n");
            },
            1 => {
                try out.print(a, "  ~ {s} =", .{gen.oneOf(s, []const u8, &words)});
                try spaces(s, &out, a);
                try out.appendSlice(a, gen.oneOf(s, []const u8, &.{ "true", "false", "3", "other" }));
                try out.append(a, '\n');
            },
            2 => {
                try out.print(a, "  ~ {s} +=", .{gen.oneOf(s, []const u8, &words)});
                try spaces(s, &out, a);
                try out.appendSlice(a, gen.oneOf(s, []const u8, &words));
                try out.append(a, '\n');
            },
            3 => {
                try out.appendSlice(a, "  ~");
                try spaces(s, &out, a);
                try out.print(a, "{s}({s})\n", .{ gen.oneOf(s, []const u8, &.{ "rest", "wait" }), gen.oneOf(s, []const u8, &words) });
            },
            else => try out.appendSlice(a, "MUM: Something said.\n"),
        };
    }
    return out.items;
}

test "any story reads with every name placed where its word starts" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            const text = try story(case.source, a);
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

test "any bytes read to a tree or diagnostics, each at a line and column in the file" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            var buffer: [512]u8 = undefined;
            const seed = try story(case.source, a);
            const text = gen.mutated(case.source, &buffer, &.{ seed, "== a\n{ x }\n  ~ y = 1\n-> a\n", "cast:\n  mum: Mum # role\n" });
            var diags: source.Diagnostics = .{};
            defer diags.deinit(testing.allocator);
            _ = try parse.parseFile(a, testing.allocator, &diags, 0, "story.river", text);
            const lines = std.mem.countScalar(u8, text, '\n') + 1;
            try testing.expect(diags.list.items.len <= source.max_diagnostics + 1);
            for (diags.list.items) |d| {
                if (d.span.line == 0) continue;
                try testing.expect(d.span.line <= lines);
                const line = lineOf(text, d.span.line).?;
                try testing.expect(d.span.col >= 1 and d.span.col <= line.len + 1);
            }
        }
    }.one, .{ .cases = 3000, .seed = 0xb17e5 });
}
