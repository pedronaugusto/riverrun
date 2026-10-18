//! A story built by hand, shaped like the proof's kitchen_1985: lines, a
//! gather the choices return to, a choice gated by `carried has play`, a
//! line with a value and words chosen by a condition, effects on a line, a
//! call, and a jump to the fork. The layer's tests read it back.

const std = @import("std");
const facts = @import("../facts.zig");
const model = @import("model.zig");
const Builder = @import("builder.zig").Builder;
const Term = @import("format.zig").Term;

pub const Built = struct {
    graph: []u8,
    strings: []u8,
    /// Every step as it was given, by id.
    nodes: []model.Node,
    kitchen: model.SectionId,
    fork: model.SectionId,
    ask: model.NodeId,
    offer: model.NodeId,
    carried: facts.FactId,
    life: facts.FactId,

    pub fn deinit(b: *Built, gpa: std.mem.Allocator) void {
        gpa.free(b.graph);
        gpa.free(b.strings);
        gpa.free(b.nodes);
        b.* = undefined;
    }
};

pub fn kitchen(gpa: std.mem.Allocator) !Built {
    var b: Builder = try .init(gpa);
    defer b.deinit();
    var given: std.ArrayList(model.Node) = .empty;
    defer given.deinit(gpa);

    const life_scope = try b.scope("life");
    const player = try b.scope("player");
    const sides = try b.enumeration(&.{ "stay", "go" });
    const memories = try b.enumeration(&.{ "play", "gave", "hands" });
    const life = try b.fact(.{ .name = "life", .scope = life_scope, .kind = .one_of, .enumeration = sides });
    const carried = try b.fact(.{ .name = "carried", .scope = player, .kind = .set_of, .enumeration = memories });
    const dad = try b.castMember(.{ .name = "dad", .display = try b.line("cast.dad", "Dad"), .relation = try b.line("cast.dad.who", "Frank, her father") });
    const lived = try b.externFn("lived", &.{.{ .kind = .one_of, .enumeration = sides }}, .{ .kind = .boolean }, false);
    const rest_in = try b.externFn("rest_in", &.{.{ .kind = .one_of, .enumeration = sides }}, null, true);
    const go = Term.item(sides.raw(), 1);

    const kitchen_s = try b.section(.{
        .name = "kitchen_1985",
        .tags = try b.tagList(&.{ .{ .key = "talk" }, .{ .key = "picture", .values = &.{.{ .text = "kitchen_1985" }} } }),
        .visits = try b.visits("kitchen_1985"),
    });
    const fork_s = try b.section(.{ .name = "fork_1985", .tags = try b.tagList(&.{.{ .key = "fork" }}), .visits = try b.visits("fork_1985") });

    const ask = try b.reserve();
    const offer = try b.reserve();
    const shop = try b.reserve();
    const play = try b.reserve();
    const case = try b.reserve();
    const leave = try b.reserve();

    const letter = try b.text(try b.line("kitchen_1985.letter", "The last bus north leaves at {0}. {1:You came all this way.|You came.}"), &.{
        .{ .kind = .value, .expr = try b.expr(&.{.of(.text, try b.literal("22:40"))}) },
        .{ .kind = .choose, .expr = try b.expr(&.{ .of(.fact, life.raw()), go, .of(.eq, 0) }), .arity = 2 },
    });
    const go_line = try b.reserve();
    const first = try define(&b, &given, null, .{ .step = .{ .line = .{ .text = letter, .next = go_line } } });
    _ = try define(&b, &given, go_line, .{ .step = .{ .line = .{ .text = try b.text(try b.line("kitchen_1985.go", "Go."), &.{}), .speaker = dad, .next = ask } } });
    b.enter(kitchen_s, first);
    _ = try define(&b, &given, ask, .{ .step = .{ .gather = .{ .visits = try b.visits("kitchen_1985.ask"), .next = offer } } });

    const choices = try b.choiceList(&.{
        .{ .text = try b.text(try b.line("kitchen_1985.shop", "Who'll run the shop?"), &.{}), .visits = try b.visits("kitchen_1985.shop"), .target = shop },
        .{
            .text = try b.text(try b.line("kitchen_1985.play", "You could still play, Dad."), &.{}),
            .cond = try b.expr(&.{ .of(.fact, carried.raw()), Term.item(memories.raw(), 0), .of(.has, 0) }),
            .visits = try b.visits("kitchen_1985.play"),
            .tags = try b.tagList(&.{.{ .key = "known", .values = &.{.{ .text = "play" }} }}),
            .target = play,
        },
        .{ .text = try b.text(try b.line("kitchen_1985.case", "Pick up the case."), &.{}), .sticky = true, .visits = try b.visits("kitchen_1985.case"), .target = case },
    });
    _ = try define(&b, &given, offer, .{ .step = .{ .choices = .{ .choices = choices } } });
    _ = try define(&b, &given, shop, .{ .step = .{ .line = .{ .text = try b.text(try b.line("kitchen_1985.ran", "I ran it before you could walk."), &.{}), .speaker = dad, .next = ask } } });
    _ = try define(&b, &given, play, .{ .step = .{ .line = .{ .text = try b.text(try b.line("kitchen_1985.listen", "Who'd listen?"), &.{}), .speaker = dad, .next = ask } } });
    const kept = try b.effectList(&.{
        .{ .add = .{ .fact = carried, .item = 2 } },
        .{ .call = .{ .action = rest_in, .args = try b.expr(&.{go}) } },
    });
    _ = try define(&b, &given, case, .{ .step = .{ .line = .{ .text = try b.text(try b.line("kitchen_1985.go_on", "Go on. Go."), &.{}), .speaker = dad, .effects = kept, .next = leave } } });
    _ = try define(&b, &given, leave, .{ .step = .{ .jump = fork_s } });

    const set_go = try b.effectList(&.{.{ .set = .{ .fact = life, .value = try b.expr(&.{go}) } }});
    const end = try define(&b, &given, null, .{ .step = .end });
    const board = try define(&b, &given, null, .{ .step = .{ .effects = .{ .effects = set_go, .next = end } } });
    const unlived = try b.expr(&.{ go, .of(.query, lived.raw()), .of(.not, 0) });
    const get_on = try b.choiceList(&.{.{ .text = try b.text(try b.line("fork_1985.get_on", "Get on"), &.{}), .cond = unlived, .visits = try b.visits("fork_1985.get_on"), .target = board }});
    const fork_offer = try define(&b, &given, null, .{ .tags = try b.tagList(&.{.{ .key = "seam" }}), .step = .{ .choices = .{ .choices = get_on, .next = end } } });
    b.enter(fork_s, fork_offer);

    const graph = try b.bytes(gpa);
    errdefer gpa.free(graph);
    const hash = std.mem.readInt(u64, graph[16..24], .little);
    const words = try b.stringBytes(gpa, "en", hash);
    errdefer gpa.free(words);
    return .{
        .graph = graph,
        .strings = words,
        .nodes = try given.toOwnedSlice(gpa),
        .kitchen = kitchen_s,
        .fork = fork_s,
        .ask = ask,
        .offer = offer,
        .carried = carried,
        .life = life,
    };
}

// Defines a step (reserving one if `id` is null) and keeps what was given, by id.
fn define(b: *Builder, given: *std.ArrayList(model.Node), id: ?model.NodeId, n: model.Node) !model.NodeId {
    const at = id orelse try b.reserve();
    b.define(at, n);
    while (given.items.len <= at.raw()) try given.append(b.gpa, .{ .step = .end });
    given.items[at.raw()] = n;
    return at;
}
