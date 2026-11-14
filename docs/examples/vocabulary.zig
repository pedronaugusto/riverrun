//! The vocabulary of the stories riverrun's documentation shows: the tags of
//! a game like the proof's, so every example checks as a game's story does.

const riverrun = @import("riverrun-compiler");

const schema: riverrun.check.Schema = .{
    .keys = &.{
        // a section the game plays as hide and seek, for this long
        .{ .name = "listen", .on = .{ .section = true } },
        .{ .name = "count", .on = .{ .section = true }, .value = .number },
        // when a line is said, in seconds into its section; when a section happens, in the game's calendar
        .{ .name = "at", .on = .{ .line = true }, .value = .number },
        .{ .name = "at", .on = .{ .section = true }, .value = .text },
        // where a line can be heard from, and what a choice makes known
        .{ .name = "heard", .on = .{ .line = true }, .value = .{ .values_of = "spot" }, .count = .many },
        .{ .name = "known", .on = .{ .choice = true }, .value = .{ .values_of = "carried" } },
        .{ .name = "courier", .on = .{ .section = true } },
        // how a line is delivered: `DAD (quietly):`
        .{ .name = "delivery", .on = .{ .line = true }, .value = .text },
    },
};

pub const options: riverrun.check.Options = .{ .schema = &schema, .delivery = "delivery" };
