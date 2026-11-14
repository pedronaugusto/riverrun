//! A compiled story told a bounded number of steps, as a game would tell
//! it: loaded and validated (`Loaded`), its externs bound to a host that
//! answers every query with its type's first value and every action's
//! outcome the same way, its things given handles, and each of its sections
//! started in turn and told until it ends, stops on a named error, or runs
//! out of steps, with every choice taken by the caller (`walk`). Effects are
//! applied to the default store as they come. What the whole compiler's
//! property tells a story by, and what a package's own runtime is run over.

const std = @import("std");
const runtime = @import("riverrun");

const story = runtime.story;
const facts = runtime.facts;
const run = runtime.run;

pub const Options = struct {
    /// The most sections started, in the story's order.
    sections: u32 = 32,
    /// The most steps one section is told.
    steps: u32 = 64,
    /// What answers registered kinds' builtins, the walk's language and its other session options.
    session: run.Options = .{},
};

/// Which of the `open` choices offered (at least one) to take: an index into them.
pub const Chooser = struct {
    ctx: ?*anyopaque,
    pick: *const fn (ctx: ?*anyopaque, open: usize) usize,
};

/// What the walk saw: how many lines, choices taken, ends, and sections stopped by a named error.
pub const Told = struct {
    lines: u32 = 0,
    chosen: u32 = 0,
    ends: u32 = 0,
    /// Sections the runtime stopped with an error of its own, which a game would be told by name.
    stopped: u32 = 0,
};

/// What loading a compiled story refused: the compiler's output is never refused, so any of these is a fault of
/// the compiler's.
pub const LoadError = story.Error || StringsError || facts.SchemaError || run.BindError || error{ OutOfMemory, HostNotBound };

// What `checkStrings` refuses: a string table that does not serve its graph.
const StringsError = @typeInfo(@typeInfo(@TypeOf(story.checkStrings)).@"fn".return_type.?).error_union.error_set;

/// A compiled story loaded as a game loads one: read and validated with its string table, its facts in the
/// default store, its externs bound and its things resolved. It stays where it is made, since the store and the
/// host are borrowed by address.
pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    story: story.Story,
    strings: story.Strings,
    memory: facts.Memory,
    host: run.Host,

    pub fn init(l: *Loaded, gpa: std.mem.Allocator, graph: []const u8, words: []const u8) LoadError!void {
        l.story = try .init(graph, .{});
        l.strings = try .init(words, .{});
        try story.checkStrings(&l.story, &l.strings);
        l.arena = .init(gpa);
        errdefer l.arena.deinit();
        l.memory = try .init(gpa, try l.story.schema(l.arena.allocator()));
        errdefer l.memory.deinit();
        l.host = try bind(gpa, &l.story);
    }

    pub fn deinit(l: *Loaded) void {
        l.host.deinit();
        l.memory.deinit();
        l.arena.deinit();
        l.* = undefined;
    }
};

/// Each section of `l` started in turn and told, every choice taken by `chooser`.
pub fn walk(gpa: std.mem.Allocator, l: *Loaded, options: Options, chooser: Chooser) error{ OutOfMemory, HostNotBound }!Told {
    var session: run.Session = try .init(gpa, &l.story, &l.strings, l.memory.store(), &l.host, options.session);
    defer session.deinit();
    var told: Told = .{};
    const flow: run.FlowId = .fromRaw(0);
    for (0..@min(l.story.len(.sections), options.sections)) |i| {
        tell(&l.story, &session, l.memory.store(), flow, .fromRaw(@intCast(i)), options.steps, chooser, &told) catch { // safe: below the story's section count
            told.stopped += 1;
        };
    }
    return told;
}

// One section, from its start, until it ends or the steps run out; an error the runtime names stops it.
fn tell(s: *const story.Story, session: *run.Session, store: facts.Store, flow: run.FlowId, section: story.SectionId, steps: u32, chooser: Chooser, told: *Told) !void {
    try session.start(flow, section);
    for (0..steps) |_| switch (try session.next(flow)) {
        .line => |l| {
            told.lines += 1;
            for (l.effects) |e| _ = try facts.apply(store, e);
        },
        .choices => |list| {
            var open: usize = 0;
            for (list) |c| open += @intFromBool(c.open);
            if (open == 0) return;
            // the pick-th open choice
            var left = chooser.pick(chooser.ctx, open) % open;
            var i: usize = 0;
            while (!list[i].open or left > 0) : (i += 1) left -= @intFromBool(list[i].open);
            try session.choose(flow, i);
            told.chosen += 1;
        },
        .effects => |list| for (list) |e| {
            _ = try facts.apply(store, e);
        },
        .action => |a| {
            const returns = s.externFn(a.call.action).returns orelse return error.NoOutcome;
            try session.outcome(flow, facts.Value.initial(returns.kind));
        },
        .end => {
            told.ends += 1;
            return;
        },
    };
}

// Every extern answered with its return type's first value; every thing a handle of its own.
fn bind(gpa: std.mem.Allocator, s: *const story.Story) run.BindError!run.Host {
    var b: run.Binder = try .init(gpa, s);
    defer b.deinit();
    for (0..s.len(.externs)) |i| {
        const x = s.externFn(.fromRaw(@intCast(i))); // safe: below the story's extern count
        const params = try gpa.alloc(facts.Kind, x.params.len);
        defer gpa.free(params);
        for (params, 0..) |*k, j| k.* = s.param(x.params.start + @as(u32, @intCast(j))).kind; // safe: below a u32 length
        const returns: ?facts.Kind = if (x.returns) |r| r.kind else null;
        const entry: run.Entry = .{ .call = answers[if (returns) |k| @backingInt(k) else answers.len - 1], .user = null };
        _ = try b.set(x.name, .{ .params = params, .returns = returns }, entry);
    }
    var host = try b.finish(null);
    errdefer host.deinit();
    try host.resolveStory(gpa, s, .{ .user = null, .resolve = handle }, null);
    return host;
}

// By the kind an extern returns, in `facts.Kind`'s order, then an action's with no outcome.
const answers = blk: {
    var list: [std.enums.values(facts.Kind).len + 1]@FieldType(run.Entry, "call") = undefined;
    for (std.enums.values(facts.Kind)) |k| list[@backingInt(k)] = Answer(k).call;
    list[list.len - 1] = Answer(null).call;
    break :blk list;
};

fn Answer(comptime kind: ?facts.Kind) type {
    return struct {
        fn call(_: ?*anyopaque, _: run.Context, _: []const facts.Value) run.QueryError!facts.Value {
            return facts.Value.initial(kind orelse .boolean);
        }
    };
}

fn handle(_: ?*anyopaque, kind: []const u8, id: []const u8) ?u64 {
    var h: std.hash.Wyhash = .init(0);
    h.update(kind);
    h.update(&.{0});
    h.update(id);
    return h.final() | 1;
}
