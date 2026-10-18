//! A scope's facts as bytes: what a host saves for a moment of a life, and
//! what lantern commits to relic.
//!
//! A snapshot names every fact and every item, so it can be restored under
//! another version of the story: facts are matched by name, an item by name
//! within its fact, and what no longer fits is reported, never guessed. The
//! layout, all integers little-endian:
//!
//!     magic    "RRFACTS\x00"
//!     version  u16 (1), flags u16 (0)
//!     story    u64     the hash of the story it was taken under
//!     scope    str
//!     count    u32
//!     facts    count × { name str, kind u8, value }
//!
//!     str      u16 length, then that many bytes of UTF-8
//!     value    boolean u8 (0 or 1) · int i64 · one_of str (empty: none)
//!              · set_of u16 count, then count × str · text str
//!              · ref u8 form, then form 0: u64 handle · form 1: str id
//!
//! A `ref` to a thing a story names by its text id is saved by that id, so a
//! host may number its handles anew each run; any other is saved as the
//! host's handle, which must then be the thing's lasting id.

const std = @import("std");
const value = @import("value.zig");
const schema_ = @import("schema.zig");
const Memory = @import("memory.zig").Memory;

const FactId = value.FactId;
const ScopeId = value.ScopeId;
const Kind = value.Kind;
const Value = value.Value;

pub const magic = "RRFACTS\x00";
pub const version: u16 = 1;

pub const Error = error{
    OutOfMemory,
    Truncated,
    BadMagic,
    UnsupportedVersion,
    /// The snapshot is of another scope.
    WrongScope,
    TrailingBytes,
    NameTooLong,
    TextTooLong,
    TooManyFacts,
    TooManyItems,
    BadKind,
    BadBoolean,
    NotUtf8,
    DuplicateFact,
};

/// A fact as saved: values by name, so a restore can match them to the story it is restored under.
pub const Saved = struct {
    name: []const u8,
    value: union(Kind) {
        boolean: bool,
        int: i64,
        one_of: ?[]const u8,
        set_of: []const []const u8,
        text: []const u8,
        ref: SavedRef,
    },
};

pub const SavedRef = union(enum) { handle: u64, id: []const u8 };

/// Between the host's handles and the text ids a story names its things by, so a snapshot keeps the id.
pub const RefNames = struct {
    user: ?*anyopaque = null,
    /// The text id of the thing of `kind` whose handle is `handle`, if a story names it.
    idOf: *const fn (user: ?*anyopaque, kind: []const u8, handle: u64) ?[]const u8 = noId,
    /// The handle of the thing of `kind` named `id`, if the host knows it.
    handleOf: *const fn (user: ?*anyopaque, kind: []const u8, id: []const u8) ?u64 = noHandle,

    /// Every ref saved as the host's handle.
    pub const none: RefNames = .{};

    fn noId(_: ?*anyopaque, _: []const u8, _: u64) ?[]const u8 {
        return null;
    }

    fn noHandle(_: ?*anyopaque, _: []const u8, _: []const u8) ?u64 {
        return null;
    }
};

pub const Report = struct {
    /// Whether the snapshot was taken under this very story.
    same_story: bool,
    /// Facts the snapshot held that the story no longer declares in the scope, or declares with another kind.
    dropped: []const []const u8,
    /// Facts of the scope the snapshot held no value for, dropped ones included: they keep their initial values.
    added: []const []const u8,
    /// Values the snapshot held that the fact's items no longer name.
    lost: []const Lost,

    pub const Lost = struct { fact: []const u8, item: []const u8 };
};

pub fn write(m: *const Memory, w: *std.Io.Writer, scope: ScopeId, story_hash: u64) std.Io.Writer.Error!void {
    return writeNamed(m, w, scope, story_hash, .none);
}

/// `write`, with refs to things a story names saved by their ids.
pub fn writeNamed(m: *const Memory, w: *std.Io.Writer, scope: ScopeId, story_hash: u64, names: RefNames) std.Io.Writer.Error!void {
    try w.writeAll(magic);
    try w.writeInt(u16, version, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u64, story_hash, .little);
    try str(w, m.schema.scopes[scope.raw()]);
    var count: u32 = 0;
    for (m.schema.facts) |d| count += @intFromBool(d.scope.eql(scope));
    try w.writeInt(u32, count, .little);
    for (m.schema.facts, m.values) |d, v| {
        if (!d.scope.eql(scope)) continue;
        try str(w, d.name);
        try w.writeByte(@backingInt(d.kind));
        switch (v) {
            .boolean => |x| try w.writeByte(@intFromBool(x)),
            .int => |x| try w.writeInt(i64, x, .little),
            .one_of => |x| try str(w, if (x == Value.none) "" else d.items[x]),
            .set_of => |x| {
                try w.writeInt(u16, @intCast(x.count()), .little); // safe: at most max_items
                var it = x.iterator(.{});
                while (it.next()) |i| try str(w, d.items[i]);
            },
            .text => |x| try str(w, x),
            .ref => |x| if (names.idOf(names.user, d.ref_kind, x)) |id| {
                try w.writeByte(1);
                try str(w, id);
            } else {
                try w.writeByte(0);
                try w.writeInt(u64, x, .little);
            },
        }
    }
}

fn str(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeInt(u16, @intCast(s.len), .little); // safe: names and texts are bounded below 64 KiB
    try w.writeAll(s);
}

/// Reads a snapshot of `scope` and restores it into `m`. The report's names are borrowed from `bytes`.
pub fn read(m: *Memory, arena: std.mem.Allocator, scope: ScopeId, story_hash: u64, bytes: []const u8) Error!Report {
    return readNamed(m, arena, scope, story_hash, bytes, .none);
}

/// `read`, with refs saved by their ids given the host's handles for them.
pub fn readNamed(m: *Memory, arena: std.mem.Allocator, scope: ScopeId, story_hash: u64, bytes: []const u8, names: RefNames) Error!Report {
    var c: Cursor = .{ .bytes = bytes };
    if (!std.mem.eql(u8, try c.take(magic.len), magic)) return error.BadMagic;
    if (try c.int(u16) != version) return error.UnsupportedVersion;
    _ = try c.int(u16);
    const hash = try c.int(u64);
    if (!std.mem.eql(u8, try c.str(value.max_name, error.NameTooLong), m.schema.scopes[scope.raw()])) return error.WrongScope;
    const count = try c.int(u32);
    if (count > value.max_facts) return error.TooManyFacts;
    const saved = try arena.alloc(Saved, count);
    for (saved) |*s| s.* = try c.fact(arena);
    if (c.at != bytes.len) return error.TrailingBytes;
    return restoreSaved(m, arena, scope, hash == story_hash, saved, names);
}

/// Restores facts read from any form of snapshot, matching by name. Nothing changes unless all of it is accepted.
pub fn restoreSaved(m: *Memory, arena: std.mem.Allocator, scope: ScopeId, same_story: bool, saved: []const Saved, names: RefNames) Error!Report {
    var by_name: std.StringHashMapUnmanaged(FactId) = .empty;
    for (m.schema.facts, 0..) |d, i| {
        if (d.scope.eql(scope)) try by_name.put(arena, d.name, .fromRaw(@intCast(i))); // safe: validated to max_facts
    }
    var dropped: std.ArrayList([]const u8) = .empty;
    var lost: std.ArrayList(Report.Lost) = .empty;
    var staged: std.ArrayList(struct { id: FactId, value: Value }) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (saved) |s| {
        if ((try seen.getOrPut(arena, s.name)).found_existing) return error.DuplicateFact;
        const id = by_name.get(s.name) orelse {
            try dropped.append(arena, s.name);
            continue;
        };
        const d = m.schema.decl(id);
        if (d.kind != @as(Kind, s.value)) {
            try dropped.append(arena, s.name);
            continue;
        }
        try staged.append(arena, .{ .id = id, .value = try matched(arena, d, s, &lost, names) });
    }
    var restored: std.bit_set.Static(value.max_facts) = .empty;
    for (staged.items) |st| restored.set(st.id.raw());
    var added: std.ArrayList([]const u8) = .empty;
    for (m.schema.facts, 0..) |d, i| {
        if (d.scope.eql(scope) and !restored.isSet(i)) try added.append(arena, d.name);
    }
    // Owned texts first, so applying cannot fail halfway.
    for (staged.items, 0..) |*st, i| {
        if (st.value != .text or st.value.text.len == 0) continue;
        st.value.text = m.gpa.dupe(u8, st.value.text) catch {
            for (staged.items[0..i]) |done| if (done.value == .text and done.value.text.len > 0) m.gpa.free(done.value.text);
            return error.OutOfMemory;
        };
    }
    m.reset(scope);
    for (staged.items) |st| {
        m.values[st.id.raw()] = st.value;
        if (!st.value.eql(.initial(st.value))) m.changes.mark(st.id);
    }
    return .{ .same_story = same_story, .dropped = dropped.items, .added = added.items, .lost = lost.items };
}

// A saved value in the terms of the fact's declaration now.
fn matched(arena: std.mem.Allocator, d: schema_.Decl, s: Saved, lost: *std.ArrayList(Report.Lost), names: RefNames) Error!Value {
    switch (s.value) {
        .ref => |r| switch (r) {
            .handle => |h| return .{ .ref = h },
            .id => |id| {
                if (names.handleOf(names.user, d.ref_kind, id)) |h| return .{ .ref = h };
                try lost.append(arena, .{ .fact = s.name, .item = id });
                return .{ .ref = Value.no_ref };
            },
        },
        .boolean => |x| return .{ .boolean = x },
        .int => |x| return .{ .int = x },
        .text => |x| {
            if (x.len > value.max_text) return error.TextTooLong;
            return .{ .text = x };
        },
        .one_of => |x| {
            const item = x orelse return .{ .one_of = Value.none };
            if (d.itemNamed(item)) |i| return .{ .one_of = i };
            try lost.append(arena, .{ .fact = s.name, .item = item });
            return .{ .one_of = Value.none };
        },
        .set_of => |items| {
            var set: value.Set = .empty;
            for (items) |item| {
                if (d.itemNamed(item)) |i| set.set(i) else try lost.append(arena, .{ .fact = s.name, .item = item });
            }
            return .{ .set_of = set };
        },
    }
}

const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(c: *Cursor, n: usize) Error![]const u8 {
        if (c.bytes.len - c.at < n) return error.Truncated;
        defer c.at += n;
        return c.bytes[c.at..][0..n];
    }

    fn int(c: *Cursor, comptime T: type) Error!T {
        return std.mem.readInt(T, (try c.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    fn str(c: *Cursor, max: usize, too_long: Error) Error![]const u8 {
        const len = try c.int(u16);
        if (len > max) return too_long;
        const s = try c.take(len);
        if (!std.unicode.utf8ValidateSlice(s)) return error.NotUtf8;
        return s;
    }

    fn fact(c: *Cursor, arena: std.mem.Allocator) Error!Saved {
        const name = try c.str(value.max_name, error.NameTooLong);
        const kind = std.enums.fromInt(Kind, try c.int(u8)) orelse return error.BadKind;
        return .{ .name = name, .value = switch (kind) {
            .boolean => .{ .boolean = switch (try c.int(u8)) {
                0 => false,
                1 => true,
                else => return error.BadBoolean,
            } },
            .int => .{ .int = try c.int(i64) },
            .one_of => one: {
                const item = try c.str(value.max_name, error.NameTooLong);
                break :one .{ .one_of = if (item.len == 0) null else item };
            },
            .set_of => set: {
                const n = try c.int(u16);
                if (n > value.max_items) return error.TooManyItems;
                const items = try arena.alloc([]const u8, n);
                for (items) |*item| item.* = try c.str(value.max_name, error.NameTooLong);
                break :set .{ .set_of = items };
            },
            .text => .{ .text = try c.str(value.max_text, error.TextTooLong) },
            .ref => .{ .ref = switch (try c.int(u8)) {
                0 => .{ .handle = try c.int(u64) },
                1 => .{ .id = try c.str(value.max_name, error.NameTooLong) },
                else => return error.BadKind,
            } },
        } };
    }
};

const testing = @import("testing.zig");

fn filled(gpa: std.mem.Allocator) !Memory {
    var m: Memory = try .init(gpa, testing.schema);
    errdefer m.deinit();
    try m.set(testing.life, .{ .one_of = 1 });
    var kept: value.Set = .empty;
    kept.set(0);
    kept.set(2);
    try m.set(testing.kept, .{ .set_of = kept });
    try m.set(testing.met, .{ .boolean = true });
    try m.set(testing.hour, .{ .int = 21 });
    try m.set(testing.name, .{ .text = "Iris" });
    return m;
}

test "a scope's snapshot restores exactly, and leaves the other scopes alone" {
    const gpa = std.testing.allocator;
    var m = try filled(gpa);
    defer m.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(&m, &out.writer, testing.life_scope, 0xfeed);
    m.reset(testing.life_scope);
    try std.testing.expectEqual(Value.none, m.get(testing.life).one_of);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const report = try read(&m, arena.allocator(), testing.life_scope, 0xfeed, out.written());
    try std.testing.expect(report.same_story);
    try std.testing.expectEqual(@as(usize, 0), report.dropped.len + report.added.len + report.lost.len);
    try std.testing.expectEqual(@as(u16, 1), m.get(testing.life).one_of);
    try std.testing.expect(m.get(testing.kept).set_of.isSet(2));
    try std.testing.expectEqual(@as(i64, 21), m.get(testing.hour).int);
    try std.testing.expectEqualStrings("Iris", m.get(testing.name).text);
    try std.testing.expectError(error.WrongScope, read(&m, arena.allocator(), testing.player_scope, 0xfeed, out.written()));
}

test "a snapshot restored under a changed story matches facts and items by name" {
    const gpa = std.testing.allocator;
    var m = try filled(gpa);
    defer m.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(&m, &out.writer, testing.life_scope, 1);
    // The next version: `met` renamed, `dad` gone from what was kept, `life` gains a value before the old ones, `hour` is now text,
    // and the refs `target` and `ally` gone.
    const next: schema_.Schema = .{ .scopes = &.{ "life", "player" }, .facts = &.{
        .{ .name = "hour", .scope = testing.life_scope, .kind = .text },
        .{ .name = "life", .scope = testing.life_scope, .kind = .one_of, .items = &.{ "unborn", "stay", "go" } },
        .{ .name = "spoke", .scope = testing.life_scope, .kind = .boolean },
        .{ .name = "kept", .scope = testing.life_scope, .kind = .set_of, .items = &.{ "stock", "ruth" } },
    } };
    var n: Memory = try .init(gpa, next);
    defer n.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const report = try read(&n, arena.allocator(), testing.life_scope, 2, out.written());
    try std.testing.expect(!report.same_story);
    try std.testing.expectEqual(@as(u16, 2), n.get(.fromRaw(1)).one_of);
    try std.testing.expect(n.get(.fromRaw(3)).set_of.isSet(1));
    try std.testing.expectEqual(@as(usize, 1), n.get(.fromRaw(3)).set_of.count());
    try std.testing.expectEqual(@as(usize, 4), report.dropped.len);
    try std.testing.expectEqualStrings("met", report.dropped[0]);
    try std.testing.expectEqualStrings("hour", report.dropped[1]);
    try std.testing.expectEqualStrings("target", report.dropped[2]);
    try std.testing.expectEqual(@as(usize, 2), report.added.len);
    try std.testing.expectEqualStrings("hour", report.added[0]);
    try std.testing.expectEqualStrings("spoke", report.added[1]);
    try std.testing.expectEqual(@as(usize, 1), report.lost.len);
    try std.testing.expectEqualStrings("dad", report.lost[0].item);
}

test "a refused snapshot changes nothing" {
    const gpa = std.testing.allocator;
    var m = try filled(gpa);
    defer m.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(&m, &out.writer, testing.life_scope, 1);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const bytes = out.written();
    try std.testing.expectError(error.Truncated, read(&m, arena.allocator(), testing.life_scope, 1, bytes[0 .. bytes.len - 1]));
    try std.testing.expectError(error.BadMagic, read(&m, arena.allocator(), testing.life_scope, 1, "RRFACTX\x00"));
    try std.testing.expectEqual(@as(u16, 1), m.get(testing.life).one_of);
}

test "any bytes are restored or refused, never crash" {
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

test "a ref a story names is saved by its id, any other by the host's handle" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const Names = struct {
        // The host's handles this run, and the next run's: margaret is 7 now, 70 after a restart.
        fn idOf(user: ?*anyopaque, kind: []const u8, handle: u64) ?[]const u8 {
            _ = user;
            return if (std.mem.eql(u8, kind, "person") and handle == 7) "margaret" else null;
        }
        fn handleOf(user: ?*anyopaque, kind: []const u8, id: []const u8) ?u64 {
            _ = user;
            return if (std.mem.eql(u8, kind, "person") and std.mem.eql(u8, id, "margaret")) 70 else null;
        }
    };
    const names: RefNames = .{ .idOf = Names.idOf, .handleOf = Names.handleOf };
    var m: Memory = try .init(gpa, testing.schema);
    defer m.deinit();
    try m.set(testing.target, .{ .ref = 7 });
    try m.set(testing.ally, .{ .ref = 900 });
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeNamed(&m, &out.writer, testing.life_scope, 1, names);
    var again: Memory = try .init(gpa, testing.schema);
    defer again.deinit();
    const report = try readNamed(&again, arena.allocator(), testing.life_scope, 1, out.written(), names);
    try std.testing.expectEqual(@as(usize, 0), report.lost.len);
    try std.testing.expectEqual(@as(u64, 70), again.get(testing.target).ref);
    try std.testing.expectEqual(@as(u64, 900), again.get(testing.ally).ref);
    // a host that no longer knows the thing loses it, and says so
    var lost: Memory = try .init(gpa, testing.schema);
    defer lost.deinit();
    const r = try readNamed(&lost, arena.allocator(), testing.life_scope, 1, out.written(), .none);
    try std.testing.expectEqualStrings("margaret", r.lost[0].item);
    try std.testing.expectEqual(Value.no_ref, lost.get(testing.target).ref);
}
