//! The proof: the WAKE prototype's whole story, read without a problem, and
//! printed back as it is written.

const std = @import("std");
const syntax = struct {
    const parse = @import("parse.zig").parseFile;
    const print = @import("print.zig").print;
    const Diagnostics = @import("source.zig").Diagnostics;
};

const files = .{ "cast", "1969", "1985", "1998", "years", "wake", "back", "rest" };

test "every file of the proof reads without a problem, and prints back byte for byte" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: syntax.Diagnostics = .{};
    defer diags.deinit(gpa);
    var sections: usize = 0;
    inline for (files, 0..) |name, i| {
        const text = @embedFile("testdata/proof/" ++ name ++ ".river");
        const f = try syntax.parse(arena.allocator(), gpa, &diags, i, name ++ ".river", text);
        sections += f.sections.len;
        for (diags.list.items) |d| if (d.span.file == i) {
            const at = f.place(d.span);
            std.debug.print("{s}:{d}:{d}: {s}\n", .{ f.path, at.line, at.col, d.message });
        };
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try syntax.print(&out.writer, &f);
        try std.testing.expectEqualStrings(text, out.written());
    }
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
    try std.testing.expect(sections >= 20);
}
