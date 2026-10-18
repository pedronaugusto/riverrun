//! A scope's facts as JSON, through strand: the readable form of a snapshot,
//! for tools, tests and a session started from chosen facts.
//!
//!     {"story":"00000000deadbeef","scope":"life","facts":[
//!       {"name":"life","kind":"one_of","one_of":"go"},
//!       {"name":"kept","kind":"set_of","set_of":["ruth","dad"]}]}
//!
//! A `one of` with no value has no `one_of`. Reading it back matches facts
//! and items by name, as a snapshot does.

const std = @import("std");
const strand = @import("strand");
const value = @import("value.zig");
const Memory = @import("memory.zig").Memory;
const snapshot = @import("snapshot.zig");

const ScopeId = value.ScopeId;
const Kind = value.Kind;
const Value = value.Value;

const Entry = struct {
    name: []const u8,
    kind: Kind,
    boolean: ?bool = null,
    int: ?i64 = null,
    one_of: ?[]const u8 = null,
    set_of: ?[]const []const u8 = null,
    text: ?[]const u8 = null,
};

const Document = struct {
    /// The story's hash, as 16 hexadecimal digits.
    story: []const u8,
    scope: []const u8,
    facts: []const Entry,
};

pub const ReadError = snapshot.Error || error{ Malformed, MissingValue };

/// Writes `scope`'s facts as one JSON document; `arena` holds what is built to write it.
pub fn write(m: *const Memory, arena: std.mem.Allocator, w: *std.Io.Writer, scope: ScopeId, story_hash: u64) !void {
    var entries: std.ArrayList(Entry) = .empty;
    for (m.schema.facts, m.values) |d, v| {
        if (!d.scope.eql(scope)) continue;
        var e: Entry = .{ .name = d.name, .kind = d.kind };
        switch (v) {
            .boolean => |x| e.boolean = x,
            .int => |x| e.int = x,
            .one_of => |x| e.one_of = if (x == Value.none) null else d.items[x],
            .set_of => |x| {
                const items = try arena.alloc([]const u8, x.count());
                var it = x.iterator(.{});
                var i: usize = 0;
                while (it.next()) |item| : (i += 1) items[i] = d.items[item];
                e.set_of = items;
            },
            .text => |x| e.text = x,
        }
        try entries.append(arena, e);
    }
    var hex: [16]u8 = undefined;
    _ = std.mem.print(&hex, "{x:0>16}", .{story_hash}) catch unreachable; // unreachable: a u64 is 16 digits
    const doc: Document = .{ .story = &hex, .scope = m.schema.scopes[scope.raw()], .facts = entries.items };
    try strand.json.write(w, doc, .{ .nulls = .omit, .whitespace = .indent_2 });
}

/// Restores `scope` from its JSON form, as `Memory.restore` does from bytes.
pub fn read(m: *Memory, arena: std.mem.Allocator, scope: ScopeId, story_hash: u64, bytes: []const u8) ReadError!snapshot.Report {
    const doc = strand.json.parseLeaky(Document, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    if (!std.mem.eql(u8, doc.scope, m.schema.scopes[scope.raw()])) return error.WrongScope;
    if (doc.facts.len > value.max_facts) return error.TooManyFacts;
    const hash = std.fmt.parseInt(u64, doc.story, 16) catch return error.Malformed;
    const saved = try arena.alloc(snapshot.Saved, doc.facts.len);
    for (saved, doc.facts) |*s, e| {
        s.* = .{ .name = e.name, .value = switch (e.kind) {
            .boolean => .{ .boolean = e.boolean orelse return error.MissingValue },
            .int => .{ .int = e.int orelse return error.MissingValue },
            .one_of => .{ .one_of = e.one_of },
            .set_of => .{ .set_of = e.set_of orelse &.{} },
            .text => .{ .text = e.text orelse "" },
        } };
    }
    return snapshot.restoreSaved(m, arena, scope, hash == story_hash, saved);
}

const testing = @import("testing.zig");

test "a scope's JSON form reads back to the same facts" {
    const gpa = std.testing.allocator;
    var m: Memory = try .init(gpa, testing.schema);
    defer m.deinit();
    try m.set(testing.life, .{ .one_of = 0 });
    var kept: value.Set = .empty;
    kept.set(1);
    try m.set(testing.kept, .{ .set_of = kept });
    try m.set(testing.hour, .{ .int = -3 });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(&m, arena.allocator(), &out.writer, testing.life_scope, 0xbeef);
    try std.testing.expect(std.mem.find(u8, out.written(), "\"one_of\": \"stay\"") != null);
    var n: Memory = try .init(gpa, testing.schema);
    defer n.deinit();
    const report = try read(&n, arena.allocator(), testing.life_scope, 0xbeef, out.written());
    try std.testing.expect(report.same_story);
    try std.testing.expectEqual(@as(u16, 0), n.get(testing.life).one_of);
    try std.testing.expect(n.get(testing.kept).set_of.isSet(1));
    try std.testing.expectEqual(@as(i64, -3), n.get(testing.hour).int);
    try std.testing.expectError(error.Malformed, read(&n, arena.allocator(), testing.life_scope, 0, "{\"story\":1}"));
}

test "any bytes are read as JSON facts or refused, never crash" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var input: [512]u8 = undefined;
            const bytes = input[0..smith.sliceWithHash(&input, 0)];
            var m: Memory = try .init(std.testing.allocator, testing.schema);
            defer m.deinit();
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            _ = read(&m, arena.allocator(), testing.life_scope, 0, bytes) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
        }
    }.one, .{});
}
