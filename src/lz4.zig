//! LZ4 frame decompression, for Arrow buffers compressed with LZ4_FRAME
//! (the default of pyarrow's `write_feather`). The output size is known in
//! advance (Arrow stores it before each buffer), so frames decode straight
//! into the caller's buffer; blocks may refer back into earlier blocks.
//! Checksums are skipped, not verified.

const std = @import("std");

pub const Error = error{Malformed};

const frame_magic = 0x184D2204;

/// Decompresses the LZ4 frames in `src`, which must fill `dst` exactly.
pub fn decompress(src: []const u8, dst: []u8) Error!void {
    var in: usize = 0;
    var out: usize = 0;
    while (in < src.len) {
        const magic = try int(u32, src, in);
        in += 4;
        if (magic & 0xFFFFFFF0 == 0x184D2A50) { // skippable frame
            const size = try int(u32, src, in);
            if (size > src.len - in - 4) return error.Malformed;
            in += 4 + size;
            continue;
        }
        if (magic != frame_magic) return error.Malformed;

        if (src.len - in < 3) return error.Malformed;
        const flg = src[in];
        if (flg >> 6 != 1 or flg & 1 != 0) return error.Malformed; // version 01, no dictionary id
        const block_checksum = flg & 0x10 != 0;
        const content_checksum = flg & 0x04 != 0;
        in += 2; // FLG, BD
        if (flg & 0x08 != 0) in += 8; // content size
        in += 1; // header checksum

        while (true) {
            const header = try int(u32, src, in);
            in += 4;
            if (header == 0) break; // end mark
            const size = header & 0x7FFF_FFFF;
            if (size > src.len - in) return error.Malformed;
            const block = src[in..][0..size];
            in += size;
            if (header & 0x8000_0000 != 0) { // stored uncompressed
                if (size > dst.len - out) return error.Malformed;
                @memcpy(dst[out..][0..size], block);
                out += size;
            } else {
                out = try decodeBlock(block, dst, out);
            }
            if (block_checksum) in += 4;
        }
        if (content_checksum) in += 4;
        if (in > src.len) return error.Malformed;
    }
    if (out != dst.len) return error.Malformed;
}

// Decodes one LZ4 block into dst[out..] and returns the new end. Matches
// may reach back before `out`, into earlier blocks of the same frame.
fn decodeBlock(src: []const u8, dst: []u8, out_start: usize) Error!usize {
    var i: usize = 0;
    var o = out_start;
    while (true) {
        if (i >= src.len) return error.Malformed;
        const token = src[i];
        i += 1;

        const lit = try length(src, &i, token >> 4);
        if (lit > src.len - i or lit > dst.len - o) return error.Malformed;
        @memcpy(dst[o..][0..lit], src[i..][0..lit]);
        i += lit;
        o += lit;
        if (i == src.len) return o; // the last sequence has only literals

        const offset: usize = try int(u16, src, i);
        i += 2;
        if (offset == 0 or offset > o) return error.Malformed;
        const len = 4 + try length(src, &i, token & 15);
        if (len > dst.len - o) return error.Malformed;
        if (offset >= len) {
            @memcpy(dst[o..][0..len], dst[o - offset ..][0..len]);
        } else {
            // Overlapping: the match repeats bytes it is still producing.
            for (dst[o..][0..len], o - offset..) |*d, s| d.* = dst[s];
        }
        o += len;
    }
}

// A 4-bit length; 15 means more bytes follow, each added, until one isn't 255.
fn length(src: []const u8, i: *usize, nibble: u8) Error!usize {
    var n: usize = nibble;
    if (nibble != 15) return n;
    while (true) {
        if (i.* >= src.len) return error.Malformed;
        const b = src[i.*];
        i.* += 1;
        n += b;
        if (b != 255) return n;
    }
}

fn int(comptime T: type, buf: []const u8, p: usize) Error!T {
    if (p > buf.len or buf.len - p < @sizeOf(T)) return error.Malformed;
    return std.mem.readInt(T, buf[p..][0..@sizeOf(T)], .little);
}

test "decompress frames made by pyarrow" {
    // pyarrow.compress(b"hello hello hello hello world" * 3, "lz4"): one
    // compressed block with overlapping matches.
    const frame = "\x04\x22\x4d\x18\x60\x40\x82\x1e\x00\x00\x00\x6e\x68\x65\x6c\x6c\x6f\x20\x06\x00\x5e\x77\x6f\x72\x6c\x64\x17\x00\x02\x12\x00\x0f\x1d\x00\x0a\x50\x77\x6f\x72\x6c\x64\x00\x00\x00\x00";
    const expected = "hello hello hello hello world" ++ "hello hello hello hello world" ++ "hello hello hello hello world";
    var out: [expected.len]u8 = undefined;
    try decompress(frame, &out);
    try std.testing.expectEqualStrings(expected, &out);

    // Truncated input or a wrong output size is an error, never a crash.
    for (0..frame.len) |n| try std.testing.expectError(error.Malformed, decompress(frame[0..n], &out));
    var short: [expected.len - 1]u8 = undefined;
    try std.testing.expectError(error.Malformed, decompress(frame, &short));
}
