//! Between the graph's values and its records: what the builder writes and
//! the reader gives back, field by field. Decoding assumes a record the
//! reader has validated.

const format = @import("format.zig");
const model = @import("model.zig");

const none = format.none;
const none16 = format.none16;

pub fn optional(comptime Id: type, raw: anytype) ?Id {
    const absent = if (@TypeOf(raw) == u16) none16 else none;
    return if (raw == absent) null else .fromRaw(raw);
}

pub fn raw32(id: anytype) u32 {
    return if (id) |x| x.raw() else none;
}

pub fn raw16(id: anytype) u16 {
    return if (id) |x| x.raw() else none16;
}

pub fn encodeNode(n: model.Node) format.Node {
    var r: format.Node = .{ .tags = n.tags, .a = 0, .b = 0, .c = 0, .d = 0, .next = none, .speaker = none16, .kind = @backingInt(@as(format.NodeKind, n.step)) };
    switch (n.step) {
        .line => |s| {
            r.a = s.text.raw();
            r.b = s.effects.start;
            r.c = s.effects.len;
            r.speaker = raw16(s.speaker);
            r.next = raw32(s.next);
        },
        .choices => |s| {
            r.a = s.choices.start;
            r.b = s.choices.len;
            r.next = raw32(s.next);
        },
        .branch => |s| {
            r.a = s.cond.start;
            r.b = s.cond.len;
            r.c = raw32(s.then);
            r.d = raw32(s.otherwise);
        },
        .gather => |s| {
            r.a = raw16(s.visits);
            r.next = raw32(s.next);
        },
        .effects => |s| {
            r.a = s.effects.start;
            r.b = s.effects.len;
            r.next = raw32(s.next);
        },
        .jump => |s| r.a = s.raw(),
        .call => |s| {
            r.a = s.section.raw();
            r.next = raw32(s.next);
        },
        .ret, .end => {},
    }
    return r;
}

pub fn decodeNode(r: format.Node) model.Node {
    const next = optional(model.NodeId, r.next);
    const kind: format.NodeKind = @fromBackingInt(r.kind);
    return .{
        .tags = r.tags,
        .step = switch (kind) {
            .line => .{ .line = .{ .text = .fromRaw(r.a), .speaker = optional(model.CastId, r.speaker), .effects = .{ .start = r.b, .len = r.c }, .next = next } },
            .choices => .{ .choices = .{ .choices = .{ .start = r.a, .len = r.b }, .next = next } },
            .branch => .{ .branch = .{ .cond = .{ .start = r.a, .len = r.b }, .then = optional(model.NodeId, r.c), .otherwise = optional(model.NodeId, r.d) } },
            .gather => .{ .gather = .{ .visits = optional(model.FactId, @as(u16, @intCast(r.a))), .next = next } }, // safe: validated to a u16
            .effects => .{ .effects = .{ .effects = .{ .start = r.a, .len = r.b }, .next = next } },
            .jump => .{ .jump = .fromRaw(r.a) },
            .call => .{ .call = .{ .section = .fromRaw(r.a), .next = next } },
            .ret => .ret,
            .end => .end,
        },
    };
}

pub fn encodeEffect(e: model.Effect) format.Effect {
    var r: format.Effect = .{ .expr = .empty, .fact = none16, .item = 0, .action = none16, .result = none16, .kind = @backingInt(@as(format.EffectKind, e)) };
    switch (e) {
        .set => |s| {
            r.fact = s.fact.raw();
            r.expr = s.value;
        },
        .add, .remove => |s| {
            r.fact = s.fact.raw();
            r.item = s.item;
        },
        .call => |s| {
            r.action = s.action.raw();
            r.expr = s.args;
            r.result = raw16(s.result);
        },
    }
    return r;
}

pub fn decodeEffect(r: format.Effect) model.Effect {
    const kind: format.EffectKind = @fromBackingInt(r.kind);
    return switch (kind) {
        .set => .{ .set = .{ .fact = .fromRaw(r.fact), .value = r.expr } },
        .add => .{ .add = .{ .fact = .fromRaw(r.fact), .item = @intCast(r.item) } }, // safe: validated below max_items
        .remove => .{ .remove = .{ .fact = .fromRaw(r.fact), .item = @intCast(r.item) } }, // safe: validated below max_items
        .call => .{ .call = .{ .action = .fromRaw(r.action), .args = r.expr, .result = optional(model.FactId, r.result) } },
    };
}
