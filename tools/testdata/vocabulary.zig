//! The vocabulary of addStory's test host: one tag it knows, and one
//! package registered beside it.

const riverrun = @import("riverrun-compiler");
const stall = @import("stall-compiler");

const schema: riverrun.check.Schema = .{ .keys = &.{.{ .name = "stall", .on = .{ .section = true } }} };

pub const options: riverrun.check.Options = .{ .schema = &schema };
pub const packages: []const riverrun.Package = &.{stall.package};
