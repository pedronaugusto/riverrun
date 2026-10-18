//! The story layer's tests over a built story: what is written reads back
//! the same, a string table serves it, and damaged bytes are refused.

const std = @import("std");
const facts = @import("../facts.zig");
const format = @import("format.zig");
const Story = @import("reader.zig").Story;
const Builder = @import("builder.zig").Builder;
const strings = @import("strings.zig");
const testing = @import("testing.zig");

test "a built story reads back step for step" {
    const gpa = std.testing.allocator;
    var built = try testing.kitchen(gpa);
    defer built.deinit(gpa);
    const story: Story = try .init(built.graph, .{});
    try std.testing.expectEqual(@as(u32, @intCast(built.nodes.len)), story.len(.nodes));
    for (built.nodes, 0..) |given, i| {
        try std.testing.expectEqualDeep(given, story.node(.fromRaw(@intCast(i))));
    }
    const kitchen = story.section(built.kitchen);
    try std.testing.expectEqualStrings("kitchen_1985", kitchen.name);
    try std.testing.expectEqualStrings("kitchen_1985", story.tagValue(story.tagNamed(kitchen.tags, "picture").?.values.start).text);
    try std.testing.expect(story.sectionNamed("fork_1985").?.eql(built.fork));
    try std.testing.expectEqualStrings("visits:kitchen_1985", story.fact(kitchen.visits).name);
    try std.testing.expect(story.reservedScope().eql(story.fact(kitchen.visits).scope));
}

test "a choice is gated by a condition over the facts, in postfix" {
    const gpa = std.testing.allocator;
    var built = try testing.kitchen(gpa);
    defer built.deinit(gpa);
    const story: Story = try .init(built.graph, .{});
    const offer = story.node(built.offer).step.choices;
    try std.testing.expectEqual(@as(u32, 3), offer.choices.len);
    const play = story.choice(offer.choices.start + 1);
    try std.testing.expectEqual(@as(u32, 3), play.cond.len);
    const terms = [_]format.Term{ story.term(play.cond.start), story.term(play.cond.start + 1), story.term(play.cond.start + 2) };
    try std.testing.expectEqual(format.Term.Op.fact, terms[0].op);
    try std.testing.expectEqual(@as(u24, built.carried.raw()), terms[0].arg);
    try std.testing.expectEqual(@as(u8, 0), terms[1].itemIndex());
    try std.testing.expectEqual(format.Term.Op.has, terms[2].op);
    try std.testing.expect(story.choice(offer.choices.start + 2).sticky);
    try std.testing.expect(!play.sticky);
}

test "the string table serves the story, and a translation is swapped in by id" {
    const gpa = std.testing.allocator;
    var built = try testing.kitchen(gpa);
    defer built.deinit(gpa);
    const story: Story = try .init(built.graph, .{});
    const words: strings.Strings = try .init(built.strings, .{});
    try strings.check(&story, &words);
    try std.testing.expectEqual(story.hash(), words.story());
    // A translation: the same ids, the slots moved, the speaker's name its own.
    var lines: std.ArrayList(strings.Line) = .empty;
    defer lines.deinit(gpa);
    for (0..words.len()) |i| {
        const e = words.at(@intCast(i));
        const swapped = if (std.mem.eql(u8, e.id_text, "kitchen_1985.letter")) "{1:Vieste de tão longe.|Vieste.} O último autocarro sai às {0}." else e.template;
        try lines.append(gpa, .{ .id = try strings.lineId(e.id_text), .id_text = e.id_text, .template = swapped });
    }
    const pt_bytes = try strings.write(gpa, lines.items, "pt-PT", story.hash());
    defer gpa.free(pt_bytes);
    const pt: strings.Strings = try .init(pt_bytes, .{});
    try strings.check(&story, &pt);
    // One that drops a line, or breaks a slot, does not serve it.
    const broken = try strings.write(gpa, &.{.{ .id = try strings.lineId("kitchen_1985.letter"), .id_text = "kitchen_1985.letter", .template = "{1:Vieste.}" }}, "pt-PT", story.hash());
    defer gpa.free(broken);
    try std.testing.expectError(error.WrongBranches, strings.check(&story, &(try strings.Strings.init(broken, .{}))));
    const dropped = try strings.write(gpa, lines.items[1..], "pt-PT", story.hash());
    defer gpa.free(dropped);
    try std.testing.expectError(error.MissingLine, strings.check(&story, &(try strings.Strings.init(dropped, .{}))));
}

test "the story's facts make a store" {
    const gpa = std.testing.allocator;
    var built = try testing.kitchen(gpa);
    defer built.deinit(gpa);
    const story: Story = try .init(built.graph, .{});
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const schema = try story.schema(arena.allocator());
    var memory: facts.Memory = try .init(gpa, schema);
    defer memory.deinit();
    try memory.set(built.life, .{ .one_of = 1 });
    try std.testing.expectEqualStrings("go", schema.decl(built.life).items[memory.get(built.life).one_of]);
    try std.testing.expectEqualStrings(facts.reserved_scope, schema.scopes[story.reservedScope().raw()]);
}

test "a condition is typed for its place, and a mistyped one is never written" {
    const gpa = std.testing.allocator;
    var b: Builder = try .init(gpa);
    defer b.deinit();
    const sides = try b.enumeration(&.{ "stay", "go" });
    const life = try b.fact(.{ .name = "life", .scope = try b.scope("life"), .kind = .one_of, .enumeration = sides });
    const visits = try b.visits("wake");
    const wake = try b.section(.{ .name = "wake", .visits = visits });
    const end = try b.node(.{ .step = .end });
    const zero = try b.int(0);
    // `{ seen(wake) }`: the visits above zero.
    const seen = try b.expr(&.{ .of(.fact, visits.raw()), .of(.int, zero), .of(.gt, 0) });
    b.enter(wake, try b.node(.{ .step = .{ .branch = .{ .cond = seen, .then = end, .otherwise = end } } }));
    const good = try b.bytes(gpa);
    gpa.free(good);
    const wrong = try b.expr(&.{ .of(.fact, life.raw()), .of(.int, zero), .of(.gt, 0) });
    _ = try b.node(.{ .step = .{ .branch = .{ .cond = wrong, .then = end, .otherwise = end } } });
    try std.testing.expectError(error.BadExpression, b.bytes(gpa));
    try std.testing.expectError(error.ReservedScope, b.scope(facts.reserved_scope));
}

test "damaged bytes are refused" {
    const gpa = std.testing.allocator;
    var built = try testing.kitchen(gpa);
    defer built.deinit(gpa);
    const bytes = try gpa.dupe(u8, built.graph);
    defer gpa.free(bytes);
    try std.testing.expectError(error.LengthMismatch, Story.init(bytes[0 .. bytes.len - 8], .{}));
    try std.testing.expectError(error.TooShort, Story.init(bytes[0..16], .{}));
    bytes[bytes.len - 1] ^= 0xff;
    try std.testing.expectError(error.BadHash, Story.init(bytes, .{}));
    bytes[bytes.len - 1] ^= 0xff;
    // A jump to a section past the table, unseen by a reader that skips the hash.
    const story: Story = try .init(bytes, .{});
    const nodes = story.g.dirs[@backingInt(format.Table.nodes)];
    for (0..nodes.count) |i| {
        const at = nodes.offset + i * nodes.stride;
        const n = std.mem.bytesToValue(format.Node, bytes[at..][0..@sizeOf(format.Node)]);
        if (n.kind != @backingInt(format.NodeKind.jump)) continue;
        std.mem.writeInt(u32, bytes[at + @offsetOf(format.Node, "a") ..][0..4], 99, .little);
    }
    try std.testing.expectError(error.OutOfRange, Story.init(bytes, .{ .verify_hash = false }));
    bytes[0] = 'X';
    try std.testing.expectError(error.BadMagic, Story.init(bytes, .{ .verify_hash = false }));
}

// Patches a built story at places the fuzzer picks, then reads it: a story
// that passes must be safe to walk end to end.
test "any damage to a story is refused or read safely, never crash" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            const gpa = std.testing.allocator;
            var built = try testing.kitchen(gpa);
            defer built.deinit(gpa);
            const bytes = built.graph;
            while (!smith.eosWithHash(1)) {
                const at = smith.indexWithHash(bytes.len, 2);
                bytes[at] = smith.valueWithHash(u8, 3);
            }
            const story = Story.init(bytes, .{ .verify_hash = false }) catch return;
            walk(&story);
            const words = strings.Strings.init(built.strings, .{}) catch return;
            strings.check(&story, &words) catch return;
        }
    }.one, .{});
}

test "any bytes are a string table or refused, never crash" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            const gpa = std.testing.allocator;
            var built = try testing.kitchen(gpa);
            defer built.deinit(gpa);
            const bytes = built.strings;
            while (!smith.eosWithHash(4)) {
                const at = smith.indexWithHash(bytes.len, 5);
                bytes[at] = smith.valueWithHash(u8, 6);
            }
            const words = strings.Strings.init(bytes, .{ .verify_hash = false }) catch return;
            for (0..words.len()) |i| _ = words.at(@intCast(i));
        }
    }.one, .{});
}

// Reads every record the way an executor and a tool would.
fn walk(story: *const Story) void {
    for (0..story.len(.sections)) |i| _ = story.section(.fromRaw(@intCast(i)));
    for (0..story.len(.candidates)) |i| _ = story.candidate(@intCast(i));
    for (0..story.len(.nodes)) |i| _ = story.node(.fromRaw(@intCast(i)));
    for (0..story.len(.choices)) |i| _ = story.choice(@intCast(i));
    for (0..story.len(.texts)) |i| _ = story.text(.fromRaw(@intCast(i)));
    for (0..story.len(.slots)) |i| _ = story.slot(@intCast(i));
    for (0..story.len(.effects)) |i| _ = story.effect(@intCast(i));
    for (0..story.len(.facts)) |i| _ = story.fact(.fromRaw(@intCast(i)));
    for (0..story.len(.cast)) |i| _ = story.castMember(.fromRaw(@intCast(i)));
    for (0..story.len(.externs)) |i| _ = story.externFn(.fromRaw(@intCast(i)));
    for (0..story.len(.tags)) |i| _ = story.tag(@intCast(i));
    for (0..story.len(.tag_values)) |i| _ = story.tagValue(@intCast(i));
    for (0..story.len(.params)) |i| _ = story.param(@intCast(i));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const schema = story.schema(arena.allocator()) catch return;
    var memory = facts.Memory.init(std.testing.allocator, schema) catch return;
    memory.deinit();
}
