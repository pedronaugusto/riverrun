//! `riverrun`, the program a writer runs, built by a game's build with the
//! game's vocabulary in it (`addStory`, `addProgram`): it checks a story
//! exactly as that build does, gives its lines their ids, and compiles it
//! for the build. Its arguments are read by ensign; what it does is
//! `riverrun-tools`', which the editor to come calls too. It prints every
//! diagnostic in `tools.report`'s form and exits 0 when nothing is wrong, 1
//! when something in the story is (or a file cannot be read or written),
//! and 2 when the command line is mistaken.

const std = @import("std");
const aegis = @import("aegis");
const ensign = @import("ensign");
const river = @import("riverrun-compiler");
const tools = @import("riverrun-tools");
const vocabulary = @import("vocabulary");

const syntax = river.syntax;
const report = tools.report;
const joined = river.join(vocabulary);

const Check = struct {
    release: bool = false,
    files: []const []const u8,

    pub const spec: ensign.Spec(@This()) = .{
        .about = "Check a story as the game's build checks it, and build nothing",
        .description = "Reads the story's files as one story, checks them against the game's vocabulary and its " ++
            "packages, and compiles them without writing anything, so a story that checks here builds there. " ++
            "Every problem is printed, one to a line: the file, the place it starts and the place just past its end " ++
            "(line:column, counting from 1), error or warning, and what is wrong. Nothing printed means nothing is " ++
            "wrong. The exit status is 0 when there is no error (warnings allowed), 1 when there is.",
        .options = .{
            .release = .{ .help = "Check as a release build does: every line and choice needs its id (riverrun tag writes them)" },
            .files = .{ .positional = true, .hint = .file, .value_name = "FILE", .help = "The story's .river files, all of them: names one file uses from another are found across them" },
        },
        .examples = &.{
            .{ .command = "riverrun check story/*.river", .help = "Check every file of the story." },
            .{ .command = "riverrun check --release story/*.river", .help = "Check that the story is ready for a release, ids and all." },
        },
    };
};

const Tag = struct {
    check: bool = false,
    files: []const []const u8,

    pub const spec: ensign.Spec(@This()) = .{
        .about = "Give every line and choice without an id its id, ^ and six letters and digits at the end of its row",
        .description = "Writes ` ^id` at the end of every line and choice that has none, before its comment, and " ++
            "changes nothing else in the files: an id once written is never changed, so translations and " ++
            "recorded voices keyed on it survive any edit of the words. Each id is new to all the files given, and " ++
            "the same files always get the same ids. Prints the name of each file it changed. A file the reader " ++
            "refuses is reported and nothing is written.",
        .options = .{
            .check = .{ .help = "Change nothing: print every line and choice without an id, and exit 1 if there is one" },
            .files = .{ .positional = true, .hint = .file, .value_name = "FILE", .help = "The story's .river files, all of them, so no id is given twice" },
        },
        .examples = &.{
            .{ .command = "riverrun tag story/*.river", .help = "Give every new line its id." },
            .{ .command = "riverrun tag --check story/*.river", .help = "Fail if a line has no id, as a release's CI may." },
        },
    };
};

const Compile = struct {
    graph: []const u8,
    words: []const u8,
    release: bool = false,
    files: []const []const u8,

    pub const spec: ensign.Spec(@This()) = .{
        .about = "Compile a story into its graph and string table, as the game's build does",
        .description = "What a game's build runs through addStory: checks the story as `riverrun check` does and, " ++
            "when there is no error, writes the graph and the string table the game embeds. Problems are printed " ++
            "as `check` prints them, to standard error.",
        .options = .{
            .graph = .{ .value_name = "PATH", .hint = .file, .help = "Where the compiled graph is written" },
            .words = .{ .value_name = "PATH", .hint = .file, .help = "Where the string table is written" },
            .release = .{ .help = "Compile a release: every line and choice needs its id" },
            .files = .{ .positional = true, .hint = .file, .value_name = "FILE", .help = "The story's .river files" },
        },
    };
};

const Cli = struct {
    command: union(enum) {
        check: Check,
        tag: Tag,
        compile: Compile,
    },

    pub const spec: ensign.Spec(@This()) = .{
        .name = "riverrun",
        .about = "Check, tag and compile river stories with the game's vocabulary",
        .description = "This riverrun was built by the game's build, with the game's vocabulary and its packages in " ++
            "it, so it checks a story exactly as that build does.",
        .commands = .{
            .check = .{ .help = "Check a story as the game's build checks it" },
            .tag = .{ .help = "Give every line and choice its id" },
            .compile = .{ .help = "Compile a story, as the game's build does" },
        },
        .examples = &.{
            .{ .command = "riverrun check story/*.river", .help = "Check every file of the story." },
            .{ .command = "riverrun tag story/*.river", .help = "Give every new line its id." },
        },
    };
};

pub fn main(init: std.process.Init) !u8 {
    const cli = ensign.parseOrExit(Cli, init);
    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buffer);
    var err_buffer: [4096]u8 = undefined;
    var err = std.Io.File.stderr().writer(init.io, &err_buffer);
    const status = switch (cli.command) {
        .check => |c| try check(init, &out.interface, c),
        .tag => |t| try tag(init, &out.interface, t),
        .compile => |c| try compile(init, &err.interface, c),
    };
    try out.interface.flush();
    try err.interface.flush();
    return status;
}

fn check(init: std.process.Init, w: *std.Io.Writer, c: Check) !u8 {
    var m = try read(init, w, c.files) orelse return 1;
    defer m.deinit();
    var compiled = try build(w, &m, c.release) orelse return 1;
    compiled.deinit(init.gpa);
    return @intFromBool(m.errors() > 0);
}

fn compile(init: std.process.Init, w: *std.Io.Writer, c: Compile) !u8 {
    var m = try read(init, w, c.files) orelse return 1;
    defer m.deinit();
    var compiled = try build(w, &m, c.release) orelse return 1;
    defer compiled.deinit(init.gpa);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(init.io, .{ .sub_path = c.graph, .data = compiled.graph });
    try cwd.writeFile(init.io, .{ .sub_path = c.words, .data = compiled.words });
    return 0;
}

// Checks and compiles the story, printing every diagnostic: the compiled story, or null when it is refused.
fn build(w: *std.Io.Writer, m: *tools.Manuscript, release: bool) !?river.compile.Compiled {
    var options = joined.options;
    if (release) options.mode = .release;
    try m.check(options);
    const compiled = m.compile(joined.passes) catch |e| switch (e) {
        error.OutOfMemory => return e,
        // what the checker passed, the compiler should build: a fault of riverrun's, said as one
        else => {
            try report.all(w, m.files, &m.diags);
            try w.print("{s}: error: the story checks, and the compiler could not build it ({t}): this is riverrun's fault, not the story's; please report it\n", .{ report.program, e });
            return null;
        },
    };
    try report.all(w, m.files, &m.diags);
    return compiled;
}

fn tag(init: std.process.Init, w: *std.Io.Writer, t: Tag) !u8 {
    var m = try read(init, w, t.files) orelse return 1;
    defer m.deinit();
    if (m.errors() > 0) {
        try report.all(w, m.files, &m.diags);
        try w.print("{s}: error: nothing was written: the reader refused these files, and an id goes only where the reader reads a line\n", .{report.program});
        return 1;
    }
    const a = m.arena.allocator();
    if (t.check) {
        const missing = try tools.tag.missing(a, m.files);
        for (missing) |p| {
            const f = &m.files[p.file];
            const r = report.range(f, p.span);
            try w.print("{s}:{d}:{d}-{d}:{d}: error: this has no id: `riverrun tag` writes one\n", .{ f.path, r.from.line, r.from.col, r.to.line, r.to.col });
        }
        return @intFromBool(missing.len > 0);
    }
    const given = try tools.tag.give(a, m.files);
    var failed = false;
    for (given.files, given.added) |*f, n| {
        if (n == 0) continue;
        var text: std.Io.Writer.Allocating = .init(init.gpa);
        defer text.deinit();
        try syntax.print(&text.writer, f);
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = f.path, .data = text.written() }) catch |e| {
            try report.whole(w, f.path, .err, "cannot be written ({t}): its ids were not saved", .{e});
            failed = true;
            continue;
        };
        try w.print("{s}\n", .{f.path});
    }
    return @intFromBool(failed);
}

// Every file read, in order, as one story; a file that cannot be read is reported and null returned.
fn read(init: std.process.Init, w: *std.Io.Writer, paths: []const []const u8) !?tools.Manuscript {
    const a = init.arena.allocator();
    const pages = try a.alloc(tools.Manuscript.Page, paths.len);
    var unread = false;
    for (paths, pages) |path, *p| {
        const text = aegis.own.readFile(init.io, std.Io.Dir.cwd(), path, a, .fromRaw(syntax.max_file + 1)) catch |e| {
            switch (e) {
                error.FileNotFound => try report.whole(w, path, .err, "there is no such file", .{}),
                error.IsDir => try report.whole(w, path, .err, "this is a directory: give the .river files in it", .{}),
                error.AccessDenied, error.PermissionDenied => try report.whole(w, path, .err, "this file may not be read", .{}),
                error.StreamTooLong => try report.whole(w, path, .err, "this file is longer than a story file may be ({d} bytes)", .{syntax.max_file}),
                else => try report.whole(w, path, .err, "this file cannot be read ({t})", .{e}),
            }
            unread = true;
            continue;
        };
        p.* = .{ .path = path, .text = text };
    }
    if (unread) return null;
    return tools.Manuscript.read(init.gpa, pages) catch |e| switch (e) {
        error.TooManyFiles => {
            try w.print("{s}: error: a story has at most {d} files, and {d} were given\n", .{ report.program, tools.Manuscript.max_files, paths.len });
            return null;
        },
        else => |other| return other,
    };
}
