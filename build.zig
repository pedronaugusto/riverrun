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
    manualTests(b, test_step);
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
        .imports = &.{ .{ .name = "riverrun-compiler", .module = river }, .{ .name = "riverrun", .module = runtime } },
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
        .imports = &.{ .{ .name = "riverrun-compiler", .module = compiler(river) orelse return }, .{ .name = "riverrun", .module = river.module("riverrun") } },
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
    // played from a script: the transcript, and a status that says how it ended
    const played = playRun(b, program, &.{ "--set", "furs = 2", "-i", "1" }, p.path("tools/testdata/sample.river"));
    played.expectExitCode(0);
    played.expectStdOutEqual(
        \\> :set furs = 2
        \\! opens stall
        \\  2 wares
        \\== market
        \\  [stall] [sells furs]
        \\HILDE: Ten pelts before the frost.
        \\HILDE: You have furs already.
        \\* 1 I'll bring them.
        \\* 2 Not this year.
        \\> 1
        \\[pelts += 10]
        \\HILDE: Good.
        \\-> end
        \\
    );
    test_step.dependOn(&played.step);
    // a call the game made into a package before the story starts, as the package's command
    const called = playRun(b, program, &.{ "--call", "restock furs count=2", "-i", "2" }, p.path("tools/testdata/sample.river"));
    called.expectExitCode(0);
    called.expectStdOutEqual(
        \\> :restock furs count=2
        \\! opens stall
        \\  2 wares
        \\! restocked furs
        \\  [furs += 2]
        \\== market
        \\  [stall] [sells furs]
        \\HILDE: Ten pelts before the frost.
        \\HILDE: You have furs already.
        \\* 1 I'll bring them.
        \\* 2 Not this year.
        \\> 2
        \\HILDE: Then next.
        \\-> end
        \\
    );
    test_step.dependOn(&called.step);
    const not_a_call = playRun(b, program, &.{ "--call", "set furs = 2" }, p.path("tools/testdata/sample.river"));
    not_a_call.expectExitCode(1);
    not_a_call.expectStdErrEqual("riverrun: error: --call `set furs = 2`: a package's command, as :help lists them, is what the game calls before the story starts\n");
    test_step.dependOn(&not_a_call.step);
    const waiting = playRun(b, program, &.{}, p.path("tools/testdata/sample.river"));
    waiting.expectExitCode(3);
    waiting.expectStdErrEqual("riverrun: the story waits for a choice, and the script gives no more\n");
    test_step.dependOn(&waiting.step);
    const unoffered = playRun(b, program, &.{ "-i", "3" }, p.path("tools/testdata/sample.river"));
    unoffered.expectExitCode(1);
    unoffered.expectStdOutMatch("> 3\nriverrun: error: the input `3`: there is no choice 3: 2 are offered\n");
    test_step.dependOn(&unoffered.step);
    const broken = playRun(b, program, &.{}, p.path("tools/testdata/broken.river"));
    broken.expectExitCode(4);
    broken.expectStdOutMatch("broken.river:9:1-9:11: error: a sum, or a change, passed what an int holds (64 bits) (Overflow)\n");
    test_step.dependOn(&broken.step);
}

// `riverrun play` over a story with `args`, its standard input empty, so a script is all it is given.
fn playRun(b: *std.Build, program: *std.Build.Step.Compile, args: []const []const u8, story: std.Build.LazyPath) *std.Build.Step.Run {
    const run = b.addRunArtifact(program);
    run.addArg("play");
    run.addArgs(args);
    run.addFileArg2(story, .{});
    run.setStdIn(.{ .bytes = "" });
    return run;
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

/// riverrun's manual: its chapters, the stories they show, the runs of the program they show, and the story shown
/// before and after `riverrun tag`. Every story under `stories/` checks and prints nothing; every story under
/// `mistakes/` prints what a chapter shows the checker saying about it. `docs/manual/README.md` says how a chapter
/// is written to it.
const manual = struct {
    const vocabulary = "docs/manual/stories/vocabulary.zig";
    const documents = [_][]const u8{
        "docs/manual/01-a-page-of-words.md",
        "docs/manual/02-choices.md",
        "docs/manual/03-remembering.md",
        "docs/manual/04-telling-the-game.md",
        "docs/manual/05-scenes-and-flow.md",
        "docs/manual/06-text-that-varies.md",
        "docs/manual/07-the-games-vocabulary.md",
        "docs/manual/08-pools.md",
        "docs/manual/09-rules.md",
    };
    const stories = [_][]const u8{
        "docs/manual/stories/01/ferry.river",
        "docs/manual/stories/02/ferry.river",
        "docs/manual/stories/03/ferry.river",
        "docs/manual/stories/04/ferry.river",
        "docs/manual/stories/05/ferry.river",
        "docs/manual/stories/06/ferry.river",
        "docs/manual/stories/06/bank.river",
        "docs/manual/stories/06/tagged/bank.river",
        "docs/manual/stories/07/ferry.river",
        "docs/manual/stories/08/ferry.river",
        "docs/manual/stories/08/inn.river",
        "docs/manual/stories/09/ferry.river",
    };
    const runs = [_]ShownRun{
        .{ .dir = "docs/manual/stories/01", .args = &.{ "play", "ferry.river" }, .output = "ferry.transcript" },
        .{ .dir = "docs/manual/mistakes/01", .args = &.{ "check", "ferry.river" }, .output = "ferry.diagnostics", .status = 1 },
        .{ .dir = "docs/manual/stories/02", .args = &.{ "play", "-i", "1", "-i", "2", "-i", "2", "-i", "3", "-i", "2", "ferry.river" }, .output = "ferry.transcript" },
        .{ .dir = "docs/manual/mistakes/02", .args = &.{ "check", "ferry.river" }, .output = "ferry.diagnostics", .status = 1 },
        .{ .dir = "docs/manual/stories/03", .args = &.{ "play", "--set", "rain = easing", "--script", "ferry.play", "ferry.river" }, .output = "ferry.transcript" },
        .{ .dir = "docs/manual/mistakes/03", .args = &.{ "check", "ferry.river" }, .output = "ferry.diagnostics", .status = 1 },
        .{ .dir = "docs/manual/stories/04", .args = &.{ "play", "--set", "rain = easing", "--script", "ferry.play", "ferry.river" }, .output = "ferry.transcript" },
        .{ .dir = "docs/manual/mistakes/04", .args = &.{ "check", "ferry.river" }, .output = "ferry.diagnostics", .status = 1 },
        .{ .dir = "docs/manual/stories/05", .args = &.{ "play", "--from", "crossing", "--set", "carrying = lantern", "--set", "trust = 1", "-i", "2", "-i", "1", "ferry.river" }, .output = "ferry.transcript" },
        .{ .dir = "docs/manual/mistakes/05", .args = &.{ "check", "ferry.river" }, .output = "ferry.diagnostics", .status = 1 },
        .{ .dir = "docs/manual/mistakes/05/jump", .args = &.{ "check", "ferry.river" }, .output = "ferry.diagnostics" },
        .{ .dir = "docs/manual/stories/06", .args = &.{ "play", "--set", "rain = easing", "--set", "coins = 1", "-i", "3", "-i", "3", "-i", "1", "-i", "1", "-i", "4", "ferry.river" }, .output = "ferry.transcript" },
        .{ .dir = "docs/manual/stories/06", .args = &.{ "play", "--from", "crossing", "--set", "trust = 1", "-i", "2", "-i", "1", "ferry.river" }, .output = "crossing.transcript" },
        .{ .dir = "docs/manual/stories/06", .args = &.{ "tag", "--check", "bank.river" }, .output = "bank.diagnostics", .status = 1 },
        .{ .dir = "docs/manual/stories/06/tagged", .args = &.{ "check", "--release", "bank.river" }, .output = "bank.diagnostics" },
        .{ .dir = "docs/manual/stories/06/tagged", .args = &.{ "play", "-i", "1", "bank.river" }, .output = "bank.transcript" },
        .{ .dir = "docs/manual/stories/07", .args = &.{ "play", "--set", "rain = easing", "--set", "coins = 1", "--set", "crossings_left() = 1", "--script", "ferry.play", "ferry.river" }, .output = "ferry.transcript" },
        .{ .dir = "docs/manual/mistakes/07", .args = &.{ "check", "ferry.river" }, .output = "ferry.diagnostics", .status = 1 },
        .{ .dir = "docs/manual/stories/07/fair", .args = &.{ "check", "fair.river", "stall.river" }, .output = "fair.diagnostics" },
        .{ .dir = "docs/manual/mistakes/07/fair", .args = &.{ "check", "fair.river", "stall.river" }, .output = "fair.diagnostics", .status = 1 },
        .{ .dir = "docs/manual/stories/07/fair", .args = &.{ "play", "--set", "owes(miller) = 3", "--set", "price(needles) = 2", "--wait", "21", "-i", "1", "fair.river", "stall.river" }, .output = "fair.transcript" },
        .{ .dir = "docs/manual/stories/08", .args = &.{ "play", "--set", "rain = easing", "--set", "near = otto, boy", "--script", "ferry.play", "ferry.river" }, .output = "ferry.transcript" },
        .{ .dir = "docs/manual/stories/08", .args = &.{ "play", "-i", "1", "inn.river" }, .output = "inn.transcript" },
        .{ .dir = "docs/manual/stories/08", .args = &.{ "play", "--from", "inn_night", "--set", "room = taproom", "--set", "hour = 22", "--set", "stood_a_drink = true", "inn.river" }, .output = "night.transcript" },
        .{ .dir = "docs/manual/mistakes/08", .args = &.{ "check", "ferry.river" }, .output = "ferry.diagnostics", .status = 1 },
        .{ .dir = "docs/manual/stories/09", .args = &.{ "play", "--set", "rain = pouring", "--script", "ferry.play", "ferry.river" }, .output = "ferry.transcript" },
        .{ .dir = "docs/manual/mistakes/09", .args = &.{ "check", "ferry.river" }, .output = "ferry.diagnostics", .status = 1 },
    };
    const tagged = [_]TaggedStory{.{ .before = "docs/manual/stories/06/bank.river", .after = "docs/manual/stories/06/tagged/bank.river" }};
};

// Each of `paths`, a file of `package`, copied beside the generated test as `{prefix}{i}` and named in its source.
fn embedEach(b: *std.Build, files: *std.Build.Step.WriteFile, root: *std.ArrayList(u8), package: *std.Build, prefix: []const u8, paths: []const []const u8) void {
    for (paths, 0..) |s, i| {
        _ = files.addCopyFile(package.path(s), b.fmt("{s}{d}", .{ prefix, i }));
        root.print(b.allocator, "    .{{ .path = \"{f}\", .text = @embedFile(\"{s}{d}\") }},\n", .{ std.zig.fmtString(s), prefix, i }) catch @panic("OOM");
    }
}

// The manual's stories checked, each printing nothing; its runs pinned; what its chapters show held to them: in the
// test step, and alone in `manual-test`. `bay manual` installs the program its stories are written for.
fn manualTests(b: *std.Build, tests: *std.Build.Step) void {
    const river = b.dependency("riverrun", building(b));
    const p = river.builder;
    const program = addProgram(b, river, .{ .vocabulary = p.path(manual.vocabulary) });
    b.step("manual", "The riverrun program the manual's stories are written for, into zig-out/bin").dependOn(&b.addInstallArtifact(program, .{}).step);
    const test_step = b.step("manual-test", "The manual's stories checked, its runs pinned, and what its chapters show held to them");
    tests.dependOn(test_step);
    for (manual.stories) |story| {
        const clean = addCheck(b, program, &.{p.path(story)}, .{});
        clean.expectStdOutEqual("");
        test_step.dependOn(&clean.step);
    }
    addShownRuns(b, test_step, program, p, &manual.runs);
    // a story some chapter shows the checker warn about checks too, and a ```river block may show it
    var stories: std.ArrayList([]const u8) = .empty;
    stories.appendSlice(b.allocator, &manual.stories) catch @panic("OOM");
    for (manual.runs) |r| if (r.status == 0 and std.mem.eql(u8, r.args[0], "check")) for (r.args[1..]) |a| {
        if (std.mem.endsWith(u8, a, ".river")) stories.append(b.allocator, b.pathJoin(&.{ r.dir, a })) catch @panic("OOM");
    };
    const excerpts = addExcerptsTest(b, river, .{ .package = p, .stories = stories.items, .documents = &manual.documents, .runs = &manual.runs, .tagged = &manual.tagged }) orelse return;
    test_step.dependOn(&b.addRunArtifact(excerpts).step);
}

/// A run of the `riverrun` program that a package's documents show in a ```console block, pinned by its tests: what
/// it prints to standard output, exactly, and its exit status.
pub const ShownRun = struct {
    /// The folder it runs in, relative to the package: the files it names, and the paths it prints, are relative to
    /// it, as a writer running it there sees them.
    dir: []const u8,
    /// Its arguments, after `riverrun`. Each that ends in `.river` or `.play` is a file of `dir` that it reads.
    args: []const []const u8,
    /// The file of `dir` holding what it prints to standard output, exactly.
    output: []const u8,
    /// Its exit status.
    status: u8 = 0,
};

/// A story a package's documents show as written and as `riverrun tag` leaves it: two files of the package.
pub const TaggedStory = struct { before: []const u8, after: []const u8 };

/// Each run, with `program`, its standard input empty, its output held to its file and its exit status to its own,
/// hung on `step` (a package's test step). `package` is the package the paths are in.
pub fn addShownRuns(b: *std.Build, step: *std.Build.Step, program: *std.Build.Step.Compile, package: *std.Build, runs: []const ShownRun) void {
    for (runs) |r| {
        const run = b.addRunArtifact(program);
        run.setName(b.fmt("{s}, in {s}", .{ commandOf(b, r.args), r.dir }));
        run.setCwd(package.path(r.dir));
        run.addArgs(r.args);
        for (r.args) |a| if (std.mem.endsWith(u8, a, ".river") or std.mem.endsWith(u8, a, ".play")) run.addFileInput(package.path(b.pathJoin(&.{ r.dir, a })));
        run.setStdIn(.{ .bytes = "" });
        run.addCheck(.{ .expect_stdout_snapshot = package.path(b.pathJoin(&.{ r.dir, r.output })) });
        run.expectExitCode(r.status);
        step.dependOn(&run.step);
    }
}

// The command as a writer types it: `riverrun` and the arguments, each quoted where a shell would split it.
fn commandOf(b: *std.Build, args: []const []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(b.allocator, "riverrun") catch @panic("OOM");
    for (args) |a| {
        const bare = a.len > 0 and for (a) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and std.mem.findScalar(u8, "_./=:+-,", ch) == null) break false;
        } else true;
        if (std.mem.findScalar(u8, a, '\'') != null) std.debug.panic("a shown run's argument holds a quote, which its command cannot show plainly: {s}", .{a});
        if (bare) out.print(b.allocator, " {s}", .{a}) catch @panic("OOM") else out.print(b.allocator, " '{s}'", .{a}) catch @panic("OOM");
    }
    return out.items;
}

pub const ExcerptsOptions = struct {
    /// The package the paths are in.
    package: *std.Build,
    /// Whole stories, each checked on its own.
    stories: []const []const u8,
    /// Markdown, whose ```river blocks are shown stories, and Zig, whose `//!` blocks indented four spaces past the
    /// `//!` are. A Markdown document's ```console blocks are runs, and its ```river refused blocks the stories
    /// those runs refuse.
    documents: []const []const u8,
    /// The runs the documents show, as `addShownRuns` pins them: each must be shown whole, and by some document.
    runs: []const ShownRun = &.{},
    /// Stories shown as written and as `riverrun tag` leaves them.
    tagged: []const TaggedStory = &.{},
};

/// A test that every story a package's documents show is rows of one of its checked stories, one after another as
/// written, so what the documents show is what `addCheck` checked; that every run they show is shown whole, as
/// `addShownRuns` pins it, and every refused story as the run refuses it; and that a story shown tagged is what
/// `riverrun tag` writes. `dep` is riverrun asked by `building(b)`.
pub fn addExcerptsTest(b: *std.Build, dep: *std.Build.Dependency, options: ExcerptsOptions) ?*std.Build.Step.Compile {
    const kit = tools(dep) orelse return null;
    const files = b.addWriteFiles();
    var root: std.ArrayList(u8) = .empty;
    root.appendSlice(b.allocator,
        \\//! Every story a document shows is rows of a checked story, every run it shows is what the run printed, and
        \\//! every story it shows tagged is what `riverrun tag` writes.
        \\const std = @import("std");
        \\const excerpts = @import("riverrun-tools").excerpts;
        \\const Named = excerpts.Named;
        \\
        \\const stories = [_]Named{
        \\
    ) catch @panic("OOM");
    embedEach(b, files, &root, options.package, "story", options.stories);
    root.appendSlice(b.allocator, "};\nconst documents = [_]Named{\n") catch @panic("OOM");
    embedEach(b, files, &root, options.package, "document", options.documents);
    root.appendSlice(b.allocator, "};\nconst runs = [_]excerpts.Run{\n") catch @panic("OOM");
    for (options.runs, 0..) |r, i| {
        _ = files.addCopyFile(options.package.path(b.pathJoin(&.{ r.dir, r.output })), b.fmt("run{d}", .{i}));
        root.print(b.allocator, "    .{{ .command = \"{f}\", .output = @embedFile(\"run{d}\"), .refused = &.{{\n", .{ std.zig.fmtString(commandOf(b, r.args)), i }) catch @panic("OOM");
        // the stories `riverrun check` refuses here: what a ```river refused block shows
        if (r.status == 1 and std.mem.eql(u8, r.args[0], "check")) for (r.args[1..], 0..) |a, k| {
            if (!std.mem.endsWith(u8, a, ".river")) continue;
            const path = b.pathJoin(&.{ r.dir, a });
            _ = files.addCopyFile(options.package.path(path), b.fmt("run{d}_{d}", .{ i, k }));
            root.print(b.allocator, "        .{{ .path = \"{f}\", .text = @embedFile(\"run{d}_{d}\") }},\n", .{ std.zig.fmtString(path), i, k }) catch @panic("OOM");
        };
        root.appendSlice(b.allocator, "    } },\n") catch @panic("OOM");
    }
    root.appendSlice(b.allocator, "};\nconst tagged = [_]excerpts.Tagged{\n") catch @panic("OOM");
    for (options.tagged, 0..) |t, i| {
        _ = files.addCopyFile(options.package.path(t.before), b.fmt("before{d}", .{i}));
        _ = files.addCopyFile(options.package.path(t.after), b.fmt("after{d}", .{i}));
        root.print(b.allocator, "    .{{ .before = .{{ .path = \"{f}\", .text = @embedFile(\"before{d}\") }}, .after = .{{ .path = \"{f}\", .text = @embedFile(\"after{d}\") }} }},\n", .{ std.zig.fmtString(t.before), i, std.zig.fmtString(t.after), i }) catch @panic("OOM");
    }
    root.appendSlice(b.allocator,
        \\};
        \\
        \\test "every story a document shows is rows of a checked story, and every run what it printed" {
        \\    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        \\    defer arena.deinit();
        \\    const unshown = try excerpts.unshown(arena.allocator(), &documents, .{ .stories = &stories, .runs = &runs });
        \\    for (unshown) |u| std.debug.print("{s}:{d}: {s}\n", .{ u.path, u.line, u.why });
        \\    try std.testing.expectEqual(@as(usize, 0), unshown.len);
        \\}
        \\
        \\test "every story shown tagged is what `riverrun tag` writes into it as written" {
        \\    for (tagged) |t| {
        \\        const same = try excerpts.retagged(std.testing.allocator, t);
        \\        if (!same) std.debug.print("{s}: not what `riverrun tag` writes into {s}\n", .{ t.after.path, t.before.path });
        \\        try std.testing.expect(same);
        \\    }
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
        .imports = &.{ .{ .name = "riverrun-compiler", .module = compiler(river) orelse return null }, .{ .name = "riverrun", .module = river.module("riverrun") } },
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
