//! Stories built by hand for the run layer's tests, and a session told over
//! one with the default store.

const std = @import("std");
const facts = @import("../facts.zig");
const story = @import("../story.zig");
const Session = @import("Session.zig");
const host_ = @import("host.zig");
const Host = host_.Host;

const Builder = story.Builder;
const NodeId = story.NodeId;

pub const Built = struct {
    graph: []u8,
    words: []u8,

    pub fn deinit(b: *Built, gpa: std.mem.Allocator) void {
        gpa.free(b.graph);
        gpa.free(b.words);
    }
};

/// The graph and its string table, from a builder done with.
pub fn finish(b: *Builder, gpa: std.mem.Allocator) !Built {
    const graph = try b.bytes(gpa);
    errdefer gpa.free(graph);
    const read: story.Story = try .init(graph, .{});
    return .{ .graph = graph, .words = try b.stringBytes(gpa, "en", read.hash()) };
}

/// Words with no slots.
pub fn words(b: *Builder, id: []const u8, template: []const u8) !story.TextId {
    return b.text(try b.line(id, template), &.{});
}

/// A line of narration, then `next`.
pub fn say(b: *Builder, id: []const u8, template: []const u8, next: ?NodeId) !NodeId {
    return b.node(.{ .step = .{ .line = .{ .text = try words(b, id, template), .next = next } } });
}

pub fn scene(b: *Builder, name: []const u8) !story.SectionId {
    return b.section(.{ .name = name, .visits = try b.visits(name) });
}

/// A session over a built story, its facts in a `Memory` store.
pub const Told = struct {
    gpa: std.mem.Allocator,
    built: Built,
    story: story.Story,
    words: story.Strings,
    arena: std.heap.ArenaAllocator,
    memory: facts.Memory,
    host: Host,
    session: Session,

    /// Takes `built`, and binds `impls` with `user` (nothing, for a story with no externs).
    /// The result must not move, so it is made on `gpa`.
    pub fn init(gpa: std.mem.Allocator, built: Built, user: anytype, comptime impls: anytype) !*Told {
        const t = try gpa.create(Told);
        errdefer gpa.destroy(t);
        t.* = .{ .gpa = gpa, .built = built, .story = try .init(built.graph, .{}), .words = try .init(built.words, .{}), .arena = .init(gpa), .memory = undefined, .host = .none, .session = undefined };
        errdefer t.arena.deinit();
        try story.checkStrings(&t.story, &t.words);
        if (@typeInfo(@TypeOf(impls)).@"struct".field_names.len > 0) t.host = try .bind(gpa, &t.story, user, impls, null);
        errdefer t.host.deinit();
        t.memory = try .init(gpa, try t.story.schema(t.arena.allocator()));
        errdefer t.memory.deinit();
        t.session = try .init(gpa, &t.story, &t.words, t.memory.store(), &t.host, .{});
        return t;
    }

    /// A story with no externs.
    pub fn plain(gpa: std.mem.Allocator, built: Built) !*Told {
        return init(gpa, built, {}, .{});
    }

    pub fn deinit(t: *Told) void {
        t.session.deinit();
        t.host.deinit();
        t.memory.deinit();
        t.arena.deinit();
        t.built.deinit(t.gpa);
        t.gpa.destroy(t);
    }

    pub fn fact(t: *const Told, name: []const u8) facts.FactId {
        return t.story.factNamed(name).?;
    }

    pub fn section(t: *const Told, name: []const u8) story.SectionId {
        return t.story.sectionNamed(name).?;
    }

    /// The next step, which must be a line: its words.
    pub fn line(t: *Told, flow: u8) ![]const u8 {
        const step = try t.session.next(.fromRaw(flow));
        if (step != .line) return error.TestUnexpectedResult;
        return step.line.text;
    }

    pub fn expectLine(t: *Told, flow: u8, expected: []const u8) !void {
        try std.testing.expectEqualStrings(expected, try t.line(flow));
    }

    pub fn expectEnd(t: *Told, flow: u8) !void {
        try std.testing.expect(try t.session.next(.fromRaw(flow)) == .end);
    }
};

/// A host whose one query, `lived`, says whether a life was lived, and remembers what it was asked from.
pub const Lives = struct {
    lived: bool = false,
    asked: usize = 0,
    flow: u8 = 0,
    owner: u64 = 0,

    pub const impls = .{ .lived = answer };

    fn answer(l: *Lives, cx: host_.Context, life: u16) bool {
        _ = life;
        l.asked += 1;
        l.flow = cx.flow;
        l.owner = cx.owner(.fromRaw(2)); // the kitchen's `player` scope, after `story` and `life`
        return l.lived;
    }
};
