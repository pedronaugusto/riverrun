//! The vocabulary of the game this manual's stories are written for: a small
//! game of a ferry crossing at night. A game's vocabulary says which tags its
//! stories may carry and where; this one has a few, so every example checks
//! as a game's story does. Your game has its own.

const riverrun = @import("riverrun-compiler");

const schema: riverrun.check.Schema = .{
    .keys = &.{
        // the music the game plays under a scene
        .{ .name = "music", .on = .{ .section = true }, .value = .word },
        // the picture the game shows behind a scene, or a part of one
        .{ .name = "picture", .on = .{ .section = true, .part = true }, .value = .word },
        // a sound the game plays as a line is said
        .{ .name = "sound", .on = .{ .line = true }, .value = .word },
        // how long the game holds a line before the next, in seconds
        .{ .name = "pause", .on = .{ .line = true }, .value = .number },
        // a choice the game shows with a mark beside it: one that matters
        .{ .name = "marked", .on = .{ .choice = true } },
        // how a line is said, `ADA (quietly):`: words for the actor and the translator
        .{ .name = "delivery", .on = .{ .line = true }, .value = .text },
        // a night the game plays room by room: the rooms the player may be in, the hours it moves them through, the
        // pool it asks what happens in each room at each hour, and the scene it goes on to when the night is over
        .{ .name = "rooms", .on = .{ .section = true }, .value = .{ .values_of = "room" }, .count = .many },
        .{ .name = "hours", .on = .{ .section = true }, .value = .number, .count = .many },
        .{ .name = "pool", .on = .{ .section = true }, .value = .section },
        .{ .name = "then", .on = .{ .section = true }, .value = .section, .leads = true },
    },
};

// the game's things a story names by id, `[give(lantern)]`: each kind with every id the game knows
const things: []const riverrun.check.Things = &.{
    .{ .kind = "item", .ids = &.{ "lantern", "needles", "thread", "buttons" } },
    .{ .kind = "person", .ids = &.{ "ada", "otto", "miller" } },
};

pub const options: riverrun.check.Options = .{ .schema = &schema, .delivery = "delivery", .things = things };
