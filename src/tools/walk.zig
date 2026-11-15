//! A compiled story told a bounded number of steps, as a game would tell
//! it: loaded and validated (`Loaded`), its externs bound to a host that
//! answers every query as `Loaded.answers` says (its type's first value
//! unless a player says otherwise) and every action's outcome with its
//! type's first value, its things given handles, and each of its sections
//! started in turn and told until it ends, stops on a named error, or runs
//! out of steps, with every choice taken by the caller (`walk`). Effects are
//! applied to the default store as they come, and the story's rules fire
//! over them as a game fires them: settled when the story starts and after
//! each change, a rule's effects applied in turn, the outcomes its actions
//! owe given once the rules are settled. What the whole compiler's property
//! tells a story by, what a package's own runtime is run over, and what
//! `Play` plays.

const std = @import("std");
const runtime = @import("riverrun");

const story = runtime.story;
const facts = runtime.facts;
const run = runtime.run;
const react = runtime.react;

pub const Options = struct {
    /// The most sections started, in the story's order.
    sections: u32 = 32,
    /// The most steps one section is told.
    steps: u32 = 64,
    /// What answers registered kinds' builtins, the walk's language and its other session options.
    session: run.Options = .{},
    /// Each step as the walk is told it, before it acts on it: for what compares another front with the walk.
    seen: ?Seen = null,
};

/// Each step a walk is told, in order.
pub const Seen = struct {
    ctx: ?*anyopaque,
    step: *const fn (ctx: ?*anyopaque, step: run.Step) void,
};

/// What answers a query when there is no game: by default its type's first value; a player gives its own.
pub const Answers = struct {
    ctx: ?*anyopaque = null,
    answer: *const fn (ctx: ?*anyopaque, query: facts.ExternId, kind: facts.Kind, args: []const facts.Value) facts.Value = first,

    fn first(_: ?*anyopaque, _: facts.ExternId, kind: facts.Kind, _: []const facts.Value) facts.Value {
        return facts.Value.initial(kind);
    }
};

/// Which of the `open` choices offered (at least one) to take: an index into them.
pub const Chooser = struct {
    ctx: ?*anyopaque,
    pick: *const fn (ctx: ?*anyopaque, open: usize) usize,
};

/// What the walk saw: how many lines, choices taken, ends, rules fired, and sections stopped by a named error.
pub const Told = struct {
    lines: u32 = 0,
    chosen: u32 = 0,
    ends: u32 = 0,
    fired: u32 = 0,
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
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    story: story.Story,
    strings: story.Strings,
    schema: facts.Schema,
    memory: facts.Memory,
    host: run.Host,
    /// What each query is answered with.
    answers: Answers = .{},

    pub fn init(l: *Loaded, gpa: std.mem.Allocator, graph: []const u8, words: []const u8) LoadError!void {
        l.gpa = gpa;
        l.answers = .{};
        l.story = try .init(graph, .{});
        l.strings = try .init(words, .{});
        try story.checkStrings(&l.story, &l.strings);
        l.arena = .init(gpa);
        errdefer l.arena.deinit();
        l.schema = try l.story.schema(l.arena.allocator());
        l.memory = try .init(gpa, l.schema);
        errdefer l.memory.deinit();
        l.host = try bind(gpa, l);
    }

    pub fn deinit(l: *Loaded) void {
        l.host.deinit();
        l.memory.deinit();
        l.arena.deinit();
        l.* = undefined;
    }

    /// A new game: every fact back where it starts, in a store of its own, the change log with it.
    pub fn fresh(l: *Loaded) error{OutOfMemory}!void {
        const memory: facts.Memory = facts.Memory.init(l.gpa, l.schema) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // the schema was taken from this story when it loaded
            else => unreachable,
        };
        l.memory.deinit();
        l.memory = memory;
    }

    /// The thing the story names by `id` among the things of `kind`: the handle the host gave it.
    pub fn thing(l: *const Loaded, kind: []const u8, id: []const u8) ?u64 {
        for (0..l.story.len(.things)) |i| {
            const t = l.story.thing(@intCast(i)); // safe: below a u32 count
            if (std.mem.eql(u8, t.kind, kind) and std.mem.eql(u8, t.id, id)) return l.host.refs[i];
        }
        return null;
    }

    /// The id a thing of the story is named by, from its handle.
    pub fn thingName(l: *const Loaded, kind: []const u8, handle_: u64) ?[]const u8 {
        for (l.host.refs, 0..) |h, i| {
            if (h != handle_) continue;
            const t = l.story.thing(@intCast(i)); // safe: refs are one per thing
            if (std.mem.eql(u8, t.kind, kind)) return t.id;
        }
        return null;
    }
};

/// Each section of `l` started in turn and told, every choice taken by `chooser`.
pub fn walk(gpa: std.mem.Allocator, l: *Loaded, options: Options, chooser: Chooser) error{ OutOfMemory, HostNotBound }!Told {
    var session: run.Session = try .init(gpa, &l.story, &l.strings, l.memory.store(), &l.host, options.session);
    defer session.deinit();
    var told: Told = .{};
    const owners: [facts.max_scopes]u64 = @splat(0);
    var rules: react.Rules = react.Rules.init(gpa, &l.story, l.memory.store(), &l.host, &owners, .{ .builtins = options.session.builtins }) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        // a rule's condition that cannot be watched: the game stops before it tells anything
        told.stopped += 1;
        return told;
    };
    defer rules.deinit();
    rules.start() catch {
        told.stopped += 1;
        return told;
    };
    var w: Walk = .{ .s = &l.story, .session = &session, .rules = &rules, .store = l.memory.store(), .options = options, .chooser = chooser, .told = &told };
    for (0..@min(l.story.len(.sections), options.sections)) |i| {
        w.tell(.fromRaw(@intCast(i))) catch |e| { // safe: below the story's section count
            if (e == error.OutOfMemory) return error.OutOfMemory;
            told.stopped += 1;
        };
    }
    return told;
}

const Walk = struct {
    s: *const story.Story,
    session: *run.Session,
    rules: *react.Rules,
    store: facts.Store,
    options: Options,
    chooser: Chooser,
    told: *Told,

    const flow: run.FlowId = .fromRaw(0);

    // One section, from its start, until it ends or the steps run out; an error the runtime names stops it.
    fn tell(w: *Walk, section: story.SectionId) !void {
        try w.session.start(flow, section);
        try w.settle();
        for (0..w.options.steps) |_| {
            const step = try w.session.next(flow);
            if (w.options.seen) |seen| seen.step(seen.ctx, step);
            switch (step) {
                .line => |l| {
                    w.told.lines += 1;
                    for (l.effects) |e| _ = try facts.apply(w.store, e);
                    // the outcomes its effects owe, in order, each its type's first value
                    for (l.effects) |e| if (e == .call) if (e.call.result) |r| try w.session.outcome(flow, facts.Value.initial(w.s.fact(r).kind));
                    try w.settle();
                },
                .choices => |list| {
                    var open: usize = 0;
                    for (list) |c| open += @intFromBool(c.open);
                    if (open == 0) return;
                    // the pick-th open choice
                    var left = w.chooser.pick(w.chooser.ctx, open) % open;
                    var i: usize = 0;
                    while (!list[i].open or left > 0) : (i += 1) left -= @intFromBool(list[i].open);
                    try w.session.choose(flow, i);
                    w.told.chosen += 1;
                },
                .effects => |list| {
                    for (list) |e| _ = try facts.apply(w.store, e);
                    try w.settle();
                },
                .action => |a| {
                    const returns = w.s.externFn(a.call.action).returns orelse return error.NoOutcome;
                    try w.session.outcome(flow, facts.Value.initial(returns.kind));
                    try w.settle();
                },
                .end => {
                    w.told.ends += 1;
                    return;
                },
            }
        }
    }

    // The rules fired to a fixed point over what changed, each one's effects applied in turn; the outcomes their
    // actions owe given, each its type's first value, once they settle, and the rules settled again after.
    fn settle(w: *Walk) !void {
        while (true) {
            var owed: std.ArrayList(facts.FactId) = .empty;
            defer owed.deinit(w.rules.watch.gpa);
            var rounds: u32 = 0;
            while (true) : (rounds += 1) {
                const fired = try w.rules.step();
                if (fired.len == 0) break;
                if (rounds == react.max_rounds) return error.NoFixedPoint;
                for (fired) |f| {
                    w.told.fired += 1;
                    for (f.effects) |e| {
                        if (e == .call) {
                            if (e.call.result) |r| try owed.append(w.rules.watch.gpa, r);
                            continue;
                        }
                        _ = try facts.apply(w.store, e);
                    }
                }
            }
            if (owed.items.len == 0) return;
            for (owed.items) |r| try w.store.set(r, facts.Value.initial(w.s.fact(r).kind));
        }
    }
};

// Every query answered as `l.answers` says, every action with its return type's first value; every thing a handle
// of its own.
fn bind(gpa: std.mem.Allocator, l: *Loaded) run.BindError!run.Host {
    const s = &l.story;
    var b: run.Binder = try .init(gpa, s);
    defer b.deinit();
    const asked = try l.arena.allocator().alloc(Asked, s.len(.externs));
    for (0..s.len(.externs)) |i| {
        const x = s.externFn(.fromRaw(@intCast(i))); // safe: below the story's extern count
        const params = try gpa.alloc(facts.Kind, x.params.len);
        defer gpa.free(params);
        for (params, 0..) |*k, j| k.* = s.param(x.params.start + @as(u32, @intCast(j))).kind; // safe: below a u32 length
        const returns: ?facts.Kind = if (x.returns) |r| r.kind else null;
        asked[i] = .{ .loaded = l, .query = .fromRaw(@intCast(i)), .returns = returns, .action = x.action }; // safe: below the story's extern count
        _ = try b.set(x.name, .{ .params = params, .returns = returns }, .{ .call = Asked.call, .user = &asked[i] });
    }
    var host = try b.finish(null);
    errdefer host.deinit();
    try host.resolveStory(gpa, s, .{ .user = null, .resolve = handle }, null);
    return host;
}

// One extern, as the bound host calls it: a query is answered by the loaded story's `answers`.
const Asked = struct {
    loaded: *const Loaded,
    query: facts.ExternId,
    returns: ?facts.Kind,
    action: bool,

    fn call(user: ?*anyopaque, _: run.Context, args: []const facts.Value) run.QueryError!facts.Value {
        const a: *const Asked = @ptrCast(@alignCast(user.?)); // safe: made by `bind`, one per extern
        const kind = a.returns orelse return facts.Value.initial(.boolean);
        if (a.action) return facts.Value.initial(kind);
        return a.loaded.answers.answer(a.loaded.answers.ctx, a.query, kind, args);
    }
};

/// The handle the walk's host gives a thing of `kind` named `id`: what a player's stand-in for one of the game's
/// things is given too, so every handle the walk sees is named.
pub fn handle(_: ?*anyopaque, kind: []const u8, id: []const u8) ?u64 {
    var h: std.hash.Wyhash = .init(0);
    h.update(kind);
    h.update(&.{0});
    h.update(id);
    return h.final() | 1;
}
