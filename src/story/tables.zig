//! The tables of a compiled file, found through its header and directory,
//! each record read where it lies. Opening checks the header, the directory
//! and the hash; what the records say is `validate`'s.
//!
//! The story graph and the string table share this layout, each with tables
//! of its own, so one reader opens both.

const std = @import("std");
const builtin = @import("builtin");
const format = @import("format.zig");
const aegis = @import("aegis");

comptime {
    // Records are viewed in place: every target riverrun builds for is little-endian.
    if (builtin.cpu.arch.endian() != .little) @compileError("riverrun reads its compiled format on little-endian hosts");
}

pub const Error = error{
    TooShort,
    TooLarge,
    BadMagic,
    UnsupportedVersion,
    /// The header's length is not the file's.
    LengthMismatch,
    BadHash,
    /// A table this version needs is missing from the directory.
    MissingTable,
    /// A table past the end of the file, misaligned, or with records smaller than this version's.
    BadTable,
    /// A name past its table, cut through a character, or not UTF-8.
    BadName,
    /// An index past its table.
    OutOfRange,
    /// An enumeration's tag that names nothing.
    BadKind,
    /// A condition, a value or arguments that do not evaluate to what their place needs.
    BadExpression,
    /// A step whose fields do not fit its kind.
    BadNode,
    TooManyFacts,
    TooManyScopes,
    TooManyItems,
    TooManyChoices,
    TooManySlots,
    /// The reserved scope, or the executor's facts, are not as the format says.
    BadReserved,
    /// A string table whose ids are not in strictly ascending order.
    Unsorted,
    BadTemplate,
};

pub fn Tables(comptime T: type, comptime Record: fn (comptime T) type) type {
    const count = @typeInfo(T).@"enum".field_names.len;
    return struct {
        const Self = @This();

        bytes: []const u8,
        dirs: [count]format.Dir,
        header: format.Header,

        /// The header and directory of `bytes`, checked against `magic` and, if asked, the hash.
        pub fn open(bytes: []const u8, magic: [8]u8, verify_hash: bool) Error!Self {
            if (bytes.len > format.max_bytes) return error.TooLarge;
            if (bytes.len < @sizeOf(format.Header)) return error.TooShort;
            const header = std.mem.bytesToValue(format.Header, bytes[0..@sizeOf(format.Header)]);
            if (!std.mem.eql(u8, &header.magic, &magic)) return error.BadMagic;
            if (header.major != format.major) return error.UnsupportedVersion;
            if (header.length != bytes.len) return error.LengthMismatch;
            if (header.tables < count) return error.MissingTable;
            const dir_end = @sizeOf(format.Header) + @as(u64, header.tables) * @sizeOf(format.Dir);
            if (dir_end > bytes.len) return error.TooShort;
            if (verify_hash and hashOf(bytes) != header.hash) return error.BadHash;
            var t: Self = .{ .bytes = bytes, .dirs = undefined, .header = header };
            inline for (0..count) |i| {
                const at = @sizeOf(format.Header) + i * @sizeOf(format.Dir);
                const d = std.mem.bytesToValue(format.Dir, bytes[at..][0..@sizeOf(format.Dir)]);
                const R = Record(@as(T, @fromBackingInt(i)));
                const size = @as(u64, d.count) * d.stride;
                if (d.stride < @sizeOf(R) or d.offset % format.alignment != 0) return error.BadTable;
                if (d.offset < dir_end or d.offset + size > bytes.len) return error.BadTable;
                t.dirs[i] = d;
            }
            return t;
        }

        pub fn len(t: *const Self, comptime table: T) u32 {
            return t.dirs[@backingInt(table)].count;
        }

        /// Record `i` of `table`, which must be in range.
        pub fn get(t: *const Self, comptime table: T, i: u32) Record(table) {
            const R = Record(table);
            const d = t.dirs[@backingInt(table)];
            aegis.assert.invariant(i < d.count, "the record is in its table, as the caller checks");
            const at = @as(usize, d.offset) + @as(usize, i) * d.stride;
            return std.mem.bytesToValue(R, t.bytes[at..][0..@sizeOf(R)]);
        }

        /// A table of bytes, whole.
        pub fn raw(t: *const Self, comptime table: T) []const u8 {
            const d = t.dirs[@backingInt(table)];
            return t.bytes[d.offset..][0 .. @as(usize, d.count) * d.stride];
        }
    };
}

/// The story graph's tables.
pub const Graph = Tables(format.Table, format.Record);

/// The file's hash: XxHash64, seed 0, of every byte with the header's hash field taken as zero.
pub fn hashOf(bytes: []const u8) u64 {
    const at = @offsetOf(format.Header, "hash");
    var h: std.hash.XxHash64 = .init(0);
    h.update(bytes[0..at]);
    const zero: [8]u8 = @splat(0);
    h.update(&zero);
    h.update(bytes[at + 8 ..]);
    return h.final();
}

/// Whether `s` lies in `names`, whole characters of UTF-8.
pub fn validName(names: []const u8, s: format.Str) bool {
    if (@as(u64, s.offset) + s.len > names.len) return false;
    const bytes = names[s.offset..][0..s.len];
    if (s.len > 0 and isContinuation(bytes[0])) return false;
    if (s.offset + s.len < names.len and isContinuation(names[s.offset + s.len])) return false;
    return true;
}

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// One table's records, as bytes, for `assemble`.
pub const Part = struct { bytes: []const u8, count: u32, stride: u32 };

/// A table's records as a part.
pub fn part(comptime R: type, records: []const R) Part {
    return .{ .bytes = std.mem.sliceAsBytes(records), .count = @intCast(records.len), .stride = @sizeOf(R) }; // safe: tables are bounded by max_bytes
}

/// A file of `parts` in directory order: the header, the directory, then each
/// table aligned, and the hash over all of it. The caller owns the bytes.
pub fn assemble(gpa: std.mem.Allocator, magic: [8]u8, parts: []const Part) error{ OutOfMemory, TooLarge }![]u8 {
    var size: u64 = @sizeOf(format.Header) + parts.len * @sizeOf(format.Dir);
    for (parts) |p| size = std.mem.alignForward(u64, size, format.alignment) + p.bytes.len;
    if (size > format.max_bytes) return error.TooLarge;
    const out = try gpa.alloc(u8, @intCast(size)); // safe: below max_bytes
    @memset(out, 0);
    var at: usize = @sizeOf(format.Header) + parts.len * @sizeOf(format.Dir);
    for (parts, 0..) |p, i| {
        at = std.mem.alignForward(usize, at, format.alignment);
        const d: format.Dir = .{ .offset = @intCast(at), .count = p.count, .stride = p.stride, .reserved = 0 }; // safe: below max_bytes
        @memcpy(out[@sizeOf(format.Header) + i * @sizeOf(format.Dir) ..][0..@sizeOf(format.Dir)], std.mem.asBytes(&d));
        @memcpy(out[at..][0..p.bytes.len], p.bytes);
        at += p.bytes.len;
    }
    var header: format.Header = .{
        .magic = magic,
        .major = format.major,
        .minor = format.minor,
        .flags = 0,
        .hash = 0,
        .length = @intCast(size), // safe: below max_bytes
        .tables = @intCast(parts.len), // safe: a handful of tables
    };
    @memcpy(out[0..@sizeOf(format.Header)], std.mem.asBytes(&header));
    header.hash = hashOf(out);
    @memcpy(out[0..@sizeOf(format.Header)], std.mem.asBytes(&header));
    return out;
}
