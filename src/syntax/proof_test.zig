//! The proof: the WAKE prototype's whole story, read without a problem.

const std = @import("std");
const syntax = struct {
    const parse = @import("parse.zig").parseFile;
    const Diagnostics = @import("source.zig").Diagnostics;
};

const files = .{ "cast", "1969", "1985", "1998", "years", "wake", "back", "rest" };

test "every file of the proof reads without a problem" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: syntax.Diagnostics = .{};
    defer diags.deinit(gpa);
    var sections: usize = 0;
    inline for (files, 0..) |name, i| {
        const f = try syntax.parse(arena.allocator(), gpa, &diags, i, name ++ ".river", @embedFile("testdata/proof/" ++ name ++ ".river"));
        sections += f.sections.len;
    }
    for (diags.list.items) |d| std.debug.print("{s}:{d}:{d}: {s}\n", .{ "proof", d.span.line, d.span.col, d.message });
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
    try std.testing.expect(sections >= 20);
}
