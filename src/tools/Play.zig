//! A story played as its game would play it, with the player in the game's
//! place: the one session `riverrun play` drives in a terminal, a script of
//! inputs drives for tests and for an AI writing a story, and the editor's
//! play button will drive.
//!
//! It is the runtime over a loaded story (`walk.Loaded`), the same session a
//! game holds, its rules fired over the facts (`react.Rules`) and each
//! package's runtime run beside it (`river.Running`: cairn's quests, tide's
//! time), and it gives, in order, what a game is given: a section's heading
//! as the flow comes to it, a line with its speaker, delivery, tags and
//! effects, an effects step, the choices on offer (the closed ones marked),
//! an action whose outcome the game decides, every query the story asked and
//! what it was answered, a rule that fired, what a package's runtime did,
//! and the end (`next`). It takes what a game gives back (`give`): a choice,
//! an outcome, a fact set or a query's answer, a clock moved, and a call
//! the game makes into a package, which the package offers as a command
//! (`commands`: cairn's `start` of a quest with its roles).
//!
//! The game's side, with no game: what the game keeps, its `(game)` facts,
//! its queries' answers and its clocks, is the player's to set, stands until
//! changed, and is shown wherever the story reads it (a query asked is told
//! with its answer, the type's first value until the player sets one); what
//! the game decides at a moment, a choice or an action's outcome, is waited
//! for, so the terminal asks the player then, a script gives the next of its
//! inputs, and the editor shows the question. A line's effects are applied
//! when the line is delivered: when the next thing is asked for, after the
//! line was shown. A section ending with a tag the vocabulary says leads on
//! goes on to the section it names, as the game's mechanic would.
//!
//! Every input given is kept, and the session is deterministic, so going
//! back is playing again from the start with the inputs but the last
//! (`back`), and a session can be told again from its inputs alone.

const std = @import("std");
const runtime = @import("riverrun");
const river = @import("riverrun-compiler");
const walk = @import("walk.zig");

const Play = @This();
const story = runtime.story;
const facts = runtime.facts;
const run = runtime.run;
const react = runtime.react;
const Running = river.Running;

pub const Options = struct {
    /// Where the flow starts: the host's first entry, or a section the player names.
    start: story.SectionId,
    /// The tag keys the vocabulary says lead on into the game's mechanic: a section the flow runs out of, or
    /// ends in, with one of them naming a section, goes on there.
    leads: []const []const u8 = &.{},
    /// The key a line's delivery fills (`DAD (quietly):`), so the front shows it in its parentheses.
    delivery: ?[]const u8 = null,
    /// The packages' runtimes, as the vocabulary joined them.
    running: []const Running = &.{},
    /// The most steps between two inputs: a story that says something forever without waiting for the player
    /// stops there, named. Null for the story's own count of steps and `round` more: a story that never comes back
    /// to a step it told is never stopped, however long, and one that goes round is stopped once it went round
    /// `round` times more than it has steps.
    steps: ?u32 = null,
    /// The language plurals and genders are worded in.
    language: run.Language = .{},
};

/// The most arguments a package's command takes.
pub const max_params = 32;

/// Steps past the story's own count that a stretch with nothing waited for may take: going round.
pub const round = 10_000;

/// What the player is waited for.
pub const Waiting = enum {
    /// One of the choices offered.
    choice,
    /// The outcome of the action asked about.
    outcome,
    /// The story has ended: only going back, starting again, a fact set or a clock moved.
    end,
    /// The story stopped on a named error: only going back or starting again.
    stopped,
};

/// What the play stopped on: a named error of the runtime's, the store's, the rules' or a package's.
pub const Failure = run.Error || facts.SetError || react.Rules.Error || error{
    /// More steps than `Options.steps` with nothing waited for.
    Endless,
    /// A package's runtime stopped, saying why.
    Stopped,
};

/// A choice as offered: its number, the one a player types, its words, and whether it can be taken.
pub const Choice = struct {
    number: usize,
    text: []const u8,
    open: bool,
    tags: story.Range,
    id: story.LineId,
};

/// A query the story asked, and what it was answered: `given` when the player set that answer.
pub const Asked = struct {
    query: facts.ExternId,
    args: []const facts.Value,
    answer: facts.Value,
    given: bool,
};

pub const Event = union(enum) {
    /// The flow came to a section, or to a part of one, other than the one it was in.
    section: struct { section: story.SectionId, part: ?story.SectionId },
    /// A line, its effects applied once it is delivered: when the next event is asked for.
    line: run.Line,
    /// The choices offered, closed ones among them; the play waits for one.
    choices: []const Choice,
    /// Effects reached on their own, applied as they are told; the actions among them told to the game.
    effects: []const facts.Effect,
    /// An action whose outcome the game decides; the play waits for it.
    asks: facts.Call,
    asked: Asked,
    /// A rule that fired, and what it did.
    rule: struct { section: story.SectionId, name: []const u8, effects: []const facts.Effect },
    /// What a package's runtime did, and the queries it asked while it worked that out, told as part of it.
    news: struct { package: []const u8, news: Running.News, asked: []const Asked = &.{} },
    /// The flow came to its end, and nothing leads on.
    end,
    /// The story stopped on a named error, where it is written when that is known.
    stopped: Stop,
};

pub const Stop = struct {
    failure: Failure,
    /// What of the story it was met at: the effect, the condition or value, the choice or the step, which the
    /// compiler's `Where` says where it is written; null where it is about nothing written (said in `why`).
    at: ?story.At = null,
    /// A package's words, for `Stopped`; the sections a story went round, for `Endless`.
    why: ?[]const u8 = null,
};

/// The target of `Input.set`: a fact (one kept per thing with its key), or a query's answer for its arguments.
pub const Target = union(enum) {
    fact: struct { fact: facts.FactId, key: ?facts.Key = null },
    answer: struct { query: facts.ExternId, args: []const facts.Value },
};

/// What a game gives back.
pub const Input = union(enum) {
    /// A choice, by the number it was offered with.
    choose: usize,
    /// The outcome of the action asked about.
    outcome: facts.Value,
    /// A fact set, or changed (`+=`, `-=`), or what a query answers from now on.
    set: struct { target: Target, effect: enum { set, add, remove }, value: facts.Value },
    /// A clock fact moved on.
    advance: struct { clock: facts.FactId, by: u64 },
    /// A call the game makes into a package, as the package offers it (`commands`).
    command: Called,
};

/// A package's command given: which (`Offered`, by its place in `commands`), the form, and its arguments in the
/// order of the form's parameters.
pub const Called = struct {
    command: usize,
    form: usize,
    args: []const Arg,
};

/// An argument of a command: a value, or a thing by the name the player gave it, which is the story's thing of
/// that name, or a stand-in for one of the game's, made under that name where there is none.
pub const Arg = union(enum) {
    value: facts.Value,
    thing: []const u8,
};

/// A package's command, as the play offers it: whose, what it is and does, and what it applies to in this story,
/// each with its parameters.
pub const Offered = struct {
    /// The package's place in `Options.running`.
    package: usize,
    command: *const Running.Command,
    forms: []const Running.Form,
};

/// Why an input was not taken: its words, for the player, in `Play.refusal`.
pub const GiveError = error{ OutOfMemory, Refused };

gpa: std.mem.Allocator,
loaded: *walk.Loaded,
options: Options,
session: run.Session = undefined,
rules: react.Rules = undefined,
/// Each package's runtime state, by `options.running`; null where the story has nothing of it.
states: []?*anyopaque,
owners: [facts.max_scopes]u64 = @splat(0),
/// Whether `session` and `rules` hold a game now.
begun: bool = false,

/// What the game has set, and how far its clocks have run, when the story starts: applied at every start.
given: []const Input = &.{},
given_arena: std.heap.ArenaAllocator,
/// Every input taken, in order, with what they hold.
log: std.ArrayList(Input) = .empty,
log_arena: std.heap.ArenaAllocator,
/// What the events of the inputs since the last hold.
events_arena: std.heap.ArenaAllocator,
queue: std.ArrayList(Event) = .empty,
/// The first event of `queue` not yet given.
head: usize = 0,
/// Queries asked since they were last queued, and every one queued since the last input, so each is told once.
asked: std.ArrayList(Asked) = .empty,
told_asks: std.ArrayList(Asked) = .empty,
/// What the player said queries answer.
answers: std.ArrayList(Asked) = .empty,
/// Things standing in for the game's, by the names they were given.
stand_ins: std.ArrayList(struct { kind: []const u8, name: []const u8, handle: u64 }) = .empty,
/// The packages' commands, as the story being played gives their forms.
offered: std.ArrayList(Offered) = .empty,
offered_arena: std.heap.ArenaAllocator,

/// The line told and not yet delivered.
hand: ?run.Line = null,
/// The outcomes owed, in order: the calls asked about, whether the flow owes each (else a rule or a package
/// does, and the outcome is written into its fact here), and how many are given.
owed: std.ArrayList(Owed) = .empty,
owed_given: usize = 0,
waiting: ?Waiting = null,
/// The choices offered, while they wait.
choosing: []const Choice = &.{},
/// Where the flow is, as its last heading said.
section: ?story.SectionId = null,
part: ?story.SectionId = null,
/// Sections a package said the game tells now (a scheduled scene come due), in order.
due: std.ArrayList(story.SectionId) = .empty,
/// Steps taken since the last input, and the sections their lines were told in, with how often.
steps: u32 = 0,
stretch: std.ArrayList(struct { section: story.SectionId, lines: u32 }) = .empty,
/// Rounds the rules and packages fired since the flow last moved or the player last gave anything but an outcome
/// a rule or a package owes: rules that keep asking the game an outcome that sets them off again go round once per
/// outcome, and are stopped as rules that keep setting each other off are.
rounds: u32 = 0,
/// Why the last input was refused.
refusal: []const u8 = "",
refusal_arena: std.heap.ArenaAllocator,
/// A package's words for why it stopped the play.
stopping_why: ?[]const u8 = null,
/// What of the story a named error met now is about, where the site that met it says (an effect being applied,
/// a rule's condition, a package's); else the flow's (`run.Session.metAt`) while `blame` is `cursor`, and nothing
/// while it is `nowhere` (a rule's or a package's error that says none).
met: ?story.At = null,
blame: enum { cursor, nowhere } = .cursor,
/// Replaying the inputs kept: what is told is not queued.
quiet: bool = false,
/// A query's answer could not be told for want of memory: said at the next step.
out_of_memory: bool = false,

const flow: run.FlowId = .fromRaw(0);

const Owed = struct { call: facts.Call, flow: bool };

/// Where the game starts the story: the first of the entries the checker found (the host's, or else each section
/// nothing leads to) that is not a package's to run, as the story was compiled.
pub fn entry(checked: *const river.check.Checked, s: *const story.Story) ?story.SectionId {
    for (checked.entries) |id| {
        const section = checked.sections[id.raw()];
        if (section.kind == .other) continue;
        const module = checked.modules[section.module.raw()];
        for (0..s.len(.sections)) |i| {
            const sid: story.SectionId = .fromRaw(@intCast(i)); // safe: below a u32 count
            if (qualifiedIs(s.section(sid).name, module, section.name)) return sid;
        }
    }
    return null;
}

fn qualifiedIs(compiled: []const u8, module: []const u8, name: []const u8) bool {
    if (module.len == 0) return std.mem.eql(u8, compiled, name);
    return compiled.len == module.len + 1 + name.len and std.mem.startsWith(u8, compiled, module) and
        compiled[module.len] == '.' and std.mem.endsWith(u8, compiled, name);
}

/// The keys a vocabulary's schema says lead on into the game's mechanic, for `Options.leads`.
pub fn leadsOf(a: std.mem.Allocator, options: river.check.Options) error{OutOfMemory}![]const []const u8 {
    const schema = options.schema orelse return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    for (schema.keys) |k| if (k.leads) try list.append(a, k.name);
    return list.items;
}

/// A play of `loaded`, which stays where it is and outlives it, begun at `options.start`; `next` gives what the
/// game is given first.
pub fn init(p: *Play, gpa: std.mem.Allocator, loaded: *walk.Loaded, options: Options) error{OutOfMemory}!void {
    p.* = .{
        .gpa = gpa,
        .loaded = loaded,
        .options = options,
        .states = try gpa.alloc(?*anyopaque, options.running.len),
        .log_arena = .init(gpa),
        .given_arena = .init(gpa),
        .events_arena = .init(gpa),
        .refusal_arena = .init(gpa),
        .offered_arena = .init(gpa),
    };
    @memset(p.states, null);
    loaded.answers = .{ .ctx = p, .answer = answer };
    p.begin() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => unreachable, // unreachable: nothing is given at the first start
    };
}

pub fn deinit(p: *Play) void {
    p.end();
    p.loaded.answers = .{};
    const gpa = p.gpa;
    gpa.free(p.states);
    p.log.deinit(gpa);
    p.log_arena.deinit();
    p.given_arena.deinit();
    p.events_arena.deinit();
    p.refusal_arena.deinit();
    p.offered_arena.deinit();
    p.queue.deinit(gpa);
    p.asked.deinit(gpa);
    p.told_asks.deinit(gpa);
    p.answers.deinit(gpa);
    p.stand_ins.deinit(gpa);
    p.offered.deinit(gpa);
    p.owed.deinit(gpa);
    p.due.deinit(gpa);
    p.stretch.deinit(gpa);
    p.* = undefined;
}

/// The next thing the game is given, in order; null while the play waits for the player (`waitingFor`). What it
/// returns is valid until the next input.
pub fn next(p: *Play) error{OutOfMemory}!?Event {
    while (p.head == p.queue.items.len) {
        if (p.waiting != null) return null;
        p.advance() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |failure| try p.stopAt(failure),
        };
    }
    const e = p.queue.items[p.head];
    p.head += 1;
    return e;
}

/// What the play waits for, once `next` returned null.
pub fn waitingFor(p: *const Play) ?Waiting {
    return if (p.head == p.queue.items.len) p.waiting else null;
}

/// The choices waiting, while a choice is waited for.
pub fn choices(p: *const Play) []const Choice {
    return if (p.waiting == .choice) p.choosing else &.{};
}

/// The action whose outcome is waited for.
pub fn asking(p: *const Play) ?facts.Call {
    return if (p.waiting == .outcome) p.owed.items[p.owed_given].call else null;
}

/// The packages' commands the story being played offers, each with what it applies to and its parameters: what
/// `:help` lists, a script's row is read against, and the editor draws a control for.
pub fn commands(p: *const Play) []const Offered {
    return p.offered.items;
}

/// The inputs taken so far, in order.
pub fn inputs(p: *const Play) []const Input {
    return p.log.items;
}

/// Takes what the game gives back, once `next` returned null; refused, with `refusal` saying why, where it does not
/// fit what is waited for (a choice that is not offered or is closed, an outcome of the wrong kind, a fact or a
/// clock that is not the player's to move, a command its package refuses, anything once the story stopped).
pub fn give(p: *Play, input: Input) GiveError!void {
    try p.take(input);
    try p.log.append(p.gpa, try p.keep(input));
}

/// Starts again from the start with `inputs` (facts set, queries answered, clocks moved, packages' commands) as
/// what the game has done when the story starts: applied before the flow begins, at this start and every one after
/// (`restart`, `back`). Refused, with `refusal` saying why, where one is a choice or an outcome, or is refused as an
/// input would be; then none is kept.
pub fn startWith(p: *Play, inputs_: []const Input) GiveError!void {
    _ = p.given_arena.reset(.retain_capacity);
    const kept = try p.given_arena.allocator().alloc(Input, inputs_.len);
    for (kept, inputs_) |*k, i| {
        if (i == .choose or i == .outcome) return p.refuse("the story starts with facts set, clocks moved and packages' commands, and nothing else", .{});
        k.* = try keepIn(p.given_arena.allocator(), i);
    }
    p.given = kept;
    p.log.clearRetainingCapacity();
    p.end();
    p.clearEvents();
    p.answers.clearRetainingCapacity();
    p.owed.clearRetainingCapacity();
    p.begin() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => {
            p.given = &.{};
            const why = p.refusal;
            try p.restart();
            p.refusal = why;
            return error.Refused;
        },
    };
}

/// Back one input: the play as it was before the last input was given, played again from the start with the
/// inputs before it, and what was told after the input before it told again. False when no input was given.
pub fn back(p: *Play) error{OutOfMemory}!bool {
    if (p.log.items.len == 0) return false;
    p.log.items.len -= 1;
    try p.replay();
    return true;
}

/// From the start again, every input forgotten.
pub fn restart(p: *Play) error{OutOfMemory}!void {
    p.log.clearRetainingCapacity();
    p.end();
    p.answers.clearRetainingCapacity();
    p.stand_ins.clearRetainingCapacity();
    p.owed.clearRetainingCapacity();
    _ = p.log_arena.reset(.retain_capacity);
    try p.replay();
}

// ---------------------------------------------------------------- the game's start and end

fn begin(p: *Play) GiveError!void {
    const l = p.loaded;
    try l.fresh();
    p.waiting = null;
    p.hand = null;
    p.owed.clearRetainingCapacity();
    p.owed_given = 0;
    p.choosing = &.{};
    p.section = null;
    p.part = null;
    p.due.clearRetainingCapacity();
    p.steps = 0;
    p.rounds = 0;
    p.stretch.clearRetainingCapacity();
    p.stopping_why = null;
    p.met = null;
    p.blame = .cursor;
    p.offered.clearRetainingCapacity();
    _ = p.offered_arena.reset(.retain_capacity);
    p.session = run.Session.init(p.gpa, &l.story, &l.strings, l.memory.store(), &l.host, .{ .builtins = p.builtins(), .language = p.options.language }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.HostNotBound => unreachable, // unreachable: a loaded story's host is bound to it
    };
    p.rules = react.Rules.init(p.gpa, &l.story, l.memory.store(), &l.host, &p.owners, .{ .builtins = p.builtins() }) catch |e| {
        p.session.deinit();
        if (e == error.OutOfMemory) return error.OutOfMemory;
        // a rule's condition the watch could not file: nothing of the game is told
        try p.push(.{ .stopped = .{ .failure = e } });
        p.waiting = .stopped;
        return;
    };
    p.begun = true;
    p.starting() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return error.Refused,
        else => |failure| try p.stopAt(failure),
    };
}

// What the game has done when the story starts, and what that set off.
fn startingWith(p: *Play) GiveError!void {
    for (p.given) |input| {
        switch (input) {
            .set => |s| try p.setting(s.target, s.effect, s.value),
            .advance => |m| try p.moving(m.clock, m.by),
            .command => |c| try p.calling(c),
            .choose, .outcome => unreachable, // unreachable: `startWith` keeps neither
        }
        if (p.waiting == .stopped) return;
    }
}

// The game's first moments: its rules told it is a new game, each package's runtime started and its commands
// offered, the flow begun at its start, and what holds at the start reacted to.
fn starting(p: *Play) (Failure || error{Refused})!void {
    try p.rules.start();
    for (p.options.running, p.states) |r, *state| {
        try p.flush();
        var told: Running.Told = .{ .arena = p.events_arena.allocator(), .queries = &p.asked.items.len };
        state.* = r.start(p.gpa, p.game(), &told) catch |e| {
            try p.tell(r.name, &told);
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.Stopped => p.stopped(told.stopped, told.at),
            };
        };
        try p.tell(r.name, &told);
    }
    try p.offer();
    try p.startingWith();
    if (p.waiting == .stopped) return;
    try p.session.start(flow, p.options.start);
    try p.heading(p.options.start, null);
    try p.flush();
    try p.settle();
}

// The packages' commands, with what each applies to in this story.
fn offer(p: *Play) error{OutOfMemory}!void {
    const a = p.offered_arena.allocator();
    for (p.options.running, p.states, 0..) |r, state, i| {
        const st = state orelse continue;
        for (r.commands) |*c| try p.offered.append(p.gpa, .{ .package = i, .command = c, .forms = try c.forms(st, a) });
    }
}

fn end(p: *Play) void {
    if (!p.begun) return;
    for (p.options.running, p.states) |r, *state| if (state.*) |st| {
        r.stop(p.gpa, st);
        state.* = null;
    };
    p.rules.deinit();
    p.session.deinit();
    p.begun = false;
}

// From the start again, with the inputs kept: those but the last told quietly, what the last one told and after
// told again.
fn replay(p: *Play) error{OutOfMemory}!void {
    p.end();
    p.clearEvents();
    p.answers.clearRetainingCapacity();
    p.owed.clearRetainingCapacity();
    const log = p.log.items;
    p.quiet = log.len > 0;
    p.begin() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => unreachable, // unreachable: what the story starts with was taken at the start before
    };
    for (log, 0..) |input, i| {
        while (try p.next()) |_| {}
        if (i + 1 == log.len) {
            p.quiet = false;
            p.clearEvents();
        }
        // what was taken once is taken again: the play is the same until it
        p.take(input) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Refused => unreachable, // unreachable: the play is deterministic, and took this input before
        };
    }
    p.quiet = false;
}

fn clearEvents(p: *Play) void {
    p.queue.clearRetainingCapacity();
    p.head = 0;
    p.asked.clearRetainingCapacity();
    p.told_asks.clearRetainingCapacity();
    _ = p.events_arena.reset(.retain_capacity);
}

// ---------------------------------------------------------------- telling

// One more step of the game's: the line in hand delivered, an outcome or a choice waited for, or the session's next
// step told.
fn advance(p: *Play) Failure!void {
    if (p.hand) |l| {
        p.hand = null;
        try p.deliver(l.effects, .{ .range = try p.session.toldEffects(flow) }, true);
        if (p.waiting != null) return;
        return p.settle();
    }
    p.steps += 1;
    p.rounds = 0;
    const bound = p.options.steps orelse (p.loaded.story.len(.nodes) +| round);
    if (p.steps > bound) return p.endless();
    const step = try p.session.next(flow);
    switch (step) {
        .line => |l| {
            try p.heading(l.section, l.part);
            try p.flush();
            try p.push(.{ .line = l });
            try p.counted(l.part orelse l.section);
            p.hand = l;
        },
        .choices => |list| {
            if (try p.session.cursor(flow)) |at| if (p.session.places.where(&p.loaded.story, at)) |w| try p.heading(w.section, w.part);
            try p.flush();
            const offered = try p.events_arena.allocator().alloc(Choice, list.len);
            for (offered, list, 1..) |*o, c, n| o.* = .{ .number = n, .text = c.text, .open = c.open, .tags = c.tags, .id = c.id };
            p.choosing = offered;
            try p.push(.{ .choices = offered });
            p.waiting = .choice;
        },
        .effects => |list| {
            try p.flush();
            try p.push(.{ .effects = list });
            try p.deliver(list, .{ .range = try p.session.toldEffects(flow) }, true);
            if (p.waiting == null) try p.settle();
        },
        .action => |a| {
            try p.flush();
            try p.owe(a.call, true);
        },
        .end => {
            try p.flush();
            if (try p.leadsTo()) |to| {
                try p.session.start(flow, to);
                try p.heading(to, null);
                return p.flush();
            }
            try p.push(.end);
            p.waiting = .end;
        },
    }
}

// A line told in the stretch since the last input, counted under where it is written.
fn counted(p: *Play, section: story.SectionId) error{OutOfMemory}!void {
    for (p.stretch.items) |*s| if (s.section.eql(section)) {
        s.lines += 1;
        return;
    };
    try p.stretch.append(p.gpa, .{ .section = section, .lines = 1 });
}

// A story that went round without waiting for the player: stopped, with the sections it kept coming back to.
fn endless(p: *Play) Failure {
    const a = p.events_arena.allocator();
    var words: std.ArrayList(u8) = .empty;
    for (p.stretch.items) |s| {
        if (s.lines < 2) continue;
        try words.appendSlice(a, if (words.items.len == 0) "it keeps coming back to " else ", ");
        try words.print(a, "`{s}`", .{p.loaded.story.section(s.section).name});
    }
    p.stopping_why = if (words.items.len > 0) words.items else null;
    return error.Endless;
}

/// Where the effects a step or a package emitted are written, in order.
const Written = union(enum) {
    /// A range of the story's effects: a line's, an effects step's, a rule's.
    range: story.Range,
    /// Each one's place among the story's effects: a package's.
    list: []const u32,

    fn at(w: Written, k: usize) ?story.At {
        return switch (w) {
            .range => |r| if (k < r.len) .{ .effect = r.start + @as(u32, @intCast(k)) } else null, // safe: below a u32 length
            .list => |l| if (k < l.len) .{ .effect = l[k] } else null,
        };
    }
};

// Effects the game is given: each applied to the facts, an action told, and an action with an outcome owed, asked
// about in order; `flow` when the flow emitted them and owes those outcomes. An error applying one is that effect's.
fn deliver(p: *Play, list: []const facts.Effect, written: Written, from_flow: bool) Failure!void {
    const store = p.loaded.memory.store();
    for (list, 0..) |e, k| {
        if (e == .call) {
            if (e.call.result != null) try p.owe(e.call, from_flow);
            continue;
        }
        _ = facts.apply(store, e) catch |err| {
            p.met = written.at(k);
            return err;
        };
    }
}

fn owe(p: *Play, call: facts.Call, from_flow: bool) Failure!void {
    if (p.owed_given == p.owed.items.len) {
        p.owed.clearRetainingCapacity();
        p.owed_given = 0;
    }
    const kept = (try (facts.Effect{ .call = call }).dupe(p.log_arena.allocator())).call;
    try p.owed.append(p.gpa, .{ .call = kept, .flow = from_flow });
    if (p.owed.items.len == p.owed_given + 1) try p.push(.{ .asks = kept });
    p.waiting = .outcome;
}

// What the facts' change set off, to a fixed point: the rules that fired, what each package's runtime did, each
// one's effects applied; then the sections that came due told.
fn settle(p: *Play) Failure!void {
    // a rule's or a package's error is not where the flow is: it says where it is, or is about nothing written
    p.blame = .nowhere;
    try p.settleRounds();
    p.blame = .cursor;
    try p.tellDue();
}

fn settleRounds(p: *Play) Failure!void {
    while (true) : (p.rounds += 1) {
        const rounds = p.rounds;
        var moved = false;
        const fired = p.rules.step() catch |e| {
            p.met = p.rules.metAt();
            return e;
        };
        try p.flush();
        if (rounds == react.max_rounds and fired.len > 0) return p.keptFiring(fired);
        for (fired) |f| {
            moved = true;
            const a = p.events_arena.allocator();
            const effects = try a.alloc(facts.Effect, f.effects.len);
            for (effects, f.effects) |*to, from| to.* = try from.dupe(a);
            try p.push(.{ .rule = .{ .section = f.section, .name = try a.dupe(u8, f.name), .effects = effects } });
            try p.deliver(effects, .{ .range = f.written }, false);
        }
        for (p.options.running, p.states) |r, state| {
            const st = state orelse continue;
            const step = r.step orelse continue;
            try p.flush();
            var told: Running.Told = .{ .arena = p.events_arena.allocator(), .queries = &p.asked.items.len };
            step(st, &told) catch |e| {
                try p.tell(r.name, &told);
                return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.Stopped => p.stopped(told.stopped, told.at),
                };
            };
            moved = moved or told.news.items.len > 0;
            if (rounds == react.max_rounds and moved) {
                p.stopping_why = try p.events_arena.allocator().print("`{s}` still said what happened", .{r.name});
                return error.NoFixedPoint;
            }
            try p.tell(r.name, &told);
        }
        if (!moved) break;
    }
}

// Rules that kept firing each other: stopped at the condition of the first still firing, the rest named.
fn keptFiring(p: *Play, fired: []const react.Rules.Fired) Failure {
    const s = &p.loaded.story;
    const a = p.events_arena.allocator();
    var words: std.ArrayList(u8) = .empty;
    for (fired) |f| try words.print(a, "{s}`{s}.{s}`", .{ if (words.items.len == 0) "still firing: " else ", ", s.section(f.section).name, f.name });
    p.stopping_why = words.items;
    p.met = .{ .terms = s.candidate(fired[0].rule).when };
    return error.NoFixedPoint;
}

// News a package's runtime gave: queued, each with the queries the package asked while it worked it out (those
// asked before it was said, since the news before it), its effects applied, a section it says comes due kept to
// tell. The queries asked before the package was called were told then (`flush`).
fn tell(p: *Play, package: []const u8, told: *const Running.Told) Failure!void {
    const asked = p.asked.items;
    const a = p.events_arena.allocator();
    var from: usize = 0;
    const n = told.news.items.len;
    for (told.news.items, told.asked.items, 0..) |item, mark, j| {
        const to = if (j + 1 == n) asked.len else @max(from, @min(mark, asked.len));
        var own: std.ArrayList(Asked) = .empty;
        for (asked[from..to]) |q| {
            if (find(p.told_asks.items, q.query, q.args) != null) continue;
            try p.told_asks.append(p.gpa, q);
            try own.append(a, q);
        }
        from = to;
        try p.push(.{ .news = .{ .package = package, .news = item, .asked = own.items } });
        try p.deliver(item.effects, .{ .list = item.written }, false);
        if (item.section) |s| try p.due.append(p.gpa, s);
    }
    // with no news, what it asked is told at the next row, as any query is
    if (n > 0) p.asked.clearRetainingCapacity();
}

// The sections that came due, told as the game tells a scene that comes up: into the flow as an interruption, which
// goes back to where the flow was, the first due told first; started anew where the flow has ended.
fn tellDue(p: *Play) Failure!void {
    if (p.due.items.len == 0 or p.waiting == .outcome or p.waiting == .stopped) return;
    var i = p.due.items.len;
    if (p.waiting == .end) {
        // the last is started, and each before it interrupts it, so the first is told first
        i -= 1;
        try p.session.start(flow, p.due.items[i]);
        p.waiting = null;
        while (i > 0) : (i -= 1) try p.session.interrupt(flow, p.due.items[i - 1]);
    } else {
        while (i > 0) : (i -= 1) try p.session.interrupt(flow, p.due.items[i - 1]);
        p.waiting = null;
        p.choosing = &.{};
    }
    p.due.clearRetainingCapacity();
}

// The section a tag that leads on names, on the section the flow ended in.
fn leadsTo(p: *Play) Failure!?story.SectionId {
    const s = &p.loaded.story;
    const where = p.part orelse p.section orelse return null;
    for ([_]?story.SectionId{ where, p.section }) |maybe| {
        const id = maybe orelse continue;
        const tags = s.section(id).tags;
        for (0..tags.len) |k| {
            const t = s.tag(tags.start + @as(u32, @intCast(k))); // safe: below a u32 length
            if (!isLead(p.options.leads, t.key)) continue;
            for (0..t.values.len) |v| if (s.tagValue(t.values.start + @as(u32, @intCast(v))).section) |to| return to; // safe: below a u32 length
        }
    }
    return null;
}

fn isLead(leads: []const []const u8, key: []const u8) bool {
    for (leads) |l| if (std.mem.eql(u8, l, key)) return true;
    return false;
}

fn heading(p: *Play, section: story.SectionId, part: ?story.SectionId) error{OutOfMemory}!void {
    if (p.section != null and p.section.?.eql(section) and eqlPart(p.part, part)) return;
    p.section = section;
    p.part = part;
    try p.push(.{ .section = .{ .section = section, .part = part } });
}

fn eqlPart(a: ?story.SectionId, b: ?story.SectionId) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

fn push(p: *Play, e: Event) error{OutOfMemory}!void {
    if (p.quiet) return;
    try p.queue.append(p.gpa, e);
}

// The queries asked since the last event, each queued once since the last input.
fn flush(p: *Play) error{OutOfMemory}!void {
    if (p.out_of_memory) {
        p.out_of_memory = false;
        return error.OutOfMemory;
    }
    for (p.asked.items) |a| {
        if (find(p.told_asks.items, a.query, a.args) != null) continue;
        try p.told_asks.append(p.gpa, a);
        try p.push(.{ .asked = a });
    }
    p.asked.clearRetainingCapacity();
}

// A package stopped the play: its words, and what of the story it met the error at.
fn stopped(p: *Play, why: ?[]const u8, at: ?story.At) Failure {
    p.stopping_why = why;
    p.met = at;
    return error.Stopped;
}

fn stopAt(p: *Play, failure: Failure) error{OutOfMemory}!void {
    try p.flush();
    const at: ?story.At = p.met orelse switch (p.blame) {
        .cursor => if (p.begun) p.session.metAt(flow) catch null else null,
        .nowhere => null,
    };
    const why = p.stopping_why;
    p.met = null;
    p.stopping_why = null;
    p.blame = .cursor;
    try p.push(.{ .stopped = .{ .failure = failure, .at = at, .why = why } });
    p.waiting = .stopped;
    p.hand = null;
}

// ---------------------------------------------------------------- what the game gives back

fn take(p: *Play, input: Input) GiveError!void {
    const waiting = p.waitingFor() orelse return p.refuse("the story is not waiting for anything yet", .{});
    if (waiting == .stopped) return p.refuse("the story stopped: go back (:back) or start again (:restart)", .{});
    // an outcome a rule or a package owes goes on with the rounds that asked it
    if (!(input == .outcome and waiting == .outcome and !p.owed.items[p.owed_given].flow)) p.rounds = 0;
    switch (input) {
        .choose => |n| {
            if (waiting != .choice) return p.refuse("{s}", .{whatIsWaited(waiting)});
            if (n == 0 or n > p.choosing.len) return p.refuse("there is no choice {d}: {d} {s} offered", .{ n, p.choosing.len, if (p.choosing.len == 1) "is" else "are" });
            if (!p.choosing[n - 1].open) return p.refuse("choice {d} is closed: its condition does not hold", .{n});
            p.fresh();
            p.waiting = null;
            p.choosing = &.{};
            p.session.choose(flow, n - 1) catch |e| return p.failed(e);
        },
        .outcome => |v| {
            if (waiting != .outcome) return p.refuse("{s}", .{whatIsWaited(waiting)});
            const owed = p.owed.items[p.owed_given];
            const r = owed.call.result.?;
            const kind = p.loaded.story.fact(r).kind;
            if (@as(facts.Kind, v) != kind) return p.refuse("`{s}` decides a {s}", .{ p.loaded.story.externFn(owed.call.action).name, kindWord(kind) });
            if (p.loaded.story.fact(r).bounds) |bounds| if (!bounds.holds(v.int)) return p.refuse("`{s}` holds from {d} to {d}", .{ p.loaded.story.fact(r).name, bounds.min, bounds.max });
            p.fresh();
            if (owed.flow) {
                p.session.outcome(flow, v) catch |e| return p.failed(e);
            } else p.loaded.memory.store().set(r, v) catch |e| return p.failed(e);
            p.owed_given += 1;
            if (p.owed_given < p.owed.items.len) {
                try p.push(.{ .asks = p.owed.items[p.owed_given].call });
                return;
            }
            p.waiting = null;
            p.settle() catch |e| return p.failed(e);
        },
        .set => |s| {
            try p.setting(s.target, s.effect, s.value);
            if (p.waiting == .stopped) return;
            p.settle() catch |e| return p.failed(e);
            try p.again(waiting);
        },
        .advance => |m| {
            if (waiting == .outcome) return p.refuse("the game owes `{s}`'s outcome first", .{p.loaded.story.externFn(p.owed.items[p.owed_given].call.action).name});
            try p.moving(m.clock, m.by);
            if (p.waiting == .stopped) return;
            p.settle() catch |e| return p.failed(e);
            try p.again(waiting);
        },
        .command => |c| {
            try p.calling(c);
            if (p.waiting == .stopped) return;
            p.settle() catch |e| return p.failed(e);
            try p.again(waiting);
        },
    }
}

// A new stretch: what the last told is done with.
fn fresh(p: *Play) void {
    p.clearEvents();
    p.steps = 0;
    p.stretch.clearRetainingCapacity();
}

// After the facts moved while the player was waited for: the choices offered again as they now hold, or the
// outcome asked about again.
fn again(p: *Play, was: Waiting) GiveError!void {
    // a section that came due took the flow, and offers again what it offered once it is back
    if (p.waiting != was) return;
    switch (was) {
        .choice => {
            p.session.offerAgain(flow) catch |e| return p.failed(e);
            p.waiting = null;
            p.choosing = &.{};
        },
        .outcome => try p.push(.{ .asks = p.owed.items[p.owed_given].call }),
        .end, .stopped => {},
    }
}

fn setting(p: *Play, target: Target, effect: @FieldType(@FieldType(Input, "set"), "effect"), v: facts.Value) GiveError!void {
    const store = p.loaded.memory.store();
    switch (target) {
        .fact => |f| {
            const d = p.loaded.story.fact(f.fact);
            if (d.role == .clock) return p.refuse("`{s}` is a clock, which only moves on: :wait", .{d.name});
            if (p.waiting != null) p.fresh();
            const e: facts.Effect = switch (effect) {
                .set => .{ .set = .{ .fact = f.fact, .key = f.key, .value = v } },
                .add, .remove => blk: {
                    if (d.kind == .int) {
                        const by = if (effect == .add) v.int else std.math.negate(v.int) catch return p.refuse("that is past what an int holds", .{});
                        break :blk .{ .change = .{ .fact = f.fact, .key = f.key, .by = by } };
                    }
                    const item: facts.Effect.Item = .{ .fact = f.fact, .key = f.key, .item = v.one_of };
                    break :blk if (effect == .add) .{ .add = item } else .{ .remove = item };
                },
            };
            _ = facts.apply(store, e) catch |err| return p.refuse("`{s}` cannot hold that ({t})", .{ d.name, err });
        },
        .answer => |a| {
            const x = p.loaded.story.externFn(a.query);
            if (effect != .set) return p.refuse("a query is answered with `=`: `{s}(…) = …`", .{x.name});
            if (p.waiting != null) p.fresh();
            const kept = try p.log_arena.allocator().dupe(facts.Value, a.args);
            for (kept) |*k| k.* = try facts.dupeValue(p.log_arena.allocator(), k.*);
            const given: Asked = .{ .query = a.query, .args = kept, .answer = try facts.dupeValue(p.log_arena.allocator(), v), .given = true };
            if (find(p.answers.items, a.query, a.args)) |i| p.answers.items[i] = given else try p.answers.append(p.gpa, given);
            // what reads the query is woken as a game's bump wakes it
            if (x.stamp) |stamp| {
                var keyed: std.ArrayList(facts.Value) = .empty;
                defer keyed.deinit(p.gpa);
                for (kept, 0..) |arg, i| if (stamp.keys & (@as(u32, 1) << @intCast(i)) != 0) try keyed.append(p.gpa, arg); // safe: below 32 parameters
                p.rules.watch.bump(stamp.family, keyed.items) catch |e| return p.failed(e);
                for (p.options.running, p.states) |r, state| {
                    const bump = r.bump orelse continue;
                    bump(state orelse continue, stamp.family, keyed.items) catch |e| return p.failed(e);
                }
            }
        },
    }
}

fn moving(p: *Play, clock: facts.FactId, by: u64) GiveError!void {
    const d = p.loaded.story.fact(clock);
    if (d.role != .clock) return p.refuse("`{s}` is not a clock: set it with :set", .{d.name});
    if (p.waiting != null) p.fresh();
    for (p.options.running, p.states) |r, state| {
        const move = r.advance orelse continue;
        try p.flush();
        var told: Running.Told = .{ .arena = p.events_arena.allocator(), .queries = &p.asked.items.len };
        const kept = move(state orelse continue, clock, by, &told) catch |e| {
            p.tell(r.name, &told) catch |f| return p.failed(f);
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return p.failed(p.stopped(told.stopped, told.at));
        };
        p.tell(r.name, &told) catch |e| return p.failed(e);
        if (kept) return;
    }
    const store = p.loaded.memory.store();
    const now = store.get(clock).int;
    const to = std.math.add(i64, now, std.math.cast(i64, by) orelse return p.refuse("a clock moves on at most {d}", .{std.math.maxInt(i64)})) catch return p.refuse("`{s}` would pass what an int holds", .{d.name});
    store.set(clock, .{ .int = to }) catch |e| return p.failed(e);
}

// A package's command: its arguments resolved (a thing named, or a stand-in made for one of the game's), then done
// by its package, which says what that did.
fn calling(p: *Play, c: Called) GiveError!void {
    const o = p.offered.items[c.command];
    const form = o.forms[c.form];
    const r = p.options.running[o.package];
    const state = p.states[o.package].?; // a command is offered only while its package runs
    // resolved before the stretch is new, so a refusal changes nothing; held here, as the events' arena is reset
    var buffer: [max_params]facts.Value = undefined;
    if (c.args.len > max_params) return p.refuse("a command takes at most {d} arguments", .{max_params});
    const values = buffer[0..c.args.len];
    for (values, c.args, form.params) |*v, arg, param| v.* = switch (arg) {
        .value => |x| x,
        .thing => |name| .{ .ref = try p.thingFor(param, name) },
    };
    if (p.waiting != null) p.fresh();
    try p.flush();
    var told: Running.Told = .{ .arena = p.events_arena.allocator(), .queries = &p.asked.items.len };
    o.command.run(state, c.form, values, &told) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return p.refuse("{s}", .{told.refused orelse "the package refused it"}),
        error.Stopped => {
            p.tell(r.name, &told) catch |f| return p.failed(f);
            return p.failed(p.stopped(told.stopped, told.at));
        },
    };
    p.tell(r.name, &told) catch |e| return p.failed(e);
}

// The thing a command's parameter names: the story's thing of its kind by that name, a stand-in made before, or a
// new stand-in for one of the game's; refused where the name is a thing of another kind.
fn thingFor(p: *Play, param: Running.Param, name: []const u8) GiveError!u64 {
    const s = &p.loaded.story;
    const kind = if (param.type.ref_kind) |k| s.refKind(k) else "";
    if (p.thingNamed(kind, name)) |h| return h;
    for (0..s.len(.things)) |i| {
        const t = s.thing(@intCast(i)); // safe: below a u32 count
        if (std.mem.eql(u8, t.id, name)) return p.refuse("`{s}` is a thing of the kind `{s}`, and `{s}` takes one of the kind `{s}`", .{ name, t.kind, param.name, kind });
    }
    for (p.stand_ins.items) |t| if (std.mem.eql(u8, t.name, name)) return p.refuse("`{s}` stands in for a thing of the kind `{s}`, and `{s}` takes one of the kind `{s}`", .{ name, t.kind, param.name, kind });
    return standIn(p, kind, name);
}

// A named error while taking an input: the play stops there, as it does while telling; the input was taken.
fn failed(p: *Play, e: Failure) GiveError!void {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    try p.stopAt(e);
}

fn refuse(p: *Play, comptime fmt: []const u8, args: anytype) GiveError {
    _ = p.refusal_arena.reset(.retain_capacity);
    p.refusal = try p.refusal_arena.allocator().print(fmt, args);
    return error.Refused;
}

fn whatIsWaited(w: Waiting) []const u8 {
    return switch (w) {
        .choice => "a choice is waited for: its number",
        .outcome => "an action's outcome is waited for",
        .end => "the story has ended: go back (:back) or start again (:restart)",
        .stopped => "the story stopped: go back (:back) or start again (:restart)",
    };
}

/// A kind of value, as a writer says it.
pub fn kindWord(k: facts.Kind) []const u8 {
    return switch (k) {
        .boolean => "true or false",
        .int => "number",
        .one_of => "value of its list",
        .set_of => "set",
        .text => "text",
        .ref => "thing",
    };
}

// An input as the log keeps it: what it holds copied.
fn keep(p: *Play, input: Input) error{OutOfMemory}!Input {
    return keepIn(p.log_arena.allocator(), input);
}

fn keepIn(a: std.mem.Allocator, input: Input) error{OutOfMemory}!Input {
    var out = input;
    switch (out) {
        .outcome => |*v| v.* = try facts.dupeValue(a, v.*),
        .set => |*s| {
            s.value = try facts.dupeValue(a, s.value);
            if (s.target == .answer) {
                const args = try a.dupe(facts.Value, s.target.answer.args);
                for (args) |*x| x.* = try facts.dupeValue(a, x.*);
                s.target.answer.args = args;
            }
        },
        .command => |*c| {
            const args = try a.dupe(Arg, c.args);
            for (args) |*x| x.* = switch (x.*) {
                .value => |v| .{ .value = try facts.dupeValue(a, v) },
                .thing => |name| .{ .thing = try a.dupe(u8, name) },
            };
            c.args = args;
        },
        .choose, .advance => {},
    }
    return out;
}

// ---------------------------------------------------------------- the game's side

fn game(p: *Play) Running.Game {
    const l = p.loaded;
    return .{ .story = &l.story, .words = &l.strings, .store = l.memory.store(), .host = &l.host, .owners = &p.owners, .stand_in = .{ .ctx = p, .give = standInFor } };
}

fn standInFor(ctx: ?*anyopaque, kind: []const u8, name: []const u8) error{OutOfMemory}!u64 {
    const p: *Play = @ptrCast(@alignCast(ctx.?)); // safe: made by `game`
    return standIn(p, kind, name);
}

// A thing standing in for one of the game's, of `kind`, named so: the same handle for the same kind and name.
fn standIn(p: *Play, kind: []const u8, name: []const u8) error{OutOfMemory}!u64 {
    const h = walk.handle(null, kind, name).?;
    for (p.stand_ins.items) |s| if (s.handle == h) return h;
    const a = p.log_arena.allocator();
    try p.stand_ins.append(p.gpa, .{ .kind = try a.dupe(u8, kind), .name = try a.dupe(u8, name), .handle = h });
    return h;
}
/// The name of a thing of `kind` by its handle: the story's id for it, or the name a stand-in was given.
pub fn thingName(p: *const Play, kind: []const u8, h: u64) ?[]const u8 {
    if (p.loaded.thingName(kind, h)) |n| return n;
    for (p.stand_ins.items) |s| if (s.handle == h and std.mem.eql(u8, s.kind, kind)) return s.name;
    return null;
}

/// The handle of the thing of `kind` named `name`: the story's, or a stand-in's.
pub fn thingNamed(p: *const Play, kind: []const u8, name: []const u8) ?u64 {
    if (p.loaded.thing(kind, name)) |h| return h;
    for (p.stand_ins.items) |s| if (std.mem.eql(u8, s.kind, kind) and std.mem.eql(u8, s.name, name)) return s.handle;
    return null;
}

// A query, answered as the player said, else with its type's first value, and told.
fn answer(ctx: ?*anyopaque, query: facts.ExternId, kind: facts.Kind, args: []const facts.Value) facts.Value {
    const p: *Play = @ptrCast(@alignCast(ctx.?)); // safe: set by `init`
    const given = if (find(p.answers.items, query, args)) |i| p.answers.items[i] else null;
    const value = if (given) |g| g.answer else facts.Value.initial(kind);
    if (p.quiet or find(p.asked.items, query, args) != null) return value;
    // a query is answered whatever happens to the telling of it: memory run out is said at the next step
    p.record(query, args, value, given != null) catch {
        p.out_of_memory = true;
    };
    return value;
}

fn record(p: *Play, query: facts.ExternId, args: []const facts.Value, value: facts.Value, given: bool) error{OutOfMemory}!void {
    const a = p.events_arena.allocator();
    const kept = try a.dupe(facts.Value, args);
    for (kept) |*k| k.* = try facts.dupeValue(a, k.*);
    try p.asked.append(p.gpa, .{ .query = query, .args = kept, .answer = try facts.dupeValue(a, value), .given = given });
}

fn find(list: []const Asked, query: facts.ExternId, args: []const facts.Value) ?usize {
    outer: for (list, 0..) |a, i| {
        if (!a.query.eql(query) or a.args.len != args.len) continue;
        for (a.args, args) |x, y| if (!x.eql(y)) continue :outer;
        return i;
    }
    return null;
}

fn builtins(p: *Play) ?run.Builtins {
    for (p.options.running) |r| if (r.builtins != null) return .{ .user = p, .call = builtin };
    return null;
}

// A builtin, answered by the runtime of the package whose kind registered it.
fn builtin(user: ?*anyopaque, s: *const story.Story, index: u32, cx: run.Context) error{BuiltinFailed}!facts.Value {
    const p: *Play = @ptrCast(@alignCast(user.?)); // safe: set by `builtins`
    const kind = s.builtin(index).kind;
    for (p.options.running, p.states) |r, state| {
        const answers = r.builtins orelse continue;
        for (r.kinds) |k| if (std.mem.eql(u8, k.name, kind)) {
            const b = answers(state orelse return error.BuiltinFailed);
            return b.call(b.user, s, index, cx);
        };
    }
    return error.BuiltinFailed;
}
