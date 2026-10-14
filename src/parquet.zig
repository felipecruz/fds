//! Reading Parquet files: just enough to search their string columns. No
//! I/O: the input is the whole file as bytes (mmap'd by search.zig).
//!
//! A file is `PAR1`, column chunks, a Thrift footer (FileMetaData), its
//! length and `PAR1` again. The footer has the schema and, for each row
//! group, where each column's chunk is. A chunk is pages: an optional
//! dictionary page, then data pages. Each page is a Thrift header, then
//! (compressed) definition levels, which say which rows are null, and
//! values in one of several encodings.
//!
//! Searched: BYTE_ARRAY columns annotated as strings (STRING, ENUM, JSON;
//! or UTF8/ENUM/JSON converted types) with no repeated field above them, so
//! that every value is one row: top-level columns and struct fields
//! (`user.name`). Lists are not searched yet.
//!
//! Pages are skipped without being decompressed when they can't match: a
//! dictionary-encoded page when no dictionary entry matched, and a
//! PLAIN-encoded page when its raw bytes don't contain the term (`mayMatch`).
//!
//! Every offset, length and count read from the file is checked, and sizes
//! claimed by the file never decide an allocation alone: a malformed file
//! is `error.Malformed`, never a crash or a runaway.
//!
//! Spec: https://github.com/apache/parquet-format

const std = @import("std");
const Allocator = std.mem.Allocator;
const codecs = @import("codecs.zig");
const thrift = @import("thrift.zig");

pub const Error = error{ Malformed, Unsupported, OutOfMemory };

/// The most values one data page may hold. Real writers stay far below it
/// (pages are cut at about 1 MB or 20,000 rows); the cap bounds what a
/// corrupted header can make us allocate.
pub const max_page_values = 1 << 24;

/// A string column to search.
pub const Column = struct {
    name: []const u8, // path, joined with "."
    top: []const u8, // its first part: the top-level column
    leaf: usize, // position among the schema's leaves, = its chunk in each row group
    max_def: u16, // definition level of a present value
};

/// One column of one row group: its pages, in a slice of the file.
pub const Chunk = struct {
    codec: ?codecs.Codec, // null: a codec fds can't decompress (LZO, Brotli)
    bytes: []const u8,
    num_values: u64,
    physical_type: i32,
};

pub const RowGroup = struct {
    first_row: u64,
    num_rows: u64,
    chunks: []const Chunk, // one per leaf
};

pub const File = struct {
    columns: []const Column,
    row_groups: []const RowGroup,
};

const magic = "PAR1";

pub fn isParquet(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, magic);
}

/// Reads the footer of a Parquet file.
pub fn open(arena: Allocator, bytes: []const u8) Error!File {
    if (bytes.len < 12 or !std.mem.startsWith(u8, bytes, magic)) return error.Malformed;
    if (std.mem.endsWith(u8, bytes, "PARE")) return error.Unsupported; // encrypted footer
    if (!std.mem.endsWith(u8, bytes, magic)) return error.Malformed;
    const meta_len = std.mem.readInt(u32, bytes[bytes.len - 8 ..][0..4], .little);
    if (meta_len > bytes.len - 12) return error.Malformed;
    const meta_start = bytes.len - 8 - meta_len;
    const data = bytes[0..meta_start]; // where chunks may be

    var r: thrift.Reader = .{ .buf = bytes[meta_start .. bytes.len - 8] };
    var leaves: []const Leaf = &.{};
    var groups: std.ArrayList(RowGroup) = .empty;
    var raw_groups: std.ArrayList([]const RawChunk) = .empty;
    var raw_rows: std.ArrayList(u64) = .empty;
    var last: i16 = 0;
    // FileMetaData { 1: version, 2: schema, 3: num_rows, 4: row_groups, ... }
    while (try r.field(&last)) |f| switch (f.id) {
        2 => leaves = try parseSchema(arena, &r, f.type),
        4 => {
            const l = try listOf(&r, f.type, .@"struct");
            for (0..l.len) |_| {
                const g = try parseRowGroup(arena, &r);
                try raw_groups.append(arena, g.chunks);
                try raw_rows.append(arena, g.num_rows);
            }
        },
        else => try r.skip(f.type),
    };

    var first_row: u64 = 0;
    for (raw_groups.items, raw_rows.items) |chunks, rows| {
        if (chunks.len != leaves.len) return error.Malformed;
        const out = try arena.alloc(Chunk, chunks.len);
        for (chunks, out) |c, *o| o.* = try c.locate(data);
        try groups.append(arena, .{ .first_row = first_row, .num_rows = rows, .chunks = out });
        first_row +|= rows;
    }

    var columns: std.ArrayList(Column) = .empty;
    for (leaves, 0..) |l, i| {
        if (!l.string or l.max_rep > 0) continue;
        try columns.append(arena, .{ .name = l.name, .top = l.top, .leaf = i, .max_def = l.max_def });
    }
    return .{ .columns = columns.items, .row_groups = groups.items };
}

const Leaf = struct {
    name: []const u8,
    top: []const u8,
    max_def: u16,
    max_rep: u16,
    string: bool, // a BYTE_ARRAY annotated as text
};

const Element = struct {
    name: []const u8 = "",
    physical_type: ?i32 = null,
    repetition: i32 = 0, // REQUIRED 0, OPTIONAL 1, REPEATED 2
    num_children: usize = 0,
    text: bool = false,
};

// The schema is a flattened tree: a pre-order list of elements, where each
// group says how many children follow it. Returns the leaves in order.
fn parseSchema(arena: Allocator, r: *thrift.Reader, t: thrift.Type) Error![]const Leaf {
    const l = try listOf(r, t, .@"struct");
    const elems = try arena.alloc(Element, l.len);
    for (elems) |*e| e.* = try parseElement(r);
    if (elems.len == 0) return error.Malformed;

    var leaves: std.ArrayList(Leaf) = .empty;
    var i: usize = 1; // element 0 is the root
    for (0..elems[0].num_children) |_| try walk(arena, elems, &i, &leaves, "", "", 0, 0, 0);
    if (i != elems.len) return error.Malformed;
    return leaves.items;
}

fn walk(arena: Allocator, elems: []const Element, i: *usize, leaves: *std.ArrayList(Leaf), prefix: []const u8, top: []const u8, def: u16, rep: u16, depth: usize) Error!void {
    if (i.* >= elems.len or depth > 64) return error.Malformed;
    const e = elems[i.*];
    i.* += 1;
    const name = if (prefix.len == 0) e.name else try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, e.name });
    const d = def + @intFromBool(e.repetition != 0); // optional and repeated fields add a level
    const p = rep + @intFromBool(e.repetition == 2);
    const t = if (top.len == 0) e.name else top;
    if (e.num_children == 0) {
        try leaves.append(arena, .{ .name = name, .top = t, .max_def = d, .max_rep = p, .string = e.text and e.physical_type == byte_array });
        return;
    }
    for (0..e.num_children) |_| try walk(arena, elems, i, leaves, name, t, d, p, depth + 1);
}

const byte_array = 6;

// SchemaElement { 1: type, 2: type_length, 3: repetition_type, 4: name,
//                 5: num_children, 6: converted_type, ..., 10: logicalType }
fn parseElement(r: *thrift.Reader) Error!Element {
    var e: Element = .{};
    var last: i16 = 0;
    while (try r.field(&last)) |f| switch (f.id) {
        1 => e.physical_type = try r.int(i32, f.type),
        3 => e.repetition = try r.int(i32, f.type),
        4 => e.name = try r.binary(f.type),
        5 => e.num_children = try r.int(usize, f.type),
        // ConvertedType: UTF8 0, ENUM 4, JSON 19.
        6 => e.text = e.text or switch (try r.int(i32, f.type)) {
            0, 4, 19 => true,
            else => false,
        },
        // LogicalType is a union: the set field says which. STRING 1, ENUM 4, JSON 12.
        10 => {
            if (f.type != .@"struct") return error.Malformed;
            var last_lt: i16 = 0;
            while (try r.field(&last_lt)) |lt| {
                if (lt.id == 1 or lt.id == 4 or lt.id == 12) e.text = true;
                try r.skip(lt.type);
            }
        },
        else => try r.skip(f.type),
    };
    return e;
}

const RawChunk = struct {
    codec: i32 = 0,
    num_values: i64 = 0,
    compressed: i64 = 0,
    data_page_offset: i64 = -1,
    dictionary_page_offset: ?i64 = null,
    physical_type: i32 = -1,
    external: bool = false, // stored in another file

    // The chunk's bytes: from its dictionary page (if any) or first data
    // page, `total_compressed_size` long, inside the data part of the file.
    fn locate(c: RawChunk, data: []const u8) Error!Chunk {
        if (c.external) return error.Unsupported;
        const codec = codecFrom(c.codec);
        if (c.num_values < 0) return error.Malformed;
        // No values (an empty row group): nothing to read, and writers
        // leave the page offsets at 0 or anywhere.
        if (c.num_values == 0) return .{ .codec = codec, .bytes = "", .num_values = 0, .physical_type = c.physical_type };
        var start = c.data_page_offset;
        // The dictionary page comes first, if there is one. Some writers
        // store 0 for "no dictionary page".
        if (c.dictionary_page_offset) |d| if (d > 0 and (d < start or start <= 0)) {
            start = d;
        };
        if (start < 4 or c.compressed < 0) return error.Malformed;
        if (start > data.len or c.compressed > data.len - @as(usize, @intCast(start))) return error.Malformed;
        return .{
            .codec = codec,
            .bytes = data[@intCast(start)..][0..@intCast(c.compressed)],
            .num_values = @intCast(c.num_values),
            .physical_type = c.physical_type,
        };
    }
};

// CompressionCodec, or null for one fds can't decompress (3 LZO, 4 BROTLI).
fn codecFrom(c: i32) ?codecs.Codec {
    return switch (c) {
        0 => .none,
        1 => .snappy,
        2 => .gzip,
        5 => .lz4_hadoop,
        6 => .zstd,
        7 => .lz4_raw,
        else => null,
    };
}

// RowGroup { 1: columns, 2: total_byte_size, 3: num_rows, ... }
fn parseRowGroup(arena: Allocator, r: *thrift.Reader) Error!struct { chunks: []const RawChunk, num_rows: u64 } {
    var chunks: []RawChunk = &.{};
    var rows: i64 = 0;
    var last: i16 = 0;
    while (try r.field(&last)) |f| switch (f.id) {
        1 => {
            const l = try listOf(r, f.type, .@"struct");
            chunks = try arena.alloc(RawChunk, l.len);
            for (chunks) |*c| c.* = try parseColumnChunk(r);
        },
        3 => rows = try r.int(i64, f.type),
        else => try r.skip(f.type),
    };
    if (rows < 0) return error.Malformed;
    return .{ .chunks = chunks, .num_rows = @intCast(rows) };
}

// ColumnChunk { 1: file_path, 2: file_offset, 3: meta_data, ... }
// ColumnMetaData { 1: type, 2: encodings, 3: path_in_schema, 4: codec,
//   5: num_values, 6: total_uncompressed_size, 7: total_compressed_size,
//   8: key_value_metadata, 9: data_page_offset, 10: index_page_offset,
//   11: dictionary_page_offset, ... }
fn parseColumnChunk(r: *thrift.Reader) Error!RawChunk {
    var c: RawChunk = .{};
    var last: i16 = 0;
    while (try r.field(&last)) |f| switch (f.id) {
        1 => {
            _ = try r.binary(f.type);
            c.external = true;
        },
        3 => {
            if (f.type != .@"struct") return error.Malformed;
            var last_m: i16 = 0;
            while (try r.field(&last_m)) |m| switch (m.id) {
                1 => c.physical_type = try r.int(i32, m.type),
                4 => c.codec = try r.int(i32, m.type),
                5 => c.num_values = try r.int(i64, m.type),
                7 => c.compressed = try r.int(i64, m.type),
                9 => c.data_page_offset = try r.int(i64, m.type),
                11 => c.dictionary_page_offset = try r.int(i64, m.type),
                else => try r.skip(m.type),
            };
        },
        else => try r.skip(f.type),
    };
    return c;
}

fn listOf(r: *thrift.Reader, t: thrift.Type, elem: thrift.Type) Error!thrift.List {
    if (t != .list) return error.Malformed;
    const l = try r.list();
    if (l.elem != elem and l.len > 0) return error.Malformed;
    return l;
}

// ---------------------------------------------------------------- pages

const PageType = enum(i32) { data = 0, index = 1, dictionary = 2, data_v2 = 3, _ };

const Encoding = enum(i32) {
    plain = 0,
    plain_dictionary = 2,
    rle = 3,
    delta_binary_packed = 5,
    delta_length_byte_array = 6,
    delta_byte_array = 7,
    rle_dictionary = 8,
    _,

    fn isDictionary(e: Encoding) bool {
        return e == .plain_dictionary or e == .rle_dictionary;
    }
};

const PageHeader = struct {
    type: PageType = .index,
    uncompressed: usize = 0,
    compressed: usize = 0,
    num_values: usize = 0,
    encoding: Encoding = .plain,
    // Data page v2 only: levels are stored uncompressed before the values.
    def_len: usize = 0,
    rep_len: usize = 0,
    values_compressed: bool = true,

    // PageHeader { 1: type, 2: uncompressed_page_size, 3: compressed_page_size,
    //   4: crc, 5: data_page_header, 6: index_page_header,
    //   7: dictionary_page_header, 8: data_page_header_v2 }
    // DataPageHeader { 1: num_values, 2: encoding, ... }
    // DictionaryPageHeader { 1: num_values, 2: encoding, 3: is_sorted }
    // DataPageHeaderV2 { 1: num_values, 2: num_nulls, 3: num_rows, 4: encoding,
    //   5: definition_levels_byte_length, 6: repetition_levels_byte_length,
    //   7: is_compressed }
    fn parse(r: *thrift.Reader) Error!PageHeader {
        var h: PageHeader = .{};
        var last: i16 = 0;
        while (try r.field(&last)) |f| switch (f.id) {
            1 => h.type = @enumFromInt(try r.int(i32, f.type)),
            2 => h.uncompressed = try r.int(usize, f.type),
            3 => h.compressed = try r.int(usize, f.type),
            5, 7, 8 => {
                if (f.type != .@"struct") return error.Malformed;
                var last_h: i16 = 0;
                while (try r.field(&last_h)) |g| {
                    switch (g.id) {
                        1 => h.num_values = try r.int(usize, g.type),
                        2 => if (f.id != 8) {
                            h.encoding = @enumFromInt(try r.int(i32, g.type));
                        } else try r.skip(g.type),
                        4 => if (f.id == 8) {
                            h.encoding = @enumFromInt(try r.int(i32, g.type));
                        } else try r.skip(g.type),
                        5 => if (f.id == 8) {
                            h.def_len = try r.int(usize, g.type);
                        } else try r.skip(g.type),
                        6 => if (f.id == 8) {
                            h.rep_len = try r.int(usize, g.type);
                        } else try r.skip(g.type),
                        7 => if (f.id == 8) {
                            h.values_compressed = try r.boolean(g.type);
                        } else try r.skip(g.type),
                        else => try r.skip(g.type),
                    }
                }
            },
            else => try r.skip(f.type),
        };
        return h;
    }
};

/// Searches a column chunk. `matcher` has `findValues(O, off, data, sink)`,
/// `matches(value) bool` and `mayMatch(bytes) bool` (false only if no value
/// in `bytes` can match). `sink.onValue(slot, value)` gets each matching
/// value, `slot` being its row within the chunk, in order.
pub fn searchChunk(arena: Allocator, chunk: Chunk, column: Column, matcher: anytype, sink: anytype) !void {
    if (chunk.physical_type != byte_array) return error.Malformed;
    const codec = chunk.codec orelse return error.Unsupported;
    var dict: ?Dictionary = null;
    var pos: usize = 0;
    var slot: usize = 0; // row of the next page's first value
    while (pos < chunk.bytes.len and slot < chunk.num_values) {
        var r: thrift.Reader = .{ .buf = chunk.bytes, .pos = pos };
        const h = try PageHeader.parse(&r);
        if (h.compressed > chunk.bytes.len - r.pos) return error.Malformed;
        const page = chunk.bytes[r.pos..][0..h.compressed];
        pos = r.pos + h.compressed;
        switch (h.type) {
            .dictionary => {
                if (dict != null) return error.Malformed; // one per chunk
                const values = try codecs.decompress(arena, codec, page, h.uncompressed);
                dict = try .init(arena, values, h.num_values, matcher);
            },
            .data, .data_v2 => {
                if (h.num_values > max_page_values) return error.Unsupported;
                try searchPage(arena, codec, h, page, column, if (dict) |*d| d else null, matcher, Offset(@TypeOf(sink)){ .sink = sink, .base = slot });
                slot += h.num_values;
            },
            else => {}, // index pages
        }
    }
}

// Adds the page's first row to every slot.
fn Offset(comptime Sink: type) type {
    return struct {
        sink: Sink,
        base: usize,
        fn onValue(o: @This(), slot: usize, value: []const u8) !void {
            try o.sink.onValue(o.base + slot, value);
        }
    };
}

fn searchPage(arena: Allocator, codec: codecs.Codec, h: PageHeader, page: []const u8, column: Column, dict: ?*const Dictionary, matcher: anytype, sink: anytype) !void {
    // A dictionary page with no matching entry: nothing here can match,
    // so the page is not even decompressed.
    if (h.encoding.isDictionary()) {
        const d = dict orelse return error.Malformed;
        if (!d.any) return;
    }

    // Definition levels, then values.
    var def_levels: []const u8 = "";
    var values: []const u8 = undefined;
    if (h.type == .data) {
        const data = try codecs.decompress(arena, codec, page, h.uncompressed);
        var rest = data;
        if (column.max_def > 0) {
            if (rest.len < 4) return error.Malformed;
            const len = std.mem.readInt(u32, rest[0..4], .little);
            if (len > rest.len - 4) return error.Malformed;
            def_levels = rest[4..][0..len];
            rest = rest[4 + len ..];
        }
        values = rest;
    } else {
        if (h.rep_len > page.len or h.def_len > page.len - h.rep_len) return error.Malformed;
        def_levels = page[h.rep_len..][0..h.def_len];
        const rest = page[h.rep_len + h.def_len ..];
        if (h.uncompressed < h.rep_len + h.def_len) return error.Malformed;
        const n = h.uncompressed - h.rep_len - h.def_len;
        values = if (h.values_compressed and codec != .none) try codecs.decompress(arena, codec, rest, n) else rest;
    }
    if (h.encoding == .plain and !matcher.mayMatch(values)) return;

    // Which rows hold a value: those whose level is the maximum.
    const slots = try presentSlots(arena, def_levels, column.max_def, h.num_values);
    const n = if (slots) |s| s.len else h.num_values;
    const slot_sink: Slots(@TypeOf(sink)) = .{ .sink = sink, .slots = slots };

    switch (h.encoding) {
        .plain => {
            const v = try plainValues(arena, values, n);
            try matcher.findValues(i64, v.off, v.data, slot_sink);
        },
        .plain_dictionary, .rle_dictionary => {
            const d = dict.?;
            if (values.len < 1 or values[0] > 32) return error.Malformed;
            const keys = try hybrid(arena, values[1..], values[0], n);
            for (keys, 0..) |k, i| {
                if (k >= d.len()) return error.Malformed;
                if (d.matches.isSet(k)) try slot_sink.onValue(i, d.get(k));
            }
        },
        .delta_length_byte_array => {
            var p: usize = 0;
            const lengths = try deltaBinaryPacked(arena, values, &p, n);
            const v = try lengthValues(arena, lengths, values[p..]);
            try matcher.findValues(i64, v.off, v.data, slot_sink);
        },
        .delta_byte_array => {
            const v = try deltaByteArray(arena, values, n);
            try matcher.findValues(i64, v.off, v.data, slot_sink);
        },
        else => return error.Unsupported,
    }
}

// Maps the index of a value among the page's present values to its row.
fn Slots(comptime Sink: type) type {
    return struct {
        sink: Sink,
        slots: ?[]const u32, // null: every row has a value
        pub fn onValue(s: @This(), i: usize, value: []const u8) !void {
            try s.sink.onValue(if (s.slots) |sl| sl[i] else i, value);
        }
    };
}

// The rows (within the page) that hold a value, or null if all do.
fn presentSlots(arena: Allocator, def_levels: []const u8, max_def: u16, n: usize) Error!?[]const u32 {
    if (max_def == 0) return null;
    const levels = try hybrid(arena, def_levels, bitWidth(max_def), n);
    var count: usize = 0;
    for (levels) |l| count += @intFromBool(l == max_def);
    if (count == n) return null;
    const slots = try arena.alloc(u32, count);
    var k: usize = 0;
    for (levels, 0..) |l, i| if (l == max_def) {
        slots[k] = @intCast(i);
        k += 1;
    };
    return slots;
}

fn bitWidth(max: u16) u6 {
    return @intCast(16 - @clz(max));
}

/// Values as offsets into contiguous data, as match.findValues takes them.
const Values = struct { off: []const i64, data: []const u8 };

// PLAIN byte arrays: each a 4-byte length, then its bytes. Copied out so
// they are back to back.
fn plainValues(arena: Allocator, buf: []const u8, n: usize) Error!Values {
    // Every value takes at least its 4-byte length.
    if (n > buf.len / 4) return error.Malformed;
    const off = try arena.alloc(i64, n + 1);
    const data = try arena.alloc(u8, buf.len - 4 * n);
    var p: usize = 0;
    var o: usize = 0;
    off[0] = 0;
    for (0..n) |i| {
        if (buf.len - p < 4) return error.Malformed;
        const len = std.mem.readInt(u32, buf[p..][0..4], .little);
        p += 4;
        if (len > buf.len - p or len > data.len - o) return error.Malformed;
        @memcpy(data[o..][0..len], buf[p..][0..len]);
        p += len;
        o += len;
        off[i + 1] = @intCast(o);
    }
    return .{ .off = off, .data = data[0..o] };
}

// Values given their lengths, stored back to back in `data`.
fn lengthValues(arena: Allocator, lengths: []const i64, data: []const u8) Error!Values {
    const off = try arena.alloc(i64, lengths.len + 1);
    off[0] = 0;
    var total: u64 = 0;
    for (lengths, 1..) |l, i| {
        if (l < 0) return error.Malformed;
        total += @intCast(l);
        if (total > data.len) return error.Malformed;
        off[i] = @intCast(total);
    }
    return .{ .off = off, .data = data };
}

// DELTA_BYTE_ARRAY: each value is a prefix of the previous one plus a
// suffix. Prefix lengths, then the suffixes as DELTA_LENGTH_BYTE_ARRAY.
fn deltaByteArray(arena: Allocator, buf: []const u8, n: usize) Error!Values {
    var p: usize = 0;
    const prefixes = try deltaBinaryPacked(arena, buf, &p, n);
    const suffix_lengths = try deltaBinaryPacked(arena, buf, &p, n);
    const suffixes = try lengthValues(arena, suffix_lengths, buf[p..]);
    // Rebuilt values can be much larger than the page (that is the point
    // of the encoding), but not without bound.
    const max_bytes = 256 << 20;
    var out: std.ArrayList(u8) = .empty;
    const off = try arena.alloc(i64, n + 1);
    off[0] = 0;
    var prev_start: usize = 0;
    var prev_len: usize = 0;
    for (prefixes, 0..) |pre, i| {
        if (pre < 0 or pre > prev_len) return error.Malformed;
        const suffix = suffixes.data[@intCast(suffixes.off[i])..@intCast(suffixes.off[i + 1])];
        const start = out.items.len;
        const len = @as(usize, @intCast(pre)) + suffix.len;
        if (len > max_bytes - start) return error.Unsupported;
        try out.ensureUnusedCapacity(arena, len);
        out.appendSliceAssumeCapacity(out.items[prev_start..][0..@intCast(pre)]);
        out.appendSliceAssumeCapacity(suffix);
        off[i + 1] = @intCast(out.items.len);
        prev_start = start;
        prev_len = len;
    }
    return .{ .off = off, .data = out.items };
}

// The RLE / bit-packing hybrid: runs of one repeated value, or groups of 8
// bit-packed values, until `n` values are read.
fn hybrid(arena: Allocator, buf: []const u8, bit_width: u8, n: usize) Error![]const u32 {
    if (bit_width > 32) return error.Malformed;
    const out = try arena.alloc(u32, n);
    var i: usize = 0;
    var p: usize = 0;
    while (i < n) {
        const header = try varint(buf, &p);
        if (header & 1 == 0) { // run: count, then the value in ceil(width / 8) bytes
            const count = header >> 1;
            if (count == 0) return error.Malformed;
            const bytes = (@as(usize, bit_width) + 7) / 8;
            if (buf.len - p < bytes) return error.Malformed;
            var v: u32 = 0;
            for (buf[p..][0..bytes], 0..) |b, k| v |= @as(u32, b) << @intCast(8 * k);
            p += bytes;
            if (bit_width < 32 and v >> @intCast(bit_width) != 0) return error.Malformed;
            const take: usize = @intCast(@min(count, n - i));
            @memset(out[i..][0..take], v);
            i += take;
        } else { // bit-packed: groups of 8 values, `width` bytes per group
            const groups = header >> 1;
            if (groups > (buf.len - p) / @max(1, bit_width)) return error.Malformed;
            const bytes: usize = @intCast(groups * bit_width);
            const count: usize = @intCast(groups * 8);
            const take = @min(count, n - i);
            for (0..take) |k| out[i + k] = @intCast(unpack(buf[p..][0..bytes], k, bit_width));
            p += bytes;
            i += take;
        }
    }
    return out;
}

// DELTA_BINARY_PACKED: a header (block size, miniblocks per block, count,
// first value), then blocks: a min delta, each miniblock's bit width, and
// the miniblocks, each holding deltas from the min. Exactly `n` values are
// expected; `p` ends after the last miniblock used.
fn deltaBinaryPacked(arena: Allocator, buf: []const u8, p: *usize, n: usize) Error![]const i64 {
    const block_size = try varint(buf, p);
    const miniblocks = try varint(buf, p);
    const total = try varint(buf, p);
    var value = try zigzag(buf, p);
    if (total != n) return error.Malformed;
    if (block_size == 0 or block_size % 128 != 0 or block_size > 1 << 20) return error.Malformed;
    if (miniblocks == 0 or block_size % miniblocks != 0 or (block_size / miniblocks) % 32 != 0) return error.Malformed;
    const per_miniblock: usize = @intCast(block_size / miniblocks);
    const out = try arena.alloc(i64, n);
    if (n == 0) return out;
    out[0] = value;
    var got: usize = 1;
    while (got < n) {
        const min_delta = try zigzag(buf, p);
        if (buf.len - p.* < miniblocks) return error.Malformed;
        const widths = buf[p.*..][0..@intCast(miniblocks)];
        p.* += widths.len;
        for (widths) |w| {
            if (got == n) break; // later miniblocks are absent
            if (w > 64) return error.Malformed;
            const bytes = per_miniblock * w / 8;
            if (buf.len - p.* < bytes) return error.Malformed;
            const mini = buf[p.*..][0..bytes];
            p.* += bytes;
            for (0..@min(per_miniblock, n - got)) |k| {
                value = value +% min_delta +% @as(i64, @bitCast(unpack(mini, k, @intCast(w))));
                out[got] = value;
                got += 1;
            }
        }
    }
    return out;
}

// Value `k` of `width` bits, packed least significant bit first.
fn unpack(bytes: []const u8, k: usize, width: u8) u64 {
    if (width == 0) return 0;
    const bit = k * width;
    var window: u128 = 0;
    const first = bit / 8;
    const last = @min(bytes.len, (bit + width + 7) / 8);
    for (bytes[first..last], 0..) |b, j| window |= @as(u128, b) << @intCast(8 * j);
    const v = window >> @intCast(bit % 8);
    return @truncate(if (width == 64) v else v & ((@as(u128, 1) << @intCast(width)) - 1));
}

fn varint(buf: []const u8, p: *usize) Error!u64 {
    var v: u64 = 0;
    var shift: u7 = 0;
    while (true) {
        if (p.* >= buf.len) return error.Malformed;
        const b = buf[p.*];
        p.* += 1;
        v |= @as(u64, b & 0x7f) << @intCast(shift);
        if (b & 0x80 == 0) return v;
        shift += 7;
        if (shift > 63) return error.Malformed;
    }
}

fn zigzag(buf: []const u8, p: *usize) Error!i64 {
    const v = try varint(buf, p);
    return @as(i64, @bitCast(v >> 1)) ^ -@as(i64, @intCast(v & 1));
}

// A chunk's dictionary: its values, searched once, and which keys matched.
const Dictionary = struct {
    values: Values,
    matches: std.DynamicBitSetUnmanaged,
    any: bool,

    fn init(arena: Allocator, buf: []const u8, n: usize, matcher: anytype) !Dictionary {
        var d: Dictionary = .{ .values = try plainValues(arena, buf, n), .matches = try .initEmpty(arena, n), .any = false };
        try matcher.findValues(i64, d.values.off, d.values.data, Mark{ .bits = &d.matches });
        d.any = d.matches.count() > 0;
        return d;
    }

    fn len(d: *const Dictionary) usize {
        return d.values.off.len - 1;
    }

    fn get(d: *const Dictionary, k: usize) []const u8 {
        return d.values.data[@intCast(d.values.off[k])..@intCast(d.values.off[k + 1])];
    }

    const Mark = struct {
        bits: *std.DynamicBitSetUnmanaged,
        pub fn onValue(m: Mark, i: usize, _: []const u8) !void {
            m.bits.set(i);
        }
    };
};

test "hybrid and delta decoding" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A run of five 1s, then a bit-packed group of 8 values 0..7 (width 3).
    const h = [_]u8{ 5 << 1, 1, (1 << 1) | 1, 0b10001000, 0b11000110, 0b11111010 };
    try std.testing.expectEqualSlices(u32, &.{ 1, 1, 1, 1, 1, 0, 1, 2, 3, 4, 5, 6, 7 }, try hybrid(a, &h, 3, 13));
    try std.testing.expectError(error.Malformed, hybrid(a, h[0..4], 3, 13));
    // DELTA_BINARY_PACKED for 1, 2, 3, 4, 5: block 128, 4 miniblocks, 5
    // values, first 1; min delta 1, widths 0 (no data needed).
    const d = [_]u8{ 0x80, 0x01, 4, 5, 2, 2, 0, 0, 0, 0 };
    var p: usize = 0;
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3, 4, 5 }, try deltaBinaryPacked(a, &d, &p, 5));
    try std.testing.expectEqual(d.len, p);
    p = 0;
    try std.testing.expectError(error.Malformed, deltaBinaryPacked(a, &d, &p, 6));
    try std.testing.expectEqual(3, bitWidth(4));
    try std.testing.expectEqual(1, bitWidth(1));
}
