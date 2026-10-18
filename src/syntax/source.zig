//! Where things are in a story's files, and what is wrong there.
//!
//! Every diagnostic carries the file, the line and the column it is about,
//! and the reader collects them all rather than stopping at the first, so a
//! writer sees every problem in a file at once.

const std = @import("std");

/// A file of the story, by its place in the list the reader was given.
pub const FileId = u16;

/// A place in a file: line and column count from one, as editors show them.
pub const Span = struct {
    file: FileId,
    line: u32,
    col: u32,

    pub const none: Span = .{ .file = 0, .line = 0, .col = 0 };
};

pub const Severity = enum { err, warning };

pub const Diagnostic = struct {
    span: Span,
    severity: Severity,
    message: []const u8,
};

/// The most diagnostics kept for one story: past this, one more says so.
pub const max_diagnostics = 1024;

pub const Diagnostics = struct {
    list: std.ArrayList(Diagnostic) = .empty,
    dropped: usize = 0,

    pub fn deinit(d: *Diagnostics, gpa: std.mem.Allocator) void {
        for (d.list.items) |item| gpa.free(item.message);
        d.list.deinit(gpa);
        d.* = undefined;
    }

    pub fn add(d: *Diagnostics, gpa: std.mem.Allocator, span: Span, severity: Severity, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        if (d.list.items.len == max_diagnostics) {
            d.dropped += 1;
            return;
        }
        const message = try gpa.print(fmt, args);
        errdefer gpa.free(message);
        try d.list.append(gpa, .{ .span = span, .severity = severity, .message = message });
    }

    pub fn errors(d: *const Diagnostics) usize {
        var n: usize = 0;
        for (d.list.items) |item| n += @intFromBool(item.severity == .err);
        return n;
    }
};

test "diagnostics are collected, and counted by severity" {
    const gpa = std.testing.allocator;
    var d: Diagnostics = .{};
    defer d.deinit(gpa);
    try d.add(gpa, .{ .file = 0, .line = 3, .col = 1 }, .err, "unknown speaker {s}", .{"MUM"});
    try d.add(gpa, .{ .file = 0, .line = 4, .col = 1 }, .warning, "nothing sets {s}", .{"met"});
    try std.testing.expectEqual(@as(usize, 1), d.errors());
    try std.testing.expectEqualStrings("unknown speaker MUM", d.list.items[0].message);
}
