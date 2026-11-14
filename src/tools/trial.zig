//! A story put through everything a game does with it: read, checked with
//! the vocabulary's packages, compiled, and, when it compiles, loaded and
//! told a bounded number of steps, with a package's own runtime run over
//! it too. What the whole compiler promises over any text, so a property
//! asks it of riverrun and of each package alike: a story told, or
//! diagnostics placed in the files they are about, and never anything else
//! (a `Fault`). A crash, a hang or a leak is the property's to see.

const std = @import("std");
const river = @import("riverrun-compiler");
const Manuscript = @import("Manuscript.zig");
const walk = @import("walk.zig");

const syntax = river.syntax;

/// What the whole compiler never gives.
pub const Fault = union(enum) {
    /// The checker passed a story the compiler could not build, and nothing says where.
    unbuilt: river.compile.Compiler.Error,
    /// No story and no error.
    silent,
    /// A diagnostic whose range is not in its file: where it was.
    misplaced: syntax.Span,
    /// The runtime refused what the compiler wrote.
    unloaded: walk.LoadError,
    /// A package's runtime refused what its compile pass wrote.
    package,
};

pub const Outcome = union(enum) {
    /// Refused, with diagnostics placed in the files.
    refused,
    /// Compiled, loaded and told.
    told: walk.Told,
    fault: Fault,
};

/// A package's own runtime, run over the loaded story once it has been told: it returns `error.Refused` where
/// its runtime refuses what its compile pass wrote, and anything its runtime names otherwise is the story's.
pub const Package = struct {
    ctx: ?*anyopaque = null,
    run: *const fn (ctx: ?*anyopaque, loaded: *walk.Loaded) error{ OutOfMemory, Refused }!void,
};

pub const Options = struct {
    mode: river.check.Mode = .development,
    walk: walk.Options = .{},
    package: ?Package = null,
};

pub fn trial(gpa: std.mem.Allocator, pages: []const Manuscript.Page, joined: river.Joined, options: Options, chooser: walk.Chooser) error{ OutOfMemory, TooManyFiles }!Outcome {
    var m, var out = Manuscript.build(gpa, pages, joined, options.mode) catch |e| return switch (e) {
        error.OutOfMemory, error.TooManyFiles => |other| other,
        else => |unbuilt| .{ .fault = .{ .unbuilt = unbuilt } },
    };
    defer m.deinit();
    defer if (out) |*o| o.deinit(gpa);
    for (m.diags.list.items) |d| {
        if (d.span.start == syntax.Span.none.start) continue;
        if (d.span.file >= pages.len or d.span.start > d.span.end or d.span.end > pages[d.span.file].text.len) return .{ .fault = .{ .misplaced = d.span } };
    }
    const compiled = out orelse return if (m.errors() > 0) .refused else .{ .fault = .silent };
    var loaded: walk.Loaded = undefined;
    loaded.init(gpa, compiled.graph, compiled.words) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => |refused| .{ .fault = .{ .unloaded = refused } },
    };
    defer loaded.deinit();
    const told = walk.walk(gpa, &loaded, options.walk, chooser) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.HostNotBound => .{ .fault = .{ .unloaded = error.HostNotBound } },
    };
    if (options.package) |p| p.run(p.ctx, &loaded) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Refused => .{ .fault = .package },
    };
    return .{ .told = told };
}

/// A message for a fault, for the property that found it.
pub fn describe(f: Fault, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (f) {
        .unbuilt => |e| try w.print("the checker passed a story the compiler could not build, with no place: {t}", .{e}),
        .silent => try w.writeAll("no story and no error"),
        .misplaced => |s| try w.print("a diagnostic outside its file: file {d}, bytes {d}..{d}", .{ s.file, s.start, s.end }),
        .unloaded => |e| try w.print("the runtime refused what the compiler wrote: {t}", .{e}),
        .package => try w.writeAll("the package's runtime refused what its compile pass wrote"),
    }
}
