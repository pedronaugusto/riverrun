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

const Play = struct {
    from: ?[]const u8 = null,
    set: []const []const u8 = &.{},
    wait: []const []const u8 = &.{},
    call: []const []const u8 = &.{},
    script: ?[]const u8 = null,
    input: []const []const u8 = &.{},
    files: []const []const u8,

    pub const spec: ensign.Spec(@This()) = .{
        .about = "Play a story as the game would, with you in the game's place",
        .description = "Checks the story as `riverrun check` does, then plays it from where the game starts it (the " ++
            "vocabulary's entry, or the first section nothing leads to), with its rules and its packages' runtimes " ++
            "running as in the game: quests reach their stages, a schedule comes due when a clock moves. Every line is " ++
            "printed as the story writes it, what the game is told in brackets under it, the choices numbered. Type a " ++
            "choice's number to take it, and :help for the rest: see the facts, set one, set what a query answers, move " ++
            "a clock, go back, start again, and make the calls the game makes into its packages (start a quest with its " ++
            "roles: :start bounty target=wolf), each listed with what it applies to in this story. Queries are answered " ++
            "with what you set, else their type's first value, and each answer is shown where it is asked; an action's " ++
            "outcome is asked of you when the story waits for it. What the game does by its own mechanics (a pool a " ++
            "tag names, a day's sticky choices offered again) is the game's and does not run here.\n\n" ++
            "With --script or --input, or with a script on standard input, every input is given up front, one to a row, " ++
            "as you would type it, and the play is written down in a plain, stable form: the same script always gives " ++
            "the same transcript. The exit status says how it ended: 0 the story came to its end, 3 it waits for an " ++
            "input the script did not give, 4 it stopped on an error at run time (printed where what met it is written: the " ++
            "effect, the condition, the line), 1 the " ++
            "story does not check or a row of the script could not be taken (printed where it is written), 2 the " ++
            "command line is mistaken.",
        .options = .{
            .from = .{ .value_name = "SECTION", .help = "Start at this section (`section.part` for a part) rather than where the game starts" },
            .set = .{ .value_name = "FACT=VALUE", .help = "A fact the game has set when the story starts, or what a query answers, as :set takes it (`spot = door`); give it again for each" },
            .wait = .{ .value_name = "N", .help = "How far a clock has run when the story starts, as :wait takes it (`27`, `27 turn`)" },
            .call = .{ .value_name = "COMMAND", .help = "A call the game made into a package before the story starts, as its command takes it (`start bounty target=wolf`); give it again for each" },
            .script = .{ .value_name = "PATH", .hint = .file, .help = "Inputs from this file, one to a row as you would type them; `//` begins a comment" },
            .input = .{ .short = 'i', .value_name = "INPUT", .help = "An input, as you would type it; give it again for each, after the script's" },
            .files = .{ .positional = true, .hint = .file, .value_name = "FILE", .help = "The story's .river files, all of them" },
        },
        .examples = &.{
            .{ .command = "riverrun play story/*.river", .help = "Play the story in the terminal." },
            .{ .command = "riverrun play --from found_1969 --set 'spot = door' story/*.river", .help = "Try one scene, with what the game would have set before it." },
            .{ .command = "riverrun play --call 'start bounty target=wolf' --from board story/*.river", .help = "Try a scene with a quest the game started." },
            .{ .command = "riverrun play -i 2 -i ':set met = true' -i 1 story/*.river", .help = "Take choice 2, set a fact, take choice 1, and print the transcript." },
            .{ .command = "riverrun play --script tests/hide.play story/*.river", .help = "Play a script of inputs; exit 0 when the story reaches its end." },
        },
    };
};

const Cli = struct {
    command: union(enum) {
        check: Check,
        tag: Tag,
        play: Play,
        compile: Compile,
    },

    pub const spec: ensign.Spec(@This()) = .{
        .name = "riverrun",
        .about = "Check, tag, play and compile river stories with the game's vocabulary",
        .description = "This riverrun was built by the game's build, with the game's vocabulary and its packages in " ++
            "it, so it checks a story exactly as that build does.",
        .commands = .{
            .check = .{ .help = "Check a story as the game's build checks it" },
            .tag = .{ .help = "Give every line and choice its id" },
            .play = .{ .help = "Play a story as the game would, in the terminal or from a script" },
            .compile = .{ .help = "Compile a story, as the game's build does" },
        },
        .examples = &.{
            .{ .command = "riverrun check story/*.river", .help = "Check every file of the story." },
            .{ .command = "riverrun tag story/*.river", .help = "Give every new line its id." },
            .{ .command = "riverrun play story/*.river", .help = "Play the story." },
        },
    };
};

pub fn main(init: std.process.Init) !u8 {
    const cli = ensign.parseOrExit(Cli, init);
    var out_buffer: [4096]u8 = undefined;
    // streams: what the shell appends to is appended to, and the two in one file follow each other
    var out = ensign.stdout(init.io, &out_buffer);
    var err_buffer: [4096]u8 = undefined;
    var err = ensign.stderr(init.io, &err_buffer);
    const status = switch (cli.command) {
        .check => |c| try check(init, &out.interface, c),
        .tag => |t| try tag(init, &out.interface, t),
        .play => |p| try play(init, &out.interface, &err.interface, p),
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

fn play(init: std.process.Init, out: *std.Io.Writer, err: *std.Io.Writer, p: Play) !u8 {
    var m = try read(init, err, p.files) orelse return 1;
    defer m.deinit();
    var compiled = try build(err, &m, false) orelse return 1;
    defer compiled.deinit(init.gpa);
    if (m.errors() > 0) return 1;
    var loaded: tools.walk.Loaded = undefined;
    loaded.init(init.gpa, compiled.graph, compiled.words) catch |e| {
        try err.print("{s}: error: the story checks, and the runtime could not load what the compiler wrote ({t}): this is riverrun's fault, not the story's; please report it\n", .{ report.program, e });
        return 1;
    };
    defer loaded.deinit();
    const a = init.arena.allocator();
    const start = if (p.from) |name| loaded.story.sectionNamed(name) orelse {
        // a pool's candidate is named as a part is, and is the pool's to pick
        if (std.mem.findScalarLast(u8, name, '.')) |dot| if (loaded.story.sectionNamed(name[0..dot])) |whole| if (loaded.story.section(whole).kind == .pool) {
            try err.print("{s}: error: `{s}` is a candidate of the pool `{s}`, which picks it: a play starts at a section, or a part of a scene\n", .{ report.program, name, name[0..dot] });
            return 1;
        };
        try err.print("{s}: error: the story has no section or part called `{s}` to start at\n", .{ report.program, name });
        return 1;
    } else tools.Play.entry(&m.checked.?, &loaded.story) orelse {
        try err.print("{s}: error: the story has no section to start at: name one with --from\n", .{report.program});
        return 1;
    };
    var session: tools.Play = undefined;
    try session.init(init.gpa, &loaded, .{ .start = start, .leads = try tools.Play.leadsOf(a, joined.options), .delivery = joined.options.delivery, .running = joined.running });
    defer session.deinit();
    // what the game has set when the story starts, read as :set and :wait read it
    var given: std.ArrayList(tools.Play.Input) = .empty;
    var shown: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ p.set, p.wait, p.call }, [_][]const u8{ "set", "wait", "call" }) |list, option| for (list) |words| {
        // read as the command it is written as: `:set`, `:wait`, or a package's own
        const row = if (std.mem.eql(u8, option, "call")) try std.mem.concat(a, u8, &.{ ":", words }) else try std.mem.concat(a, u8, &.{ ":", option, " ", words });
        var why: []const u8 = "";
        const taken = tools.script.read(a, &session, row, &why) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.Refused => {
                try err.print("{s}: error: --{s} `{s}`: {s}\n", .{ report.program, option, words, why });
                return 1;
            },
        };
        const command = taken orelse continue;
        if (command != .input or (std.mem.eql(u8, option, "call") and command.input != .command)) {
            try err.print("{s}: error: --call `{s}`: a package's command, as :help lists them, is what the game calls before the story starts\n", .{ report.program, words });
            return 1;
        }
        try given.append(a, command.input);
        try shown.append(a, row);
    };
    if (given.items.len > 0) session.startWith(given.items) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.Refused => {
            try err.print("{s}: error: the story cannot start so: {s}\n", .{ report.program, session.refusal });
            return 1;
        },
    };
    const color = (std.Io.File.stdout().isTty(init.io) catch false) and init.environ_map.get("NO_COLOR") == null;
    const t: tools.transcript.Transcript = .{ .play = &session, .files = m.files, .where = &compiled.where, .color = color };
    for (shown.items) |row| try t.echo(out, row);
    const interactive = p.script == null and p.input.len == 0 and (std.Io.File.stdin().isTty(init.io) catch false);
    if (interactive) return terminal(init, out, err, &t, &session);
    // every input up front: the script's rows, then each --input, or else standard input's rows
    var rows: std.ArrayList(tools.script.Row) = .empty;
    if (p.script) |path| try rowsOf(a, &rows, path, try readInputs(init, err, path) orelse return 1);
    for (p.input) |i| try rows.append(a, .{ .text = i });
    if (p.script == null and p.input.len == 0) try rowsOf(a, &rows, "stdin", try readInputs(init, err, null) orelse return 1);
    const ending = try tools.script.run(init.gpa, out, &t, &session, rows.items);
    return switch (ending) {
        .ended => 0,
        .refused => 1,
        .waiting => blk: {
            try err.print("{s}: the story waits for {s}, and the script gives no more\n", .{ report.program, if (session.waitingFor() == .choice) "a choice" else "an action's outcome" });
            break :blk 3;
        },
        .stopped => 4,
    };
}

// A play in the terminal: what is told printed, then a prompt, until the player quits or the input ends.
fn terminal(init: std.process.Init, out: *std.Io.Writer, err: *std.Io.Writer, t: *const tools.transcript.Transcript, p: *tools.Play) !u8 {
    var buffer: [4096]u8 = undefined;
    var in = std.Io.File.stdin().reader(init.io, &buffer);
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    try err.writeAll("riverrun play: type a choice's number to take it, :help for the rest, :quit to stop\n");
    try err.flush();
    try tools.script.tellAll(out, t, p);
    while (true) {
        try out.writeAll("> ");
        try out.flush();
        // a row the player typed: what the terminal gives, behind the program's one boundary for what it reads
        const row = (in.interface.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                try err.print("{s}: a row is at most {d} bytes\n", .{ report.program, buffer.len });
                try err.flush();
                continue;
            },
            else => return e,
        }) orelse break;
        _ = arena.reset(.retain_capacity);
        switch (try tools.script.one(arena.allocator(), out, t, p, row, false)) {
            .taken => {},
            .quit => return 0,
            .refused => |why| {
                try out.flush();
                try err.print("{s}: {s}\n", .{ report.program, why });
                try err.flush();
            },
        }
    }
    try out.writeByte('\n');
    return 0;
}

// The rows of a script, each placed by its path and line.
fn rowsOf(a: std.mem.Allocator, rows: *std.ArrayList(tools.script.Row), path: []const u8, text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var line: u32 = 0;
    while (it.next()) |row| {
        line += 1;
        if (row.len == 0 and it.peek() == null) break;
        try rows.append(a, .{ .text = row, .path = path, .line = line });
    }
}

// A script's text, from its file or from standard input; null when it cannot be read, which is reported.
fn readInputs(init: std.process.Init, err: *std.Io.Writer, path: ?[]const u8) !?[]const u8 {
    const a = init.arena.allocator();
    const limit: std.Io.Limit = .limited(syntax.max_file + 1);
    const p = path orelse {
        var buffer: [4096]u8 = undefined;
        var in = std.Io.File.stdin().reader(init.io, &buffer);
        return in.interface.allocRemaining(a, limit) catch |e| {
            try report.whole(err, "stdin", .err, "the script cannot be read ({t})", .{e});
            return null;
        };
    };
    return aegis.own.readFile(init.io, std.Io.Dir.cwd(), p, a, .fromRaw(syntax.max_file + 1)) catch |e| {
        switch (e) {
            error.FileNotFound => try report.whole(err, p, .err, "there is no such file", .{}),
            else => try report.whole(err, p, .err, "this script cannot be read ({t})", .{e}),
        }
        return null;
    };
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
