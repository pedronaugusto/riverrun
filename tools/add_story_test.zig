//! A story compiled by `addStory` while riverrun builds, with a package
//! registered, embedded and told: what a game's build does.

const std = @import("std");
const riverrun = @import("riverrun");
const story = @import("story");

test "a story compiled at build time is embedded and told" {
    const gpa = std.testing.allocator;
    const s: riverrun.story.Story = try .init(story.graph, .{});
    const words: riverrun.story.Strings = try .init(story.words, .{});
    try riverrun.story.checkStrings(&s, &words);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var memory: riverrun.facts.Memory = try .init(gpa, try s.schema(arena.allocator()));
    defer memory.deinit();
    var session: riverrun.run.Session = try .init(gpa, &s, &words, memory.store(), &riverrun.run.Host.none, .{});
    defer session.deinit();
    const flow: riverrun.run.FlowId = .fromRaw(0);
    try session.start(flow, s.sectionNamed("market").?);
    try std.testing.expectEqualStrings("Ten pelts before the frost.", (try session.next(flow)).line.text);
    try std.testing.expectEqual(@as(usize, 2), (try session.next(flow)).choices.len);
    try session.choose(flow, 0);
    for ((try session.next(flow)).effects) |e| _ = try riverrun.facts.apply(memory.store(), e);
    try std.testing.expectEqual(@as(i64, 10), memory.get(s.factNamed("pelts").?).int);
    try std.testing.expectEqualStrings("Good.", (try session.next(flow)).line.text);
    try std.testing.expectEqual(riverrun.run.Step.end, try session.next(flow));
}

test "a package registered through addStory declared its facts and wrote its block" {
    const s: riverrun.story.Story = try .init(story.graph, .{});
    const furs = s.factNamed("furs").?;
    try std.testing.expectEqual(riverrun.facts.Role.game, s.fact(furs).role);
    try std.testing.expectEqualStrings("world", s.scope(s.fact(furs).scope));
    try std.testing.expectEqualSlices(u8, &.{2}, s.block("stall").?.bytes);
}
