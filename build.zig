const std = @import("std");

/// What a host that depends on riverrun builds: the `riverrun` module. A
/// game compiles its story with `addStory`. The tests and the gate are
/// `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("riverrun", .{
        .root_source_file = b.path("src/riverrun.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports(b, target, optimize),
    });
}

pub const StoryOptions = struct {
    /// The story's `.river` files, in the order their diagnostics number them.
    files: []const std.Build.LazyPath,
    /// The host's vocabulary: a Zig file with `pub const options: riverrun.check.Options` (its tag schema,
    /// the kinds of section packages register, its widths and things) and, where packages add them,
    /// `pub const passes: []const riverrun.compile.Pass`. It imports `riverrun`.
    vocabulary: std.Build.LazyPath,
    /// A release refuses a line without a written `# id`.
    release: bool = false,
    name: []const u8 = "story",
};

/// A story compiled while a game builds: its graph and string table, and a module whose `graph` and `words`
/// embed them.
pub const Story = struct {
    graph: std.Build.LazyPath,
    words: std.Build.LazyPath,
    module: *std.Build.Module,
};

/// Reads, checks and compiles a story at build time, against the host's vocabulary; a diagnostic fails the
/// build with `file:line:col: severity: message`.
///
///     const story = riverrun.addStory(b, dep, .{ .files = &.{ b.path("episodes/ep1/story.river") },
///         .vocabulary = b.path("src/vocabulary.zig") });
///     exe.root_module.addImport("story", story.module);
pub fn addStory(b: *std.Build, dep: *std.Build.Dependency, options: StoryOptions) Story {
    const d = dep.builder;
    const host = b.graph.host;
    // the compiler runs while the game builds, so it is built for the machine doing the building
    const riverrun = b.createModule(.{
        .root_source_file = d.path("src/riverrun.zig"),
        .target = host,
        .optimize = .ReleaseSafe,
        .imports = imports(d, host, .ReleaseSafe),
    });
    const vocabulary = b.createModule(.{
        .root_source_file = options.vocabulary,
        .target = host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "riverrun", .module = riverrun }},
    });
    const exe = b.addExecutable(.{
        .name = "riverrun-compile",
        .root_module = b.createModule(.{
            .root_source_file = d.path("tools/compile.zig"),
            .target = host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "riverrun", .module = riverrun },
                .{ .name = "vocabulary", .module = vocabulary },
            },
        }),
    });
    const run = b.addRunArtifact(exe);
    const graph = run.addOutputFileArg2(b.fmt("{s}.graph", .{options.name}), .{});
    const words = run.addOutputFileArg2(b.fmt("{s}.words", .{options.name}), .{});
    if (options.release) run.addArg("--release");
    for (options.files) |f| run.addFileArg2(f, .{});
    const embed = b.addWriteFiles();
    _ = embed.addCopyFile(graph, "story.graph");
    _ = embed.addCopyFile(words, "story.words");
    const root = embed.add("story.zig",
        \\//! A story riverrun compiled at build time.
        \\pub const graph = @embedFile("story.graph");
        \\pub const words = @embedFile("story.words");
        \\
    );
    return .{ .graph = graph, .words = words, .module = b.createModule(.{ .root_source_file = root }) };
}

/// riverrun's development: its tests under preflight's gate, and a story compiled through `addStory` and told.
/// Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("riverrun", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const test_step = b.step("test", "Run the tests");
    const tests = b.addTest(.{
        .name = "riverrun-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/riverrun.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports(p, target, optimize),
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const sample = addStory(b, package, .{ .files = &.{p.path("tools/testdata/sample.river")}, .vocabulary = p.path("tools/testdata/vocabulary.zig") });
    const built = b.addTest(.{
        .name = "add-story-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("tools/add_story_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "riverrun", .module = package.module("riverrun") },
                .{ .name = "story", .module = sample.module },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(built).step);
    tools.preflight.addCi(b, p, .{ .tests = test_step });
}

fn imports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const std.Build.Module.Import {
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    const xenoglyph = b.dependency("xenoglyph", .{ .target = target, .optimize = optimize });
    const strand = b.dependency("strand", .{ .target = target, .optimize = optimize });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "aegis", .module = aegis.module("aegis") },
        .{ .name = "xenoglyph", .module = xenoglyph.module("xenoglyph") },
        .{ .name = "strand", .module = strand.module("strand") },
    }) catch @panic("OOM");
}
