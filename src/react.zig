//! The react layer: what happens when facts change, not when a flow is told.
//! `Watch` re-evaluates conditions only when what they read may have
//! changed: the facts they read, the stamps of the queries they ask, the
//! clocks they compare with numbers. `Rules` fires a story's `(rules)`
//! sections over it. A package that watches conditions of its own (cairn's
//! quests) adds them to a `Watch` and gives them its own meaning. It needs
//! `story`, `facts` and `run`'s evaluator, and emits effects for the host to
//! apply, as the rest of riverrun does.

pub const Watch = @import("react/Watch.zig");
pub const Rules = @import("react/Rules.zig");
pub const CondId = Watch.CondId;
pub const Evaluated = Watch.Evaluated;
pub const Options = Watch.Options;
pub const Fired = Rules.Fired;
pub const max_rounds = Rules.max_rounds;

test {
    _ = Watch;
    _ = Rules;
    _ = @import("react/heap.zig");
    _ = @import("react/react_test.zig");
}
