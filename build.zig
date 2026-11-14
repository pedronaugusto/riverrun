const std = @import("std");

/// What a host that depends on riverrun builds: the `riverrun` module, the
/// runtime, on aegis alone. The compiler, `riverrun-compiler`, is `compiler`'s
/// to make, on first ask: its dependencies (xenoglyph, strand) are lazy, so a
/// game that only tells stories never fetches them. A game compiles its story
/// with `addStory`. The tests and the gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("riverrun", .{
        .root_source_file = b.path("src/riverrun.zig"),
        .target = target,
        .optimize = optimize,
        .imports = runtimeImports(b, target, optimize),
    });
}

/// The arguments a package is asked with for a story's build.
pub const Building = struct { target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode };

/// How a story's build asks for riverrun, and for each package whose compiler side its vocabulary imports: for the
/// machine doing the building, ReleaseSafe. Zig keeps one instance of a package for one set of arguments, and every
/// package asks its dependencies with its own target and optimize alone, so all asked this way stand on one riverrun.
///
///     const river = b.dependency("riverrun", riverrun.building(b));
///     const tide_side = tide.compiler(b.dependency("tide", riverrun.building(b))) orelse return;
pub fn building(b: *std.Build) Building {
    return .{ .target = b.graph.host, .optimize = .safe };
}

/// The compiler, `riverrun-compiler`, of the riverrun instance `dep`, on that instance's runtime and built as it
/// is: made on the first ask and kept with the instance, so whatever asks one instance gets one module. Null until
/// its lazy dependencies are fetched, after which the build runs again.
pub fn compiler(dep: *std.Build.Dependency) ?*std.Build.Module {
    const d = dep.builder;
    if (d.modules.get("riverrun-compiler")) |m| return m;
    const runtime = dep.module("riverrun");
    const target = runtime.resolved_target.?;
    const optimize = runtime.optimize.?;
    const imports = compilerImports(d, runtime, target, optimize) orelse return null;
    return d.addModule("riverrun-compiler", .{ .root_source_file = d.path("src/compiler.zig"), .target = target, .optimize = optimize, .imports = imports });
}

pub const StoryOptions = struct {
    /// The story's `.river` files, in the order their diagnostics number them.
    files: []const std.Build.LazyPath,
    /// The host's vocabulary: a Zig file with `pub const options: riverrun.check.Options` (its tag schema, its
    /// widths and things) and, where it has them, `pub const packages: []const riverrun.Package` and
    /// `pub const passes: []const riverrun.compile.Pass`. It imports `riverrun-compiler`, `riverrun` and `packages`.
    vocabulary: std.Build.LazyPath,
    /// The compiler sides the vocabulary imports, each by its name: every package's, from its `compiler` with the
    /// package asked by `building(b)`, so each stands on this riverrun.
    packages: []const std.Build.Module.Import = &.{},
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

/// Reads, checks and compiles a story at build time, against the host's vocabulary and the packages it registers;
/// a diagnostic, riverrun's or a package's, fails the build with `file:line:col: severity: message`. `dep` is
/// riverrun asked by `building(b)`; a package that stands on another riverrun is refused here, by name, since one
/// compiler holds one riverrun.
///
///     const river = b.dependency("riverrun", riverrun.building(b));
///     const tide_side = tide.compiler(b.dependency("tide", riverrun.building(b))) orelse return;
///     const story = riverrun.addStory(b, river, .{ .files = &.{ b.path("episodes/ep1/story.river") },
///         .vocabulary = b.path("src/vocabulary.zig"), .packages = &.{.{ .name = "tide-compiler", .module = tide_side }} });
///     exe.root_module.addImport("story", story.module);
pub fn addStory(b: *std.Build, dep: *std.Build.Dependency, options: StoryOptions) Story {
    const runtime = dep.module("riverrun");
    if (!forBuilding(b, runtime)) std.debug.panic("addStory takes riverrun asked by `riverrun.building(b)`, for the machine doing the building", .{});
    // fetched on first use, after which the build runs again with them
    const river = compiler(dep) orelse return .{ .graph = options.vocabulary, .words = options.vocabulary, .module = b.createModule(.{}) };
    for (options.packages) |p| standsOn(b, p, runtime, river);
    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    imports.appendSlice(b.allocator, &.{ .{ .name = "riverrun", .module = runtime }, .{ .name = "riverrun-compiler", .module = river } }) catch @panic("OOM");
    imports.appendSlice(b.allocator, options.packages) catch @panic("OOM");
    const vocabulary = b.createModule(.{
        .root_source_file = options.vocabulary,
        .target = runtime.resolved_target,
        .optimize = runtime.optimize,
        .imports = imports.items,
    });
    const exe = b.addExecutable(.{
        .name = "riverrun-compile",
        .root_module = b.createModule(.{
            .root_source_file = dep.builder.path("tools/compile.zig"),
            .target = runtime.resolved_target,
            .optimize = runtime.optimize,
            .imports = &.{
                .{ .name = "riverrun-compiler", .module = river },
                .{ .name = "vocabulary", .module = vocabulary },
                .{ .name = "aegis", .module = dep.builder.dependency("aegis", .{ .target = runtime.resolved_target.?, .optimize = runtime.optimize.? }).module("aegis") },
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

// Whether the runtime was built as `building` asks: for the machine doing the building, ReleaseSafe.
fn forBuilding(b: *std.Build, runtime: *std.Build.Module) bool {
    const t = runtime.resolved_target.?.result;
    const h = b.graph.host.result;
    const same = t.cpu.arch == h.cpu.arch and t.os.tag == h.os.tag and t.abi == h.abi and t.cpu.model == h.cpu.model;
    return same and runtime.optimize == .safe;
}

// A package's compiler side must import this riverrun, wherever in its graph it does: two in one compiler would be
// two kinds of every type. Refused by its name, with the way to fix it.
fn standsOn(b: *std.Build, p: std.Build.Module.Import, runtime: *std.Build.Module, river: *std.Build.Module) void {
    var seen: std.array_hash_map.Auto(*std.Build.Module, void) = .empty;
    seen.put(b.allocator, p.module, {}) catch @panic("OOM");
    var i: usize = 0;
    while (i < seen.count()) : (i += 1) {
        const m = seen.keys()[i];
        for (m.import_table.keys(), m.import_table.values()) |name, imported| {
            const own = if (std.mem.eql(u8, name, "riverrun")) runtime else if (std.mem.eql(u8, name, "riverrun-compiler")) river else null;
            if (own != null and own.? != imported) std.debug.panic("`{s}` stands on another riverrun than the story's: ask its package by `riverrun.building(b)`", .{p.name});
            seen.put(b.allocator, imported, {}) catch @panic("OOM");
        }
    }
}

/// riverrun's development: the runtime's tests, the compiler's, and a story compiled through `addStory` with a
/// package registered, and told, under preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("riverrun", .{ .target = target, .optimize = optimize });
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
    const compiler_tests = b.addTest(.{
        .name = "riverrun-compiler-tests",
        .filters = filters,
        .root_module = b.createModule(.{ .root_source_file = p.path("src/compiler.zig"), .target = target, .optimize = optimize, .imports = imports }),
    });
    // The reader's properties: shakedown, for the tests alone.
    compiler_tests.root_module.addImport("shakedown", b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown"));
    test_step.dependOn(&b.addRunArtifact(compiler_tests).step);
    test_step.dependOn(&b.addRunArtifact(storyTests(b, target, optimize, filters) orelse return).step);
    // The one-shot rewriter from the first syntax to design B, on the reader of the first.
    const rewrite = b.addExecutable(.{
        .name = "riverrun-rewrite",
        .root_module = b.createModule(.{
            .root_source_file = p.path("tools/rewrite.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "riverrun-compiler", .module = compiler(package) orelse return },
                .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
            },
        }),
    });
    b.step("rewrite", "Build the one-shot rewriter to design B").dependOn(&b.addInstallArtifact(rewrite, .{}).step);
    tools.preflight.addCi(b, p, .{ .tests = test_step });
}

// A story compiled as a game's build compiles one: through `addStory`, with a package's compiler side registered,
// then embedded and told by a test built for `target`.
fn storyTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, filters: []const []const u8) ?*std.Build.Step.Compile {
    const river = b.dependency("riverrun", building(b));
    const p = river.builder;
    const stall = b.createModule(.{
        .root_source_file = p.path("tools/testdata/stall.zig"),
        .target = building(b).target,
        .optimize = building(b).optimize,
        .imports = &.{.{ .name = "riverrun-compiler", .module = compiler(river) orelse return null }},
    });
    const sample = addStory(b, river, .{
        .files = &.{p.path("tools/testdata/sample.river")},
        .vocabulary = p.path("tools/testdata/vocabulary.zig"),
        .packages = &.{.{ .name = "stall-compiler", .module = stall }},
    });
    return b.addTest(.{
        .name = "add-story-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("tools/add_story_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "riverrun", .module = b.dependency("riverrun", .{ .target = target, .optimize = optimize }).module("riverrun") },
                .{ .name = "story", .module = sample.module },
            },
        }),
    });
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
