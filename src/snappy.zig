//! Snappy decompression (the raw block format, not the framed one), for
//! Parquet pages: SNAPPY is the default codec of pyarrow, pandas and Spark.
//!
//! A block is the uncompressed length as a varint, then elements: literals
//! (bytes copied from the input) and copies (bytes repeated from earlier
//! output, given an offset and a length). Spec:
//! https://github.com/google/snappy/blob/main/format_description.txt

const std = @import("std");

pub const Error = error{Malformed};

/// The uncompressed length a block declares.
pub fn length(src: []const u8) Error!usize {
    var i: usize = 0;
    return varint(src, &i);
}

/// The most `src_len` compressed bytes can produce: the densest element is
/// a 2-byte copy of 11 bytes or a 3-byte copy of 64, so about 22 times the
/// input, plus slack.
pub fn maxDecompressedLen(src_len: usize) usize {
    return src_len *| 22 +| 64;
}

/// Decompresses one block, which must fill `dst` exactly.
pub fn decompress(src: []const u8, dst: []u8) Error!void {
    var i: usize = 0;
    if (try varint(src, &i) != dst.len) return error.Malformed;
    var o: usize = 0;
    while (i < src.len) {
        const tag = src[i];
        i += 1;
        switch (@as(u2, @truncate(tag))) {
            0b00 => { // literal; lengths of 61+ bytes follow in 1-4 bytes
                var len: usize = tag >> 2;
                if (len >= 60) {
                    const n = len - 59;
                    if (src.len - i < n) return error.Malformed;
                    len = 0;
                    for (src[i..][0..n], 0..) |b, k| len |= @as(usize, b) << @intCast(8 * k);
                    i += n;
                }
                len += 1;
                if (len > src.len - i or len > dst.len - o) return error.Malformed;
                @memcpy(dst[o..][0..len], src[i..][0..len]);
                i += len;
                o += len;
            },
            0b01 => { // copy: 3-bit length - 4, 11-bit offset
                if (i >= src.len) return error.Malformed;
                const len = 4 + @as(usize, (tag >> 2) & 7);
                const offset = (@as(usize, tag >> 5) << 8) | src[i];
                i += 1;
                o = try copy(dst, o, offset, len);
            },
            0b10 => { // copy: 6-bit length - 1, 16-bit offset
                if (src.len - i < 2) return error.Malformed;
                const offset = std.mem.readInt(u16, src[i..][0..2], .little);
                i += 2;
                o = try copy(dst, o, offset, 1 + @as(usize, tag >> 2));
            },
            0b11 => { // copy: 6-bit length - 1, 32-bit offset
                if (src.len - i < 4) return error.Malformed;
                const offset = std.mem.readInt(u32, src[i..][0..4], .little);
                i += 4;
                o = try copy(dst, o, offset, 1 + @as(usize, tag >> 2));
            },
        }
    }
    if (o != dst.len) return error.Malformed;
}

fn copy(dst: []u8, o: usize, offset: usize, len: usize) Error!usize {
    if (offset == 0 or offset > o or len > dst.len - o) return error.Malformed;
    if (offset >= len) {
        @memcpy(dst[o..][0..len], dst[o - offset ..][0..len]);
    } else {
        // Overlapping: the copy repeats bytes it is still producing.
        for (dst[o..][0..len], o - offset..) |*d, s| d.* = dst[s];
    }
    return o + len;
}

fn varint(src: []const u8, i: *usize) Error!usize {
    var v: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (i.* >= src.len) return error.Malformed;
        const b = src[i.*];
        i.* += 1;
        v |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return std.math.cast(usize, v) orelse error.Malformed;
        if (shift >= 63 - 7) return error.Malformed;
        shift += 7;
    }
}

test "decompress blocks made by python-snappy (via pyarrow)" {
    // pyarrow.compress(b"needle in a haystack, " * 4 + b"!", "snappy")
    const block = "\x59\x54\x6e\x65\x65\x64\x6c\x65\x20\x69\x6e\x20\x61\x20\x68\x61\x79\x73\x74\x61\x63\x6b\x2c\x20\xee\x16\x00\x09\x16\x00\x21";
    const expected = "needle in a haystack, " ++ "needle in a haystack, " ++ "needle in a haystack, " ++ "needle in a haystack, " ++ "!";
    try std.testing.expectEqual(expected.len, try length(block));
    var out: [expected.len]u8 = undefined;
    try decompress(block, &out);
    try std.testing.expectEqualStrings(expected, &out);
    try std.testing.expect(expected.len <= maxDecompressedLen(block.len));

    // Truncated input or a wrong output size is an error, never a crash.
    for (0..block.len) |n| try std.testing.expectError(error.Malformed, decompress(block[0..n], &out));
    var short: [expected.len - 1]u8 = undefined;
    try std.testing.expectError(error.Malformed, decompress(block, &short));
}
