//! The host's tags, as it gives them to the checker: which keys it knows,
//! where each may stand, and what its values are. riverrun carries tags and
//! never reads them, except `id`, a line's id, and `gender` on a cast entry,
//! which a gender's words are chosen by: those are riverrun's own.

const std = @import("std");

/// The key riverrun reserves for a line's id: `# id k7f3a2`.
pub const id_key = "id";
/// The key riverrun reserves on a cast entry for the gender its words are chosen by: `# gender feminine`.
pub const gender_key = "gender";

pub const Schema = struct {
    keys: []const Key,

    /// Where a tag stands.
    pub const Place = enum { cast, section, part, line, choice, other };

    pub const Places = struct {
        cast: bool = false,
        section: bool = false,
        part: bool = false,
        line: bool = false,
        choice: bool = false,
        /// Any other statement: a condition, a gather, an effect, a flow.
        other: bool = false,

        pub fn has(p: Places, at: Place) bool {
            return switch (at) {
                inline else => |t| @field(p, @tagName(t)),
            };
        }
    };

    pub const Value = union(enum) {
        /// A mark: the key alone.
        none,
        /// Digits, with an optional fraction: `2.5`.
        number,
        /// Letters, digits and `_`.
        word,
        /// Anything; quote it to hold `·` or `,`.
        text,
        /// One of these words.
        words: []const []const u8,
        /// One of the values of the story's fact with this name, a `one of` or a `set of`.
        values_of: []const u8,
        /// A section of the story.
        section,
    };

    pub const Count = enum {
        one,
        /// One or more.
        many,
        /// None or more: a key that is also a mark.
        any,
    };

    pub const Key = struct {
        name: []const u8,
        on: Places,
        value: Value = .none,
        count: Count = .one,
        /// On a section, with a section value: when the section ends the host goes on to that one.
        leads: bool = false,
    };

    pub const Found = union(enum) { found: *const Key, elsewhere, unknown };

    /// The key called `name` that may stand at `at`, else whether any key has the name.
    pub fn find(s: *const Schema, name: []const u8, at: Place) Found {
        var elsewhere = false;
        for (s.keys) |*k| if (std.mem.eql(u8, k.name, name)) {
            if (k.on.has(at)) return .{ .found = k };
            elsewhere = true;
        };
        return if (elsewhere) .elsewhere else .unknown;
    }
};

test "a key is found where it may stand" {
    const s: Schema = .{ .keys = &.{
        .{ .name = "at", .on = .{ .line = true }, .value = .number },
        .{ .name = "at", .on = .{ .choice = true }, .value = .word, .count = .many },
    } };
    try std.testing.expectEqual(Schema.Value.word, std.meta.activeTag(s.find("at", .choice).found.value));
    try std.testing.expect(s.find("at", .section) == .elsewhere);
    try std.testing.expect(s.find("heard", .line) == .unknown);
}
