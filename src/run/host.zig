//! The host's vocabulary at run time, bound by name when a session is made.
//!
//! A compiled story names its externs and their signatures. A host binds an
//! implementation to each by name, once, and the bind is checked: every
//! extern bound, each with the story's signature, or a named error and the
//! list of what is unbound or mismatched. At run time a call is an index
//! into the bound table, never a lookup by name.
//!
//! A Zig host binds a struct of functions with `Host.bind`: each field is
//! named for an extern, and its function takes the host's own pointer, the
//! call's `Context`, then the extern's parameters. A host in another
//! language binds through `Binder`, a function pointer and user data per
//! name, over the same table.
//!
//! A query is pure, so the executor may ask it at any time and as often as
//! a condition needs. An action is never called by the executor: it is
//! emitted in a step, and the host performs it, through `perform` if it
//! likes. Things of the host's a story names by text (`wolf_pelt`) are
//! resolved to the host's handles once, at load, by `resolve`.

const std = @import("std");
const facts = @import("../facts.zig");
const story = @import("../story.zig");

const Value = facts.Value;
const Kind = facts.Kind;

pub const QueryError = error{
    /// The host could not answer, or refuses the arguments.
    QueryFailed,
};

/// Whose facts a call is about, and where it was asked.
/// The flow a context names when no flow made the call: a rule's, a watched condition's.
pub const no_flow: u8 = std.math.maxInt(u8);

pub const Context = struct {
    /// The flow the call came from, by its place in the session, or `no_flow`.
    flow: u8,
    /// The host's handle for whose facts each scope holds (a player, a region), by scope; 0 if the host gave none.
    owners: *const [facts.max_scopes]u64,
    /// The thing the evaluation is for, where a section kept per thing is evaluated for one (a quest's instance);
    /// `facts.Value.no_ref` where none is.
    this: u64 = facts.Value.no_ref,

    pub fn owner(cx: Context, scope: facts.ScopeId) u64 {
        return cx.owners[scope.raw()];
    }
};

/// An extern's implementation, type-erased: the host's data, then the call's context and arguments.
pub const Fn = *const fn (user: ?*anyopaque, cx: Context, args: []const Value) QueryError!Value;

pub const Entry = struct { call: Fn, user: ?*anyopaque };

/// What an implementation takes and gives, in facts' kinds; a null return is an action with no outcome.
pub const Signature = struct { params: []const Kind, returns: ?Kind };

pub const Problem = struct {
    /// The extern's name in the story, or the thing's text id for a ref.
    name: []const u8,
    why: enum { unbound, mismatched, unknown_ref },
};

pub const BindError = error{
    OutOfMemory,
    /// An extern the story declares has no implementation.
    UnboundExtern,
    /// An implementation whose parameters or return are not the story's.
    MismatchedExtern,
    /// A thing the story names that the host does not know.
    UnknownRef,
};

/// A host's thing, as a story names it: its kind and its text id.
pub const RefName = struct { kind: []const u8, id: []const u8 };

/// The host's handle for a thing, or null if it knows none by that id.
pub const Resolver = struct {
    user: ?*anyopaque,
    resolve: *const fn (user: ?*anyopaque, kind: []const u8, id: []const u8) ?u64,
};

pub const Host = struct {
    /// The hash of the story the host is bound to.
    story: u64,
    /// By extern id.
    entries: []const Entry,
    /// The handles of the things the story names, by their place in its list.
    refs: []const u64 = &.{},
    /// Owns `entries` and `refs`; null for `none`.
    gpa: ?std.mem.Allocator = null,

    /// A host with nothing bound, for a story that declares no externs.
    pub const none: Host = .{ .story = 0, .entries = &.{} };

    pub fn deinit(h: *Host) void {
        const gpa = h.gpa orelse return;
        gpa.free(h.entries);
        gpa.free(h.refs);
        h.* = undefined;
    }

    /// Whether the host serves `s`: bound to it with every thing it names resolved, or `none` for a
    /// story that declares no externs and names no things.
    pub fn serves(h: *const Host, s: *const story.Story) bool {
        if (s.len(.externs) == 0 and s.len(.things) == 0) return true;
        return h.story == s.hash() and h.entries.len == s.len(.externs) and h.refs.len == s.len(.things);
    }

    pub fn query(h: *const Host, id: facts.ExternId, cx: Context, args: []const Value) QueryError!Value {
        const e = h.entries[id.raw()];
        return e.call(e.user, cx, args);
    }

    /// Performs an action a step handed over, through its binding: its outcome, if the story declared one.
    pub fn perform(h: *const Host, call: facts.Call, cx: Context) QueryError!?Value {
        const v = try h.query(call.action, cx, call.args);
        return if (call.result == null) null else v;
    }

    /// Binds each field of `impls` to the extern of its name in `s`, with `user` as the first argument
    /// of each. Every extern must be bound with its signature; what is not goes to `problems`.
    pub fn bind(gpa: std.mem.Allocator, s: *const story.Story, user: anytype, comptime impls: anytype, problems: ?*std.ArrayList(Problem)) BindError!Host {
        var b: Binder = try .init(gpa, s);
        defer b.deinit();
        const names = @typeInfo(@TypeOf(impls)).@"struct".field_names;
        inline for (names) |name| {
            const f = @field(impls, name);
            const T = @TypeOf(user);
            const entry: Entry = .{ .call = thunk(f), .user = @ptrCast(user) }; // safe: the host's pointer, cast back by its thunk
            if (try b.set(name, comptime signatureOf(@TypeOf(f), T), entry) == .mismatched) {
                try note(gpa, problems, b.nameOf(name), .mismatched);
            }
        }
        return b.finish(problems);
    }

    /// Resolves every thing `s` names to the host's handle, once, at load: the step after `bind`.
    pub fn resolveStory(h: *Host, gpa: std.mem.Allocator, s: *const story.Story, resolver: Resolver, problems: ?*std.ArrayList(Problem)) BindError!void {
        const names = try gpa.alloc(RefName, s.len(.things));
        defer gpa.free(names);
        for (names, 0..) |*n, i| {
            const t = s.thing(@intCast(i)); // safe: below a u32 count
            n.* = .{ .kind = t.kind, .id = t.id };
        }
        try h.resolve(gpa, names, resolver, problems);
        // a story with things and no externs is served by a host bound to nothing else
        if (h.entries.len == 0) h.story = s.hash();
    }

    /// Resolves each thing the story names to the host's handle, once, at load.
    pub fn resolve(h: *Host, gpa: std.mem.Allocator, names: []const RefName, resolver: Resolver, problems: ?*std.ArrayList(Problem)) BindError!void {
        const refs = try gpa.alloc(u64, names.len);
        errdefer gpa.free(refs);
        var unknown = false;
        for (refs, names) |*r, n| {
            r.* = resolver.resolve(resolver.user, n.kind, n.id) orelse blk: {
                unknown = true;
                try note(gpa, problems, n.id, .unknown_ref);
                break :blk 0;
            };
        }
        if (unknown) return error.UnknownRef;
        if (h.gpa) |owner| owner.free(h.refs);
        h.refs = refs;
        h.gpa = h.gpa orelse gpa;
    }
};

/// The host's handles and the ids a story names its things by, for saving refs by name: what
/// `facts.snapshot.writeNamed` and `readNamed` take. It and what it borrows outlive the names it gives.
pub const RefLookup = struct {
    story: *const story.Story,
    host: *const Host,

    pub fn names(l: *const RefLookup) facts.RefNames {
        return .{ .user = @ptrCast(@constCast(l)), .idOf = idOf, .handleOf = handleOf }; // safe: read back as a *const RefLookup
    }

    fn idOf(user: ?*anyopaque, kind: []const u8, handle: u64) ?[]const u8 {
        const l: *const RefLookup = @ptrCast(@alignCast(user)); // safe: made by `names`
        for (l.host.refs, 0..) |h, i| {
            if (h != handle) continue;
            const t = l.story.thing(@intCast(i)); // safe: refs are one per thing
            if (std.mem.eql(u8, t.kind, kind)) return t.id;
        }
        return null;
    }

    fn handleOf(user: ?*anyopaque, kind: []const u8, id: []const u8) ?u64 {
        const l: *const RefLookup = @ptrCast(@alignCast(user)); // safe: made by `names`
        for (0..l.host.refs.len) |i| {
            const t = l.story.thing(@intCast(i)); // safe: refs are one per thing
            if (std.mem.eql(u8, t.kind, kind) and std.mem.eql(u8, t.id, id)) return l.host.refs[i];
        }
        return null;
    }
};

/// Binds implementations by name, one at a time: the path a host outside Zig takes.
pub const Binder = struct {
    gpa: std.mem.Allocator,
    story: *const story.Story,
    entries: []?Entry,
    /// By extern id: a binding was offered with another signature.
    mismatched: []bool,

    pub fn init(gpa: std.mem.Allocator, s: *const story.Story) error{OutOfMemory}!Binder {
        const entries = try gpa.alloc(?Entry, s.len(.externs));
        errdefer gpa.free(entries);
        const mismatched = try gpa.alloc(bool, s.len(.externs));
        @memset(entries, null);
        @memset(mismatched, false);
        return .{ .gpa = gpa, .story = s, .entries = entries, .mismatched = mismatched };
    }

    pub fn deinit(b: *Binder) void {
        b.gpa.free(b.entries);
        b.gpa.free(b.mismatched);
        b.* = undefined;
    }

    pub const Set = enum { bound, mismatched, not_in_story };

    /// Binds `entry` to the extern named `name` if `sig` is its signature. A name the
    /// story does not declare is left alone: a host may serve several stories.
    pub fn set(b: *Binder, name: []const u8, sig: Signature, entry: Entry) error{OutOfMemory}!Set {
        const id = b.find(name) orelse return .not_in_story;
        if (!fits(b.story, id, sig)) {
            b.mismatched[id] = true;
            return .mismatched;
        }
        b.entries[id] = entry;
        return .bound;
    }

    /// The bound table, if every extern is bound with its signature; what is not goes to `problems`.
    pub fn finish(b: *Binder, problems: ?*std.ArrayList(Problem)) BindError!Host {
        var unbound = false;
        var mismatched = false;
        for (b.entries, b.mismatched, 0..) |e, wrong, i| {
            if (e != null) continue;
            if (wrong) mismatched = true else unbound = true;
            if (!wrong) try note(b.gpa, problems, b.story.externFn(.fromRaw(@intCast(i))).name, .unbound); // safe: below none16
        }
        if (mismatched) return error.MismatchedExtern;
        if (unbound) return error.UnboundExtern;
        const entries = try b.gpa.alloc(Entry, b.entries.len);
        for (entries, b.entries) |*to, from| to.* = from.?;
        return .{ .story = b.story.hash(), .entries = entries, .gpa = b.gpa };
    }

    fn find(b: *const Binder, name: []const u8) ?usize {
        for (0..b.story.len(.externs)) |i| {
            if (std.mem.eql(u8, b.story.externFn(.fromRaw(@intCast(i))).name, name)) return i; // safe: below none16
        }
        return null;
    }

    // The story's spelling of a name a binding gave, for a problem's report.
    fn nameOf(b: *const Binder, name: []const u8) []const u8 {
        const id = b.find(name) orelse return name;
        return b.story.externFn(.fromRaw(@intCast(id))).name; // safe: below none16
    }
};

fn note(gpa: std.mem.Allocator, problems: ?*std.ArrayList(Problem), name: []const u8, why: @FieldType(Problem, "why")) error{OutOfMemory}!void {
    if (problems) |p| try p.append(gpa, .{ .name = name, .why = why });
}

fn fits(s: *const story.Story, id: usize, sig: Signature) bool {
    const x = s.externFn(.fromRaw(@intCast(id))); // safe: below none16
    if (x.params.len != sig.params.len) return false;
    for (sig.params, 0..) |k, i| if (s.param(x.params.start + @as(u32, @intCast(i))).kind != k) return false; // safe: below a u32 length
    const ret: ?Kind = if (x.returns) |r| r.kind else null;
    return ret == sig.returns;
}

// ------------------------------------------------------------ Zig functions, reflected

/// The kind a Zig type carries across a binding.
fn kindOf(comptime T: type) Kind {
    return switch (T) {
        bool => .boolean,
        i64 => .int,
        // A `one of`: the item's index, or `Value.none`.
        u16 => .one_of,
        facts.Set => .set_of,
        []const u8 => .text,
        // A `ref`: the host's handle.
        u64 => .ref,
        else => @compileError("an extern's value is bool, i64, u16 (a one of), facts.Set, []const u8 or u64 (a ref), not " ++ @typeName(T)),
    };
}

fn Returned(comptime F: type) type {
    const R = @typeInfo(F).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |e| e.payload,
        else => R,
    };
}

fn signatureOf(comptime F: type, comptime User: type) Signature {
    const params = @typeInfo(F).@"fn".param_types;
    if (params.len < 2 or params[0].? != User or params[1].? != Context) {
        @compileError("an extern's implementation takes the host's pointer and a run.Context first");
    }
    var kinds: [params.len - 2]Kind = undefined;
    for (params[2..], &kinds) |p, *k| k.* = kindOf(p.?);
    const final = kinds;
    const R = Returned(F);
    return .{ .params = &final, .returns = if (R == void) null else kindOf(R) };
}

fn thunk(comptime f: anytype) Fn {
    const F = @TypeOf(f);
    return struct {
        fn call(user: ?*anyopaque, cx: Context, args: []const Value) QueryError!Value {
            var tuple: std.meta.ArgsTuple(F) = undefined;
            tuple[0] = @ptrCast(@alignCast(user)); // safe: bound from the host's pointer by `bind`
            tuple[1] = cx;
            inline for (2..@typeInfo(F).@"fn".param_types.len) |i| tuple[i] = unwrap(@TypeOf(tuple[i]), args[i - 2]);
            const R = Returned(F);
            const result = @call(.auto, f, tuple);
            const v: R = if (@typeInfo(@typeInfo(F).@"fn".return_type.?) == .error_union) result catch return error.QueryFailed else result;
            return if (R == void) .{ .boolean = false } else wrap(v);
        }
    }.call;
}

fn unwrap(comptime T: type, v: Value) T {
    return switch (comptime kindOf(T)) {
        .boolean => v.boolean,
        .int => v.int,
        .one_of => v.one_of,
        .set_of => v.set_of,
        .text => v.text,
        .ref => v.ref,
    };
}

fn wrap(v: anytype) Value {
    return switch (comptime kindOf(@TypeOf(v))) {
        .boolean => .{ .boolean = v },
        .int => .{ .int = v },
        .one_of => .{ .one_of = v },
        .set_of => .{ .set_of = v },
        .text => .{ .text = v },
        .ref => .{ .ref = v },
    };
}
