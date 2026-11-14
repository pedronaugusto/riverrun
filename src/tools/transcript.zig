//! A play written down, one row a thing, in the plain form a test pins, an
//! AI reads and a writer reads in a terminal. A row reads as the story is
//! written: a section's heading and its tags as under it, a line as
//! `SPEAKER (delivery): words` or its words alone, what the game is told in
//! brackets on a row of its own, indented under the line or the choice it is
//! of. What is not the story's words begins with a mark of its own:
//!
//!     == hide_1969                      a section the flow came to (`= part` a part)
//!       [listen] [count 20]             its tags, as written under it
//!     MUM: You could still play, Frank. a line
//!       [at 9.5] [heard piano]          the line's tags, then its effects
//!       [carried += play]
//!     The piano is locked.              narration (`\` before a first mark of these)
//!     [cutscene(gate)]                  effects reached on their own
//!     * 1 Who'll run the shop?          a choice, by the number a player gives
//!     * 2 (closed) You could still play, Dad.
//!     ? lived(go) = false (not set)     a query the story asked, and its answer
//!     ? pay(5) -> true or false         an action whose outcome the game decides
//!     ! rule watch.woke                 a rule that fired, its effects under it
//!     ! reached the_stranger.noticed    what a package's runtime did, its words under it
//!     > 1                               an input, as it was given
//!     -> end                            the end
//!     story.river:12:1-12:30: error: …  a run-time error, in the diagnostics' one form
//!
//! The same play written twice is the same text: nothing in it depends on a
//! handle, an address or a clock.

const std = @import("std");
const runtime = @import("riverrun");
const river = @import("riverrun-compiler");
const Play = @import("Play.zig");
const report = @import("report.zig");

const story = runtime.story;
const facts = runtime.facts;
const ast = river.syntax.ast;
const Writer = std.Io.Writer;

/// What a transcript is written with: the play, and, to place a run-time error, the story's files and where its
/// steps are written.
pub const Transcript = struct {
    play: *const Play,
    files: []const ast.File = &.{},
    where: ?*const river.compile.Where = null,
    /// ANSI colours, for a terminal.
    color: bool = false,

    /// One event, its rows.
    pub fn event(t: *const Transcript, w: *Writer, e: Play.Event) Writer.Error!void {
        const s = t.graph();
        switch (e) {
            .section => |at| {
                const name = s.section(at.section).name;
                try t.mark(w, .heading, "== {s}", .{name});
                try t.tagsRow(w, s.section(at.section).tags, 2, null);
                if (at.part) |part| {
                    const full = s.section(part).name;
                    const short = if (std.mem.startsWith(u8, full, name) and full.len > name.len) full[name.len + 1 ..] else full;
                    try t.mark(w, .heading, "= {s}", .{short});
                    try t.tagsRow(w, s.section(part).tags, 2, null);
                }
            },
            .line => |l| {
                const delivery = t.play.options.delivery;
                if (l.speaker) |who| {
                    try t.on(w, .speaker);
                    try speakerLabel(w, t.play, who);
                    try t.off(w);
                    if (delivery) |key| if (s.tagNamed(l.tags, key)) |d| {
                        try t.on(w, .dim);
                        try w.writeAll(" (");
                        for (0..d.values.len) |v| try w.writeAll(s.tagValue(d.values.start + @as(u32, @intCast(v))).text); // safe: below a u32 length
                        try w.writeByte(')');
                        try t.off(w);
                    };
                    try w.print(": {s}", .{l.text});
                } else {
                    if (l.text.len > 0 and std.mem.findScalar(u8, "=*>?![-\\", l.text[0]) != null) try w.writeByte('\\');
                    try w.writeAll(l.text);
                }
                try t.lineId(w, l.tags);
                try w.writeByte('\n');
                try t.tagsRow(w, l.tags, 2, delivery);
                try t.effectsRow(w, l.effects, 2);
            },
            .choices => |list| for (list) |c| {
                try t.on(w, if (c.open) .choice else .dim);
                try w.print("* {d}", .{c.number});
                try t.off(w);
                if (!c.open) {
                    try t.on(w, .dim);
                    try w.writeAll(" (closed)");
                    try t.off(w);
                }
                try w.print(" {s}", .{c.text});
                try t.lineId(w, c.tags);
                try w.writeByte('\n');
                try t.tagsRow(w, c.tags, 2, null);
            },
            .effects => |list| try t.effectsRow(w, list, 0),
            .asks => |call| {
                try t.on(w, .asked);
                try w.writeAll("? ");
                try t.callText(w, call);
                try w.writeAll(" -> ");
                try t.kindText(w, s.fact(call.result.?));
                try t.off(w);
                try w.writeByte('\n');
            },
            .asked => |a| {
                const x = s.externFn(a.query);
                try t.on(w, .asked);
                try w.print("? {s}(", .{x.name});
                try t.args(w, x, a.args);
                try w.writeAll(") = ");
                try t.value(w, a.answer, paramShape(s, x.returns.?));
                if (!a.given) try w.writeAll(" (not set)");
                try t.off(w);
                try w.writeByte('\n');
            },
            .rule => |r| {
                try t.mark(w, .news, "! rule {s}.{s}", .{ s.section(r.section).name, r.name });
                try t.effectsRow(w, r.effects, 2);
            },
            .news => |n| {
                try t.mark(w, .news, "! {s} {s}", .{ n.news.what, n.news.name });
                for (n.news.words) |words| try w.print("  {s}\n", .{words});
                try t.effectsRow(w, n.news.effects, 2);
            },
            .end => try t.mark(w, .dim, "-> end", .{}),
            .stopped => |stop| try t.stopped(w, stop),
        }
    }

    /// An input as it was given: `> 1`, `> :set met = true`.
    pub fn echo(t: *const Transcript, w: *Writer, text: []const u8) Writer.Error!void {
        try t.mark(w, .dim, "> {s}", .{text});
    }

    /// The facts, each `name = value` on a row of its own, indented: those named, or else every one that holds
    /// something other than where it started. Facts riverrun or a package keeps for itself, whose names a writer
    /// cannot write, are left out.
    pub fn factsNow(t: *const Transcript, w: *Writer, names: []const facts.FactId) Writer.Error!void {
        const s = t.graph();
        const store = t.play.loaded.memory.store();
        if (names.len > 0) {
            for (names) |f| _ = try t.factRows(w, f, true);
            return;
        }
        var any = false;
        for (0..s.len(.facts)) |i| {
            const f: facts.FactId = .fromRaw(@intCast(i)); // safe: below max_facts
            const d = s.fact(f);
            if (d.scope.eql(s.reservedScope()) or !writable(d.name)) continue;
            if (d.key == .none and store.get(f).eql(d.start())) continue;
            if (try t.factRows(w, f, false)) any = true;
        }
        if (!any) try w.writeAll("  (every fact holds what it started with)\n");
    }

    // A fact's rows: its value, or each key's that holds something other than where it started (every key where
    // `all`). Whether it wrote one.
    fn factRows(t: *const Transcript, w: *Writer, f: facts.FactId, all: bool) Writer.Error!bool {
        const s = t.graph();
        const store = t.play.loaded.memory.store();
        const d = s.fact(f);
        const shape = factShape(d);
        switch (d.key) {
            .none => {
                try w.print("  {s} = ", .{d.name});
                try t.value(w, store.get(f), shape);
                try w.writeByte('\n');
                return true;
            },
            .items => |e| {
                var wrote = false;
                const r = s.items(e);
                for (0..r.len) |k| {
                    const v = store.getKey(f, k);
                    if (!all and v.eql(d.start())) continue;
                    try w.print("  {s}({s}) = ", .{ d.name, s.item(r.start + @as(u32, @intCast(k))) }); // safe: below a u32 length
                    try t.value(w, v, shape);
                    try w.writeByte('\n');
                    wrote = true;
                }
                return wrote;
            },
            .ref => |kind_id| {
                const kind = s.refKind(kind_id);
                var wrote = false;
                for (0..s.len(.things)) |i| {
                    const named = s.thing(@intCast(i)); // safe: below a u32 count
                    if (!std.mem.eql(u8, named.kind, kind)) continue;
                    const v = store.getKey(f, t.play.loaded.host.refs[i]);
                    if (!all and v.eql(d.start())) continue;
                    try w.print("  {s}({s}) = ", .{ d.name, named.id });
                    try t.value(w, v, shape);
                    try w.writeByte('\n');
                    wrote = true;
                }
                return wrote;
            },
        }
    }

    // A run-time error, in the diagnostics' form, placed where its step is written when that is known.
    fn stopped(t: *const Transcript, w: *Writer, stop: Play.Stop) Writer.Error!void {
        try t.on(w, .err);
        if (t.placeOf(stop.step)) |at| {
            const f = &t.files[at.file];
            const r = report.range(f, at);
            try w.print("{s}:{d}:{d}-{d}:{d}: error: ", .{ f.path, r.from.line, r.from.col, r.to.line, r.to.col });
        } else try w.print("{s}: error: ", .{report.program});
        try w.writeAll(describe(stop.failure));
        if (stop.why) |why| try w.print(": {s}", .{why});
        try w.print(" ({t})", .{stop.failure});
        try t.off(w);
        try w.writeByte('\n');
    }

    // Where a step is written: its first row, the statement itself without what is under it.
    fn placeOf(t: *const Transcript, step: ?story.NodeId) ?river.syntax.Span {
        const where = t.where orelse return null;
        const id = step orelse return null;
        const count = std.math.cast(u32, where.steps.len) orelse return null;
        if (id.compare(.fromRaw(count)) != .lt) return null;
        const span = where.steps[id.raw()];
        if (span.start == river.syntax.Span.none.start or span.file >= t.files.len) return null;
        return firstRow(&t.files[span.file], span);
    }

    fn graph(t: *const Transcript) *const story.Story {
        return &t.play.loaded.story;
    }

    // A line's or a choice's id, where it has one written, ` ^id` as at the end of its row.
    fn lineId(t: *const Transcript, w: *Writer, tags: story.Range) Writer.Error!void {
        const s = t.graph();
        const tag = s.tagNamed(tags, "id") orelse return;
        if (tag.values.len == 0) return;
        try t.on(w, .dim);
        try w.print(" ^{s}", .{s.tagValue(tag.values.start).text});
        try t.off(w);
    }

    // A row of a section's, a line's or a choice's tags, `[key value, value]` each, indented; the delivery's key
    // left out, since it stands in the line's parentheses.
    fn tagsRow(t: *const Transcript, w: *Writer, tags: story.Range, indent: usize, skip: ?[]const u8) Writer.Error!void {
        const s = t.graph();
        var first = true;
        for (0..tags.len) |k| {
            const tag = s.tag(tags.start + @as(u32, @intCast(k))); // safe: below a u32 length
            if (skip) |key| if (std.mem.eql(u8, tag.key, key)) continue;
            // riverrun's own: the id stands at the end of the row
            if (std.mem.eql(u8, tag.key, "id")) continue;
            if (first) {
                try w.splatByteAll(' ', indent);
                try t.on(w, .dim);
                first = false;
            } else try w.writeByte(' ');
            try w.print("[{s}", .{tag.key});
            for (0..tag.values.len) |v| {
                try w.writeAll(if (v == 0) " " else ", ");
                try tagValue(w, s.tagValue(tag.values.start + @as(u32, @intCast(v))).text); // safe: below a u32 length
            }
            try w.writeByte(']');
        }
        if (!first) {
            try t.off(w);
            try w.writeByte('\n');
        }
    }

    // A row of effects, each in its bracket as the story writes it, indented.
    fn effectsRow(t: *const Transcript, w: *Writer, list: []const facts.Effect, indent: usize) Writer.Error!void {
        if (list.len == 0) return;
        try w.splatByteAll(' ', indent);
        try t.on(w, .dim);
        for (list, 0..) |e, i| {
            if (i > 0) try w.writeByte(' ');
            try w.writeByte('[');
            try t.effect(w, e);
            try w.writeByte(']');
        }
        try t.off(w);
        try w.writeByte('\n');
    }

    /// An effect as written in its bracket: `carried += play`, `opinion(marta) -= 5`, `give(letter)`,
    /// `paid = pay(5)`.
    pub fn effect(t: *const Transcript, w: *Writer, e: facts.Effect) Writer.Error!void {
        const s = t.graph();
        switch (e) {
            .set => |x| {
                try t.factName(w, x.fact, x.key);
                try w.writeAll(" = ");
                try t.value(w, x.value, factShape(s.fact(x.fact)));
            },
            .add, .remove => |x| {
                try t.factName(w, x.fact, x.key);
                try w.writeAll(if (e == .add) " += " else " -= ");
                const d = s.fact(x.fact);
                try w.writeAll(if (d.enumeration) |en| itemName(s, en, x.item) else "?");
            },
            .change => |x| {
                try t.factName(w, x.fact, x.key);
                if (x.by < 0) try w.print(" -= {d}", .{-@as(i128, x.by)}) else try w.print(" += {d}", .{x.by});
            },
            .call => |c| {
                if (c.result) |r| {
                    try w.writeAll(s.fact(r).name);
                    try w.writeAll(" = ");
                }
                try t.callText(w, c);
            },
        }
    }

    fn callText(t: *const Transcript, w: *Writer, c: facts.Call) Writer.Error!void {
        const x = t.graph().externFn(c.action);
        try w.print("{s}(", .{x.name});
        try t.args(w, x, c.args);
        try w.writeByte(')');
    }

    fn args(t: *const Transcript, w: *Writer, x: story.Extern, list: []const facts.Value) Writer.Error!void {
        const s = t.graph();
        for (list, 0..) |v, i| {
            if (i > 0) try w.writeAll(", ");
            const shape: Shape = if (i < x.params.len) paramShape(s, s.param(x.params.start + @as(u32, @intCast(i)))) else .{ .kind = @as(facts.Kind, v) }; // safe: below a u32 length
            try t.value(w, v, shape);
        }
    }

    fn factName(t: *const Transcript, w: *Writer, f: facts.FactId, key: ?facts.Key) Writer.Error!void {
        const s = t.graph();
        const d = s.fact(f);
        try w.writeAll(d.name);
        const k = key orelse return;
        try w.writeByte('(');
        switch (d.key) {
            .items => |e| try w.writeAll(itemName(s, e, std.math.cast(u16, k) orelse std.math.maxInt(u16))),
            .ref => |kind| try t.thing(w, s.refKind(kind), k),
            .none => try w.print("{d}", .{k}),
        }
        try w.writeByte(')');
    }

    /// A value as a writer writes it: `true`, `-3`, a value of its list, the items of a set (`none` for none), a
    /// thing's id, words in quotes.
    pub fn value(t: *const Transcript, w: *Writer, v: facts.Value, shape: Shape) Writer.Error!void {
        const s = t.graph();
        switch (v) {
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .int => |n| try w.print("{d}", .{n}),
            .one_of => |i| try w.writeAll(if (shape.enumeration) |e| itemName(s, e, i) else "?"),
            .set_of => |set| {
                var first = true;
                var it = set.iterator(.{});
                while (it.next()) |i| {
                    if (!first) try w.writeAll(", ");
                    first = false;
                    try w.writeAll(if (shape.enumeration) |e| itemName(s, e, @intCast(i)) else "?"); // safe: below max_items
                }
                if (first) try w.writeAll("none");
            },
            .text => |words| try w.print("\"{s}\"", .{words}),
            .ref => |h| try t.thing(w, if (shape.ref_kind) |k| s.refKind(k) else "", h),
        }
    }

    fn thing(t: *const Transcript, w: *Writer, kind: []const u8, h: u64) Writer.Error!void {
        if (h == facts.Value.no_ref) return w.writeAll("none");
        if (t.play.thingName(kind, h)) |name| return w.writeAll(name);
        try w.print("#{x}", .{h});
    }

    // What an action's outcome is, as a player answers it.
    fn kindText(t: *const Transcript, w: *Writer, d: story.FactDecl) Writer.Error!void {
        const s = t.graph();
        switch (d.kind) {
            .boolean => try w.writeAll("true or false"),
            .int => try w.writeAll("a number"),
            .one_of => {
                try w.writeAll("one of ");
                const r = s.items(d.enumeration.?);
                for (0..r.len) |k| {
                    if (k > 0) try w.writeAll(", ");
                    try w.writeAll(s.item(r.start + @as(u32, @intCast(k)))); // safe: below a u32 length
                }
            },
            .set_of => try w.writeAll("a set"),
            .text => try w.writeAll("words in quotes"),
            .ref => try w.print("a {s}", .{if (d.ref_kind) |k| s.refKind(k) else "thing"}),
        }
    }

    fn mark(t: *const Transcript, w: *Writer, style: Style, comptime fmt: []const u8, a: anytype) Writer.Error!void {
        try t.on(w, style);
        try w.print(fmt, a);
        try t.off(w);
        try w.writeByte('\n');
    }

    fn on(t: *const Transcript, w: *Writer, style: Style) Writer.Error!void {
        if (!t.color) return;
        try w.writeAll(switch (style) {
            .heading => "\x1b[1;34m",
            .speaker => "\x1b[1m",
            .dim => "\x1b[2m",
            .choice => "\x1b[1;36m",
            .asked => "\x1b[35m",
            .news => "\x1b[33m",
            .err => "\x1b[1;31m",
        });
    }

    fn off(t: *const Transcript, w: *Writer) Writer.Error!void {
        if (t.color) try w.writeAll("\x1b[0m");
    }
};

const Style = enum { heading, speaker, dim, choice, asked, news, err };

/// What a value's words are read against: its kind, its list's values, the kind of thing it names.
pub const Shape = struct {
    kind: facts.Kind,
    enumeration: ?story.EnumId = null,
    ref_kind: ?story.RefKindId = null,
};

pub fn factShape(d: story.FactDecl) Shape {
    return .{ .kind = d.kind, .enumeration = d.enumeration, .ref_kind = d.ref_kind };
}

pub fn paramShape(_: *const story.Story, p: story.Param) Shape {
    return .{ .kind = p.kind, .enumeration = p.enumeration, .ref_kind = p.ref_kind };
}

/// A run-time error in words a writer acts on.
pub fn describe(f: Play.Failure) []const u8 {
    return switch (f) {
        error.Overflow => "a sum, or a change, passed what an int holds (64 bits)",
        error.NoProgress => "the story walked 100,000 steps and said nothing: jumps in a loop",
        error.CallTooDeep => "calls, interruptions and pools nested more than 64 deep: a call that never comes back",
        error.TooManyOutcomes => "one step waits on more than 8 actions with an outcome",
        error.OutOfBounds => "a value was set past the fact's bounds",
        error.NoFixedPoint => "rules kept firing each other for 64 rounds",
        error.Endless => "the story went on without waiting for the player: a loop that says something each time round",
        error.Stopped => "a package's runtime stopped the story",
        error.BuiltinFailed => "a package's builtin could not answer",
        error.QueryFailed => "the game could not answer a query",
        else => "the runtime stopped the story",
    };
}

// A speaker as the story writes it: a cast member's id in capitals, an extra's words in capitals.
fn speakerLabel(w: *Writer, p: *const Play, who: story.CastId) Writer.Error!void {
    const cast = p.loaded.story.castMember(who);
    const name = if (cast.name.len > 0) cast.name else p.loaded.strings.template(cast.display) orelse "";
    for (name) |c| try w.writeByte(std.ascii.toUpper(c));
}

fn itemName(s: *const story.Story, e: story.EnumId, i: u16) []const u8 {
    if (i == facts.Value.none) return "none";
    const r = s.items(e);
    if (i >= r.len) return "?";
    return s.item(r.start + i);
}

// A tag's value: bare where it is a word or a number, in quotes where it holds anything else.
fn tagValue(w: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-')) return w.print("\"{s}\"", .{text});
    try w.writeAll(text);
}

/// A name a writer can write: letters, digits, `_` and the `.` between a module or a section and its own; what
/// riverrun and packages keep for themselves is named otherwise.
pub fn writable(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) return false;
    return true;
}

// A span cut to the words of its first row.
fn firstRow(file: *const ast.File, span: river.syntax.Span) river.syntax.Span {
    var out = span;
    var row: ?ast.Row = null;
    for (file.rows) |r| {
        if (r.start > span.start) break;
        row = r;
    }
    const r = row orelse return out;
    var end = r.start + r.indent + @as(u32, @intCast(r.text.len)); // safe: within a file
    if (r.id.len > 0) end += r.before_id + @as(u32, @intCast(r.id.len)); // safe: within a file
    if (end > span.start and end < out.end) out.end = end;
    return out;
}
