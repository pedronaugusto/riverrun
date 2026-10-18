//! The run layer: a compiled story told. A `Session` walks its flows over
//! the host's facts and hands over what each has next: a line, choices,
//! effects, an action, or the end. Effects are emitted, never applied; the
//! session writes only its own bookkeeping, in the reserved scope. It needs
//! only `story` and `facts`, so a game that plays links nothing that reads
//! or checks `.river` files. A session is made over a `Host` bound to the
//! story by name: every extern implemented, with its signature.

const Session_ = @import("run/Session.zig");
const cursors = @import("run/cursors.zig");

pub const Session = Session_;
pub const FlowId = Session_.FlowId;
pub const Step = Session_.Step;
pub const Line = Session_.Line;
pub const Choice = Session_.Choice;
pub const Action = Session_.Action;
pub const Options = Session_.Options;
pub const Error = Session_.Error;
const host = @import("run/host.zig");
pub const Host = host.Host;
pub const Binder = host.Binder;
pub const Context = host.Context;
pub const Signature = host.Signature;
pub const Entry = host.Entry;
pub const Problem = host.Problem;
pub const BindError = host.BindError;
pub const QueryError = host.QueryError;
pub const RefName = host.RefName;
pub const Resolver = host.Resolver;
pub const RefLookup = host.RefLookup;
pub const Builtins = @import("run/eval.zig").Builtins;

pub const max_flows = Session_.max_flows;
pub const max_call_depth = Session_.max_call_depth;
pub const max_pick = @import("run/pool.zig").max_pick;
pub const max_outcomes = @import("run/flow.zig").max_outcomes;

pub const CursorReport = cursors.Report;
pub const SaveError = cursors.SaveError;
pub const RestoreError = cursors.RestoreError;

test {
    _ = Session_;
    _ = cursors;
    _ = @import("run/eval.zig");
    _ = @import("run/text.zig");
    _ = @import("run/pool.zig");
    _ = @import("run/run_test.zig");
}
