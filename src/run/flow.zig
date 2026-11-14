//! A flow: one cursor over the story. Where it is, the calls it is inside,
//! and what it waits for. A session holds several over the same facts, for
//! conversations held at once.

const std = @import("std");
const facts = @import("../facts.zig");
const story = @import("../story.zig");
const pool = @import("pool.zig");
const text = @import("text.zig");

/// The most flows a session holds.
pub const max_flows = 16;

/// The most actions with an outcome one step waits on.
pub const max_outcomes = 8;

/// Where a call, an interruption or a pool's turn hands the flow back.
pub const Frame = struct {
    /// The step to go on from, or null to keep handing back.
    back: ?story.NodeId,
    /// Within an effects step, the effect to go on from.
    effect_at: u32 = 0,
    /// A pool's candidates: given one after another, then handed back.
    pool: ?Pool = null,

    pub const Pool = struct {
        section: story.SectionId,
        picks: pool.Picks,
        /// Candidates begun so far.
        given: u8 = 0,
    };
};

pub const Pending = union(enum) {
    none,
    /// Choices offered at `node`: their indices within its choices, and which are open.
    choices: struct { node: story.NodeId, offered: [story.max_choices]u8, open: [story.max_choices]bool, len: u8 },
    /// Actions whose outcomes the host owes, in order.
    outcomes: struct { list: [max_outcomes]facts.FactId, len: u8, given: u8 = 0 },
};

/// The line a flow last handed over, held until its next step: where it is, and what its slots held.
pub const Hand = struct {
    node: story.NodeId,
    /// As they were filled when it was handed over; null where a restored story's line no longer has the slots it
    /// was saved with, so it is filled afresh.
    filled: ?text.Filled,
};

pub const Flow = struct {
    /// Its place in the session.
    id: u8,
    /// `start` has been called and `stop` has not.
    started: bool = false,
    /// The flow reached its end; `next` says so again.
    ended: bool = false,
    /// The step to run next; null hands back to the innermost frame.
    at: ?story.NodeId = null,
    /// Within an effects step, the next effect to emit.
    effect_at: u32 = 0,
    depth: u8 = 0,
    frames: [story.max_call_depth]Frame = undefined,
    pending: Pending = .none,
    /// The line handed over and still held: until the next step, a start, a stop or an interruption.
    hand: ?Hand = null,
    /// The step `next` last handed over: a line, choices, effects or an action.
    told: ?story.NodeId = null,
    /// What a step hands the host: valid until this flow's next step.
    arena: std.heap.ArenaAllocator,

    pub fn reset(f: *Flow) void {
        f.started = false;
        f.ended = false;
        f.at = null;
        f.effect_at = 0;
        f.depth = 0;
        f.pending = .none;
        f.hand = null;
        f.told = null;
    }
};
