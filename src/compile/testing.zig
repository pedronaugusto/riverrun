//! Stories compiled from their text for the compile layer's tests: read,
//! checked, compiled, then told by a session over the default store.

const std = @import("std");
const syntax = @import("../syntax.zig");
const check = @import("../check.zig");
const story = @import("riverrun").story;
const facts = @import("riverrun").facts;
const run = @import("riverrun").run;
const compile = @import("../compile.zig");

pub const Told = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    compiled: compile.Compiled,
    story: story.Story,
    words: story.Strings,
    memory: facts.Memory,
    host: run.Host,
    session: run.Session,

    /// `files`, read, checked with `options`, compiled, and a session over them with `host` bound to its story.
    pub fn init(gpa: std.mem.Allocator, files: []const []const u8, options: check.Options, passes: []const compile.Pass, bind: anytype) !*Told {
        const t = try gpa.create(Told);
        errdefer gpa.destroy(t);
        t.* = .{ .gpa = gpa, .arena = .init(gpa), .compiled = undefined, .story = undefined, .words = undefined, .memory = undefined, .host = undefined, .session = undefined };
        errdefer t.arena.deinit();
        t.compiled = try compiled(gpa, t.arena.allocator(), files, options, passes);
        errdefer t.compiled.deinit(gpa);
        t.story = try .init(t.compiled.graph, .{});
        t.words = try .init(t.compiled.words, .{});
        t.memory = try .init(gpa, try t.story.schema(t.arena.allocator()));
        errdefer t.memory.deinit();
        t.host = try bind.host(gpa, &t.story);
        errdefer t.host.deinit();
        t.session = try .init(gpa, &t.story, &t.words, t.memory.store(), &t.host, .{});
        return t;
    }

    pub fn deinit(t: *Told) void {
        const gpa = t.gpa;
        t.session.deinit();
        t.host.deinit();
        t.memory.deinit();
        t.compiled.deinit(gpa);
        t.arena.deinit();
        gpa.destroy(t);
    }

    pub fn section(t: *const Told, name: []const u8) story.SectionId {
        return t.story.sectionNamed(name).?;
    }

    pub fn fact(t: *const Told, name: []const u8) facts.FactId {
        return t.story.factNamed(name).?;
    }

    /// The next line's words, which must be `want`; its effects applied, as a host that delivers it does.
    pub fn line(t: *Told, want: []const u8) !void {
        const step = try t.session.next(.fromRaw(0));
        if (step != .line) return error.TestExpectedLine;
        try std.testing.expectEqualStrings(want, step.line.text);
        for (step.line.effects) |e| _ = try facts.apply(t.memory.store(), e);
    }

    /// The choices offered, which must be `want`, closed ones in brackets.
    pub fn choices(t: *Told, want: []const []const u8) !void {
        const step = try t.session.next(.fromRaw(0));
        if (step != .choices) return error.TestExpectedChoices;
        try std.testing.expectEqual(want.len, step.choices.len);
        for (want, step.choices) |w, have| {
            const shown = if (have.open) have.text else try t.arena.allocator().print("[{s}]", .{have.text});
            try std.testing.expectEqualStrings(w, shown);
        }
    }

    /// Effects reached on their own, applied.
    pub fn effects(t: *Told) !void {
        const step = try t.session.next(.fromRaw(0));
        if (step != .effects) return error.TestExpectedEffects;
        for (step.effects) |e| _ = try facts.apply(t.memory.store(), e);
    }

    pub fn end(t: *Told) !void {
        const step = try t.session.next(.fromRaw(0));
        if (step != .end) return error.TestExpectedEnd;
    }
};

/// No externs and no things: the host that serves such a story.
pub const NoHost = struct {
    pub fn host(_: NoHost, _: std.mem.Allocator, _: *const story.Story) !run.Host {
        return .none;
    }
};

/// `files` read, checked and compiled; diagnostics printed, and none allowed.
pub fn compiled(gpa: std.mem.Allocator, arena: std.mem.Allocator, files: []const []const u8, options: check.Options, passes: []const compile.Pass) !compile.Compiled {
    var diags: syntax.Diagnostics = .{};
    defer diags.deinit(gpa);
    const trees = try arena.alloc(syntax.ast.File, files.len);
    for (files, trees, 0..) |text, *tree, i| {
        tree.* = try syntax.parse(arena, gpa, &diags, @intCast(i), try arena.print("f{d}.river", .{i}), text); // safe: a test's few files
    }
    var checked = try check.run(gpa, &diags, trees, options);
    defer checked.deinit();
    if (diags.errors() > 0) return error.TestStoryRefused;
    return compile.run(gpa, &diags, &checked, .{ .passes = passes });
}
