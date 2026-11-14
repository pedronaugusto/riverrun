//! riverrun's compiler: `.river` files read (`syntax`), checked against a
//! host's vocabulary (`check`) and compiled into the format the runtime
//! tells (`compile`), and the JSON forms tools read (`json`). A game runs it
//! at build time through `addStory`; nothing at run time needs it. It stands
//! on the `riverrun` module, the runtime, and adds what only building needs.

const std = @import("std");

pub const syntax = @import("syntax.zig");
pub const check = @import("check.zig");
pub const compile = @import("compile.zig");
pub const json = @import("json.zig");

const runtime = @import("riverrun");
const facts = runtime.facts;
const story = runtime.story;
const run = runtime.run;

/// What a package adds to a story's language and its build, registered as one in a vocabulary's `packages`: its
/// kinds of section, the tags it adds anywhere beside the host's, its check of the whole story and its compile pass.
pub const Package = struct {
    kinds: []const check.Kind = &.{},
    keys: []const check.Schema.Key = &.{},
    check: ?check.Pass = null,
    compile: ?compile.Pass = null,
    /// Its runtime, as a story is played without the game (`riverrun play`): run as the game runs it.
    running: ?Running = null,
};

/// A package's runtime as riverrun's tools run it when a story is played with no game (`riverrun play`, and the
/// editor's play button): started over the loaded story, stepped whenever the facts change, a clock it keeps moved
/// by it, and what happened said, each time, as news the player sees. So a story with a package's quests or time
/// plays as it would in a game, and the package is the one that says what its runtime did.
pub const Running = struct {
    /// The package's name, as its news is shown under.
    name: []const u8,
    /// The kinds of section the package registered, whose builtins `builtins` answers: filled in by `join`.
    kinds: []const check.Kind = &.{},
    /// Its runtime started over the story `game` holds, its state returned; null when the story has nothing of the
    /// package's (no block of its own). What it refuses stops the play, said in `told.stopped`.
    start: *const fn (gpa: std.mem.Allocator, game: Game, told: *Told) error{ OutOfMemory, Stopped }!?*anyopaque,
    stop: *const fn (gpa: std.mem.Allocator, state: *anyopaque) void,
    /// What answers the builtins it registered, which the story's conditions and words call.
    builtins: ?*const fn (state: *anyopaque) run.Builtins = null,
    /// After the facts changed: what that did, as news into `told`, with the effects the game would apply.
    step: ?*const fn (state: *anyopaque, told: *Told) error{ OutOfMemory, Stopped }!void = null,
    /// The player said what a query answers now: `family` is the stamp it declared, `keyed` its keyed arguments,
    /// as a game bumps a stamp when what the query reads changes.
    bump: ?*const fn (state: *anyopaque, family: []const u8, keyed: []const facts.Value) error{ OutOfMemory, Stopped }!void = null,
    /// The clock fact `clock` moved on `by` ticks by the player: moved by the package, its facts written and what
    /// came due told, when it keeps that clock; false when it does not, and the player moves the fact itself.
    advance: ?*const fn (state: *anyopaque, clock: facts.FactId, by: u64, told: *Told) error{ OutOfMemory, Stopped }!bool = null,

    /// What the runtime runs over: the loaded story, its facts and its bound host, as a game holds them.
    pub const Game = struct {
        story: *const story.Story,
        words: *const story.Strings,
        store: facts.Store,
        host: *const run.Host,
        owners: *const [facts.max_scopes]u64,
        /// A thing standing in for one of the game's, where a role or a value needs one and the game would give
        /// it: a handle the player names it by.
        stand_in: StandIn,
    };

    pub const StandIn = struct {
        ctx: ?*anyopaque,
        give: *const fn (ctx: ?*anyopaque, kind: []const u8, name: []const u8) error{OutOfMemory}!u64,
    };

    /// One thing the runtime did: `what` happened to `name` (`reached` `the_stranger.noticed`, `due` `ramen`), the
    /// words a player is shown for it (a journal's lines), the effects it emits for the game to apply, and a
    /// section the game would tell now (a scheduled scene come due).
    pub const News = struct {
        what: []const u8,
        name: []const u8,
        words: []const []const u8 = &.{},
        effects: []const facts.Effect = &.{},
        section: ?story.SectionId = null,
    };

    /// Where a runtime says what it did: its news in order, copied by `say` onto the player's arena, and why it
    /// stopped, if it did (`Stopped`).
    pub const Told = struct {
        arena: std.mem.Allocator,
        news: std.ArrayList(News) = .empty,
        stopped: ?[]const u8 = null,

        /// News, its words and effects copied.
        pub fn say(t: *Told, n: News) error{OutOfMemory}!void {
            const words = try t.arena.alloc([]const u8, n.words.len);
            for (words, n.words) |*to, from| to.* = try t.arena.dupe(u8, from);
            const effects = try t.arena.alloc(facts.Effect, n.effects.len);
            for (effects, n.effects) |*to, from| to.* = try from.dupe(t.arena);
            try t.news.append(t.arena, .{ .what = try t.arena.dupe(u8, n.what), .name = try t.arena.dupe(u8, n.name), .words = words, .effects = effects, .section = n.section });
        }

        /// Stops the play: what the runtime refused or could not do, in words a writer acts on.
        pub fn stop(t: *Told, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, Stopped } {
            t.stopped = try t.arena.print(fmt, args);
            return error.Stopped;
        }
    };
};

/// A vocabulary as the compiler takes it: the check's options and the compile passes, and the packages' runtimes
/// as a story is played without its game.
pub const Joined = struct {
    options: check.Options,
    passes: []const compile.Pass,
    running: []const Running = &.{},
};

/// A vocabulary's `options` and `passes` with each of its `packages` joined in after the host's own: their kinds,
/// their keys in the host's schema, their checks and their passes. A vocabulary is a Zig file of the host's,
/// `pub const options: check.Options` with, where it has them, `pub const packages: []const Package` and
/// `pub const passes: []const compile.Pass`. Two kinds of one name, or one key twice where both may stand, fail to
/// compile: nothing a package adds is shadowed silently.
pub fn join(comptime vocabulary: type) Joined {
    comptime {
        const packages: []const Package = if (@hasDecl(vocabulary, "packages")) vocabulary.packages else &.{};
        var options: check.Options = vocabulary.options;
        var passes: []const compile.Pass = if (@hasDecl(vocabulary, "passes")) vocabulary.passes else &.{};
        var keys: []const check.Schema.Key = if (options.schema) |s| s.keys else &.{};
        var running: []const Running = &.{};
        for (packages) |p| {
            options.kinds = options.kinds ++ p.kinds;
            keys = keys ++ p.keys;
            if (p.check) |c| options.passes = options.passes ++ &[_]check.Pass{c};
            if (p.compile) |c| passes = passes ++ &[_]compile.Pass{c};
            if (p.running) |r| {
                var with = r;
                with.kinds = p.kinds;
                running = running ++ &[_]Running{with};
            }
        }
        // every pair compared: a host's schema of a few dozen keys is past the default quota
        @setEvalBranchQuota(1000 + 200 * (keys.len * keys.len + options.kinds.len * options.kinds.len));
        distinct(options.kinds, keys);
        if (options.schema == null and keys.len == 0) return .{ .options = options, .passes = passes, .running = running };
        const schema: check.Schema = .{ .keys = keys };
        options.schema = &schema;
        return .{ .options = options, .passes = passes, .running = running };
    }
}

fn distinct(comptime kinds: []const check.Kind, comptime keys: []const check.Schema.Key) void {
    for (kinds, 0..) |k, i| for (kinds[0..i]) |before| if (std.mem.eql(u8, k.name, before.name)) {
        @compileError("two packages register the kind `" ++ k.name ++ "`");
    };
    for (keys, 0..) |k, i| for (keys[0..i]) |before| if (std.mem.eql(u8, k.name, before.name) and overlap(k.on, before.on)) {
        @compileError("the tag `" ++ k.name ++ "` is added twice where both may stand");
    };
}

fn overlap(a: check.Schema.Places, b: check.Schema.Places) bool {
    for (std.enums.values(check.Schema.Place)) |at| if (a.has(at) and b.has(at)) return true;
    return false;
}

test "a vocabulary of many keys joins: every pair is compared within the quota" {
    const Vocabulary = struct {
        const many: check.Schema = .{ .keys = blk: {
            @setEvalBranchQuota(100_000);
            var keys: [80]check.Schema.Key = undefined;
            for (&keys, 0..) |*k, i| k.* = .{ .name = std.fmt.comptimePrint("key_{d}", .{i}), .on = .{ .line = true } };
            const out = keys;
            break :blk &out;
        } };
        pub const options: check.Options = .{ .schema = &many };
    };
    const v = comptime join(Vocabulary);
    try std.testing.expectEqual(@as(usize, 80), v.options.schema.?.keys.len);
}

test "a vocabulary's packages are joined after the host's own" {
    const Vocabulary = struct {
        const phone: check.Schema = .{ .keys = &.{.{ .name = "phone", .on = .{ .section = true } }} };
        const Tide = struct {
            fn pass(_: ?*anyopaque, _: *compile.Compiler) compile.Compiler.Error!void {}
        };
        pub const options: check.Options = .{ .schema = &phone };
        pub const packages: []const Package = &.{.{
            .kinds = &.{.{ .name = "calendar" }},
            .keys = &.{.{ .name = "every", .on = .{ .section = true, .part = true }, .value = .word }},
            .compile = .{ .name = "tide", .run = Tide.pass },
        }};
    };
    const v = comptime join(Vocabulary);
    try std.testing.expectEqual(@as(usize, 2), v.options.schema.?.keys.len);
    try std.testing.expect(v.options.schema.?.find("every", .part) == .found);
    try std.testing.expect(v.options.schema.?.find("phone", .section) == .found);
    try std.testing.expectEqualStrings("calendar", v.options.kinds[0].name);
    try std.testing.expectEqualStrings("tide", v.passes[0].name);
    try std.testing.expect(!overlap(.{ .line = true }, .{ .section = true, .part = true }));
}

test {
    _ = syntax;
    _ = check;
    _ = compile;
    _ = json;
}
