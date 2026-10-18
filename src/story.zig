//! The story layer: a compiled story as graph data, and its string table.
//!
//! Sections are nodes, steps are joined by edges, and conditions and effects
//! are postfix terms over the facts: data an executor walks and a tool draws,
//! never bytecode. The builder writes it, the reader views it in place, and
//! `docs/format.md` specifies it for any other runtime. It needs only `facts`.

const format_ = @import("story/format.zig");
const model = @import("story/model.zig");
const strings_ = @import("story/strings.zig");

pub const format = format_;
pub const template = @import("story/template.zig");
pub const json = @import("story/json.zig");

pub const Story = @import("story/reader.zig").Story;
pub const Options = @import("story/reader.zig").Options;
pub const Error = @import("story/reader.zig").Error;
pub const Builder = @import("story/builder.zig").Builder;
pub const BuildError = @import("story/builder.zig").Error;
pub const TagIn = @import("story/builder.zig").TagIn;
pub const SectionIn = @import("story/builder.zig").SectionIn;
pub const CandidateIn = @import("story/builder.zig").CandidateIn;

pub const Strings = strings_.Strings;
pub const Line = strings_.Line;
pub const writeStrings = strings_.write;
pub const checkStrings = strings_.check;
pub const lineId = strings_.lineId;

pub const Term = format_.Term;
pub const Range = format_.Range;
pub const SectionId = model.SectionId;
pub const NodeId = model.NodeId;
pub const TextId = model.TextId;
pub const CastId = model.CastId;
pub const EnumId = model.EnumId;
pub const LineId = model.LineId;
pub const FactDecl = model.FactDecl;
pub const Cast = model.Cast;
pub const Param = model.Param;
pub const Extern = model.Extern;
pub const Section = model.Section;
pub const Candidate = model.Candidate;
pub const Node = model.Node;
pub const Choice = model.Choice;
pub const Text = model.Text;
pub const Slot = model.Slot;
pub const SlotKind = model.SlotKind;
pub const Effect = model.Effect;
pub const Tag = model.Tag;
pub const TagValue = model.TagValue;
pub const FactId = model.FactId;
pub const RefKindId = model.RefKindId;
pub const Thing = model.Thing;
pub const Stamp = model.Stamp;
pub const BuiltinCall = model.BuiltinCall;
pub const Block = model.Block;

pub const max_choices = format_.max_choices;
pub const max_slots = format_.max_slots;
pub const max_stack = format_.max_stack;
pub const max_call_depth = format_.max_call_depth;

test {
    _ = format_;
    _ = model;
    _ = template;
    _ = json;
    _ = strings_;
    _ = @import("story/tables.zig");
    _ = @import("story/validate.zig");
    _ = @import("story/codec.zig");
    _ = @import("story/reader.zig");
    _ = @import("story/builder.zig");
    _ = @import("story/story_test.zig");
}
