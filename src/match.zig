//! Finding the term in a column of strings: no I/O, no Arrow parsing.
//!
//! An Arrow string column stores its values back to back in one buffer,
//! plus an offsets array: value `i` is `data[off[i]..off[i + 1]]`. That is
//! the shape the SIMD loop wants, one contiguous run of bytes, so the whole
//! column is scanned in one pass. The one new rule is that a match must not
//! run across two values: every hit is checked against the offsets, which
//! costs a binary search per hit and nothing per byte.
//!
//! `findValues` calls `sink.onValue(row, value)` once for each value that
//! contains `term`, in row order. `sink` is any value with
//! `fn onValue(self, row: usize, value: []const u8) !void`.
//!
//! `.insensitive` is the same search with ASCII case folding: `A`-`Z` match
//! `a`-`z`; other bytes, including non-ASCII UTF-8, match exactly.

const std = @import("std");

pub const Case = enum { sensitive, insensitive };

const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vec_len, u8);
const Mask = @Int(.unsigned, vec_len);

/// Calls `sink.onValue` for each value containing `term` (not empty).
/// `off` (i32 or i64 offsets, `off.len` = values + 1) must already be
/// validated: non-decreasing, `off[0] >= 0`, last offset <= `data.len`.
pub fn findValues(comptime case: Case, comptime O: type, off: []align(1) const O, data: []const u8, term: []const u8, sink: anytype) !void {
    if (off.len < 2) return;
    const Ctx = struct {
        off: []align(1) const O,
        data: []const u8,
        n: usize,
        sink: @TypeOf(sink),
        row: usize = 0,

        fn onMatch(c: *@This(), pos: usize) !?usize {
            c.row = rowOf(O, c.off, c.row, pos);
            const end: usize = @intCast(c.off[c.row + 1]);
            if (pos + c.n > end) return pos + 1; // runs into the next value
            try c.sink.onValue(c.row, c.data[@intCast(c.off[c.row])..end]);
            return end; // one report per value
        }
    };
    var ctx: Ctx = .{ .off = off, .data = data, .n = term.len, .sink = sink };
    try scan(case, data[0..@intCast(off[off.len - 1])], term, @intCast(off[0]), &ctx);
}

/// Does `value` contain `term`? For values that are not stored back to
/// back (string views, dictionary entries).
pub fn contains(comptime case: Case, value: []const u8, term: []const u8) bool {
    const Found = struct {
        found: bool = false,
        fn onMatch(f: *@This(), _: usize) error{}!?usize {
            f.found = true;
            return null;
        }
    };
    var f: Found = .{};
    scan(case, value, term, 0, &f) catch unreachable;
    return f.found;
}

/// Where `term` next occurs in `value`, at or after `from`. For
/// highlighting matches.
pub fn indexOf(comptime case: Case, value: []const u8, term: []const u8, from: usize) ?usize {
    const First = struct {
        pos: ?usize = null,
        fn onMatch(f: *@This(), p: usize) error{}!?usize {
            f.pos = p;
            return null;
        }
    };
    var f: First = .{};
    if (from > value.len) return null;
    scan(case, value, term, from, &f) catch unreachable;
    return f.pos;
}

// The row whose value holds byte `pos`: the last r >= `from` with
// off[r] <= pos. Hits arrive in increasing order, so each search starts at
// the previous row. Requires off[from] <= pos < off[off.len - 1].
pub fn rowOf(comptime O: type, off: []align(1) const O, from: usize, pos: usize) usize {
    var lo = from + 1; // first index that may hold an offset > pos
    var hi = off.len - 1; // off[hi] > pos
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (off[mid] > pos) hi = mid else lo = mid + 1;
    }
    return lo - 1;
}

// SIMD search: for each block of `vec_len` candidate positions, compare the
// first byte of `term` at offset 0 and its last byte at offset term.len - 1.
// Only positions where both match are verified with a full comparison, and
// verified hits go to `ctx.onMatch(pos)`, which returns where to continue
// (always past `pos`) or null to stop.
//
// Ignoring case, letters in the end bytes are compared with bit 5 set (one
// extra OR per load; see `Byte`), and candidates are verified with
// `eqlIgnoreCase`. `case` is comptime, so the case-sensitive loop is
// unchanged. Turning a compare into a bitmask is expensive on NEON (no
// movemask instruction), but it happens once per block either way.
fn scan(comptime case: Case, data: []const u8, term: []const u8, start: usize, ctx: anytype) !void {
    const n = term.len;
    if (data.len < n) return;
    const first: Byte(case) = .init(term[0]);
    const last: Byte(case) = .init(term[n - 1]);
    const end = data.len - n + 1; // candidate start positions are [start, end)

    var i = start;
    outer: while (i + vec_len <= end) {
        const a: Vec = data[i..][0..vec_len].*;
        const b: Vec = data[i + n - 1 ..][0..vec_len].*;
        var mask: Mask = first.eqlMask(a) & last.eqlMask(b);
        while (mask != 0) : (mask &= mask - 1) {
            const pos = i + @ctz(mask);
            if (eql(case, data[pos..][0..n], term)) {
                i = try ctx.onMatch(pos) orelse return;
                continue :outer;
            }
        }
        i += vec_len;
    }

    // Tail: fewer than vec_len candidate positions left.
    while (i < end) {
        if (first.eqlByte(data[i]) and eql(case, data[i..][0..n], term)) {
            i = try ctx.onMatch(i) orelse return;
        } else {
            i += 1;
        }
    }
}

// One byte of the term, splatted for comparing against a block. Ignoring
// case, a letter is compared as `(v | 0x20) == lower`: setting bit 5 maps
// 'A'-'Z' onto 'a'-'z', and only 'A'-'Z' and 'a'-'z' land on 'a'-'z', so the
// compare is exact. Non-letters use `fold = 0`, a plain compare.
fn Byte(comptime case: Case) type {
    return struct {
        const Self = @This();
        lower: Vec,
        fold: if (case == .insensitive) Vec else void, // 0x20 for letters, else 0

        fn init(c: u8) Self {
            return switch (case) {
                .sensitive => .{ .lower = @splat(c), .fold = {} },
                .insensitive => .{
                    .lower = @splat(std.ascii.toLower(c)),
                    .fold = @splat(if (std.ascii.isAlphabetic(c)) 0x20 else 0),
                },
            };
        }

        fn eqlMask(self: Self, v: Vec) Mask {
            const folded = if (case == .sensitive) v else v | self.fold;
            return @bitCast(folded == self.lower);
        }

        fn eqlByte(self: Self, c: u8) bool {
            const folded = if (case == .sensitive) c else c | self.fold[0];
            return folded == self.lower[0];
        }
    };
}

fn eql(comptime case: Case, a: []const u8, b: []const u8) bool {
    return switch (case) {
        .sensitive => std.mem.eql(u8, a, b),
        .insensitive => std.ascii.eqlIgnoreCase(a, b),
    };
}

/// Reference implementation for tests: search each value on its own.
pub fn findValuesNaive(comptime case: Case, comptime O: type, off: []align(1) const O, data: []const u8, term: []const u8, sink: anytype) !void {
    if (off.len < 2) return;
    for (0..off.len - 1) |row| {
        const value = data[@intCast(off[row])..@intCast(off[row + 1])];
        const found = switch (case) {
            .sensitive => std.mem.indexOf(u8, value, term),
            .insensitive => std.ascii.findIgnoreCase(value, term),
        };
        if (found != null) try sink.onValue(row, value);
    }
}

const testing = std.testing;

const CollectRows = struct {
    gpa: std.mem.Allocator,
    rows: *std.ArrayList(usize),
    off: []align(1) const i64,
    data: []const u8,

    // Also checks that `value` is the row's value.
    pub fn onValue(c: CollectRows, row: usize, value: []const u8) !void {
        try c.rows.append(c.gpa, row);
        try testing.expectEqualStrings(c.data[@intCast(c.off[row])..@intCast(c.off[row + 1])], value);
    }
};

// Random values (empty ones included) over a tiny alphabet, so terms often
// match, and often match across two values, which must not be reported.
fn randomColumn(rand: std.Random, max_values: usize, max_len: usize, data: *std.ArrayList(u8), off: *std.ArrayList(i64), gpa: std.mem.Allocator) !void {
    data.clearRetainingCapacity();
    off.clearRetainingCapacity();
    // Some columns start at a nonzero offset, as a slice of a larger buffer.
    for (0..rand.uintLessThan(usize, 3)) |_| try data.append(gpa, 'a');
    try off.append(gpa, @intCast(data.items.len));
    for (0..rand.uintAtMost(usize, max_values)) |_| {
        for (0..rand.uintAtMost(usize, max_len)) |_| try data.append(gpa, "abAB"[rand.uintLessThan(usize, 4)]);
        try off.append(gpa, @intCast(data.items.len));
    }
    for (0..rand.uintLessThan(usize, 3)) |_| try data.append(gpa, 'b'); // bytes past the last value
}

test "SIMD search matches naive search" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0xf5f5);
    const rand = prng.random();
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var off: std.ArrayList(i64) = .empty;
    defer off.deinit(gpa);
    var off32: std.ArrayList(i32) = .empty;
    defer off32.deinit(gpa);
    var simd: std.ArrayList(usize) = .empty;
    defer simd.deinit(gpa);
    var naive: std.ArrayList(usize) = .empty;
    defer naive.deinit(gpa);
    var term_buf: [8]u8 = undefined;

    for (0..20_000) |iter| {
        // Mostly short columns; some long ones with long values.
        const long = iter % 50 == 0;
        try randomColumn(rand, if (long) 400 else 60, if (long) 40 else 8, &data, &off, gpa);
        const term = term_buf[0 .. 1 + rand.uintLessThan(usize, term_buf.len)];
        for (term) |*c| c.* = "abAB"[rand.uintLessThan(usize, 4)];
        off32.clearRetainingCapacity();
        for (off.items) |o| try off32.append(gpa, @intCast(o));

        const sink: CollectRows = .{ .gpa = gpa, .rows = undefined, .off = off.items, .data = data.items };
        inline for (.{ Case.sensitive, Case.insensitive }) |case| {
            naive.clearRetainingCapacity();
            try findValuesNaive(case, i64, off.items, data.items, term, with(sink, &naive));
            simd.clearRetainingCapacity();
            try findValues(case, i64, off.items, data.items, term, with(sink, &simd));
            try testing.expectEqualSlices(usize, naive.items, simd.items);
            simd.clearRetainingCapacity();
            try findValues(case, i32, off32.items, data.items, term, with(sink, &simd));
            try testing.expectEqualSlices(usize, naive.items, simd.items);

            for (0..off.items.len -| 1) |row| {
                const value = data.items[@intCast(off.items[row])..@intCast(off.items[row + 1])];
                const expected = std.mem.indexOfScalar(usize, naive.items, row) != null;
                try testing.expectEqual(expected, contains(case, value, term));
                // indexOf from every start agrees with a plain search.
                for (0..value.len + 1) |from| {
                    const want = switch (case) {
                        .sensitive => std.mem.indexOfPos(u8, value, from, term),
                        .insensitive => if (std.ascii.findIgnoreCase(value[from..], term)) |p| p + from else null,
                    };
                    try testing.expectEqual(want, indexOf(case, value, term, from));
                }
            }
        }
    }
}

fn with(sink: CollectRows, rows: *std.ArrayList(usize)) CollectRows {
    var s = sink;
    s.rows = rows;
    return s;
}

test "a match across two values is not reported" {
    const gpa = testing.allocator;
    var rows: std.ArrayList(usize) = .empty;
    defer rows.deinit(gpa);
    // "foo" + "bar": "obar" is in the buffer but in no value.
    const data = "foobarbaz";
    const off = [_]i64{ 0, 3, 6, 9 };
    const sink: CollectRows = .{ .gpa = gpa, .rows = &rows, .off = &off, .data = data };
    try findValues(.sensitive, i64, &off, data, "obar", sink);
    try testing.expectEqualSlices(usize, &.{}, rows.items);
    try findValues(.sensitive, i64, &off, data, "ba", sink);
    try testing.expectEqualSlices(usize, &.{ 1, 2 }, rows.items);
}

test "ignore case folds ASCII letters only" {
    const gpa = testing.allocator;
    var rows: std.ArrayList(usize) = .empty;
    defer rows.deinit(gpa);
    // Value 4 ends in 'Ö' (UTF-8), which is not folded. Value 6 lies past
    // the first SIMD blocks.
    const pad = "pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad pad ";
    const values = [_][]const u8{ "x", "HeLLo world", "[hello]", "{HELLO}", "hell\xc3\x96", pad, "HELLO" };
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var off: std.ArrayList(i64) = .empty;
    defer off.deinit(gpa);
    try off.append(gpa, 0);
    for (values) |v| {
        try data.appendSlice(gpa, v);
        try off.append(gpa, @intCast(data.items.len));
    }
    const sink: CollectRows = .{ .gpa = gpa, .rows = &rows, .off = off.items, .data = data.items };
    try findValues(.insensitive, i64, off.items, data.items, "hello", sink);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 3, 6 }, rows.items);

    // '[' and '{' are not the case forms of each other.
    rows.clearRetainingCapacity();
    try findValues(.insensitive, i64, off.items, data.items, "{hello}", sink);
    try testing.expectEqualSlices(usize, &.{3}, rows.items);
}
