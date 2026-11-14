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

/// riverrun's tools, `riverrun-tools`, of the riverrun instance `dep`: the model every tool shows (a story's files,
/// their trees and diagnostics), the ids `riverrun tag` writes, and the bounded walk of a compiled story, on that
/// instance's compiler. Made on the first ask and kept with the instance; null until the compiler's lazy
/// dependencies are fetched.
pub fn tools(dep: *std.Build.Dependency) ?*std.Build.Module {
    const d = dep.builder;
    if (d.modules.get("riverrun-tools")) |m| return m;
    const runtime = dep.module("riverrun");
    const river = compiler(dep) orelse return null;
    return d.addModule("riverrun-tools", .{
        .root_source_file = d.path("src/tools.zig"),
        .target = runtime.resolved_target,
        .optimize = runtime.optimize,
        .imports = &.{
            .{ .name = "riverrun", .module = runtime },
            .{ .name = "riverrun-compiler", .module = river },
            .{ .name = "aegis", .module = d.dependency("aegis", .{ .target = runtime.resolved_target.?, .optimize = runtime.optimize.? }).module("aegis") },
        },
    });
}

pub const ProgramOptions = struct {
    /// The host's vocabulary: a Zig file with `pub const options: riverrun.check.Options` (its tag schema, its
    /// widths and things) and, where it has them, `pub const packages: []const riverrun.Package` and
    /// `pub const passes: []const riverrun.compile.Pass`. It imports `riverrun-compiler`, `riverrun` and `packages`.
    vocabulary: std.Build.LazyPath,
    /// The compiler sides the vocabulary imports, each by its name: every package's, from its `compiler` with the
    /// package asked by `building(b)`, so each stands on this riverrun.
    packages: []const std.Build.Module.Import = &.{},
};

/// The `riverrun` program with the host's vocabulary and its packages built in, for the machine doing the building:
/// `riverrun check` checks a story exactly as the game's build does, `riverrun tag` gives its lines their ids, and
/// `riverrun compile` is what `addStory` runs. A game installs it, or runs it from a step of its own, so a writer
/// checks the story without building the game:
///
///     const program = riverrun.addProgram(b, river, .{ .vocabulary = b.path("src/vocabulary.zig"), .packages = … });
///     b.installArtifact(program); // zig-out/bin/riverrun check story/*.river
///
/// `dep` is riverrun asked by `building(b)`; a package that stands on another riverrun is refused here, by name.
pub fn addProgram(b: *std.Build, dep: *std.Build.Dependency, options: ProgramOptions) *std.Build.Step.Compile {
    const runtime = dep.module("riverrun");
    if (!forBuilding(b, runtime)) std.debug.panic("riverrun's program is built with riverrun asked by `riverrun.building(b)`, for the machine doing the building", .{});
    const target = runtime.resolved_target.?;
    const optimize = runtime.optimize.?;
    // fetched on first use, after which the build runs again with them; until then, a program never built
    const unbuilt = b.addExecutable(.{ .name = "riverrun", .root_module = b.createModule(.{ .root_source_file = options.vocabulary, .target = target, .optimize = optimize }) });
    const river = compiler(dep) orelse return unbuilt;
    const ensign = dep.builder.dependencyLazy("ensign", .{ .target = target, .optimize = optimize }) catch return unbuilt;
    for (options.packages) |p| standsOn(b, p, runtime, river);
    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    imports.appendSlice(b.allocator, &.{ .{ .name = "riverrun", .module = runtime }, .{ .name = "riverrun-compiler", .module = river } }) catch @panic("OOM");
    imports.appendSlice(b.allocator, options.packages) catch @panic("OOM");
    const vocabulary = b.createModule(.{ .root_source_file = options.vocabulary, .target = target, .optimize = optimize, .imports = imports.items });
    return b.addExecutable(.{
        .name = "riverrun",
        .root_module = b.createModule(.{
            .root_source_file = dep.builder.path("tools/riverrun.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "riverrun-compiler", .module = river },
                .{ .name = "riverrun-tools", .module = tools(dep).? },
                .{ .name = "vocabulary", .module = vocabulary },
                .{ .name = "ensign", .module = ensign.module("ensign") },
                .{ .name = "aegis", .module = dep.builder.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis") },
            },
        }),
    });
}

/// `riverrun check` over `files` with `program`, as a step that fails when the story has an error and prints every
/// diagnostic: what a game hangs on a step of its own, and a package's tests check its documentation's stories with.
pub fn addCheck(b: *std.Build, program: *std.Build.Step.Compile, files: []const std.Build.LazyPath, options: struct { release: bool = false }) *std.Build.Step.Run {
    const run = b.addRunArtifact(program);
    run.addArg("check");
    if (options.release) run.addArg("--release");
    for (files) |f| run.addFileArg2(f, .{});
    return run;
}

pub const StoryOptions = struct {
    /// The story's `.river` files, in the order their diagnostics number them.
    files: []const std.Build.LazyPath,
    /// The host's vocabulary, as `ProgramOptions.vocabulary`.
    vocabulary: std.Build.LazyPath,
    /// The compiler sides the vocabulary imports, as `ProgramOptions.packages`.
    packages: []const std.Build.Module.Import = &.{},
    /// A release refuses a line or a choice without its id, `^…` at its end.
    release: bool = false,
    name: []const u8 = "story",
};

/// A story compiled while a game builds: its graph and string table, a module whose `graph` and `words` embed them,
/// the `riverrun` program that compiled it, with the vocabulary in it, and a step that checks the story with it.
pub const Story = struct {
    graph: std.Build.LazyPath,
    words: std.Build.LazyPath,
    module: *std.Build.Module,
    program: *std.Build.Step.Compile,
    /// `riverrun check` over the story's files: a game's `zig build story`, which checks without building the game.
    check: *std.Build.Step.Run,
};

/// Reads, checks and compiles a story at build time with `riverrun compile`, the program `addProgram` makes,
/// against the host's vocabulary and the packages it registers; a diagnostic, riverrun's or a package's, fails the
/// build, printed as `riverrun check` prints it. `dep` is riverrun asked by `building(b)`.
///
///     const river = b.dependency("riverrun", riverrun.building(b));
///     const tide_side = tide.compiler(b.dependency("tide", riverrun.building(b))) orelse return;
///     const story = riverrun.addStory(b, river, .{ .files = &.{ b.path("episodes/ep1/story.river") },
///         .vocabulary = b.path("src/vocabulary.zig"), .packages = &.{.{ .name = "tide-compiler", .module = tide_side }} });
///     exe.root_module.addImport("story", story.module);
///     b.step("story", "Check the story without building the game").dependOn(&story.check.step);
pub fn addStory(b: *std.Build, dep: *std.Build.Dependency, options: StoryOptions) Story {
    const program = addProgram(b, dep, .{ .vocabulary = options.vocabulary, .packages = options.packages });
    const run = b.addRunArtifact(program);
    run.addArg("compile");
    const graph = run.addOutputFileArg2(b.fmt("{s}.graph", .{options.name}), .{ .prefix = "--graph=" });
    const words = run.addOutputFileArg2(b.fmt("{s}.words", .{options.name}), .{ .prefix = "--words=" });
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
    return .{
        .graph = graph,
        .words = words,
        .module = b.createModule(.{ .root_source_file = root }),
        .program = program,
        .check = addCheck(b, program, options.files, .{ .release = options.release }),
    };
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

/// riverrun's development: the runtime's tests, the compiler's and the tools', a story compiled through `addStory`
/// with a package registered, and told, and the documentation's stories checked by the program, under preflight's
/// gate. Run through bay.
pub fn dev(b: *std.Build, kit: type) void {
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
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown");
    const compiler_tests = b.addTest(.{
        .name = "riverrun-compiler-tests",
        .filters = filters,
        .root_module = b.createModule(.{ .root_source_file = p.path("src/compiler.zig"), .target = target, .optimize = optimize, .imports = imports }),
    });
    // The reader's properties: shakedown, for the tests alone.
    compiler_tests.root_module.addImport("shakedown", shakedown);
    test_step.dependOn(&b.addRunArtifact(compiler_tests).step);
    test_step.dependOn(&b.addRunArtifact(toolsTests(b, package, shakedown, filters) orelse return).step);
    test_step.dependOn(&b.addRunArtifact(storyTests(b, target, optimize, filters) orelse return).step);
    docs(b, test_step);
    programTests(b, test_step);
    kit.preflight.addCi(b, p, .{ .tests = test_step });
}

// The tools' tests, and the whole compiler's property over any text, with the test package registered.
fn toolsTests(b: *std.Build, package: *std.Build.Dependency, shakedown: *std.Build.Module, filters: []const []const u8) ?*std.Build.Step.Compile {
    const p = package.builder;
    const river = compiler(package) orelse return null;
    const runtime = package.module("riverrun");
    const stall = b.createModule(.{
        .root_source_file = p.path("tools/testdata/stall.zig"),
        .target = runtime.resolved_target,
        .optimize = runtime.optimize,
        .imports = &.{.{ .name = "riverrun-compiler", .module = river }},
    });
    return b.addTest(.{
        .name = "riverrun-tools-tests",
        .filters = filters,
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tools.zig"),
            .target = runtime.resolved_target,
            .optimize = runtime.optimize,
            .imports = &.{
                .{ .name = "riverrun", .module = runtime },
                .{ .name = "riverrun-compiler", .module = river },
                .{ .name = "shakedown", .module = shakedown },
                .{ .name = "stall-compiler", .module = stall },
                .{ .name = "aegis", .module = p.dependency("aegis", .{ .target = runtime.resolved_target.?, .optimize = runtime.optimize.? }).module("aegis") },
            },
        }),
    });
}

// The program as a writer runs it: a story with problems, each printed in the one form and the status 1; a story
// with lines and choices that have no id, under `tag --check`.
fn programTests(b: *std.Build, test_step: *std.Build.Step) void {
    const river = b.dependency("riverrun", building(b));
    const p = river.builder;
    const stall = b.createModule(.{
        .root_source_file = p.path("tools/testdata/stall.zig"),
        .target = building(b).target,
        .optimize = building(b).optimize,
        .imports = &.{.{ .name = "riverrun-compiler", .module = compiler(river) orelse return }},
    });
    const program = addProgram(b, river, .{ .vocabulary = p.path("tools/testdata/vocabulary.zig"), .packages = &.{.{ .name = "stall-compiler", .module = stall }} });
    const refused = addCheck(b, program, &.{p.path("tools/testdata/refused.river")}, .{});
    refused.expectExitCode(1);
    refused.expectStdOutMatch("refused.river:3:1-3:5: error: `MUMM` is not a speaker: speakers come from `cast:` and `extras:`\n");
    refused.expectStdOutMatch("refused.river:4:4-4:11: error: nothing is called `nowhere`");
    test_step.dependOn(&refused.step);
    const untagged = b.addRunArtifact(program);
    untagged.addArgs(&.{ "tag", "--check" });
    untagged.addFileArg2(p.path("tools/testdata/sample.river"), .{});
    untagged.expectExitCode(1);
    untagged.expectStdOutMatch("sample.river:11:1-11:35: error: this has no id: `riverrun tag` writes one\n");
    untagged.expectStdOutMatch("sample.river:13:1-13:19: error: this has no id: `riverrun tag` writes one\n");
    test_step.dependOn(&untagged.step);
}

/// The stories riverrun's documentation shows: each a file the program checks with the documentation's vocabulary,
/// and every story block of the documents rows of one of them.
const documented = struct {
    const stories = [_][]const u8{ "docs/examples/kitchen.river", "docs/examples/courier.river" };
    const documents = [_][]const u8{"docs/design.md"};
};

// The documentation's stories checked by `riverrun check`, as a game's build checks one, and its documents' story
// blocks found among them.
fn docs(b: *std.Build, test_step: *std.Build.Step) void {
    const river = b.dependency("riverrun", building(b));
    const p = river.builder;
    const program = addProgram(b, river, .{ .vocabulary = p.path("docs/examples/vocabulary.zig") });
    for (documented.stories) |story| test_step.dependOn(&addCheck(b, program, &.{p.path(story)}, .{}).step);
    test_step.dependOn(&b.addRunArtifact(addExcerptsTest(b, river, .{ .package = p, .stories = &documented.stories, .documents = &documented.documents }) orelse return).step);
}

pub const ExcerptsOptions = struct {
    /// The package the paths are in.
    package: *std.Build,
    /// Whole stories, each checked on its own.
    stories: []const []const u8,
    /// Markdown, whose ```river blocks are shown stories, and Zig, whose `//!` blocks indented four spaces past the
    /// `//!` are.
    documents: []const []const u8,
};

/// A test that every story a package's documents show is rows of one of its checked stories, one after another as
/// written: so what the documents show is what `addCheck` checked. `dep` is riverrun asked by `building(b)`.
pub fn addExcerptsTest(b: *std.Build, dep: *std.Build.Dependency, options: ExcerptsOptions) ?*std.Build.Step.Compile {
    const kit = tools(dep) orelse return null;
    const files = b.addWriteFiles();
    var root: std.ArrayList(u8) = .empty;
    root.appendSlice(b.allocator,
        \\//! Every story a document shows is rows of a checked story.
        \\const std = @import("std");
        \\const excerpts = @import("riverrun-tools").excerpts;
        \\const Named = excerpts.Named;
        \\
        \\const stories = [_]Named{
        \\
    ) catch @panic("OOM");
    for (options.stories, 0..) |s, i| {
        _ = files.addCopyFile(options.package.path(s), b.fmt("story{d}", .{i}));
        root.print(b.allocator, "    .{{ .path = \"{f}\", .text = @embedFile(\"story{d}\") }},\n", .{ std.zig.fmtString(s), i }) catch @panic("OOM");
    }
    root.appendSlice(b.allocator, "};\nconst documents = [_]Named{\n") catch @panic("OOM");
    for (options.documents, 0..) |d, i| {
        _ = files.addCopyFile(options.package.path(d), b.fmt("document{d}", .{i}));
        root.print(b.allocator, "    .{{ .path = \"{f}\", .text = @embedFile(\"document{d}\") }},\n", .{ std.zig.fmtString(d), i }) catch @panic("OOM");
    }
    root.appendSlice(b.allocator,
        \\};
        \\
        \\test "every story a document shows is rows of a checked story" {
        \\    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        \\    defer arena.deinit();
        \\    const unshown = try excerpts.unshown(arena.allocator(), &documents, &stories);
        \\    for (unshown) |u| std.debug.print("{s}:{d}: {s}\\n", .{ u.path, u.line, u.why });
        \\    try std.testing.expectEqual(@as(usize, 0), unshown.len);
        \\}
        \\
    ) catch @panic("OOM");
    const runtime = dep.module("riverrun");
    return b.addTest(.{
        .name = "excerpts-tests",
        .root_module = b.createModule(.{
            .root_source_file = files.add("excerpts_test.zig", root.items),
            .target = runtime.resolved_target,
            .optimize = runtime.optimize,
            .imports = &.{.{ .name = "riverrun-tools", .module = kit }},
        }),
    });
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
