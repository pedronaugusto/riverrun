//! What a player types, read against the story being played: one input to
//! a row, the same in a terminal and in a script, so a script is what a
//! player would have typed, and a play typed once plays again from it.
//!
//!     2                        the choice numbered 2
//!     true                     the outcome asked for (a number, a value of its list, a thing, "words")
//!     :set met = true          a fact set; `+=` and `-=` add to a set or an int, or take from it
//!     :set opinion(marta) = 3  a fact kept per thing, for one thing
//!     :set count(pelt) = 10    what a query answers from now on, for those arguments
//!     :wait 3                  the clock moved on 3 (`:wait 3 day` where the story has more than one)
//!     :facts                   the facts that hold something other than where they started (`:facts met kept`)
//!     :back                    back one input
//!     :restart                 from the start, every input forgotten
//!     :quit                    the end of playing
//!     :help                    these
//!
//! An empty row, or one that begins with `//`, is nothing.

const std = @import("std");
const runtime = @import("riverrun");
const Play = @import("Play.zig");
const transcript = @import("transcript.zig");

const story = runtime.story;
const facts = runtime.facts;

pub const Command = union(enum) {
    input: Play.Input,
    /// The facts to show: those named, or none for every one that moved.
    facts: []const facts.FactId,
    back,
    restart,
    quit,
    help,
};

/// The help a player is shown for `:help`.
pub const help =
    \\  N                         take the choice numbered N
    \\  VALUE                     the outcome an action waits for: true, 3, a value of its list, a thing, "words"
    \\  :set FACT = VALUE         set a fact; += and -= add to a set or an int, or take from it
    \\  :set FACT(KEY) = VALUE    a fact kept per thing, for one thing
    \\  :set QUERY(ARGS) = VALUE  what the game answers a query with, from now on
    \\  :wait N [CLOCK]           move a clock on N
    \\  :facts [FACT ...]         the facts that moved since the start, or those named
    \\  :back                     back one input
    \\  :restart                  from the start again
    \\  :quit                     stop playing
    \\
;

pub const Error = error{ OutOfMemory, Refused };

/// What `row` says, read against `p`; null for nothing. Refused with `why` saying what is wrong.
pub fn read(a: std.mem.Allocator, p: *const Play, row: []const u8, why: *[]const u8) Error!?Command {
    const text = std.mem.trim(u8, row, " \t\r");
    if (text.len == 0 or std.mem.startsWith(u8, text, "//")) return null;
    if (text[0] != ':') return .{ .input = try bare(a, p, text, why) };
    var words = std.mem.tokenizeAny(u8, text[1..], " \t");
    const verb = words.next() orelse return refuse(a, why, "`:` begins a command: :set, :wait, :facts, :back, :restart, :quit, :help", .{});
    const rest = std.mem.trim(u8, words.rest(), " \t");
    if (eql(verb, "back")) return .back;
    if (eql(verb, "restart")) return .restart;
    if (eql(verb, "quit")) return .quit;
    if (eql(verb, "help")) return .help;
    if (eql(verb, "facts")) return .{ .facts = try factList(a, p, rest, why) };
    if (eql(verb, "set")) return .{ .input = try set(a, p, rest, why) };
    if (eql(verb, "wait")) return .{ .input = try wait(a, p, rest, why) };
    return refuse(a, why, "there is no command :{s}: :set, :wait, :facts, :back, :restart, :quit, :help", .{verb});
}

// A row with no command: a choice's number, or an outcome, by what is waited for.
fn bare(a: std.mem.Allocator, p: *const Play, text: []const u8, why: *[]const u8) Error!Play.Input {
    const waiting = p.waitingFor() orelse return refuse(a, why, "the story is not waiting for anything yet", .{});
    switch (waiting) {
        .choice => {
            const n = std.fmt.parseInt(usize, text, 10) catch return refuse(a, why, "a choice is waited for: give its number", .{});
            return .{ .choose = n };
        },
        .outcome => {
            const call = p.asking().?;
            const d = p.loaded.story.fact(call.result.?);
            return .{ .outcome = try value(a, p, text, transcript.factShape(d), why) };
        },
        .end => return refuse(a, why, "the story has ended: :back, :restart or :quit", .{}),
        .stopped => return refuse(a, why, "the story stopped: :back or :restart", .{}),
    }
}

// `:set target = value`, `+=`, `-=`.
fn set(a: std.mem.Allocator, p: *const Play, text: []const u8, why: *[]const u8) Error!Play.Input {
    const usage = "write :set FACT = VALUE, :set FACT += VALUE, or :set QUERY(ARGS) = VALUE";
    // the first `=` outside parentheses and quotes, with a `+` or `-` before it
    var depth: usize = 0;
    var quoted = false;
    const at = for (text, 0..) |c, i| {
        switch (c) {
            '"' => quoted = !quoted,
            '(' => if (!quoted) {
                depth += 1;
            },
            ')' => if (!quoted) {
                depth -|= 1;
            },
            '=' => if (!quoted and depth == 0) break i,
            else => {},
        }
    } else return refuse(a, why, "{s}", .{usage});
    const op: @FieldType(@FieldType(Play.Input, "set"), "effect") = if (at > 0 and text[at - 1] == '+') .add else if (at > 0 and text[at - 1] == '-') .remove else .set;
    const left = std.mem.trim(u8, text[0..if (op == .set) at else at - 1], " \t");
    const right = std.mem.trim(u8, text[at + 1 ..], " \t");
    if (left.len == 0) return refuse(a, why, "{s}", .{usage});
    const s = &p.loaded.story;
    const name, const inner = splitCall(left) orelse return refuse(a, why, "`{s}` is not a name: {s}", .{ left, usage });
    if (s.factNamed(name)) |f| {
        const d = s.fact(f);
        var key: ?facts.Key = null;
        if (inner) |k| {
            key = switch (d.key) {
                .none => return refuse(a, why, "`{s}` is not kept per thing: :set {s} = …", .{ name, name }),
                .items => |e| try item(a, s, e, std.mem.trim(u8, k, " "), why),
                .ref => |kind| p.thingNamed(s.refKind(kind), std.mem.trim(u8, k, " ")) orelse return refuse(a, why, "there is no {s} called `{s}`", .{ s.refKind(kind), k }),
            };
        } else if (d.key != .none) return refuse(a, why, "`{s}` is kept per thing: :set {s}(KEY) = …", .{ name, name });
        const shape = transcript.factShape(d);
        const v: facts.Value = switch (op) {
            .set => try value(a, p, right, shape, why),
            .add, .remove => switch (d.kind) {
                .int => .{ .int = std.fmt.parseInt(i64, right, 10) catch return refuse(a, why, "`{s}` is an int: += and -= take a number", .{name}) },
                .set_of => .{ .one_of = try item(a, s, d.enumeration.?, right, why) },
                else => return refuse(a, why, "+= and -= change a set or an int, and `{s}` is neither", .{name}),
            },
        };
        return .{ .set = .{ .target = .{ .fact = .{ .fact = f, .key = key } }, .effect = op, .value = v } };
    }
    for (0..s.len(.externs)) |i| {
        const id: facts.ExternId = .fromRaw(@intCast(i)); // safe: below the story's extern count
        const x = s.externFn(id);
        if (!eql(x.name, name)) continue;
        if (x.action) return refuse(a, why, "`{s}` is an action: the game decides its outcome when the story asks", .{name});
        const list = try arguments(a, p, x, inner orelse "", why);
        return .{ .set = .{ .target = .{ .answer = .{ .query = id, .args = list } }, .effect = op, .value = try value(a, p, right, transcript.paramShape(s, x.returns.?), why) } };
    }
    return refuse(a, why, "the story has no fact or query called `{s}`", .{name});
}

fn arguments(a: std.mem.Allocator, p: *const Play, x: story.Extern, text: []const u8, why: *[]const u8) Error![]const facts.Value {
    const s = &p.loaded.story;
    var list: std.ArrayList(facts.Value) = .empty;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const word = std.mem.trim(u8, raw, " ");
        if (word.len == 0 and x.params.len == 0) break;
        if (list.items.len == x.params.len) return refuse(a, why, "`{s}` takes {d} argument{s}", .{ x.name, x.params.len, if (x.params.len == 1) "" else "s" });
        const param = s.param(x.params.start + @as(u32, @intCast(list.items.len))); // safe: below the extern's params
        try list.append(a, try value(a, p, word, transcript.paramShape(s, param), why));
    }
    if (list.items.len != x.params.len) return refuse(a, why, "`{s}` takes {d} argument{s}", .{ x.name, x.params.len, if (x.params.len == 1) "" else "s" });
    return list.items;
}

// `:wait N [CLOCK]`.
fn wait(a: std.mem.Allocator, p: *const Play, text: []const u8, why: *[]const u8) Error!Play.Input {
    var words = std.mem.tokenizeAny(u8, text, " \t");
    const n = words.next() orelse return refuse(a, why, "write :wait N, or :wait N CLOCK", .{});
    const by = std.fmt.parseInt(u64, n, 10) catch return refuse(a, why, "`{s}` is not a number of ticks", .{n});
    if (by == 0) return refuse(a, why, "a clock moves on 1 or more", .{});
    const s = &p.loaded.story;
    if (words.next()) |name| {
        const f = s.factNamed(name) orelse return refuse(a, why, "the story has no clock called `{s}`", .{name});
        if (s.fact(f).role != .clock) return refuse(a, why, "`{s}` is not a clock", .{name});
        return .{ .advance = .{ .clock = f, .by = by } };
    }
    var found: ?facts.FactId = null;
    for (0..s.len(.facts)) |i| {
        const f: facts.FactId = .fromRaw(@intCast(i)); // safe: below max_facts
        if (s.fact(f).role != .clock) continue;
        if (found != null) return refuse(a, why, "the story has more than one clock: :wait {d} CLOCK", .{by});
        found = f;
    }
    return .{ .advance = .{ .clock = found orelse return refuse(a, why, "the story has no clock", .{}), .by = by } };
}

fn factList(a: std.mem.Allocator, p: *const Play, text: []const u8, why: *[]const u8) Error![]const facts.FactId {
    var list: std.ArrayList(facts.FactId) = .empty;
    var words = std.mem.tokenizeAny(u8, text, " \t,");
    while (words.next()) |name| try list.append(a, p.loaded.story.factNamed(name) orelse return refuse(a, why, "the story has no fact called `{s}`", .{name}));
    return list.items;
}

/// A value of `shape` as a player writes it: `true`, `-3`, a value of its list, a set's values separated by commas
/// (none for none), a thing's id, words in quotes.
pub fn value(a: std.mem.Allocator, p: *const Play, text: []const u8, shape: transcript.Shape, why: *[]const u8) Error!facts.Value {
    const s = &p.loaded.story;
    switch (shape.kind) {
        .boolean => {
            if (eql(text, "true")) return .{ .boolean = true };
            if (eql(text, "false")) return .{ .boolean = false };
            return refuse(a, why, "true or false, not `{s}`", .{text});
        },
        .int => return .{ .int = std.fmt.parseInt(i64, text, 10) catch return refuse(a, why, "a number, not `{s}`", .{text}) },
        .one_of => return .{ .one_of = if (eql(text, "none")) facts.Value.none else try item(a, s, shape.enumeration.?, text, why) },
        .set_of => {
            var items: facts.Set = .empty;
            if (eql(text, "none") or text.len == 0) return .{ .set_of = items };
            var it = std.mem.splitScalar(u8, text, ',');
            while (it.next()) |w| items.set(try item(a, s, shape.enumeration.?, std.mem.trim(u8, w, " "), why));
            return .{ .set_of = items };
        },
        .text => {
            if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') return .{ .text = try a.dupe(u8, text[1 .. text.len - 1]) };
            return refuse(a, why, "words are written in quotes: \"{s}\"", .{text});
        },
        .ref => {
            if (eql(text, "none")) return .{ .ref = facts.Value.no_ref };
            const kind = if (shape.ref_kind) |k| s.refKind(k) else "";
            return .{ .ref = p.thingNamed(kind, text) orelse return refuse(a, why, "there is no {s} called `{s}`", .{ kind, text }) };
        },
    }
}

fn item(a: std.mem.Allocator, s: *const story.Story, e: story.EnumId, name: []const u8, why: *[]const u8) Error!u16 {
    const r = s.items(e);
    for (0..r.len) |k| if (eql(s.item(r.start + @as(u32, @intCast(k))), name)) return @intCast(k); // safe: below max_items
    var list: std.ArrayList(u8) = .empty;
    for (0..r.len) |k| {
        if (k > 0) try list.appendSlice(a, ", ");
        try list.appendSlice(a, s.item(r.start + @as(u32, @intCast(k)))); // safe: below a u32 length
    }
    return refuse(a, why, "`{s}` is not one of {s}", .{ name, list.items });
}

// `name` or `name(inner)`.
fn splitCall(text: []const u8) ?struct { []const u8, ?[]const u8 } {
    const open = std.mem.findScalar(u8, text, '(') orelse return if (isName(text)) .{ text, null } else null;
    if (text[text.len - 1] != ')') return null;
    const name = std.mem.trim(u8, text[0..open], " ");
    if (!isName(name)) return null;
    return .{ name, text[open + 1 .. text.len - 1] };
}

fn isName(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) return false;
    return true;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn refuse(a: std.mem.Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    why.* = try a.print(fmt, args);
    return error.Refused;
}

/// One row of a script: its words, and where it is written, for a refusal to be placed (a path and a line), or
/// none for an input given on the command line.
pub const Row = struct { text: []const u8, path: ?[]const u8 = null, line: u32 = 0 };

/// How a scripted play ended.
pub const Ending = enum {
    /// The story came to its end.
    ended,
    /// The story waits for an input the script did not give.
    waiting,
    /// The story stopped on a run-time error.
    stopped,
    /// A row of the script could not be taken: it is reported where it is written.
    refused,
};

/// Everything the play tells until it waits, written.
pub fn tellAll(w: *std.Io.Writer, t: *const transcript.Transcript, p: *Play) (std.Io.Writer.Error || error{OutOfMemory})!void {
    while (try p.next()) |e| try t.event(w, e);
}

/// What a row did.
pub const Took = union(enum) {
    /// Taken, or nothing to take: what it told is written.
    taken,
    /// `:quit`.
    quit,
    /// Not taken, and why.
    refused: []const u8,
};

/// One row typed or read: echoed when `echo`, read against the play and taken, and what it told written. `a`
/// holds what the row reads to and a refusal's words.
pub fn one(a: std.mem.Allocator, w: *std.Io.Writer, t: *const transcript.Transcript, p: *Play, text: []const u8, echo: bool) (std.Io.Writer.Error || error{OutOfMemory})!Took {
    var why: []const u8 = "";
    const command = (read(a, p, text, &why) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return .{ .refused = why },
    }) orelse return .taken;
    if (echo) try t.echo(w, std.mem.trim(u8, text, " \t\r"));
    switch (command) {
        .input => |input| p.give(input) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Refused => return .{ .refused = try a.dupe(u8, p.refusal) },
        },
        .facts => |names| try t.factsNow(w, names),
        .back => if (!try p.back()) return .{ .refused = "there is nothing to go back to" },
        .restart => try p.restart(),
        .quit => return .quit,
        .help => try w.writeAll(help),
    }
    try tellAll(w, t, p);
    return .taken;
}

/// A play driven by `rows` from its start, its transcript written to `w`: each row echoed after what was told
/// before it, read and taken, until the rows run out, a `:quit`, or a row that cannot be taken, which is reported
/// where it is written. How it ended.
pub fn run(gpa: std.mem.Allocator, w: *std.Io.Writer, t: *const transcript.Transcript, p: *Play, rows: []const Row) (std.Io.Writer.Error || error{OutOfMemory})!Ending {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try tellAll(w, t, p);
    for (rows) |r| {
        _ = arena.reset(.retain_capacity);
        switch (try one(arena.allocator(), w, t, p, r.text, true)) {
            .taken => {},
            .quit => break,
            .refused => |why| return refused(w, p, r, why),
        }
    }
    return endingOf(p);
}

/// How the play stands, as a script's ending.
pub fn endingOf(p: *const Play) Ending {
    return switch (p.waitingFor() orelse .stopped) {
        .end => .ended,
        .choice, .outcome => .waiting,
        .stopped => .stopped,
    };
}

// A row that could not be taken, placed where it is written; once the story stopped, the run-time error is how it
// ended.
fn refused(w: *std.Io.Writer, p: *const Play, r: Row, why: []const u8) std.Io.Writer.Error!Ending {
    if (p.waitingFor() == .stopped) return .stopped;
    const text = std.mem.trimEnd(u8, r.text, " \t\r");
    if (r.path) |path| {
        try w.print("{s}:{d}:1-{d}:{d}: error: {s}\n", .{ path, r.line, r.line, text.len + 1, why });
    } else try w.print("riverrun: error: the input `{s}`: {s}\n", .{ text, why });
    return .refused;
}
