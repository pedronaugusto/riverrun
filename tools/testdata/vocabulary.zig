//! The vocabulary of addStory's test host: one tag it knows.

const riverrun = @import("riverrun-compiler");

const schema: riverrun.check.Schema = .{ .keys = &.{.{ .name = "stall", .on = .{ .section = true } }} };

pub const options: riverrun.check.Options = .{ .schema = &schema };
