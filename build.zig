const std = @import("std");

/// What a host that depends on riverrun builds: the `riverrun` module, the
/// runtime, on aegis alone. A build that passes `.compiler = true` gets the
/// `riverrun-compiler` module too, whose dependencies (xenoglyph, strand) are
/// lazy, so a game that only tells stories never fetches them. A game
/// compiles its story with `addStory`. The tests and the gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const runtime = b.addModule("riverrun", .{
        .root_source_file = b.path("src/riverrun.zig"),
        .target = target,
        .optimize = optimize,
        .imports = runtimeImports(b, target, optimize),
    });
    if (b.option(bool, "compiler", "Offer the riverrun-compiler module") orelse false) {
        const imports = compilerImports(b, runtime, target, optimize) orelse return;
        _ = b.addModule("riverrun-compiler", .{
            .root_source_file = b.path("src/compiler.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        });
    }
}

pub const StoryOptions = struct {
    /// The story's `.river` files, in the order their diagnostics number them.
    files: []const std.Build.LazyPath,
    /// The host's vocabulary: a Zig file with `pub const options: riverrun.check.Options` (its tag schema, its
    /// widths and things) and, where it has them, `pub const packages: []const riverrun.Package` and
    /// `pub const passes: []const riverrun.compile.Pass`. It imports `riverrun-compiler`.
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
    const runtime = b.createModule(.{
        .root_source_file = d.path("src/riverrun.zig"),
        .target = host,
        .optimize = .ReleaseSafe,
        .imports = runtimeImports(d, host, .ReleaseSafe),
    });
    // fetched on first use, after which the build runs again with them
    const imports = compilerImports(d, runtime, host, .ReleaseSafe) orelse return .{ .graph = options.vocabulary, .words = options.vocabulary, .module = b.createModule(.{}) };
    const compiler = b.createModule(.{ .root_source_file = d.path("src/compiler.zig"), .target = host, .optimize = .ReleaseSafe, .imports = imports });
    const vocabulary = b.createModule(.{
        .root_source_file = options.vocabulary,
        .target = host,
        .optimize = .ReleaseSafe,
        .imports = &.{ .{ .name = "riverrun", .module = runtime }, .{ .name = "riverrun-compiler", .module = compiler } },
    });
    const exe = b.addExecutable(.{
        .name = "riverrun-compile",
        .root_module = b.createModule(.{
            .root_source_file = d.path("tools/compile.zig"),
            .target = host,
            .optimize = .ReleaseSafe,
            .imports = &.{ .{ .name = "riverrun-compiler", .module = compiler }, .{ .name = "vocabulary", .module = vocabulary } },
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

/// riverrun's development: the runtime's tests, the compiler's, and a story compiled through `addStory` and told,
/// under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("riverrun", .{ .target = target, .optimize = optimize, .compiler = true });
    const p = package.builder;
    const filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const test_step = b.step("test", "Run the tests");
    const runtime = b.addTest(.{
        .name = "riverrun-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/riverrun.zig"),
            .target = target,
            .optimize = optimize,
            .imports = runtimeImports(p, target, optimize),
        }),
    });
    test_step.dependOn(&b.addRunArtifact(runtime).step);
    const imports = compilerImports(p, package.module("riverrun"), target, optimize) orelse return;
    const compiler = b.addTest(.{
        .name = "riverrun-compiler-tests",
        .filters = filters,
        .root_module = b.createModule(.{ .root_source_file = p.path("src/compiler.zig"), .target = target, .optimize = optimize, .imports = imports }),
    });
    test_step.dependOn(&b.addRunArtifact(compiler).step);
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

// The runtime needs aegis alone.
fn runtimeImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const std.Build.Module.Import {
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "aegis", .module = aegis.module("aegis") }}) catch @panic("OOM");
}

// The compiler stands on the runtime and adds xenoglyph, for widths, and strand, for the JSON forms: both lazy,
// so null until they are fetched.
fn compilerImports(b: *std.Build, runtime: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?[]const std.Build.Module.Import {
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    // not yet fetched: the toolchain fetches them, then runs the build again
    const xenoglyph = b.dependencyLazy("xenoglyph", .{ .target = target, .optimize = optimize }) catch return null;
    const strand = b.dependencyLazy("strand", .{ .target = target, .optimize = optimize }) catch return null;
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "riverrun", .module = runtime },
        .{ .name = "aegis", .module = aegis.module("aegis") },
        .{ .name = "xenoglyph", .module = xenoglyph.module("xenoglyph") },
        .{ .name = "strand", .module = strand.module("strand") },
    }) catch @panic("OOM");
}
