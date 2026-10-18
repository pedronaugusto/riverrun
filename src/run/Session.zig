//! A story being told: its flows, walked step by step over the host's facts.
//!
//! `next` walks a flow until it has something for the host: a line, choices,
//! effects, an action, or the end. Branches, gathers, jumps, calls and pools
//! are walked through on the way. Nothing the story does is applied here:
//! effects are handed to the host, which applies them as it likes. The only
//! facts the session writes are its own, in the reserved scope: visits,
//! alternatives, pools' memory and the turn.

const std = @import("std");
const aegis = @import("aegis");
const facts = @import("../facts.zig");
const story_ = @import("../story.zig");
const eval = @import("eval.zig");
const text = @import("text.zig");
const pool = @import("pool.zig");
const flow_ = @import("flow.zig");
const cursors = @import("cursors.zig");
const host_ = @import("host.zig");
const Host = host_.Host;

const Session = @This();
const Flow = flow_.Flow;
const Frame = flow_.Frame;
const NodeId = story_.NodeId;

/// The most flows a session holds.
pub const max_flows = flow_.max_flows;
pub const max_call_depth = story_.max_call_depth;

/// A flow, by its place in the session.
pub const FlowId = aegis.id.Id(enum { flow }, u8);

pub const Error = text.Error || pool.Error || error{
    /// A flow id at or past `max_flows`.
    TooManyFlows,
    FlowNotStarted,
    /// Calls, interruptions and pools nested past `max_call_depth`.
    CallTooDeep,
    /// Choices are offered: `choose` before `next`.
    AwaitingChoice,
    /// An action's outcome is owed: `outcome` before `next`.
    AwaitingOutcome,
    /// `choose` with no choices offered.
    NoChoicePending,
    NoSuchChoice,
    ChoiceClosed,
    /// `outcome` with none owed.
    NoOutcomePending,
    /// One step's effects call more actions with an outcome than `flow.max_outcomes`.
    TooManyOutcomes,
    /// `next` walked `Options.max_walk` steps with nothing to say: jumps in a loop.
    NoProgress,
};

pub const Options = struct {
    /// The most steps one `next` walks through before it gives up on a story that says nothing.
    max_walk: u32 = 100_000,
    /// What answers registered kinds' builtins, for a session that tells their sections.
    builtins: ?eval.Builtins = null,
    /// Plural categories and things' genders, for the words plural and gender slots choose.
    language: eval.Language = .{},
};

/// What a flow has for the host. Its slices are valid until the flow's next `next`.
pub const Step = union(enum) {
    line: Line,
    choices: []const Choice,
    /// Effects reached on their own, to apply now.
    effects: []const facts.Effect,
    /// An action with an outcome: perform it, then give `outcome`.
    action: Action,
    end,
};

pub const Action = struct {
    call: facts.Call,
    /// Where it was reached and whose facts it is about, as a query is told.
    context: host_.Context,
};

pub const Line = struct {
    id: story_.LineId,
    /// Null for narration.
    speaker: ?story_.CastId,
    text: []const u8,
    tags: story_.Range,
    /// To apply if the line is delivered, and only then.
    effects: []const facts.Effect,
};

pub const Choice = struct {
    id: story_.LineId,
    text: []const u8,
    /// A closed choice is offered so it can be shown locked; it cannot be chosen.
    open: bool,
    tags: story_.Range,
};

gpa: std.mem.Allocator,
story: *const story_.Story,
words: *const story_.Strings,
store: facts.Store,
host: *const Host,
options: Options,
flows: []Flow,
/// The host's handle for whose facts each scope holds, by scope: what a call's context says.
owners: [facts.max_scopes]u64 = @splat(0),

/// A session over `s`, with its words, facts and bound host; all outlive it.
pub fn init(gpa: std.mem.Allocator, s: *const story_.Story, words: *const story_.Strings, store: facts.Store, host: *const Host, options: Options) error{ OutOfMemory, HostNotBound }!Session {
    if (!host.serves(s)) return error.HostNotBound;
    const flows = try gpa.alloc(Flow, max_flows);
    for (flows, 0..) |*f, i| f.* = .{ .id = @intCast(i), .arena = .init(gpa) }; // safe: below max_flows
    return .{ .gpa = gpa, .story = s, .words = words, .store = store, .host = host, .options = options, .flows = flows };
}

pub fn deinit(s: *Session) void {
    for (s.flows) |*f| f.arena.deinit();
    s.gpa.free(s.flows);
    s.* = undefined;
}

/// Begins `flow` at `section`, ending whatever it was telling.
pub fn start(s: *Session, id: FlowId, section: story_.SectionId) Error!void {
    const f = try s.flowAt(id);
    f.reset();
    f.started = true;
    try s.enter(f, section);
}

/// Ends `flow`; it can be started again.
pub fn stop(s: *Session, id: FlowId) Error!void {
    (try s.flowAt(id)).reset();
}

/// Runs `section` in `flow` as a call, then goes back to where the flow was:
/// the step after the one being delivered, or the choices it was offering.
pub fn interrupt(s: *Session, id: FlowId, section: story_.SectionId) Error!void {
    const f = try s.startedFlow(id);
    if (f.pending == .outcomes) return error.AwaitingOutcome;
    if (f.ended) {
        f.ended = false;
        f.at = null;
    }
    const back: ?NodeId = if (f.pending == .choices) f.pending.choices.node else f.at;
    try push(f, .{ .back = back, .effect_at = if (f.pending == .choices) 0 else f.effect_at });
    f.pending = .none;
    f.effect_at = 0;
    try s.enter(f, section);
}

/// What `flow` has next for the host.
pub fn next(s: *Session, id: FlowId) Error!Step {
    const f = try s.startedFlow(id);
    switch (f.pending) {
        .none => {},
        .choices => return error.AwaitingChoice,
        .outcomes => return error.AwaitingOutcome,
    }
    _ = f.arena.reset(.retain_capacity);
    if (f.ended) return .end;
    var walked: u32 = 0;
    while (walked < s.options.max_walk) : (walked += 1) {
        const at = f.at orelse {
            if (try s.handBack(f)) continue;
            f.ended = true;
            return .end;
        };
        if (try s.walk(f, at)) |step| return step;
    }
    return error.NoProgress;
}

/// Takes choice `i` of those `next` offered.
pub fn choose(s: *Session, id: FlowId, i: usize) Error!void {
    const f = try s.startedFlow(id);
    if (f.pending != .choices) return error.NoChoicePending;
    const p = f.pending.choices;
    if (i >= p.len) return error.NoSuchChoice;
    if (!p.open[i]) return error.ChoiceClosed;
    const at = s.story.node(p.node).step.choices;
    const c = s.story.choice(at.choices.start + p.offered[i]);
    try s.count(c.visits);
    f.at = c.target;
    f.pending = .none;
}

/// The outcome of the action `next` handed over: written into its result fact, and the flow goes on.
pub fn outcome(s: *Session, id: FlowId, v: facts.Value) Error!void {
    const f = try s.startedFlow(id);
    if (f.pending != .outcomes) return error.NoOutcomePending;
    const o = &f.pending.outcomes;
    try s.store.set(o.list[o.given], v);
    o.given += 1;
    if (o.given == o.len) f.pending = .none;
}

/// Where every flow is, as bytes that survive a recompiled story: see `cursors`.
pub fn saveCursors(s: *Session, gpa: std.mem.Allocator) cursors.SaveError![]u8 {
    return cursors.save(gpa, s.story, s.flows);
}

/// Puts every flow where a save says; a step gone from the story ends its flow, and the report says so.
pub fn restoreCursors(s: *Session, gpa: std.mem.Allocator, bytes: []const u8) cursors.RestoreError!cursors.Report {
    return cursors.restore(gpa, s.story, s.flows, bytes);
}

/// Says whose facts `scope` holds: the host's handle, handed to every query and action.
pub fn setOwner(s: *Session, scope: facts.ScopeId, owner: u64) void {
    s.owners[scope.raw()] = owner;
}

/// The context a call from `flow` is made in.
pub fn context(s: *const Session, id: FlowId) host_.Context {
    return .{ .flow = id.raw(), .owners = &s.owners };
}

/// How a speaker is shown, as the string table words it.
pub fn speaker(s: *const Session, cast: story_.CastId) ?[]const u8 {
    return s.words.template(s.story.castMember(cast).display);
}

/// The flow `id`, for tools that inspect a session.
pub fn flowAt(s: *Session, id: FlowId) Error!*Flow {
    if (id.raw() >= max_flows) return error.TooManyFlows;
    return &s.flows[id.raw()];
}

fn startedFlow(s: *Session, id: FlowId) Error!*Flow {
    const f = try s.flowAt(id);
    if (!f.started) return error.FlowNotStarted;
    return f;
}

fn evaluation(s: *Session, f: *Flow) eval.Context {
    return .{ .story = s.story, .store = s.store, .host = s.host, .call = s.context(.fromRaw(f.id)), .arena = f.arena.allocator(), .builtins = s.options.builtins, .language = s.options.language };
}

// One step of the walk: a step for the host, or null to keep walking.
fn walk(s: *Session, f: *Flow, at: NodeId) Error!?Step {
    const n = s.story.node(at);
    switch (n.step) {
        .line => |l| {
            f.at = l.next;
            return try s.line(f, l, n.tags);
        },
        .choices => |c| {
            if (try s.offer(f, at, c.choices)) |list| return .{ .choices = list };
            f.at = c.next;
        },
        .branch => |b| f.at = if (try eval.condition(s.evaluation(f), b.cond)) b.then else b.otherwise,
        .gather => |g| {
            if (g.visits) |v| try s.count(v);
            f.at = g.next;
        },
        .effects => |e| return s.effects(f, e.effects, e.next),
        .jump => |section| try s.enter(f, section),
        .call => |c| {
            try push(f, .{ .back = c.next });
            try s.enter(f, c.section);
        },
        .ret => f.at = null,
        .end => {
            f.at = null;
            f.depth = 0;
            f.ended = true;
            return .end;
        },
    }
    return null;
}

// Into a section: its visit counted, a pool's candidates chosen.
fn enter(s: *Session, f: *Flow, id: story_.SectionId) Error!void {
    const section = s.story.section(id);
    try s.count(section.visits);
    f.effect_at = 0;
    if (section.kind == .pool) {
        const picks = try pool.pick(s.evaluation(f), section);
        try push(f, .{ .back = null, .pool = .{ .section = id, .picks = picks } });
    }
    f.at = section.entry;
}

// The flow ran out of steps: the next of a pool's candidates, or back to
// where a call or an interruption began. False when nothing is left.
fn handBack(s: *Session, f: *Flow) Error!bool {
    while (f.depth > 0) {
        const top = &f.frames[f.depth - 1];
        if (top.pool) |*p| {
            if (p.given < p.picks.len) {
                f.at = s.story.candidate(p.picks.list[p.given]).entry;
                f.effect_at = 0;
                p.given += 1;
                return true;
            }
        }
        f.depth -= 1;
        if (top.back) |b| {
            f.at = b;
            f.effect_at = top.effect_at;
            return true;
        }
    }
    return false;
}

fn push(f: *Flow, frame: Frame) Error!void {
    if (f.depth == max_call_depth) return error.CallTooDeep;
    f.frames[f.depth] = frame;
    f.depth += 1;
}

fn count(s: *Session, visits: facts.FactId) Error!void {
    try s.store.set(visits, .{ .int = s.store.get(visits).int +| 1 });
}

fn line(s: *Session, f: *Flow, l: @FieldType(story_.Node.Step, "line"), tags: story_.Range) Error!Step {
    const cx = s.evaluation(f);
    const t = s.story.text(l.text);
    var owed: Owed = .{};
    const list = try cx.arena.alloc(facts.Effect, l.effects.len);
    for (list, 0..) |*e, k| e.* = try emit(cx, s.story.effect(l.effects.start + @as(u32, @intCast(k))), &owed); // safe: below a u32 length
    const words = try text.render(cx, s.words, l.text);
    try owed.hold(f);
    return .{ .line = .{ .id = t.line, .speaker = l.speaker, .text = words, .tags = tags, .effects = list } };
}

// The choices offered at `at`, or null when none is open and the flow goes past them.
fn offer(s: *Session, f: *Flow, at: NodeId, r: story_.Range) Error!?[]const Choice {
    const cx = s.evaluation(f);
    var p: @FieldType(flow_.Pending, "choices") = .{ .node = at, .offered = undefined, .open = undefined, .len = 0 };
    const list = try cx.arena.alloc(Choice, r.len);
    var any_open = false;
    for (0..r.len) |k| {
        const c = s.story.choice(r.start + @as(u32, @intCast(k))); // safe: validated to max_choices
        if (!c.sticky and s.store.get(c.visits).int > 0) continue;
        const open = try eval.condition(cx, c.cond);
        any_open = any_open or open;
        list[p.len] = .{ .id = s.story.text(c.text).line, .text = try text.render(cx, s.words, c.text), .open = open, .tags = c.tags };
        p.offered[p.len] = @intCast(k); // safe: below max_choices
        p.open[p.len] = open;
        p.len += 1;
    }
    if (!any_open) return null;
    f.pending = .{ .choices = p };
    return list[0..p.len];
}

// An effects step from where it got to: the effects up to the next action
// with an outcome, then that action on its own, then the rest.
fn effects(s: *Session, f: *Flow, r: story_.Range, after: ?NodeId) Error!?Step {
    const cx = s.evaluation(f);
    const from = f.effect_at;
    var k = from;
    while (k < r.len) : (k += 1) {
        const e = s.story.effect(r.start + k);
        if (e == .call and e.call.result != null) break;
    }
    if (k > from) {
        const list = try cx.arena.alloc(facts.Effect, k - from);
        var owed: Owed = .{};
        for (list, from..) |*e, i| e.* = try emit(cx, s.story.effect(r.start + @as(u32, @intCast(i))), &owed); // safe: below a u32 length
        f.effect_at = k;
        if (k == r.len) s.past(f, after);
        return .{ .effects = list };
    }
    if (k == r.len) {
        s.past(f, after);
        return null;
    }
    var owed: Owed = .{};
    const call = (try emit(cx, s.story.effect(r.start + k), &owed)).call;
    f.effect_at = k + 1;
    if (f.effect_at == r.len) s.past(f, after);
    try owed.hold(f);
    return .{ .action = .{ .call = call, .context = s.context(.fromRaw(f.id)) } };
}

fn past(_: *Session, f: *Flow, after: ?NodeId) void {
    f.at = after;
    f.effect_at = 0;
}

// The outcomes a step's actions owe, held on the flow once the step is handed over.
const Owed = struct {
    list: [flow_.max_outcomes]facts.FactId = undefined,
    len: u8 = 0,
    too_many: bool = false,

    fn add(o: *Owed, fact: facts.FactId) void {
        if (o.len == o.list.len) {
            o.too_many = true;
            return;
        }
        o.list[o.len] = fact;
        o.len += 1;
    }

    fn hold(o: *const Owed, f: *Flow) Error!void {
        if (o.too_many) return error.TooManyOutcomes;
        if (o.len > 0) f.pending = .{ .outcomes = .{ .list = o.list, .len = o.len } };
    }
};

// A compiled effect as the host receives it, its values worked out now.
fn emit(cx: eval.Context, e: story_.Effect, owed: *Owed) Error!facts.Effect {
    if (e == .call) if (e.call.result) |r| owed.add(r);
    return eval.effect(cx, e);
}
