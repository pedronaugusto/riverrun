//! The string table: every line's words, by line id, apart from the graph.
//!
//! A translation is another string table for the same story: the same ids,
//! each with its template in another language. It is swapped in without
//! touching the graph, and `check` says whether it fits the story: every
//! line there, every template using its slots as the graph declares them.
//! Ids are kept in ascending order, so a line is found by binary search.

const std = @import("std");
const format = @import("format.zig");
const tables = @import("tables.zig");
const templates = @import("template.zig");
const model = @import("model.zig");
const Story = @import("reader.zig").Story;

pub const magic = "RIVERTXT".*;

pub const Table = enum(u32) { meta, bytes, ids, entries };

pub const Meta = extern struct {
    /// The hash of the story the table was made with; a translation may come from an earlier one.
    story: u64,
    /// The language, as a BCP 47 tag: `en`, `pt-BR`.
    locale: format.Str,
};

pub const Entry = extern struct {
    /// The `# id` text the id is the hash of, for tools and voice scripts.
    id_text: format.Str,
    template: format.Str,
};

pub fn Record(comptime t: Table) type {
    return switch (t) {
        .meta => Meta,
        .bytes => u8,
        .ids => u64,
        .entries => Entry,
    };
}

const Blob = tables.Tables(Table, Record);

pub const Error = tables.Error;

pub const Strings = struct {
    t: Blob,

    pub fn init(bytes: []const u8, options: @import("reader.zig").Options) Error!Strings {
        const t: Blob = try .open(bytes, magic, options.verify_hash);
        if (t.len(.meta) != 1) return error.MissingTable;
        const text = t.raw(.bytes);
        if (!std.unicode.utf8ValidateSlice(text)) return error.BadName;
        if (!tables.validName(text, t.get(.meta, 0).locale)) return error.BadName;
        if (t.len(.entries) != t.len(.ids)) return error.BadTable;
        var last: u64 = 0;
        for (0..t.len(.ids)) |i| {
            const id = t.get(.ids, @intCast(i)); // safe: below a u32 count
            if (id <= last) return error.Unsorted;
            last = id;
            const e = t.get(.entries, @intCast(i)); // safe: below a u32 count
            if (!tables.validName(text, e.id_text) or !tables.validName(text, e.template)) return error.BadName;
            templates.validate(str(text, e.template), null) catch return error.BadTemplate;
        }
        return .{ .t = t };
    }

    pub fn len(s: *const Strings) u32 {
        return s.t.len(.ids);
    }

    pub fn locale(s: *const Strings) []const u8 {
        return str(s.t.raw(.bytes), s.t.get(.meta, 0).locale);
    }

    pub fn story(s: *const Strings) u64 {
        return s.t.get(.meta, 0).story;
    }

    pub fn find(s: *const Strings, id: model.LineId) ?u32 {
        var lo: u32 = 0;
        var hi: u32 = s.len();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            // a zero names no line: not a table the compiler wrote, so no line is found in it
            const here = model.LineId.fromRaw(s.t.get(.ids, mid)) catch return null;
            switch (id.compare(here)) {
                .eq => return mid,
                .gt => lo = mid + 1,
                .lt => hi = mid,
            }
        }
        return null;
    }

    /// The line's template, as `template` reads it.
    pub fn template(s: *const Strings, id: model.LineId) ?[]const u8 {
        const i = s.find(id) orelse return null;
        return str(s.t.raw(.bytes), s.t.get(.entries, i).template);
    }

    pub fn idText(s: *const Strings, id: model.LineId) ?[]const u8 {
        const i = s.find(id) orelse return null;
        return str(s.t.raw(.bytes), s.t.get(.entries, i).id_text);
    }

    /// Entry `i` in id order, for tools that list the table.
    pub fn at(s: *const Strings, i: u32) struct { id: u64, id_text: []const u8, template: []const u8 } {
        const e = s.t.get(.entries, i);
        const text = s.t.raw(.bytes);
        return .{ .id = s.t.get(.ids, i), .id_text = str(text, e.id_text), .template = str(text, e.template) };
    }
};

fn str(text: []const u8, s: format.Str) []const u8 {
    return text[s.offset..][0..s.len];
}

pub const CheckError = error{ MissingLine, TooManySlots } || templates.Error;

/// Whether `strings` serves `story`: every text's, every speaker's and every
/// tag value's line present, and every template using its text's slots as
/// the graph does (a tag value's using none).
pub fn check(story: *const Story, strings: *const Strings) CheckError!void {
    for (0..story.len(.texts)) |i| {
        const t = story.text(.fromRaw(@intCast(i))); // safe: below a u32 count
        const words = strings.template(t.line) orelse return error.MissingLine;
        var shapes: [format.max_slots]templates.Shape = undefined;
        if (t.slots.len > shapes.len) return error.TooManySlots;
        for (shapes[0..t.slots.len], 0..) |*sh, k| {
            const sl = story.slot(t.slots.start + @as(u32, @intCast(k))); // safe: below max_slots
            sh.* = .{ .kind = sl.kind, .arity = sl.arity };
        }
        try templates.validate(words, shapes[0..t.slots.len]);
    }
    for (0..story.len(.cast)) |i| {
        const c = story.castMember(.fromRaw(@intCast(i))); // safe: validated below none16
        if (strings.find(c.display) == null) return error.MissingLine;
        if (c.relation) |r| if (strings.find(r) == null) return error.MissingLine;
    }
    for (0..story.len(.tag_values)) |i| {
        const line = story.tagValue(@intCast(i)).line orelse continue; // safe: below a u32 count
        const words = strings.template(line) orelse return error.MissingLine;
        try templates.validate(words, &.{});
    }
}

/// A line for `write`.
pub const Line = struct { id: model.LineId, id_text: []const u8, template: []const u8 };

/// A string table of `lines`, in any order; an id given twice is refused.
pub fn write(gpa: std.mem.Allocator, lines: []const Line, locale: []const u8, story_hash: u64) error{ OutOfMemory, TooLarge, DuplicateLineId }![]u8 {
    const sorted = try gpa.dupe(Line, lines);
    defer gpa.free(sorted);
    std.mem.sortUnstable(Line, sorted, {}, struct {
        fn less(_: void, a: Line, b: Line) bool {
            return a.id.compare(b.id) == .lt;
        }
    }.less);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    const ids = try gpa.alloc(u64, sorted.len);
    defer gpa.free(ids);
    const entries = try gpa.alloc(Entry, sorted.len);
    defer gpa.free(entries);
    for (sorted, ids, entries, 0..) |l, *id, *e, i| {
        if (i > 0 and sorted[i - 1].id.eql(l.id)) return error.DuplicateLineId;
        id.* = l.id.raw();
        e.* = .{ .id_text = try span(gpa, &text, l.id_text), .template = try span(gpa, &text, l.template) };
    }
    const meta = [_]Meta{.{ .story = story_hash, .locale = try span(gpa, &text, locale) }};
    return tables.assemble(gpa, magic, &.{
        tables.part(Meta, &meta),
        tables.part(u8, text.items),
        tables.part(u64, ids),
        tables.part(Entry, entries),
    });
}

fn span(gpa: std.mem.Allocator, text: *std.ArrayList(u8), s: []const u8) error{ OutOfMemory, TooLarge }!format.Str {
    if (text.items.len + s.len > format.max_bytes) return error.TooLarge;
    const at: u32 = @intCast(text.items.len); // safe: below max_bytes
    try text.appendSlice(gpa, s);
    return .{ .offset = at, .len = @intCast(s.len) }; // safe: below max_bytes
}

/// A line's id: XxHash64, seed 0, of its `# id` text.
pub fn lineId(id_text: []const u8) error{LineIdZero}!model.LineId {
    return model.LineId.fromRaw(std.hash.XxHash64.hash(0, id_text)) catch error.LineIdZero;
}

test "a string table finds lines by id, and refuses an id given twice" {
    const gpa = std.testing.allocator;
    const a = try lineId("kitchen_1985.go");
    const b = try lineId("kitchen_1985.shop");
    const bytes = try write(gpa, &.{
        .{ .id = a, .id_text = "kitchen_1985.go", .template = "Go." },
        .{ .id = b, .id_text = "kitchen_1985.shop", .template = "Who'll run the shop?" },
    }, "en", 7);
    defer gpa.free(bytes);
    const s: Strings = try .init(bytes, .{});
    try std.testing.expectEqualStrings("Go.", s.template(a).?);
    try std.testing.expectEqualStrings("kitchen_1985.shop", s.idText(b).?);
    try std.testing.expectEqualStrings("en", s.locale());
    try std.testing.expectEqual(@as(?u32, null), s.find(try lineId("nowhere")));
    try std.testing.expectError(error.DuplicateLineId, write(gpa, &.{
        .{ .id = a, .id_text = "kitchen_1985.go", .template = "Go." },
        .{ .id = a, .id_text = "kitchen_1985.go", .template = "Vai." },
    }, "pt", 7));
}
