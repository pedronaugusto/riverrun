//! Tags held to the host's schema. A value typed as a section is resolved,
//! and is an edge for reachability: a section only a mechanic leads to is
//! still reached. A key that `leads` hands a section's end to the host,
//! which goes on to the section the tag names. A value a package judges is
//! handed to its judge, with where the tag stands. What is wrong with a
//! value is said where the value is written; a wrong count, at the key.

const std = @import("std");
const syntax = @import("../syntax.zig");
const sym = @import("symbols.zig");
const Checker = @import("Checker.zig");
const schema_file = @import("schema.zig");

const ast = syntax.ast;
const Error = Checker.Error;
const Schema = Checker.Schema;
const id_key = schema_file.id_key;

/// Checks the tags at one place. `from` is the section they are in, for edges, and `part` its part they are in;
/// null for the cast, and for a section's own body.
pub fn check(c: *Checker, module: sym.ModuleId, from: ?sym.SectionId, part: ?u16, tags: []const ast.Tag, at: Schema.Place) Error!void {
    const where: Where = .{ .module = module, .section = from, .part = part, .beside = tags, .place = at };
    for (tags, 0..) |*tag, i| {
        // a key stands once where it is, every value in its one bracket: so each of its values has one place, and
        // words a player reads one line id
        if (firstOf(tags[0..i], tag.key.text)) |first| {
            try c.err(tag.key.span, "`{s}` is already given here, at {f}: write all its values in that one bracket", .{ tag.key.text, c.place(first.key.span) });
            continue;
        }
        if (std.mem.eql(u8, tag.key.text, id_key)) {
            if (at != .line and at != .choice) try c.err(tag.key.span, "only a line or a choice has an `id`", .{});
            continue;
        }
        if (std.mem.eql(u8, tag.key.text, schema_file.weight_key) or std.mem.eql(u8, tag.key.text, schema_file.migrate_key)) {
            try own(c, from, tag, at);
            continue;
        }
        if (at == .cast and std.mem.eql(u8, tag.key.text, schema_file.gender_key)) {
            const g = if (tag.values.len == 1) tag.values[0] else "";
            if (!within(&@import("riverrun").story.template.gender_categories, g)) {
                try c.err(tag.key.span, "a gender is one of masculine, feminine, neuter or other", .{});
            }
            continue;
        }
        if (from) |s| if (c.kindOfSection(s)) |kind| if (kind.schema) |ks| switch (ks.find(tag.key.text, at)) {
            // a registered kind's own keys are checked by its schema; the rest fall to the host's
            .found => |k| {
                try values(c, where, tag, k);
                continue;
            },
            .elsewhere => {
                try c.err(tag.key.span, "`{s}` is not a tag of a {s} in a `({s})`", .{ tag.key.text, placeName(at), kind.name });
                continue;
            },
            .unknown => {},
        };
        const schema = c.options.schema orelse {
            _ = try notAction(c, module, tag);
            continue;
        };
        const key = switch (schema.find(tag.key.text, at)) {
            .found => |k| k,
            .elsewhere => {
                try c.err(tag.key.span, "`{s}` is not a tag of a {s}", .{ tag.key.text, placeName(at) });
                continue;
            },
            .unknown => {
                if (!try notAction(c, module, tag)) try c.err(tag.key.span, "`{s}` is not a tag the host knows", .{tag.key.text});
                continue;
            },
        };
        try values(c, where, tag, key);
    }
}

fn firstOf(before: []const ast.Tag, key: []const u8) ?*const ast.Tag {
    for (before) |*t| if (std.mem.eql(u8, t.key.text, key)) return t;
    return null;
}

// A tag whose key names an action, `[cutscene x]` for `[cutscene(x)]`, refused with the form that runs it; false
// when its key names none.
fn notAction(c: *Checker, module: sym.ModuleId, tag: *const ast.Tag) Error!bool {
    if (!c.isAction(module, tag.key.text)) return false;
    try c.err(tag.key.span, "`{s}` is an action, not a tag: run it with `[{s}(…)]`", .{ tag.key.text, tag.key.text });
    return true;
}

// Where a tag stands, as a judge is told.
const Where = struct {
    module: sym.ModuleId,
    section: ?sym.SectionId,
    part: ?u16,
    beside: []const ast.Tag,
    place: Schema.Place,
};

fn placeName(at: Schema.Place) []const u8 {
    return switch (at) {
        .cast => "cast entry",
        .section => "section",
        .part => "part",
        .line => "line",
        .choice => "choice",
    };
}

// riverrun's own keys of a part: a pool candidate's `weight`, a rule's `migrate`, each one whole number.
fn own(c: *Checker, from: ?sym.SectionId, tag: *const ast.Tag, at: Schema.Place) Error!void {
    const weight = std.mem.eql(u8, tag.key.text, schema_file.weight_key);
    const kind: ?sym.Section.Kind = if (from) |s| c.section(s).kind else null;
    const fits = at == .part and kind != null and (if (weight) kind.? == .pool else kind.? == .rules);
    if (!fits) return c.err(tag.key.span, "`{s}` is riverrun's, and belongs on {s}", .{ tag.key.text, if (weight) "a pool's candidate" else "a rule" });
    const n = if (tag.values.len == 1) std.fmt.parseInt(u32, tag.values[0], 10) catch null else null;
    if (n == null or n.? == 0 or (weight and n.? > std.math.maxInt(u16))) {
        return c.err(tag.key.span, "`{s}` takes one whole number above 0{s}", .{ tag.key.text, if (weight) ", at most 65535" else "" });
    }
    if (!weight and n.? > c.version) {
        return c.err(tag.key.span, "a migration to version {d} needs a story of that version: declare `version: {d}`", .{ n.?, n.? });
    }
}

// Whether the tag has as many values as its key takes, else says how many it takes.
fn count(c: *Checker, tag: *const ast.Tag, key: *const Schema.Key) Error!bool {
    const n = tag.values.len;
    if (key.value == .none) {
        if (n > 0) try c.err(tag.key.span, "`{s}` is a mark and takes no value", .{key.name});
        return n == 0;
    }
    switch (key.count) {
        .one => if (n != 1) try c.err(tag.key.span, "`{s}` takes one value, not {d}", .{ key.name, n }) else return true,
        .many => if (n == 0) try c.err(tag.key.span, "`{s}` takes at least one value", .{key.name}) else return true,
        .any => return true,
    }
    return false;
}

fn values(c: *Checker, where: Where, tag: *const ast.Tag, key: *const Schema.Key) Error!void {
    if (!try count(c, tag, key)) return;
    if (key.value == .judge) return key.value.judge(c, .{ .tag = tag, .beside = where.beside, .section = where.section, .part = where.part, .place = where.place, .module = where.module });
    const module = where.module;
    const from = where.section;
    const at = where.place;
    var sections: std.ArrayList(sym.SectionId) = .empty;
    if (key.value == .text) try c.text_tags.put(c.arena, tag, {});
    for (tag.values, 0..) |v, i| switch (key.value) {
        .none, .text, .judge => {},
        .number => if (!isNumber(v)) try c.err(tag.at(i), "`{s}` takes a number: `{s}` is not one", .{ key.name, v }),
        .word => if (!isWord(v)) try c.err(tag.at(i), "`{s}` takes a word: `{s}` is not one", .{ key.name, v }),
        .words => |ws| if (!within(ws, v)) {
            try c.err(tag.at(i), "`{s}` takes one of {s}: `{s}` is not one", .{ key.name, try std.mem.join(c.arena, ", ", ws), v });
        },
        .values_of => |fact| try valueOf(c, module, tag, key, fact, i),
        .section => {
            const to = c.sectionNamed(module, v) orelse {
                try c.err(tag.at(i), "`{s}` names a section: nothing is called `{s}`", .{ key.name, v });
                continue;
            };
            try sections.append(c.arena, to);
            if (from) |s| try c.edge(s, to, .tag);
        },
    };
    if (key.leads and at == .section and sections.items.len > 0) {
        if (from) |s| c.section(s).leads = true;
    }
    if (sections.items.len > 0) try c.tags.put(c.arena, tag, try sections.toOwnedSlice(c.arena));
}

// The tag's value `i`, one of the values of the story's fact `fact`.
fn valueOf(c: *Checker, module: sym.ModuleId, tag: *const ast.Tag, key: *const Schema.Key, fact: []const u8, i: usize) Error!void {
    const e = enumNamed(c, module, fact) orelse {
        return c.err(tag.key.span, "the host's `{s}` takes the values of `{s}`, which the story does not declare as `one of` or `set of`", .{ key.name, fact });
    };
    const v = tag.values[i];
    if (c.valueOf(e, v) == null) try c.err(tag.at(i), "`{s}` takes one of {s}: `{s}` is not one", .{ key.name, try c.valueList(e), v });
}

fn enumNamed(c: *const Checker, module: sym.ModuleId, fact: []const u8) ?sym.EnumId {
    const named = c.valueNamed(module, fact) orelse return null;
    if (named != .fact) return null;
    return switch (c.facts.items[named.fact.raw()].type) {
        .one_of, .set_of => |e| e,
        else => null,
    };
}

fn within(ws: []const []const u8, v: []const u8) bool {
    for (ws) |w| if (std.mem.eql(u8, w, v)) return true;
    return false;
}

fn isWord(v: []const u8) bool {
    if (v.len == 0) return false;
    for (v) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

fn isNumber(v: []const u8) bool {
    var digits: usize = 0;
    var dot = false;
    for (v, 0..) |ch, i| {
        const sign = ch == '-' and i == 0;
        const point = ch == '.' and !dot and i > 0 and i + 1 < v.len;
        if (!std.ascii.isDigit(ch) and !sign and !point) return false;
        digits += @intFromBool(std.ascii.isDigit(ch));
        dot = dot or point;
    }
    return digits > 0;
}

test "a number is digits with an optional fraction" {
    try std.testing.expect(isNumber("2.5"));
    try std.testing.expect(isNumber("20"));
    try std.testing.expect(isNumber("-1"));
    try std.testing.expect(!isNumber("2."));
    try std.testing.expect(!isNumber("piano"));
    try std.testing.expect(!isNumber(""));
}
