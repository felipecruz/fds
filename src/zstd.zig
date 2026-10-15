//! zstd decompression through the reference implementation
//! (third_party/zstd, built by build.zig: decompressor only). Zig's
//! std.compress.zstd decodes at about 175 MB/s per core; this one at about
//! 1.5 GB/s, which decides how fast zstd Parquet files are searched.
//!
//! Like every codec in codecs.zig, the expected size is only a claim: an
//! up-front allocation is made only when the frame says the same size and
//! the ratio is plausible; otherwise output grows only as it is produced.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ Malformed, OutOfMemory };

const DCtx = opaque {};
const InBuffer = extern struct { src: ?*const anyopaque, size: usize, pos: usize };
const OutBuffer = extern struct { dst: ?*anyopaque, size: usize, pos: usize };

extern fn ZSTD_createDCtx() ?*DCtx;
extern fn ZSTD_freeDCtx(dctx: *DCtx) usize;
extern fn ZSTD_decompressDCtx(dctx: *DCtx, dst: [*]u8, dst_capacity: usize, src: [*]const u8, src_size: usize) usize;
extern fn ZSTD_decompressStream(dctx: *DCtx, out: *OutBuffer, in: *InBuffer) usize;
extern fn ZSTD_getFrameContentSize(src: [*]const u8, src_size: usize) c_ulonglong;
extern fn ZSTD_isError(code: usize) c_uint;

/// Real zstd data rarely expands more than this; beyond it, output is not
/// allocated up front even when the frame header agrees.
const plausible_ratio = 64;

/// Decompresses zstd frames from `src`, which must produce exactly `n`
/// bytes, into memory from `arena`.
pub fn decompress(arena: Allocator, src: []const u8, n: usize) Error![]const u8 {
    const dctx = ZSTD_createDCtx() orelse return error.OutOfMemory;
    defer _ = ZSTD_freeDCtx(dctx);

    // One call into a buffer of exactly `n`, when the first frame states
    // that size (the usual case: one frame per page or buffer).
    const stated = ZSTD_getFrameContentSize(src.ptr, src.len);
    if (stated == n and n <= src.len *| plausible_ratio +| (1 << 20)) {
        const out = try arena.alloc(u8, n);
        const got = ZSTD_decompressDCtx(dctx, out.ptr, out.len, src.ptr, src.len);
        if (ZSTD_isError(got) != 0 or got != n) return error.Malformed;
        return out;
    }

    // Otherwise stream, growing the output as it comes, up to n + 1 bytes.
    var out: std.ArrayList(u8) = try .initCapacity(arena, @min(n, 16 * src.len + (1 << 16)) + 1);
    var in: InBuffer = .{ .src = src.ptr, .size = src.len, .pos = 0 };
    while (true) {
        if (out.unusedCapacitySlice().len == 0) {
            if (out.items.len > n) return error.Malformed;
            try out.ensureUnusedCapacity(arena, @min(out.items.len, n + 1 - out.items.len));
        }
        const spare = out.unusedCapacitySlice();
        var o: OutBuffer = .{ .dst = spare.ptr, .size = @min(spare.len, n + 1 - out.items.len), .pos = 0 };
        const in_before = in.pos;
        const ret = ZSTD_decompressStream(dctx, &o, &in);
        if (ZSTD_isError(ret) != 0) return error.Malformed;
        out.items.len += o.pos;
        if (out.items.len > n) return error.Malformed;
        if (in.pos == in.size and ret == 0) break; // all frames done
        if (o.pos == 0 and in.pos == in_before) return error.Malformed; // truncated
    }
    if (out.items.len != n) return error.Malformed;
    return out.items;
}

test "decompress, and lies about the size are errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // pyarrow.compress(b"needle in a haystack, " * 4 + b"!", "zstd")
    const frame = "\x28\xb5\x2f\xfd\x20\x59\xf5\x00\x00\xb8\x6e\x65\x65\x64\x6c\x65\x20\x69\x6e\x20\x61\x20\x68\x61\x79\x73\x74\x61\x63\x6b\x2c\x20\x21\x01\x00\x9e\xd2\x6c\x02";
    const expected = "needle in a haystack, " ++ "needle in a haystack, " ++ "needle in a haystack, " ++ "needle in a haystack, " ++ "!";
    try std.testing.expectEqualStrings(expected, try decompress(a, frame, expected.len));
    try std.testing.expectError(error.Malformed, decompress(a, frame, expected.len - 1));
    try std.testing.expectError(error.Malformed, decompress(a, frame, expected.len + 1));
    try std.testing.expectError(error.Malformed, decompress(a, frame, 1 << 40));
    for (0..frame.len) |k| try std.testing.expectError(error.Malformed, decompress(a, frame[0..k], expected.len));
}
