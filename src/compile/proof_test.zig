//! The release's proof: the WAKE prototype's whole story, read, checked
//! against a schema shaped like lantern's, compiled, loaded and told, the
//! host doing what lantern's mechanics would. 1969's hide and seek, where a
//! line is heard only where Iris hides; the kitchen of 1985, where what she
//! heard opens a choice; the fork.

const std = @import("std");
const syntax = @import("../syntax.zig");
const check = @import("../check.zig");
const story = @import("../story.zig");
const facts = @import("../facts.zig");
const run = @import("../run.zig");
const compile = @import("../compile.zig");
const wake_options = @import("../check/proof_test.zig").wake_options;

const gpa = std.testing.allocator;
const names = .{ "cast", "1969", "1985", "1998", "years", "wake", "back", "rest" };

// What lantern answers: no life is lived yet, and resting does nothing here.
const Lantern = struct {
    fn lived(_: *Lantern, _: run.Context, _: u16) bool {
        return false;
    }
    fn origin(_: *Lantern, _: run.Context, _: u16) u16 {
        return 0;
    }
    fn restIn(_: *Lantern, _: run.Context, _: u16) void {}
};

const Proof = struct {
    compiled: compile.Compiled,
    story: story.Story,
    words: story.Strings,
    memory: facts.Memory,
    host: run.Host,
    session: run.Session,
    arena: std.heap.ArenaAllocator,

    fn line(p: *Proof) !run.Line {
        const step = try p.session.next(.fromRaw(0));
        if (step != .line) return error.TestExpectedLine;
        return step.line;
    }

    // A line the host delivers: its words checked, its effects applied.
    fn said(p: *Proof, want: []const u8) !void {
        const l = try p.line();
        try std.testing.expectEqualStrings(want, l.text);
        for (l.effects) |e| _ = try facts.apply(p.memory.store(), e);
    }

    // A line the listen mechanic plays: heard, and its effects applied, only where `heard` holds the spot.
    fn played(p: *Proof, spot: []const u8, want: []const u8) !bool {
        const l = try p.line();
        try std.testing.expectEqualStrings(want, l.text);
        const heard = p.story.tagNamed(l.tags, "heard") orelse return false;
        for (0..heard.values.len) |k| if (std.mem.eql(u8, p.story.tagValue(heard.values.start + @as(u32, @intCast(k))).text, spot)) { // safe: a tag's few values
            for (l.effects) |e| _ = try facts.apply(p.memory.store(), e);
            return true;
        };
        return false;
    }

    fn offered(p: *Proof, want: []const []const u8) !void {
        const step = try p.session.next(.fromRaw(0));
        if (step != .choices) return error.TestExpectedChoices;
        try std.testing.expectEqual(want.len, step.choices.len);
        for (want, step.choices) |w, c| {
            const shown = if (c.open) c.text else try p.arena.allocator().print("[{s}]", .{c.text});
            try std.testing.expectEqualStrings(w, shown);
        }
    }

    fn deinit(p: *Proof) void {
        p.session.deinit();
        p.host.deinit();
        p.memory.deinit();
        p.compiled.deinit(gpa);
        p.arena.deinit();
    }
};

var lantern: Lantern = .{};

fn told(p: *Proof) !void {
    p.arena = .init(gpa);
    const a = p.arena.allocator();
    var diags: syntax.Diagnostics = .{};
    defer diags.deinit(gpa);
    var trees: [names.len]syntax.ast.File = undefined;
    inline for (names, 0..) |name, i| {
        trees[i] = try syntax.parse(a, gpa, &diags, i, name ++ ".river", @embedFile("../syntax/testdata/proof/" ++ name ++ ".river"));
    }
    var checked = try check.run(gpa, &diags, &trees, wake_options);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
    p.compiled = try compile.run(gpa, &diags, &checked, .{});
    p.story = try .init(p.compiled.graph, .{});
    p.words = try .init(p.compiled.words, .{});
    p.memory = try .init(gpa, try p.story.schema(a));
    p.host = try run.Host.bind(gpa, &p.story, &lantern, .{ .lived = Lantern.lived, .origin = Lantern.origin, .rest_in = Lantern.restIn }, null);
    p.session = try .init(gpa, &p.story, &p.words, p.memory.store(), &p.host, .{});
}

test "the proof compiles, and 1969, the kitchen of 1985 and the fork are told as a player sees them" {
    var p: Proof = undefined;
    try told(&p);
    defer p.deinit();
    try story.checkStrings(&p.story, &p.words);
    const flow: run.FlowId = .fromRaw(0);

    try p.session.start(flow, p.story.sectionNamed("cold_open").?);
    try p.said("Every life ends the same way.");
    try p.said("What it meant is still open.");
    // Iris hides behind the piano: she hears what reaches the piano, and carries only that
    try std.testing.expect(try p.played("piano", "She was at the piano again today. She found middle C on her own."));
    try std.testing.expect(!try p.played("piano", "Then lock it."));
    try std.testing.expect(try p.played("piano", "You could still play, Frank."));
    try std.testing.expect(try p.played("piano", "Who'd listen?"));
    try std.testing.expect(!try p.played("piano", "You gave up the conservatory for us. You don't get to give her up too."));
    try std.testing.expect(!try p.played("piano", "I'd do it again."));
    try std.testing.expect(!try p.played("piano", "She has your hands, you know. Look at them sometime."));
    try std.testing.expectEqual(run.Step.end, try p.session.next(flow));

    // the listen mechanic goes on to the section its `then` names, where she hid
    const hide = p.story.section(p.story.sectionNamed("hide_1969").?);
    const then = p.story.tagValue(p.story.tagNamed(hide.tags, "then").?.values.start).section.?;
    try std.testing.expectEqualStrings("found_1969", p.story.section(then).name);
    const spot = p.story.factNamed("spot").?;
    try p.memory.set(spot, .{ .one_of = 1 }); // piano
    try p.session.start(flow, then);
    try p.said("Margaret walks past the piano three times. The third time she stops, and listens, and walks on.");
    try p.said("In the morning the piano is locked.");

    try p.said("The scholarship letter has been on the fridge for a month. The last bus north leaves at 22:40. Her case has been packed since Sunday.");
    try p.said("Dad has been ill since the spring. He doesn't look up.");
    const go = try p.line();
    try std.testing.expectEqualStrings("Go.", go.text);
    try std.testing.expectEqualStrings("Dad", p.session.speaker(go.speaker.?).?);
    try p.offered(&.{ "Who'll run the shop?", "You're not well.", "You could still play, Dad.", "[You gave yours up.]", "Pick up the case." });
    try p.session.choose(flow, 2);
    try p.said("Who'd listen?");
    try p.said("The same two words. You were eight, behind the piano. He doesn't know you heard them.");
    try p.offered(&.{ "Who'll run the shop?", "You're not well.", "[You gave yours up.]", "Pick up the case." });
    try p.session.choose(flow, 3);
    try p.said("Go on. Go.");
    try p.said("22:31. The bus stop is four minutes away.");

    try p.offered(&.{ "Get on", "Stay" });
    try p.session.choose(flow, 0);
    const board = (try p.session.next(flow)).effects;
    for (board) |e| _ = try facts.apply(p.memory.store(), e);
    try std.testing.expectEqual(@as(u16, 1), p.memory.get(p.story.factNamed("life").?).one_of); // go
    try p.said("Six things want her today. There is time for four.");
}

test "the proof's compiled size" {
    var p: Proof = undefined;
    try told(&p);
    defer p.deinit();
    // the design's estimate: a two-hour story about 800 KB, half of it words; the proof is a few minutes
    try std.testing.expect(p.compiled.graph.len < 256 * 1024);
    try std.testing.expect(p.compiled.words.len < 256 * 1024);
}
