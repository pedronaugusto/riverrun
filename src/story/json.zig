//! A compiled story as JSON, through strand: what `riverrun dump` prints and
//! what a tool reads when it wants the graph without the binary reader.
//! Ids are kept as numbers, names beside them; conditions and values are
//! written as their postfix terms in words: `carried 'play has`.

const std = @import("std");
const strand = @import("strand");
const facts = @import("../facts.zig");
const format = @import("format.zig");
const model = @import("model.zig");
const Story = @import("reader.zig").Story;

const Allocator = std.mem.Allocator;
const Range = format.Range;

const TagDump = struct { key: []const u8, values: []const []const u8 };

const SlotDump = struct { kind: format.SlotKind, expr: ?[]const u8 = null, arity: u8, state: ?[]const u8 = null };

const TextDump = struct { line: []const u8, slots: ?[]const SlotDump = null };

const EffectDump = struct {
    kind: format.EffectKind,
    fact: ?[]const u8 = null,
    item: ?[]const u8 = null,
    value: ?[]const u8 = null,
    action: ?[]const u8 = null,
    args: ?[]const u8 = null,
    result: ?[]const u8 = null,
};

const ChoiceDump = struct {
    text: TextDump,
    cond: ?[]const u8 = null,
    sticky: bool,
    target: u32,
    visits: []const u8,
    tags: ?[]const TagDump = null,
};

const NodeDump = struct {
    id: u32,
    kind: format.NodeKind,
    speaker: ?[]const u8 = null,
    text: ?TextDump = null,
    effects: ?[]const EffectDump = null,
    choices: ?[]const ChoiceDump = null,
    cond: ?[]const u8 = null,
    then: ?u32 = null,
    otherwise: ?u32 = null,
    section: ?[]const u8 = null,
    visits: ?[]const u8 = null,
    next: ?u32 = null,
    tags: ?[]const TagDump = null,
};

const CandidateDump = struct { name: []const u8, when: ?[]const u8 = null, specificity: u16, entry: u32, tags: ?[]const TagDump = null };

const SectionDump = struct {
    name: []const u8,
    kind: format.SectionKind,
    kind_name: ?[]const u8 = null,
    pick: ?u16 = null,
    entry: ?u32 = null,
    visits: []const u8,
    tags: ?[]const TagDump = null,
    candidates: ?[]const CandidateDump = null,
};

const FactDump = struct { name: []const u8, scope: []const u8, kind: facts.Kind, role: facts.Role, items: ?[]const []const u8 = null };

const CastDump = struct { name: ?[]const u8 = null, display: []const u8, relation: ?[]const u8 = null, extra: bool, tags: ?[]const TagDump = null };

const ExternDump = struct { name: []const u8, params: []const []const u8, returns: ?[]const u8 = null, action: bool };

const Dump = struct {
    format: []const u8,
    hash: []const u8,
    scopes: []const []const u8,
    facts: []const FactDump,
    cast: []const CastDump,
    externs: []const ExternDump,
    sections: []const SectionDump,
    nodes: []const NodeDump,
};

/// Writes the whole graph; `arena` holds what is built to write it.
pub fn write(story: *const Story, arena: Allocator, w: *std.Io.Writer) !void {
    const d: Dump = .{
        .format = "riverrun 1.0",
        .hash = try hex(arena, story.hash()),
        .scopes = try scopes(story, arena),
        .facts = try factList(story, arena),
        .cast = try castList(story, arena),
        .externs = try externList(story, arena),
        .sections = try sectionList(story, arena),
        .nodes = try nodeList(story, arena),
    };
    try strand.json.write(w, d, .{ .nulls = .omit, .whitespace = .indent_2 });
}

fn hex(arena: Allocator, v: u64) ![]const u8 {
    return arena.print("{x:0>16}", .{v});
}

fn scopes(story: *const Story, arena: Allocator) ![]const []const u8 {
    const out = try arena.alloc([]const u8, story.len(.scopes));
    for (out, 0..) |*o, i| o.* = story.scope(.fromRaw(@intCast(i))); // safe: validated to max_scopes
    return out;
}

fn itemNames(story: *const Story, arena: Allocator, e: model.EnumId) ![]const []const u8 {
    const r = story.items(e);
    const out = try arena.alloc([]const u8, r.len);
    for (out, 0..) |*o, k| o.* = story.item(r.start + @as(u32, @intCast(k))); // safe: validated to max_items
    return out;
}

fn factList(story: *const Story, arena: Allocator) ![]const FactDump {
    const out = try arena.alloc(FactDump, story.len(.facts));
    for (out, 0..) |*o, i| {
        const f = story.fact(.fromRaw(@intCast(i))); // safe: validated to max_facts
        o.* = .{ .name = f.name, .scope = story.scope(f.scope), .kind = f.kind, .role = f.role, .items = if (f.enumeration) |e| try itemNames(story, arena, e) else null };
    }
    return out;
}

fn castList(story: *const Story, arena: Allocator) ![]const CastDump {
    const out = try arena.alloc(CastDump, story.len(.cast));
    for (out, 0..) |*o, i| {
        const c = story.castMember(.fromRaw(@intCast(i))); // safe: validated below none16
        o.* = .{
            .name = if (c.extra) null else c.name,
            .display = try hex(arena, c.display.raw()),
            .relation = if (c.relation) |r| try hex(arena, r.raw()) else null,
            .extra = c.extra,
            .tags = try tagList(story, arena, c.tags),
        };
    }
    return out;
}

fn paramName(story: *const Story, arena: Allocator, p: model.Param) ![]const u8 {
    const e = p.enumeration orelse return @tagName(p.kind);
    const names = try itemNames(story, arena, e);
    return arena.print("{s}({s})", .{ @tagName(p.kind), try std.mem.join(arena, ", ", names) });
}

fn externList(story: *const Story, arena: Allocator) ![]const ExternDump {
    const out = try arena.alloc(ExternDump, story.len(.externs));
    for (out, 0..) |*o, i| {
        const x = story.externFn(.fromRaw(@intCast(i))); // safe: validated below none16
        const params = try arena.alloc([]const u8, x.params.len);
        for (params, 0..) |*p, k| p.* = try paramName(story, arena, story.param(x.params.start + @as(u32, @intCast(k)))); // safe: below a u32 length
        o.* = .{ .name = x.name, .params = params, .returns = if (x.returns) |r| try paramName(story, arena, r) else null, .action = x.action };
    }
    return out;
}

fn tagList(story: *const Story, arena: Allocator, r: Range) !?[]const TagDump {
    if (r.len == 0) return null;
    const out = try arena.alloc(TagDump, r.len);
    for (out, 0..) |*o, k| {
        const t = story.tag(r.start + @as(u32, @intCast(k))); // safe: below a u32 length
        const values = try arena.alloc([]const u8, t.values.len);
        for (values, 0..) |*v, j| v.* = story.tagValue(t.values.start + @as(u32, @intCast(j))).text; // safe: below a u32 length
        o.* = .{ .key = t.key, .values = values };
    }
    return out;
}

fn sectionList(story: *const Story, arena: Allocator) ![]const SectionDump {
    const out = try arena.alloc(SectionDump, story.len(.sections));
    for (out, 0..) |*o, i| {
        const s = story.section(.fromRaw(@intCast(i))); // safe: below a u32 count
        var candidates: ?[]CandidateDump = null;
        if (s.kind == .pool) {
            const list = try arena.alloc(CandidateDump, s.candidates.len);
            for (list, 0..) |*c, k| {
                const cand = story.candidate(s.candidates.start + @as(u32, @intCast(k))); // safe: below a u32 length
                c.* = .{ .name = cand.name, .when = try exprText(story, arena, cand.when), .specificity = cand.specificity, .entry = cand.entry.raw(), .tags = try tagList(story, arena, cand.tags) };
            }
            candidates = list;
        }
        o.* = .{
            .name = s.name,
            .kind = s.kind,
            .kind_name = if (s.kind == .other) s.kind_name else null,
            .pick = if (s.kind == .pool) s.pick else null,
            .entry = if (s.entry) |e| e.raw() else null,
            .visits = story.fact(s.visits).name,
            .tags = try tagList(story, arena, s.tags),
            .candidates = candidates,
        };
    }
    return out;
}

fn textDump(story: *const Story, arena: Allocator, id: model.TextId) !TextDump {
    const t = story.text(id);
    var slots: ?[]SlotDump = null;
    if (t.slots.len > 0) {
        const list = try arena.alloc(SlotDump, t.slots.len);
        for (list, 0..) |*o, k| {
            const s = story.slot(t.slots.start + @as(u32, @intCast(k))); // safe: below max_slots
            o.* = .{ .kind = s.kind, .expr = try exprText(story, arena, s.expr), .arity = s.arity, .state = if (s.state) |f| story.fact(f).name else null };
        }
        slots = list;
    }
    return .{ .line = try hex(arena, t.line.raw()), .slots = slots };
}

fn effectList(story: *const Story, arena: Allocator, r: Range) !?[]const EffectDump {
    if (r.len == 0) return null;
    const out = try arena.alloc(EffectDump, r.len);
    for (out, 0..) |*o, k| {
        o.* = switch (story.effect(r.start + @as(u32, @intCast(k)))) { // safe: below a u32 length
            .set => |e| .{ .kind = .set, .fact = story.fact(e.fact).name, .value = try exprText(story, arena, e.value) },
            .add => |e| .{ .kind = .add, .fact = story.fact(e.fact).name, .item = itemOf(story, e.fact, e.item) },
            .remove => |e| .{ .kind = .remove, .fact = story.fact(e.fact).name, .item = itemOf(story, e.fact, e.item) },
            .call => |e| .{ .kind = .call, .action = story.externFn(e.action).name, .args = try exprText(story, arena, e.args), .result = if (e.result) |f| story.fact(f).name else null },
            .change => |e| .{ .kind = .change, .fact = story.fact(e.fact).name, .value = try exprText(story, arena, e.by) },
        };
    }
    return out;
}

fn itemOf(story: *const Story, fact: facts.FactId, item: u8) []const u8 {
    const r = story.items(story.fact(fact).enumeration.?);
    return story.item(r.start + item);
}

fn nodeList(story: *const Story, arena: Allocator) ![]const NodeDump {
    const out = try arena.alloc(NodeDump, story.len(.nodes));
    for (out, 0..) |*o, i| {
        const n = story.node(.fromRaw(@intCast(i))); // safe: below a u32 count
        o.* = .{ .id = @intCast(i), .kind = n.step, .tags = try tagList(story, arena, n.tags) }; // safe: below a u32 count
        switch (n.step) {
            .line => |s| {
                o.text = try textDump(story, arena, s.text);
                o.speaker = if (s.speaker) |c| speakerName(story, c) else null;
                o.effects = try effectList(story, arena, s.effects);
                o.next = raw(s.next);
            },
            .choices => |s| {
                const list = try arena.alloc(ChoiceDump, s.choices.len);
                for (list, 0..) |*c, k| {
                    const ch = story.choice(s.choices.start + @as(u32, @intCast(k))); // safe: below max_choices
                    c.* = .{ .text = try textDump(story, arena, ch.text), .cond = try exprText(story, arena, ch.cond), .sticky = ch.sticky, .target = ch.target.raw(), .visits = story.fact(ch.visits).name, .tags = try tagList(story, arena, ch.tags) };
                }
                o.choices = list;
                o.next = raw(s.next);
            },
            .branch => |s| {
                o.cond = try exprText(story, arena, s.cond);
                o.then = raw(s.then);
                o.otherwise = raw(s.otherwise);
            },
            .gather => |s| {
                o.visits = if (s.visits) |f| story.fact(f).name else null;
                o.next = raw(s.next);
            },
            .effects => |s| {
                o.effects = try effectList(story, arena, s.effects);
                o.next = raw(s.next);
            },
            .jump => |s| o.section = story.section(s).name,
            .call => |s| {
                o.section = story.section(s.section).name;
                o.next = raw(s.next);
            },
            .ret, .end => {},
        }
    }
    return out;
}

fn raw(n: ?model.NodeId) ?u32 {
    return if (n) |x| x.raw() else null;
}

fn speakerName(story: *const Story, c: model.CastId) []const u8 {
    const member = story.castMember(c);
    return if (member.extra) "(extra)" else member.name;
}

/// A condition or a value in words, postfix: `carried 'play has`.
pub fn exprText(story: *const Story, arena: Allocator, r: Range) !?[]const u8 {
    if (r.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(arena);
    for (0..r.len) |k| {
        if (k > 0) try out.writer.writeByte(' ');
        const t = story.term(r.start + @as(u32, @intCast(k))); // safe: below a u32 length
        switch (t.op) {
            .fact => try out.writer.writeAll(story.fact(.fromRaw(@intCast(t.arg))).name), // safe: validated to max_facts
            .int => try out.writer.print("{d}", .{story.int(t.arg)}),
            .item => {
                const items = story.items(.fromRaw(t.itemEnum()));
                try out.writer.print("'{s}", .{story.item(items.start + t.itemIndex())});
            },
            .text => try strand.json.write(&out.writer, story.literal(t.arg), .{}),
            .builtin => {
                const c = story.builtin(t.arg);
                try out.writer.print("{s}.{s}/{d}", .{ c.kind, c.name, c.args.len });
            },
            .thing => {
                const th = story.thing(t.arg);
                try out.writer.print("@{s}:{s}", .{ th.kind, th.id });
            },
            .query => {
                const x = story.externFn(.fromRaw(@intCast(t.arg))); // safe: validated below none16
                try out.writer.print("{s}/{d}", .{ x.name, x.params.len });
            },
            else => try out.writer.writeAll(@tagName(t.op)),
        }
    }
    return out.written();
}

test "a story's dump names what its ids point at" {
    const gpa = std.testing.allocator;
    var built = try @import("testing.zig").kitchen(gpa);
    defer built.deinit(gpa);
    const story: Story = try .init(built.graph, .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(&story, arena.allocator(), &out.writer);
    const text = out.written();
    try std.testing.expect(std.mem.find(u8, text, "\"cond\": \"carried 'play has\"") != null);
    try std.testing.expect(std.mem.find(u8, text, "\"cond\": \"'go lived/1 not\"") != null);
    try std.testing.expect(std.mem.find(u8, text, "\"section\": \"fork_1985\"") != null);
    try std.testing.expect(std.mem.find(u8, text, "\"visits\": \"visits:kitchen_1985.ask\"") != null);
}
