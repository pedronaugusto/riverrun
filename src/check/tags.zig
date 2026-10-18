//! Tags held to the host's schema. A value typed as a section is resolved,
//! and is an edge for reachability: a section only a mechanic leads to is
//! still reached. A key that `leads` hands a section's end to the host,
//! which goes on to the section the tag names.

const std = @import("std");
const syntax = @import("../syntax.zig");
const sym = @import("symbols.zig");
const Checker = @import("Checker.zig");
const schema_file = @import("schema.zig");

const ast = syntax.ast;
const Error = Checker.Error;
const Schema = schema_file.Schema;
const id_key = schema_file.id_key;

/// Checks the tags at one place. `from` is the section they are in, for edges; null for the cast.
pub fn check(c: *Checker, module: sym.ModuleId, from: ?sym.SectionId, tags: []const ast.Tag, at: Schema.Place) Error!void {
    for (tags) |*tag| {
        if (std.mem.eql(u8, tag.key.text, id_key)) {
            if (at != .line and at != .choice) try c.err(tag.key.span, "only a line or a choice has an `id`", .{});
            continue;
        }
        const schema = c.options.schema orelse continue;
        const key = switch (schema.find(tag.key.text, at)) {
            .found => |k| k,
            .elsewhere => {
                try c.err(tag.key.span, "`{s}` is not a tag of a {s}", .{ tag.key.text, placeName(at) });
                continue;
            },
            .unknown => {
                try c.err(tag.key.span, "`{s}` is not a tag the host knows", .{tag.key.text});
                continue;
            },
        };
        try count(c, tag, key);
        try values(c, module, from, tag, key, at);
    }
}

fn placeName(at: Schema.Place) []const u8 {
    return switch (at) {
        .cast => "cast entry",
        .section => "section",
        .part => "part",
        .line => "line",
        .choice => "choice",
        .other => "statement",
    };
}

fn count(c: *Checker, tag: *const ast.Tag, key: *const Schema.Key) Error!void {
    const n = tag.values.len;
    if (key.value == .none) {
        if (n > 0) try c.err(tag.key.span, "`{s}` is a mark and takes no value", .{key.name});
        return;
    }
    switch (key.count) {
        .one => if (n != 1) try c.err(tag.key.span, "`{s}` takes one value, not {d}", .{ key.name, n }),
        .many => if (n == 0) try c.err(tag.key.span, "`{s}` takes at least one value", .{key.name}),
        .any => {},
    }
}

fn values(c: *Checker, module: sym.ModuleId, from: ?sym.SectionId, tag: *const ast.Tag, key: *const Schema.Key, at: Schema.Place) Error!void {
    var sections: std.ArrayList(sym.SectionId) = .empty;
    for (tag.values) |v| switch (key.value) {
        .none, .text => {},
        .number => if (!isNumber(v)) try c.err(tag.key.span, "`{s}` takes a number: `{s}` is not one", .{ key.name, v }),
        .word => if (!isWord(v)) try c.err(tag.key.span, "`{s}` takes a word: `{s}` is not one", .{ key.name, v }),
        .words => |ws| if (!within(ws, v)) {
            try c.err(tag.key.span, "`{s}` takes one of {s}: `{s}` is not one", .{ key.name, try std.mem.join(c.arena, ", ", ws), v });
        },
        .values_of => |fact| try valueOf(c, module, tag, key, fact, v),
        .section => {
            const to = c.section_names.find(module, v) orelse {
                try c.err(tag.key.span, "`{s}` names a section: nothing is called `{s}`", .{ key.name, v });
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

fn valueOf(c: *Checker, module: sym.ModuleId, tag: *const ast.Tag, key: *const Schema.Key, fact: []const u8, v: []const u8) Error!void {
    const e = enumNamed(c, module, fact) orelse {
        return c.err(tag.key.span, "the host's `{s}` takes the values of `{s}`, which the story does not declare as `one of` or `set of`", .{ key.name, fact });
    };
    if (c.valueOf(e, v) == null) try c.err(tag.key.span, "`{s}` takes one of {s}: `{s}` is not one", .{ key.name, try c.valueList(e), v });
}

fn enumNamed(c: *const Checker, module: sym.ModuleId, fact: []const u8) ?sym.EnumId {
    const named = c.value_names.find(module, fact) orelse return null;
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
