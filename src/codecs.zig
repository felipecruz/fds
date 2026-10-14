//! Decompression for every codec Arrow and Parquet use, behind one call.
//!
//! Files state each buffer's uncompressed size, but a corrupted file can
//! state anything, so the size is treated as a claim. Nothing is allocated
//! for it beyond what the compressed bytes could produce: LZ4 and Snappy
//! have a small maximum ratio, so a larger claim is rejected up front;
//! zstd and gzip have none, so their output grows only as bytes come out,
//! and stops one byte past the claim.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lz4 = @import("lz4.zig");
const snappy = @import("snappy.zig");

pub const Error = error{ Malformed, OutOfMemory };

pub const Codec = enum {
    none,
    snappy, // raw Snappy block (Parquet SNAPPY)
    gzip, // gzip stream (Parquet GZIP)
    lz4_frame, // LZ4 frames (Arrow LZ4_FRAME)
    lz4_raw, // one LZ4 block (Parquet LZ4_RAW)
    lz4_hadoop, // Hadoop-framed LZ4 blocks, or a raw block (Parquet's deprecated LZ4)
    zstd, // zstd frames (Arrow ZSTD, Parquet ZSTD)
};

/// Decompresses `src`, which must produce exactly `n` bytes, into memory
/// from `arena` (or returns `src` itself for `.none`).
pub fn decompress(arena: Allocator, codec: Codec, src: []const u8, n: usize) Error![]const u8 {
    switch (codec) {
        .none => return if (src.len == n) src else error.Malformed,
        .snappy => {
            if (n > snappy.maxDecompressedLen(src.len)) return error.Malformed;
            const out = try arena.alloc(u8, n);
            snappy.decompress(src, out) catch return error.Malformed;
            return out;
        },
        .lz4_frame, .lz4_raw => {
            if (n > lz4.maxDecompressedLen(src.len)) return error.Malformed;
            const out = try arena.alloc(u8, n);
            const result = if (codec == .lz4_frame) lz4.decompress(src, out) else lz4.decompressBlock(src, out);
            result catch return error.Malformed;
            return out;
        },
        .lz4_hadoop => {
            if (n > lz4.maxDecompressedLen(src.len)) return error.Malformed;
            const out = try arena.alloc(u8, n);
            hadoopLz4(src, out) catch lz4.decompressBlock(src, out) catch return error.Malformed;
            return out;
        },
        .zstd => {
            var in: std.Io.Reader = .fixed(src);
            // The whole output stays in memory, so any window size fits.
            var d: std.compress.zstd.Decompress = .init(&in, &.{}, .{ .window_len = 1 << 30 });
            return stream(arena, &d.reader, src.len, n, std.compress.zstd.block_size_max);
        },
        .gzip => {
            var in: std.Io.Reader = .fixed(src);
            var d: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
            return stream(arena, &d.reader, src.len, n, std.compress.flate.max_window_len);
        },
    }
}

// Reads a decompressing reader to its end, into a buffer that starts small
// and grows only as output comes out. The output must be exactly `n` bytes.
fn stream(arena: Allocator, r: *std.Io.Reader, src_len: usize, n: usize, slack: usize) Error![]const u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(arena, @min(n, 16 * src_len + (1 << 16)) + slack);
    while (out.written().len <= n) {
        _ = r.stream(&out.writer, .limited(n + 1 - out.written().len)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.Malformed,
        };
    }
    if (out.written().len != n) return error.Malformed;
    return out.written();
}

// Hadoop's LZ4 framing: blocks, each [u32 BE uncompressed length][u32 BE
// compressed length][LZ4 block].
fn hadoopLz4(src: []const u8, dst: []u8) Error!void {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        if (src.len - i < 8) return error.Malformed;
        const raw_len = std.mem.readInt(u32, src[i..][0..4], .big);
        const len = std.mem.readInt(u32, src[i + 4 ..][0..4], .big);
        i += 8;
        if (len > src.len - i or raw_len > dst.len - o) return error.Malformed;
        lz4.decompressBlock(src[i..][0..len], dst[o..][0..raw_len]) catch return error.Malformed;
        i += len;
        o += raw_len;
    }
    if (o != dst.len) return error.Malformed;
}

test "every codec round trips, and lies about the size are errors" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    // From pyarrow.compress(b"needle in a haystack, " * 4 + b"!", codec).
    const expected = "needle in a haystack, " ++ "needle in a haystack, " ++ "needle in a haystack, " ++ "needle in a haystack, " ++ "!";
    const cases = [_]struct { Codec, []const u8 }{
        .{ .snappy, "\x59\x54\x6e\x65\x65\x64\x6c\x65\x20\x69\x6e\x20\x61\x20\x68\x61\x79\x73\x74\x61\x63\x6b\x2c\x20\xee\x16\x00\x09\x16\x00\x21" },
        .{ .gzip, GZIP },
        .{ .zstd, ZSTD },
        .{ .lz4_raw, LZ4_RAW },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(expected, try decompress(ar, c[0], c[1], expected.len));
        try std.testing.expectError(error.Malformed, decompress(ar, c[0], c[1], expected.len - 1));
        try std.testing.expectError(error.Malformed, decompress(ar, c[0], c[1], expected.len + 1));
        // A huge claim fails without allocating it.
        try std.testing.expectError(error.Malformed, decompress(ar, c[0], c[1], 1 << 40));
    }
}

const GZIP = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x4b\x4d\x4d\xc9\x49\x55\xc8\xcc\x53\x48\x54\xc8\x48\xac\x2c\x2e\x49\x4c\xce\xd6\x51\xc8\xa3\x58\x54\x11\x00\x69\xca\x71\xec\x59\x00\x00\x00";
const ZSTD = "\x28\xb5\x2f\xfd\x20\x59\xf5\x00\x00\xb8\x6e\x65\x65\x64\x6c\x65\x20\x69\x6e\x20\x61\x20\x68\x61\x79\x73\x74\x61\x63\x6b\x2c\x20\x21\x01\x00\x9e\xd2\x6c\x02";
const LZ4_RAW = "\xff\x07\x6e\x65\x65\x64\x6c\x65\x20\x69\x6e\x20\x61\x20\x68\x61\x79\x73\x74\x61\x63\x6b\x2c\x20\x16\x00\x2b\x50\x63\x6b\x2c\x20\x21";
