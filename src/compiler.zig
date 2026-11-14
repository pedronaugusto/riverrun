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

/// What a package adds to a story's language and its build, registered as one in a vocabulary's `packages`: its
/// kinds of section, the tags it adds anywhere beside the host's, its check of the whole story and its compile pass.
pub const Package = struct {
    kinds: []const check.Kind = &.{},
    keys: []const check.Schema.Key = &.{},
    check: ?check.Pass = null,
    compile: ?compile.Pass = null,
};

/// A vocabulary as the compiler takes it: the check's options and the compile passes.
pub const Joined = struct {
    options: check.Options,
    passes: []const compile.Pass,
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
        for (packages) |p| {
            options.kinds = options.kinds ++ p.kinds;
            keys = keys ++ p.keys;
            if (p.check) |c| options.passes = options.passes ++ &[_]check.Pass{c};
            if (p.compile) |c| passes = passes ++ &[_]compile.Pass{c};
        }
        // every pair compared: a host's schema of a few dozen keys is past the default quota
        @setEvalBranchQuota(1000 + 200 * (keys.len * keys.len + options.kinds.len * options.kinds.len));
        distinct(options.kinds, keys);
        if (options.schema == null and keys.len == 0) return .{ .options = options, .passes = passes };
        const schema: check.Schema = .{ .keys = keys };
        options.schema = &schema;
        return .{ .options = options, .passes = passes };
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
