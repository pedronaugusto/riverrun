//! The build of a game that tells a story: the game, its story compiled in,
//! and the `riverrun` program its writers run, with the game's vocabulary.
//! riverrun's README and the manual's chapter 7 show its middle rows; the
//! manual's test step compiles it against riverrun's build, so what they show
//! is what a game's build can write.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "ferry",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        }),
    });
    b.installArtifact(exe);
    const riverrun = @import("riverrun");
    const river = b.dependency("riverrun", riverrun.building(b));
    const story = riverrun.addStory(b, river, .{
        .files = &.{b.path("story/main.river")},
        .vocabulary = b.path("src/vocabulary.zig"),
    });
    exe.root_module.addImport("story", story.module);
    // zig-out/bin/riverrun, with the game's vocabulary: riverrun check story/*.river
    b.installArtifact(story.program);
    // zig build story: the story checked, the game not built
    b.step("story", "Check the story").dependOn(&story.check.step);
}
