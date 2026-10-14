//! Reading Arrow IPC files (.arrow, .feather) and streams (.arrows): just
//! enough to find every string array in each record batch. No I/O: the
//! input is the whole file as bytes (mmap'd by search.zig), and buffers are
//! slices of it unless they are compressed (LZ4 frame or zstd).
//!
//! Both formats are a sequence of messages (schema, dictionary batches,
//! record batches); the file format adds magic bytes and a footer index,
//! which is not needed to read the messages in order. Each message is a
//! FlatBuffers header plus a body of buffers. Every offset and length read
//! from the file is checked: a malformed file is `error.Malformed`.
//!
//! Spec: https://arrow.apache.org/docs/format/Columnar.html

const std = @import("std");
const Allocator = std.mem.Allocator;
const fb = @import("flatbuf.zig");
const lz4 = @import("lz4.zig");

pub const Error = error{ Malformed, Unsupported, OutOfMemory };

/// Values of the `Type` union in Schema.fbs.
pub const TypeId = enum(u8) {
    none = 0,
    null = 1,
    int = 2,
    floating_point = 3,
    binary = 4,
    utf8 = 5,
    bool = 6,
    decimal = 7,
    date = 8,
    time = 9,
    timestamp = 10,
    interval = 11,
    list = 12,
    @"struct" = 13,
    @"union" = 14,
    fixed_size_binary = 15,
    fixed_size_list = 16,
    map = 17,
    duration = 18,
    large_binary = 19,
    large_utf8 = 20,
    large_list = 21,
    run_end_encoded = 22,
    binary_view = 23,
    utf8_view = 24,
    list_view = 25,
    large_list_view = 26,
    _,

    pub fn isString(t: TypeId) bool {
        return t == .utf8 or t == .large_utf8 or t == .utf8_view;
    }
};

pub const Field = struct {
    name: []const u8,
    /// For a dictionary-encoded field, the type of the dictionary's values.
    type: TypeId,
    dict: ?Dict = null,
    sparse_union: bool = false, // with `.union`
    list_size: usize = 0, // with `.fixed_size_list`
    /// Empty for dictionary-encoded fields: in a record batch they are
    /// indices only, and their values come in dictionary batches.
    children: []const Field = &.{},
    /// Position in a pre-order walk of the schema, which is the order of
    /// field nodes in a record batch.
    index: usize = 0,
};

pub const Dict = struct {
    id: i64,
    index_width: u8, // bytes: 1, 2, 4 or 8
    index_signed: bool,
};

pub const Schema = struct {
    fields: []const Field,
    /// Fields in all, nested ones included.
    count: usize,
};

const max_depth = 64;

pub fn parseSchema(arena: Allocator, t: fb.Table) Error!Schema {
    if (try t.scalar(i16, 0, 0) != 0) return error.Unsupported; // big-endian
    var count: usize = 0;
    const fields = try parseFields(arena, try t.vector(1, 4), &count, 0);
    return .{ .fields = fields, .count = count };
}

fn parseFields(arena: Allocator, vec: ?fb.Vector, count: *usize, depth: usize) Error![]const Field {
    const v = vec orelse return &.{};
    if (depth > max_depth) return error.Malformed;
    const fields = try arena.alloc(Field, v.len);
    for (fields, 0..) |*f, i| {
        const t = try v.table(i);
        const type_id: TypeId = @enumFromInt(try t.scalar(u8, 2, 0));
        f.* = .{ .name = try t.string(0) orelse "", .type = type_id, .index = count.* };
        count.* += 1;
        if (try t.table(4)) |d| {
            var width: i32 = 32;
            var signed = true; // no index type given means int32
            if (try d.table(1)) |int| {
                width = try int.scalar(i32, 0, 0);
                signed = try int.scalar(bool, 1, false);
            }
            if (width != 8 and width != 16 and width != 32 and width != 64) return error.Malformed;
            f.dict = .{ .id = try d.scalar(i64, 0, 0), .index_width = @intCast(@divExact(width, 8)), .index_signed = signed };
            continue; // children describe the values, which are not in record batches
        }
        const type_table = try t.table(3);
        switch (type_id) {
            .@"union" => f.sparse_union = if (type_table) |u| try u.scalar(i16, 0, 0) == 0 else true,
            .fixed_size_list => {
                const size = if (type_table) |l| try l.scalar(i32, 0, 0) else 0;
                if (size < 0) return error.Malformed;
                f.list_size = @intCast(size);
            },
            else => {},
        }
        f.children = try parseFields(arena, try t.vector(5, 4), count, depth + 1);
    }
    return fields;
}

pub const Message = struct {
    kind: enum { schema, dictionary, record_batch, other },
    header: fb.Table,
    body: []const u8,
};

/// Reads the messages of an IPC file or stream in order.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize,
    end: usize, // where messages end: the footer, or the end of a stream

    pub fn init(bytes: []const u8) Error!Reader {
        const magic = "ARROW1";
        if (std.mem.startsWith(u8, bytes, "FEA1")) return error.Unsupported; // Feather v1 (2016)
        if (!std.mem.startsWith(u8, bytes, magic)) return .{ .bytes = bytes, .pos = 0, .end = bytes.len }; // a stream
        // File: magic, padding, messages, footer, footer length, magic.
        if (bytes.len < 8 + 4 + magic.len or !std.mem.endsWith(u8, bytes, magic)) return error.Malformed;
        const footer_len = try fb.readInt(i32, bytes, bytes.len - magic.len - 4);
        const footer_start = @as(i64, @intCast(bytes.len - magic.len - 4)) - footer_len;
        if (footer_len < 0 or footer_start < 8) return error.Malformed;
        return .{ .bytes = bytes, .pos = 8, .end = @intCast(footer_start) };
    }

    /// The next message, or null at the end-of-stream marker or the end.
    pub fn next(r: *Reader) Error!?Message {
        if (r.end - r.pos < 4) return null;
        var len = try fb.readInt(u32, r.bytes, r.pos);
        r.pos += 4;
        if (len == 0xFFFF_FFFF) { // continuation marker, then the length
            if (r.end - r.pos < 4) return null;
            len = try fb.readInt(u32, r.bytes, r.pos);
            r.pos += 4;
        }
        if (len == 0) return null; // end of stream
        if (len > r.end - r.pos) return error.Malformed;
        const message = try fb.Table.root(r.bytes[r.pos..][0..len]);
        r.pos += len;

        const body_len = try message.scalar(i64, 3, 0);
        if (body_len < 0 or body_len > r.end - r.pos) return error.Malformed;
        const body = r.bytes[r.pos..][0..@intCast(body_len)];
        r.pos += body.len;

        const header = try message.table(2) orelse return .{ .kind = .other, .header = undefined, .body = body };
        return .{
            .kind = switch (try message.scalar(u8, 1, 0)) {
                1 => .schema,
                2 => .dictionary,
                3 => .record_batch,
                else => .other,
            },
            .header = header,
            .body = body,
        };
    }
};

pub const DictionaryBatch = struct {
    id: i64,
    delta: bool,
    batch: Batch,

    pub fn parse(t: fb.Table, body: []const u8) Error!DictionaryBatch {
        const data = try t.table(1) orelse return error.Malformed;
        return .{ .id = try t.scalar(i64, 0, 0), .delta = try t.scalar(bool, 2, false), .batch = try .parse(data, body) };
    }
};

/// Where a field's node and buffers are in a record batch.
pub const Column = struct {
    node: usize,
    buffer: usize, // the first of the field's own buffers
    variadic: usize = 0, // extra data buffers (string views)
};

pub const Batch = struct {
    length: usize,
    nodes: fb.Vector, // FieldNode { length: i64, null_count: i64 }
    buffers: fb.Vector, // Buffer { offset: i64, length: i64 }
    variadic: ?fb.Vector, // i64 counts, one per view-typed field
    codec: ?enum { lz4, zstd },
    body: []const u8,

    pub fn parse(t: fb.Table, body: []const u8) Error!Batch {
        const empty: fb.Vector = .{ .buf = "", .start = 0, .len = 0, .elem_size = 16 };
        const length = try t.scalar(i64, 0, 0);
        if (length < 0) return error.Malformed;
        return .{
            .length = @intCast(length),
            .nodes = try t.vector(1, 16) orelse empty,
            .buffers = try t.vector(2, 16) orelse empty,
            .variadic = try t.vector(4, 8),
            .codec = if (try t.table(3)) |c| switch (try c.scalar(i8, 0, 0)) {
                0 => .lz4,
                1 => .zstd,
                else => return error.Unsupported,
            } else null,
            .body = body,
        };
    }

    /// Node and buffer positions of every field, indexed by `Field.index`.
    pub fn layout(b: *const Batch, arena: Allocator, schema: Schema) Error![]Column {
        const columns = try arena.alloc(Column, schema.count);
        var c: Cursor = .{};
        for (schema.fields) |*f| try b.place(f, columns, &c);
        return columns;
    }

    /// The layout of a dictionary batch: one column of type `value_type`.
    pub fn dictionaryColumn(b: *const Batch, value_type: TypeId) Error!Column {
        var columns: [1]Column = undefined;
        var c: Cursor = .{};
        try b.place(&.{ .name = "", .type = value_type }, &columns, &c);
        return columns[0];
    }

    const Cursor = struct { node: usize = 0, buffer: usize = 0, variadic: usize = 0 };

    fn place(b: *const Batch, f: *const Field, columns: []Column, c: *Cursor) Error!void {
        var col: Column = .{ .node = c.node, .buffer = c.buffer };
        c.node += 1;
        c.buffer += if (f.dict != null) 2 else switch (f.type) {
            .null, .run_end_encoded => 0,
            .@"struct", .fixed_size_list => 1,
            .@"union" => if (f.sparse_union) 1 else 2,
            .binary, .utf8, .large_binary, .large_utf8, .list_view, .large_list_view => 3,
            .binary_view, .utf8_view => blk: {
                const v = b.variadic orelse return error.Malformed;
                const n = try v.int(i64, c.variadic, 0);
                if (n < 0 or n > b.buffers.len) return error.Malformed;
                c.variadic += 1;
                col.variadic = @intCast(n);
                break :blk 2 + col.variadic;
            },
            .none => return error.Malformed,
            else => 2, // fixed-width types and lists: validity + data or offsets
        };
        if (col.node >= b.nodes.len or c.buffer > b.buffers.len) return error.Malformed;
        if (f.index < columns.len) columns[f.index] = col;
        for (f.children) |*child| try b.place(child, columns, c);
    }

    /// Length of the array at `col`.
    pub fn len(b: *const Batch, col: Column) Error!usize {
        const n = try b.nodes.int(i64, col.node, 0);
        if (n < 0 or n > std.math.maxInt(u32) * 64) return error.Malformed;
        return @intCast(n);
    }

    fn nullCount(b: *const Batch, col: Column) Error!i64 {
        return b.nodes.int(i64, col.node, 8);
    }

    /// Buffer `i` of the body, decompressed if needed (into `arena`).
    pub fn buffer(b: *const Batch, arena: Allocator, i: usize) Error![]const u8 {
        const offset = try b.buffers.int(i64, i, 0);
        const length = try b.buffers.int(i64, i, 8);
        if (offset < 0 or length < 0 or offset > b.body.len or length > b.body.len - @as(usize, @intCast(offset))) return error.Malformed;
        const raw = b.body[@intCast(offset)..][0..@intCast(length)];
        const codec = b.codec orelse return raw;
        if (raw.len == 0) return raw;
        // Compressed buffers start with their uncompressed length; -1 means
        // the buffer was stored uncompressed.
        const n = try fb.readInt(i64, raw, 0);
        if (n == -1) return raw[8..];
        if (n < 0 or n > 1 << 40) return error.Malformed;
        switch (codec) {
            .lz4 => {
                const out = try arena.alloc(u8, @intCast(n));
                lz4.decompress(raw[8..], out) catch return error.Malformed;
                return out;
            },
            .zstd => return unzstd(arena, raw[8..], @intCast(n)),
        }
    }

    /// The validity bitmap of `col` (its first buffer), or "" if no value
    /// is null.
    pub fn validity(b: *const Batch, arena: Allocator, col: Column) Error![]const u8 {
        if (try b.nullCount(col) == 0) return "";
        const bits = try b.buffer(arena, col.buffer);
        if (bits.len == 0) return "";
        if (bits.len < std.math.divCeil(usize, try b.len(col), 8) catch unreachable) return error.Malformed;
        return bits;
    }

    /// The values of a string array (`utf8`, `large_utf8` or `utf8_view`).
    pub fn strings(b: *const Batch, arena: Allocator, type_id: TypeId, col: Column) Error!Strings {
        const n = try b.len(col);
        const valid = try b.validity(arena, col);
        switch (type_id) {
            .utf8 => return .{ .len = n, .validity = valid, .values = .{ .small = try offsetValues(i32, try b.buffer(arena, col.buffer + 1), n, try b.buffer(arena, col.buffer + 2)) } },
            .large_utf8 => return .{ .len = n, .validity = valid, .values = .{ .large = try offsetValues(i64, try b.buffer(arena, col.buffer + 1), n, try b.buffer(arena, col.buffer + 2)) } },
            .utf8_view => {
                const views = try b.buffer(arena, col.buffer + 1);
                if (views.len / 16 < n) return error.Malformed;
                const data = try arena.alloc([]const u8, col.variadic);
                for (data, 0..) |*d, i| d.* = try b.buffer(arena, col.buffer + 2 + i);
                const s: Strings = .{ .len = n, .validity = valid, .values = .{ .view = .{ .views = views[0 .. 16 * n], .data = data } } };
                for (0..n) |i| try s.checkView(i);
                return s;
            },
            else => unreachable,
        }
    }

    /// The indices of a dictionary-encoded array.
    pub fn indices(b: *const Batch, arena: Allocator, dict: Dict, col: Column) Error!Indices {
        const n = try b.len(col);
        const bytes = try b.buffer(arena, col.buffer + 1);
        if (bytes.len / dict.index_width < n) return error.Malformed;
        return .{ .len = n, .validity = try b.validity(arena, col), .bytes = bytes, .width = dict.index_width, .signed = dict.index_signed };
    }

    /// How the entries of a nested array (struct, list, map, fixed-size
    /// list) map to its children.
    pub fn level(b: *const Batch, arena: Allocator, f: *const Field, col: Column) Error!Level {
        const n = try b.len(col);
        const valid = try b.validity(arena, col);
        return .{ .len = n, .validity = valid, .children = switch (f.type) {
            .@"struct" => .same,
            .fixed_size_list => .{ .fixed = f.list_size },
            .list, .map => .{ .small = try offsets(i32, try b.buffer(arena, col.buffer + 1), n) },
            .large_list => .{ .large = try offsets(i64, try b.buffer(arena, col.buffer + 1), n) },
            else => unreachable,
        } };
    }
};

// Decompresses zstd frames that must produce exactly `n` bytes. Output is
// limited to n + 1 bytes, so a bad length can't make it run away.
fn unzstd(arena: Allocator, src: []const u8, n: usize) Error![]const u8 {
    const zstd = std.compress.zstd;
    var in: std.Io.Reader = .fixed(src);
    // The whole output stays in memory, so any window size fits.
    var d: zstd.Decompress = .init(&in, &.{}, .{ .window_len = 1 << 30 });
    var out: std.Io.Writer.Allocating = try .initCapacity(arena, n + zstd.block_size_max);
    while (out.written().len <= n) {
        _ = d.reader.stream(&out.writer, .limited(n + 1 - out.written().len)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.Malformed,
        };
    }
    if (out.written().len != n) return error.Malformed;
    return out.written();
}

// `n + 1` offsets, checked to be non-decreasing and non-negative.
fn offsets(comptime O: type, bytes: []const u8, n: usize) Error![]align(1) const O {
    if (bytes.len / @sizeOf(O) < n + 1) return error.Malformed;
    const off = std.mem.bytesAsSlice(O, bytes[0 .. (n + 1) * @sizeOf(O)]);
    if (off[0] < 0) return error.Malformed;
    for (off[0..n], off[1..]) |a, z| if (z < a) return error.Malformed;
    return off;
}

fn offsetValues(comptime O: type, bytes: []const u8, n: usize, data: []const u8) Error!Offsets(O) {
    const off = try offsets(O, bytes, n);
    if (off[n] > data.len) return error.Malformed;
    return .{ .off = off, .data = data };
}

pub fn Offsets(comptime O: type) type {
    return struct { off: []align(1) const O, data: []const u8 };
}

/// Bit `i` of a validity bitmap; "" means every value is valid.
pub fn validBit(bits: []const u8, i: usize) bool {
    return bits.len == 0 or bits[i >> 3] & (@as(u8, 1) << @intCast(i & 7)) != 0;
}

/// A string array. Every offset and view is checked when it is built, so
/// `get` can't go out of bounds.
pub const Strings = struct {
    len: usize,
    validity: []const u8, // "" if no value is null
    values: union(enum) {
        small: Offsets(i32), // utf8
        large: Offsets(i64), // large_utf8
        view: struct { views: []const u8, data: []const []const u8 }, // utf8_view
    },

    pub fn isValid(s: Strings, i: usize) bool {
        return validBit(s.validity, i);
    }

    pub fn get(s: Strings, i: usize) []const u8 {
        return switch (s.values) {
            .small => |v| v.data[@intCast(v.off[i])..@intCast(v.off[i + 1])],
            .large => |v| v.data[@intCast(v.off[i])..@intCast(v.off[i + 1])],
            .view => |v| {
                // A view: length, then the bytes inline (up to 12), or a
                // 4-byte prefix, a buffer index and an offset.
                const view = v.views[16 * i ..][0..16];
                const n: usize = @intCast(std.mem.readInt(i32, view[0..4], .little));
                if (n <= 12) return view[4..][0..n];
                const buf: usize = @intCast(std.mem.readInt(i32, view[8..12], .little));
                const off: usize = @intCast(std.mem.readInt(i32, view[12..16], .little));
                return v.data[buf][off..][0..n];
            },
        };
    }

    fn checkView(s: Strings, i: usize) Error!void {
        const v = s.values.view;
        const view = v.views[16 * i ..][0..16];
        const n = std.mem.readInt(i32, view[0..4], .little);
        if (n < 0) return error.Malformed;
        if (n <= 12) return;
        const buf = std.mem.readInt(i32, view[8..12], .little);
        const off = std.mem.readInt(i32, view[12..16], .little);
        if (buf < 0 or buf >= v.data.len or off < 0) return error.Malformed;
        const data = v.data[@intCast(buf)];
        if (@as(usize, @intCast(off)) > data.len or @as(usize, @intCast(n)) > data.len - @as(usize, @intCast(off))) return error.Malformed;
    }
};

/// The indices of a dictionary-encoded array.
pub const Indices = struct {
    len: usize,
    validity: []const u8,
    bytes: []const u8,
    width: u8,
    signed: bool,

    /// Index `i` as a dictionary key, or null if it can't be one (negative).
    pub fn get(x: Indices, i: usize) ?u64 {
        const p = x.bytes[i * x.width ..];
        const v: i64 = switch (x.width) {
            1 => if (x.signed) @as(i8, @bitCast(p[0])) else p[0],
            2 => if (x.signed) std.mem.readInt(i16, p[0..2], .little) else std.mem.readInt(u16, p[0..2], .little),
            4 => if (x.signed) std.mem.readInt(i32, p[0..4], .little) else std.mem.readInt(u32, p[0..4], .little),
            8 => {
                const u = std.mem.readInt(u64, p[0..8], .little);
                return if (x.signed and @as(i64, @bitCast(u)) < 0) null else u;
            },
            else => unreachable,
        };
        return if (v < 0) null else @intCast(v);
    }
};

/// One nested array on the way from a string array up to its column: how
/// a child entry finds the entry it belongs to.
pub const Level = struct {
    len: usize,
    validity: []const u8,
    children: union(enum) {
        same, // struct: child j belongs to entry j
        fixed: usize, // fixed-size list: entry j / size
        small: []align(1) const i32, // list, map: entry p holds off[p]..off[p + 1]
        large: []align(1) const i64, // large list
    },

    /// The entry that child `j` belongs to, or null if none does (or it is
    /// null). Children are asked about in increasing order, and `cursor`
    /// (starting at 0) remembers where the last one was found.
    pub fn parent(l: Level, j: usize, cursor: *usize) ?usize {
        const p = switch (l.children) {
            .same => j,
            .fixed => |size| if (size == 0) return null else j / size,
            inline .small, .large => |off| blk: {
                if (j < off[0] or j >= off[l.len]) return null;
                // The last p >= cursor with off[p] <= j; off[l.len] > j.
                var lo = cursor.* + 1;
                var hi = l.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (off[mid] > j) hi = mid else lo = mid + 1;
                }
                cursor.* = lo - 1;
                break :blk lo - 1;
            },
        };
        if (p >= l.len or !validBit(l.validity, p)) return null;
        return p;
    }
};
