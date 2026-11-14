//! The one-shot rewriter from riverrun's first syntax to design B, built on
//! the reader of the first syntax, which keeps every byte:
//!
//!     riverrun-rewrite <file.river | file.zig>…
//!
//! Each file is rewritten in place: a `.river` file whole, a `.zig` file's
//! stories in its `\\` strings, each string's prefix kept. A row's tags go
//! into brackets on a row under it, at the indentation of what is under it
//! (two deeper where nothing is), and its `# id` to `^id` at its end; `~ x`
//! becomes `[x]`, `->> x` becomes `-> x ->`, `{n -> …}` becomes `{n as …}`
//! and `extras:` takes commas. A narration row that begins with `[`, and
//! words that end in `^word`, are escaped. Comments, blank rows and the
//! writer's layout stay where they are. What it cannot rewrite it names, with
//! the row, and leaves as it is.

const std = @import("std");
const aegis = @import("aegis");
const riverrun = @import("riverrun-compiler");

const syntax = riverrun.syntax;
const ast = syntax.ast;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [4096]u8 = undefined;
    var err = std.Io.File.stderr().writer(io, &buf);
    const cwd = std.Io.Dir.cwd();
    var any = false;
    var failed = false;
    while (args.next()) |path| {
        any = true;
        const bytes = try aegis.own.readFile(io, cwd, path, arena, .fromRaw(syntax.max_file + 1));
        var notes: Notes = .{ .path = path };
        const out = if (std.mem.endsWith(u8, path, ".zig")) try zigFile(arena, gpa, bytes, &notes) else try story(arena, gpa, bytes, &notes, 0);
        for (notes.list.items) |n| try err.interface.print("{s}:{d}: {s}\n", .{ path, n.line, n.what });
        failed = failed or notes.list.items.len > 0;
        if (!std.mem.eql(u8, out, bytes)) try cwd.writeFile(io, .{ .sub_path = path, .data = out });
    }
    try err.interface.flush();
    if (!any) {
        std.log.err("usage: riverrun-rewrite <file.river | file.zig>…", .{});
        return 2;
    }
    return @intFromBool(failed);
}

/// What the rewriter could not do, by the line of the file it is on.
const Notes = struct {
    path: []const u8,
    list: std.ArrayList(Note) = .empty,

    const Note = struct { line: u32, what: []const u8 };

    fn add(n: *Notes, arena: Allocator, line: u32, comptime fmt: []const u8, args: anytype) !void {
        try n.list.append(arena, .{ .line = line, .what = try std.fmt.allocPrint(arena, fmt, args) });
    }
};

// A `.zig` file's stories: each run of rows that begin, after spaces, with `\\` is one story, its prefix taken off
// each row and put back on each row rewritten.
fn zigFile(arena: Allocator, gpa: Allocator, bytes: []const u8, notes: *Notes) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rows = std.mem.splitScalar(u8, bytes, '\n');
    var pending: std.ArrayList([]const u8) = .empty;
    var prefix: []const u8 = "";
    var line: u32 = 0;
    var first: u32 = 0;
    while (rows.next()) |row| {
        line += 1;
        const lead = row.len - std.mem.trimStart(u8, row, " ").len;
        const opens = std.mem.startsWith(u8, row[lead..], "\\\\");
        if (opens and (pending.items.len == 0 or std.mem.eql(u8, row[0 .. lead + 2], prefix))) {
            if (pending.items.len == 0) {
                prefix = row[0 .. lead + 2];
                first = line;
            }
            try pending.append(arena, row[lead + 2 ..]);
            continue;
        }
        try flush(arena, gpa, &out, &pending, prefix, notes, first);
        if (opens) {
            prefix = row[0 .. lead + 2];
            first = line;
            try pending.append(arena, row[lead + 2 ..]);
            continue;
        }
        try out.appendSlice(arena, row);
        if (rows.index != null) try out.append(arena, '\n');
    }
    try flush(arena, gpa, &out, &pending, prefix, notes, first);
    return out.items;
}

fn flush(arena: Allocator, gpa: Allocator, out: *std.ArrayList(u8), pending: *std.ArrayList([]const u8), prefix: []const u8, notes: *Notes, first: u32) !void {
    if (pending.items.len == 0) return;
    const text = try std.mem.join(arena, "\n", pending.items);
    const rewritten = try story(arena, gpa, text, notes, first - 1);
    var rows = std.mem.splitScalar(u8, rewritten, '\n');
    while (rows.next()) |row| {
        try out.appendSlice(arena, prefix);
        try out.appendSlice(arena, row);
        try out.append(arena, '\n');
    }
    pending.clearRetainingCapacity();
}

/// A change to a story's bytes: `start..end` replaced by `text`; an insertion where they are equal.
const Edit = struct { start: u32, end: u32, text: []const u8 };

const Rewriter = struct {
    arena: Allocator,
    text: []const u8,
    file: *const ast.File,
    edits: std.ArrayList(Edit) = .empty,
    notes: *Notes,
    /// The line of the file the story's first row is on, less one.
    offset: u32,

    fn edit(w: *Rewriter, start: u32, end: u32, text: []const u8) !void {
        try w.edits.append(w.arena, .{ .start = start, .end = end, .text = text });
    }

    fn note(w: *Rewriter, at: u32, comptime fmt: []const u8, args: anytype) !void {
        const line = w.file.place(.{ .file = 0, .start = at, .end = at }).line;
        try w.notes.add(w.arena, w.offset + line, fmt, args);
    }
};

/// One story rewritten: `offset` is the line of its file its first row is on, less one, for the notes.
fn story(arena: Allocator, gpa: Allocator, text: []const u8, notes: *Notes, offset: u32) ![]const u8 {
    var diags: syntax.Diagnostics = .{};
    defer diags.deinit(gpa);
    const file = try syntax.parse(arena, gpa, &diags, 0, notes.path, text);
    if (file.rows.len == 0) return text;
    var w: Rewriter = .{ .arena = arena, .text = text, .file = &file, .notes = notes, .offset = offset };
    for (file.rows, 0..) |row, i| {
        try rowTags(&w, i, row);
        try rowMarks(&w, row);
    }
    for (file.decls) |d| switch (d.kind) {
        .extras => try extras(&w, d.span),
        else => {},
    };
    for (file.sections) |s| {
        try stmts(&w, s.body);
        for (s.subsections) |p| try stmts(&w, p.body);
    }
    return apply(arena, text, w.edits.items);
}

// A row's tags: its `# id` to `^id` at its end, the rest into brackets on a row under it.
fn rowTags(w: *Rewriter, i: usize, row: ast.Row) !void {
    if (row.tags.len == 0) return;
    var id: ?[]const u8 = null;
    var brackets: std.ArrayList(u8) = .empty;
    var items = Items{ .s = row.tags[1..] };
    while (items.next()) |raw| {
        const item = std.mem.trim(u8, raw, " ");
        if (item.len == 0) continue;
        if (std.mem.startsWith(u8, item, "id ")) {
            id = std.mem.trim(u8, item[3..], " ");
            continue;
        }
        if (brackets.items.len > 0) try brackets.append(w.arena, ' ');
        try brackets.print(w.arena, "[{s}]", .{item});
    }
    const words = row.start + row.indent;
    const words_end = words + @as(u32, @intCast(row.text.len)); // safe: a row is part of its file
    const tags_end = words_end + row.before_tags + @as(u32, @intCast(row.tags.len)); // safe: as above
    if (row.text.len == 0) {
        // a row of tags alone: its brackets stand where its tags were
        if (id != null) try w.note(row.start, "an id on a row of tags alone", .{});
        return w.edit(words, tags_end, brackets.items);
    }
    try w.edit(words_end, tags_end, if (id) |x| try std.fmt.allocPrint(w.arena, " ^{s}", .{x}) else "");
    if (brackets.items.len == 0) return;
    const ending = if (row.ending == .none) "\n" else row.ending.bytes();
    const at = row.start + row.len() - @as(u32, @intCast(row.ending.bytes().len)); // safe: as above
    const indent = under(w.file.rows, i);
    try w.edit(at, at, try std.fmt.allocPrint(w.arena, "{s}{s}{s}", .{ ending, try spaces(w.arena, indent), brackets.items }));
}

// A row that begins `~ x` to `[x]`, and one that begins `->> x` to `-> x ->`, whether or not the first reader read it.
fn rowMarks(w: *Rewriter, row: ast.Row) !void {
    const words = row.start + row.indent;
    const end = words + @as(u32, @intCast(row.text.len)); // safe: a row is part of its file
    if (std.mem.startsWith(u8, row.text, "~ ")) {
        return w.edit(words, end, try std.fmt.allocPrint(w.arena, "[{s}]", .{std.mem.trim(u8, row.text[1..], " ")}));
    }
    if (std.mem.startsWith(u8, row.text, "->>")) {
        return w.edit(words, end, try std.fmt.allocPrint(w.arena, "-> {s} ->", .{std.mem.trim(u8, row.text[3..], " ")}));
    }
}

// Whether `at` is where its row's words start.
fn atRowStart(w: *const Rewriter, at: u32) bool {
    const row = rowAt(w.file, at);
    return at == row.start + row.indent;
}

// The indentation of what is under row `i`, or two deeper than it where nothing is.
fn under(rows: []const ast.Row, i: usize) u32 {
    for (rows[i + 1 ..]) |r| {
        if (r.text.len == 0 and r.tags.len == 0) continue;
        return if (r.indent > rows[i].indent) r.indent else rows[i].indent + 2;
    }
    return rows[i].indent + 2;
}

fn spaces(arena: Allocator, n: u32) ![]const u8 {
    const s = try arena.alloc(u8, n);
    @memset(s, ' ');
    return s;
}

// Splits on `·` outside quotes.
const Items = struct {
    s: []const u8,
    i: usize = 0,
    done: bool = false,

    fn next(it: *Items) ?[]const u8 {
        if (it.done) return null;
        var quoted = false;
        var j = it.i;
        while (j < it.s.len) : (j += 1) {
            if (it.s[j] == '"') quoted = !quoted;
            if (!quoted and std.mem.startsWith(u8, it.s[j..], "·")) {
                const out = it.s[it.i..j];
                it.i = j + "·".len;
                return out;
            }
        }
        it.done = true;
        return it.s[it.i..];
    }
};

// `extras: a · b` to `extras: a, b`.
fn extras(w: *Rewriter, span: syntax.Span) !void {
    const words = w.text[span.start..span.end];
    var k: usize = 0;
    while (std.mem.findPos(u8, words, k, "·")) |at| : (k = at + "·".len) {
        const start = span.start + @as(u32, @intCast(at)); // safe: a span is inside its file
        const spaced = at > 0 and words[at - 1] == ' ';
        try w.edit(if (spaced) start - 1 else start, start + @as(u32, "·".len), ",");
    }
}

fn stmts(w: *Rewriter, list: []const ast.Stmt) error{OutOfMemory}!void {
    for (list) |*s| try stmt(w, s);
}

fn stmt(w: *Rewriter, s: *const ast.Stmt) error{OutOfMemory}!void {
    switch (s.kind) {
        .line => |l| {
            try escapes(w, l);
            try selections(w, l.text);
            try stmts(w, l.effects);
        },
        .choice => |c| {
            try selections(w, c.text);
            try stmts(w, c.body);
        },
        .cond => |c| {
            try stmts(w, c.body);
            try stmts(w, c.otherwise);
        },
        .gather => |g| if (g.then) |t| try stmt(w, t),
        .effect => {
            // a row that begins `~` is rewritten as a row; one written after a condition or a gather is not
            if (!atRowStart(w, s.span.start)) return w.note(s.span.start, "an effect after a condition or a gather on its row", .{});
            if (rowAt(w.file, s.span.start).tags.len > 0) try w.note(s.span.start, "an effect with tags: they have no owner in design B", .{});
        },
        .flow => |f| switch (f) {
            .call => |n| if (!atRowStart(w, s.span.start)) try call(w, n),
            else => {},
        },
        .flow_if => |f| {
            if (f.then == .call) try call(w, f.then.call);
            if (f.otherwise == .call) try call(w, f.otherwise.call);
        },
    }
}

// `->> name` to `-> name ->`: the `->>` is the last before the name.
fn call(w: *Rewriter, n: ast.Name) !void {
    const before = w.text[0..n.span.start];
    const arrow = std.mem.findLast(u8, before, "->>") orelse return w.note(n.span.start, "a call with no `->>`", .{});
    try w.edit(@intCast(arrow), n.span.end, try std.fmt.allocPrint(w.arena, "-> {s} ->", .{n.text}));
}

// A narration row that begins with `[`, and words that end in `^word`, which design B would read otherwise.
fn escapes(w: *Rewriter, l: ast.Line) !void {
    if (l.text.len == 0) return;
    const first = l.text[0];
    if (l.speaker == null and first.kind == .literal and first.kind.literal.len > 0 and first.kind.literal[0] == '[' and w.text[first.span.start] == '[') {
        try w.edit(first.span.start, first.span.start, "\\");
    }
    const last = l.text[l.text.len - 1];
    if (last.kind != .literal) return;
    const words = w.text[last.span.start..last.span.end];
    const caret = std.mem.findScalarLast(u8, words, '^') orelse return;
    if (caret == 0 or words[caret - 1] != ' ' or caret + 1 == words.len) return;
    for (words[caret + 1 ..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return;
    try w.edit(last.span.start + @as(u32, @intCast(caret)), last.span.start + @as(u32, @intCast(caret)), "\\"); // safe: as above
}

// A text's selections, `{n -> …}` to `{n as …}`, at any depth.
fn selections(w: *Rewriter, t: ast.Text) error{OutOfMemory}!void {
    for (t) |p| switch (p.kind) {
        .literal, .value => {},
        .choose => |c| {
            try selections(w, c.then);
            try selections(w, c.otherwise);
        },
        .alternatives => |a| for (a.options) |o| try selections(w, o),
        .select => |sel| {
            var at = sel.operand.span.end;
            while (at < w.text.len and w.text[at] == ' ') at += 1;
            if (!std.mem.startsWith(u8, w.text[at..], "->")) return w.note(at, "a selection with no `->`", .{});
            try w.edit(at, at + 2, "as");
            for (sel.branches) |b| try selections(w, b.text);
        },
    };
}

// The row `at` is on.
fn rowAt(f: *const ast.File, at: u32) ast.Row {
    return f.rows[f.place(.{ .file = 0, .start = at, .end = at }).line - 1];
}

// The edits made: each in order of where it starts, insertions at one place in the order they were made.
fn apply(arena: Allocator, text: []const u8, edits: []Edit) ![]const u8 {
    std.mem.sort(Edit, edits, {}, struct {
        fn less(_: void, a: Edit, b: Edit) bool {
            return a.start < b.start;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    var at: u32 = 0;
    for (edits) |e| {
        aegis.assert.invariant(e.start >= at, "edits do not overlap");
        try out.appendSlice(arena, text[at..e.start]);
        try out.appendSlice(arena, e.text);
        at = e.end;
    }
    try out.appendSlice(arena, text[at..]);
    return out.items;
}
