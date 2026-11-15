//! `riverrun tag`'s promises over any story the reader reads: every byte
//! but the ids it adds prints back as it was; it is idempotent; afterwards
//! every line and choice has an id, each new to the story; and the story
//! compiles to the same story as before, its line ids aside.

const std = @import("std");
const shakedown = @import("shakedown");
const river = @import("riverrun-compiler");
const runtime = @import("riverrun");
const Manuscript = @import("Manuscript.zig");
const tag = @import("tag.zig");
const whole = @import("whole_test.zig");

const syntax = river.syntax;
const ast = syntax.ast;
const gpa = std.testing.allocator;

const joined = whole.joined;

fn printed(a: std.mem.Allocator, f: *const ast.File) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try syntax.print(&out.writer, f);
    return out.written();
}

/// The compiled story as JSON, its hash left out and each line id, as a number and as the text it is written as
/// (where it names the state a line keeps: a choice's visits, its alternatives), named by the order it first
/// appears in, with the words of each line in that order: two stories with the same of these differ only in
/// their ids.
fn unkeyed(a: std.mem.Allocator, graph: []const u8, words: []const u8) !struct { json: []const u8, lines: []const []const u8 } {
    const s: runtime.story.Story = try .init(graph, .{});
    const strings: runtime.story.Strings = try .init(words, .{});
    var out: std.Io.Writer.Allocating = .init(a);
    try river.json.story.write(&s, a, &out.writer);
    const json = out.written();
    const key_line = "\"line\": \"";
    const key_hash = "\"hash\": \"";
    // the lines in the order they first appear, with their words and the text of their ids
    var order: std.ArrayList(u64) = .empty;
    var texts: std.ArrayList([]const u8) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (std.mem.findPos(u8, json, at, key_line)) |found| {
        at = found + key_line.len + 16;
        const id = try std.fmt.parseInt(u64, json[found + key_line.len ..][0..16], 16);
        if (std.mem.findScalar(u64, order.items, id) != null) continue;
        try order.append(a, id);
        try texts.append(a, strings.idText(try .fromRaw(id)) orelse return error.LineWithoutId);
        try lines.append(a, strings.template(try .fromRaw(id)) orelse return error.LineWithoutWords);
    }
    var named: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    // a line's id text is named only inside a string: a hand-written id may be a number (`^0`), which the JSON's own
    // numbers are not
    var quoted = false;
    while (i < json.len) {
        if (std.mem.startsWith(u8, json[i..], key_hash)) {
            try named.appendSlice(a, key_hash);
            i += key_hash.len + 16;
            // inside the string the key's value opens
            quoted = true;
            continue;
        }
        if (std.mem.startsWith(u8, json[i..], key_line)) {
            const id = try std.fmt.parseInt(u64, json[i + key_line.len ..][0..16], 16);
            try named.print(a, "{s}#{d}", .{ key_line, std.mem.findScalar(u64, order.items, id).? });
            i += key_line.len + 16;
            quoted = true;
            continue;
        }
        // a word: a line's id where it is one
        var end = i;
        while (end < json.len and isIdByte(json[end])) end += 1;
        if (end == i) {
            if (json[i] == '"' and (i == 0 or json[i - 1] != '\\')) quoted = !quoted;
            try named.append(a, json[i]);
            i += 1;
            continue;
        }
        const word = json[i..end];
        if (quoted) for (texts.items, 0..) |t, n| {
            if (std.mem.eql(u8, t, word)) break try named.print(a, "#{d}", .{n});
        } else try named.appendSlice(a, word) else try named.appendSlice(a, word);
        i = end;
    }
    // a written id is carried as the line's `id` tag too; a derived one is not
    const tree = try std.json.parseFromSliceLeaky(std.json.Value, a, named.items, .{});
    return .{ .json = try std.json.Stringify.valueAlloc(a, withoutIds(tree), .{ .whitespace = .indent_2 }), .lines = lines.items };
}

// The JSON with every `id` tag taken out of its tag list, and a list it leaves empty taken out too.
fn withoutIds(v: std.json.Value) std.json.Value {
    switch (v) {
        .array => |list| for (list.items) |*item| {
            item.* = withoutIds(item.*);
        },
        .object => |o| {
            var map = o;
            if (map.getPtr("tags")) |tags| if (tags.* == .array) {
                var list = &tags.array;
                var i: usize = 0;
                while (i < list.items.len) {
                    const key = if (list.items[i] == .object) list.items[i].object.get("key") else null;
                    if (key != null and key.? == .string and std.mem.eql(u8, key.?.string, "id")) _ = list.orderedRemove(i) else i += 1;
                }
                if (list.items.len == 0) _ = map.orderedRemove("tags");
            };
            for (map.values()) |*item| item.* = withoutIds(item.*);
            return .{ .object = map };
        },
        else => {},
    }
    return v;
}

// Two texts the same, or the first row where they part, with the rows around it.
fn expectSameRows(want: []const u8, have: []const u8) !void {
    if (std.mem.eql(u8, want, have)) return;
    var w = std.mem.splitScalar(u8, want, '\n');
    var h = std.mem.splitScalar(u8, have, '\n');
    var row: usize = 1;
    while (true) : (row += 1) {
        const a = w.next();
        const b = h.next();
        if (a == null and b == null) break;
        if (a != null and b != null and std.mem.eql(u8, a.?, b.?)) continue;
        std.debug.print("row {d}: before `{s}`, after `{s}`\n", .{ row, a orelse "(none)", b orelse "(none)" });
        break;
    }
    return error.TestUnexpectedResult;
}

fn isIdByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '~';
}

test "tagging any story the reader reads adds ids and nothing else, once, new to the story, and compiles to the same story" {
    try shakedown.check(gpa, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const pages = try whole.storyOf(case.source, a);
            expectTagged(a, pages, case) catch |e| {
                for (pages) |f| std.debug.print("--- {s}\n{s}\n", .{ f.path, f.text });
                return e;
            };
        }
    }.one, .{
        .cases = 1000,
        .seed = 0x7a6,
        // a choice's hand-written id `^0`: its text is a JSON number's too, and naming it there broke the JSON
        .regressions = &.{"2:3:1:5:0:0:5:0:6:0:a:0:0:3:8:7:1:2:0:0:3:0:0:8:0:0:5:0:1:0:0:3:5:0:0:3:2:3:7:1:0:3:0:1:0:0:4:4:1:8:1:0:2:1:0:0:0:0:8:8:0:0:0:1:1:341:0:1"},
        .reach = &.{ "tagged", "compared compiled" },
    });
}

fn expectTagged(a: std.mem.Allocator, pages: []const Manuscript.Page, case: *shakedown.Case) !void {
    var before: Manuscript = try .read(gpa, pages);
    defer before.deinit();
    // tag gives ids only where the reader read the files without an error
    if (before.errors() > 0) return;
    const given = try tag.give(a, before.files);
    var added: u32 = 0;
    const after_pages = try a.alloc(Manuscript.Page, pages.len);
    for (before.files, given.files, given.added, after_pages, pages) |*was, *now, n, *p, page| {
        added += n;
        // every row as it was but for an id where it had none
        try std.testing.expectEqual(was.rows.len, now.rows.len);
        var ids: u32 = 0;
        for (was.rows, now.rows) |r, t| {
            if (r.id.len == 0 and t.id.len > 0) {
                try std.testing.expectEqual(@as(u32, 1), t.before_id);
                try std.testing.expectEqual(@as(usize, 1 + tag.length), t.id.len);
                ids += 1;
                var plain = t;
                plain.before_id = r.before_id;
                plain.id = r.id;
                try std.testing.expectEqualDeep(r, plain);
            } else try std.testing.expectEqualDeep(r, t);
        }
        try std.testing.expectEqual(n, ids);
        const text = try printed(a, now);
        try std.testing.expectEqual(page.text.len + n * (2 + tag.length), text.len);
        p.* = .{ .path = page.path, .text = text };
    }
    if (added > 0) case.reached("tagged");
    // read again: no error, every line and choice has its id, and tagging again changes nothing
    var after: Manuscript = try .read(gpa, after_pages);
    defer after.deinit();
    for (after.diags.list.items) |d| std.debug.print("the tagged files read with a diagnostic: {s}\n", .{d.message});
    try std.testing.expectEqual(before.diags.list.items.len, after.diags.list.items.len);
    try std.testing.expectEqual(@as(usize, 0), (try tag.missing(a, after.files)).len);
    for ((try tag.give(a, after.files)).added) |n| try std.testing.expectEqual(@as(u32, 0), n);
    // the new ids are as many as were added, and none is one the story had or another new one
    var had: std.StringHashMapUnmanaged(void) = .empty;
    for (before.files) |f| for (f.rows) |r| if (r.id.len > 0) try had.put(a, r.id, {});
    var has: std.StringHashMapUnmanaged(void) = .empty;
    for (after.files) |f| for (f.rows) |r| if (r.id.len > 0) try has.put(a, r.id, {});
    try std.testing.expectEqual(had.count() + added, has.count());
    // compiled before, compiled after: the same story but for its ids
    var was_built, var was = try Manuscript.build(gpa, pages, joined, .development);
    defer was_built.deinit();
    defer if (was) |*c| c.deinit(gpa);
    var now_built, var now = try Manuscript.build(gpa, after_pages, joined, .development);
    defer now_built.deinit();
    defer if (now) |*c| c.deinit(gpa);
    const x_story = was orelse return;
    const y_story = now orelse {
        std.debug.print("the story compiled before its ids and not after\n", .{});
        for (now_built.diags.list.items) |d| std.debug.print("  {s}\n", .{d.message});
        return error.TestUnexpectedResult;
    };
    const x = try unkeyed(a, x_story.graph, x_story.words);
    const y = try unkeyed(a, y_story.graph, y_story.words);
    try expectSameRows(x.json, y.json);
    try std.testing.expectEqual(x.lines.len, y.lines.len);
    for (x.lines, y.lines) |l, r| try std.testing.expectEqualStrings(l, r);
    case.reached("compared compiled");
}
