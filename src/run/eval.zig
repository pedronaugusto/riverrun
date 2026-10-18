//! Conditions, values and arguments: postfix terms over the facts, evaluated
//! by one loop on a small stack. There are no jumps: a term pushes or
//! combines, so evaluation always ends, and `and` and `or` evaluate both
//! sides, which is sound because queries are pure. The reader has typed
//! every range for its place; what is checked here is only what the host
//! answers.

const std = @import("std");
const facts = @import("../facts.zig");
const story = @import("../story.zig");
const host_ = @import("host.zig");

const Value = facts.Value;
const Term = story.Term;
const Range = story.Range;

pub const Error = error{
    OutOfMemory,
    QueryFailed,
    /// A query answered with a value not of the kind the story declared.
    QueryWrongKind,
    /// A builtin of a registered kind, evaluated where no package answers it.
    NoBuiltins,
    /// The package could not answer its builtin, or answered with the wrong kind.
    BuiltinFailed,
    /// A fact kept per thing written for a key that holds no thing or no value.
    NoKey,
};

/// What answers the builtins registered kinds add (cairn's `since`): the package that owns them.
pub const Builtins = struct {
    user: ?*anyopaque,
    /// The answer to the call `index` of the story's `builtins`, whose arguments it reads from the story.
    call: *const fn (user: ?*anyopaque, s: *const story.Story, index: u32, cx: host_.Context) error{BuiltinFailed}!Value,
};

/// What a language says that riverrun cannot know: an int's plural category in the string table's language, and
/// a thing's grammatical gender. With none given, plurals are English's (`one` for 1, `other` else) and every
/// thing's gender is `other`.
pub const Language = struct {
    user: ?*anyopaque = null,
    /// The CLDR plural category of `n` in `locale` (a BCP 47 tag): `zero`, `one`, `two`, `few`, `many` or `other`.
    plural: ?*const fn (user: ?*anyopaque, locale: []const u8, n: i64) []const u8 = null,
    /// The grammatical gender of the thing `handle`, as the host knows it: `masculine`, `feminine`, `neuter` or `other`.
    gender: ?*const fn (user: ?*anyopaque, handle: u64) []const u8 = null,

    pub fn pluralOf(l: Language, locale: []const u8, n: i64) []const u8 {
        if (l.plural) |f| return f(l.user, locale, n);
        return if (n == 1) "one" else "other";
    }

    pub fn genderOf(l: Language, handle: u64) []const u8 {
        if (l.gender) |f| return f(l.user, handle);
        return "other";
    }
};

/// What evaluation reads: the story's terms, the facts, the host's queries
/// and the context they are asked in, and where a query's text answer is
/// copied so it outlives the next answer.
pub const Context = struct {
    story: *const story.Story,
    store: facts.Store,
    host: *const host_.Host,
    call: host_.Context,
    arena: std.mem.Allocator,
    builtins: ?Builtins = null,
    language: Language = .{},
};

pub fn condition(cx: Context, r: Range) Error!bool {
    if (r.len == 0) return true;
    return (try value(cx, r)).boolean;
}

pub fn value(cx: Context, r: Range) Error!Value {
    var stack: [story.max_stack]Value = undefined;
    const n = try run(cx, r, &stack);
    std.debug.assert(n == 1);
    return stack[0];
}

/// A call's arguments, in order, copied into `cx.arena`.
pub fn arguments(cx: Context, r: Range) Error![]Value {
    var stack: [story.max_stack]Value = undefined;
    const n = try run(cx, r, &stack);
    const out = try cx.arena.alloc(Value, n);
    for (out, stack[0..n]) |*o, v| o.* = try own(cx.arena, v);
    return out;
}

/// `v` with its text copied into `arena`, so it outlives the fact or answer it came from.
pub fn own(arena: std.mem.Allocator, v: Value) error{OutOfMemory}!Value {
    return if (v == .text) .{ .text = try arena.dupe(u8, v.text) } else v;
}

/// A compiled effect as the host receives it, its values worked out now; an action's arguments are copied into
/// `cx.arena`.
pub fn effect(cx: Context, e: story.Effect) Error!facts.Effect {
    return switch (e) {
        .set => |x| if (cx.story.fact(x.fact).key == .none)
            .{ .set = .{ .fact = x.fact, .value = try own(cx.arena, try value(cx, x.value)) } }
        else blk: {
            const kv = try arguments(cx, x.value);
            break :blk .{ .set = .{ .fact = x.fact, .key = keyOf(kv[0]) orelse return error.NoKey, .value = kv[1] } };
        },
        .add, .remove => |x| blk: {
            const key: ?facts.Key = if (x.key.len == 0) null else keyOf(try value(cx, x.key)) orelse return error.NoKey;
            const item: facts.Effect.Item = .{ .fact = x.fact, .key = key, .item = x.item };
            break :blk if (e == .add) .{ .add = item } else .{ .remove = item };
        },
        .change => |x| if (cx.story.fact(x.fact).key == .none)
            .{ .change = .{ .fact = x.fact, .by = (try value(cx, x.by)).int } }
        else blk: {
            const kv = try arguments(cx, x.by);
            break :blk .{ .change = .{ .fact = x.fact, .key = keyOf(kv[0]) orelse return error.NoKey, .by = kv[1].int } };
        },
        .call => |x| .{ .call = .{ .action = x.action, .args = try arguments(cx, x.args), .result = x.result } },
    };
}

/// A value as the key of a fact kept per thing: a thing's handle, an item's index; null for none.
pub fn keyOf(v: Value) ?facts.Key {
    return switch (v) {
        .ref => |r| if (r == Value.no_ref) null else r,
        .one_of => |i| if (i == Value.none) null else i,
        else => null,
    };
}

/// The enumeration of the value `r` leaves, for writing a `one of` or a set by name.
pub fn enumeration(s: *const story.Story, r: Range) ?story.EnumId {
    if (r.len == 0) return null;
    const t = s.term(r.start + r.len - 1);
    return switch (t.op) {
        .fact, .keyed => s.fact(.fromRaw(@intCast(t.arg))).enumeration, // safe: validated to a fact id
        .item => .fromRaw(t.itemEnum()),
        .query => if (s.externFn(.fromRaw(@intCast(t.arg))).returns) |ret| ret.enumeration else null, // safe: validated to an extern id
        else => null,
    };
}

fn run(cx: Context, r: Range, stack: *[story.max_stack]Value) Error!usize {
    var n: usize = 0;
    for (0..r.len) |k| {
        const t = cx.story.term(r.start + @as(u32, @intCast(k))); // safe: below a u32 length
        switch (t.op) {
            .fact => push(stack, &n, cx.store.get(.fromRaw(@intCast(t.arg)))), // safe: validated to a fact id
            .int => push(stack, &n, .{ .int = cx.story.int(t.arg) }),
            .item => push(stack, &n, .{ .one_of = t.itemIndex() }),
            .text => push(stack, &n, .{ .text = cx.story.literal(t.arg) }),
            .thing => push(stack, &n, .{ .ref = cx.host.refs[t.arg] }),
            .builtin => {
                const b = cx.builtins orelse return error.NoBuiltins;
                const v = try b.call(b.user, cx.story, t.arg, cx.call);
                if (@as(facts.Kind, v) != cx.story.builtin(t.arg).returns) return error.BuiltinFailed;
                push(stack, &n, v);
            },
            .keyed => {
                const f: facts.FactId = .fromRaw(@intCast(t.arg)); // safe: validated to a fact id
                stack[n - 1] = if (keyOf(stack[n - 1])) |key| cx.store.getKey(f, key) else .initial(cx.story.fact(f).kind);
            },
            .happened => {
                const f = cx.story.fact(.fromRaw(@intCast(t.arg))); // safe: validated to a fact id
                push(stack, &n, .{ .boolean = !cx.store.get(.fromRaw(@intCast(t.arg))).eql(.initial(f.kind)) }); // safe: validated to a fact id
            },
            .since_changed => {
                const w = cx.story.change(t.arg);
                push(stack, &n, .{ .int = cx.store.get(w.clock).int -| cx.store.get(w.at).int });
            },
            .true => push(stack, &n, .{ .boolean = true }),
            .false => push(stack, &n, .{ .boolean = false }),
            .not => stack[n - 1] = .{ .boolean = !stack[n - 1].boolean },
            .query => try query(cx, t, stack, &n),
            else => {
                const a = stack[n - 2];
                const b = stack[n - 1];
                n -= 1;
                stack[n - 1] = .{ .boolean = binary(t.op, a, b) };
            },
        }
    }
    return n;
}

fn push(stack: *[story.max_stack]Value, n: *usize, v: Value) void {
    stack[n.*] = v;
    n.* += 1;
}

fn binary(op: Term.Op, a: Value, b: Value) bool {
    return switch (op) {
        .eq => same(a, b),
        .ne => !same(a, b),
        .has => holds(a, b),
        .hasnt => !holds(a, b),
        .@"and" => a.boolean and b.boolean,
        .@"or" => a.boolean or b.boolean,
        .lt => a.int < b.int,
        .le => a.int <= b.int,
        .gt => a.int > b.int,
        .ge => a.int >= b.int,
        else => unreachable, // unreachable: the other ops push or take one value, handled by `run`
    };
}

// Whether a set holds an item; an item that is none is held by no set.
fn holds(set: Value, item: Value) bool {
    return item.one_of < facts.max_items and set.set_of.isSet(item.one_of);
}

// Equality, where a `one of` or a `ref` that holds nothing equals nothing.
fn same(a: Value, b: Value) bool {
    if (a == .one_of and (a.one_of == Value.none or b.one_of == Value.none)) return false;
    if (a == .ref and (a.ref == Value.no_ref or b.ref == Value.no_ref)) return false;
    return a.eql(b);
}

fn query(cx: Context, t: Term, stack: *[story.max_stack]Value, n: *usize) Error!void {
    const id: facts.ExternId = .fromRaw(@intCast(t.arg)); // safe: validated to an extern id
    const x = cx.story.externFn(id);
    const args = stack[n.* - x.params.len .. n.*];
    const answer = try own(cx.arena, try cx.host.query(id, cx.call, args));
    const ret = x.returns.?; // a query returns a value: validated
    if (@as(facts.Kind, answer) != ret.kind) return error.QueryWrongKind;
    if (ret.enumeration) |e| {
        const items = cx.story.items(e).len;
        const fits = switch (answer) {
            .one_of => |i| i == Value.none or i < items,
            .set_of => |set| if (set.findLastSet()) |last| last < items else true,
            else => true,
        };
        if (!fits) return error.QueryWrongKind;
    }
    if (answer == .text and answer.text.len > facts.max_text) return error.QueryWrongKind;
    n.* -= x.params.len;
    push(stack, n, answer);
}
