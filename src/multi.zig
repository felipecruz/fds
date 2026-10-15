//! Many literals at once (`-f`, or many `-e`): an Aho-Corasick automaton,
//! so a value is scanned once whatever the number of terms. A few terms are
//! faster as one SIMD pass each (match.zig); see `pattern.many`.
//!
//! The automaton is a trie of the terms with failure links. Bytes are
//! first mapped to *classes*: the bytes that appear in some term each get
//! one (a letter and its upper case share one with `ignore_case`), every
//! other byte is class 0. States are numbered breadth first, so shallow
//! states come first: those get a full row of transitions (a DFA row:
//! one load per byte), up to a memory budget; deeper states, rarely
//! visited in text that mostly doesn't match, keep only their trie edges
//! and fall back along failure links, whose targets are always shallower.
//! With a few thousand terms, every state gets a row.
//!
//! A transition's target has `match_bit` set when some term ends there, so
//! the scan loop tests one bit per byte. Each value is scanned from the
//! root, so a match never runs across two values.
//!
//! With `word`, a term must stand as a whole word, as with `-w`: where a
//! term starts (ends) with a word byte, the byte before (after) it must not
//! be one. At a match, every term ending there is checked, through
//! `dict` links (the nearest state on the failure chain where a term ends).

const std = @import("std");
const Allocator = std.mem.Allocator;
const match = @import("match.zig");

pub const Options = struct {
    ignore_case: bool = false,
    word: bool = false,
    /// Memory for full transition rows; the rest of the states are sparse.
    dense_bytes: usize = 64 << 20,
};

const match_bit: u32 = 1 << 31;
const state_mask: u32 = match_bit - 1;

pub const Set = struct {
    gpa: Allocator,
    word: bool,
    max_len: usize,
    classes: [256]u8,
    n_classes: usize,
    /// States 0..dense_states: row s is dense[s * n_classes ..][0..n_classes].
    dense: []u32,
    dense_states: usize,
    /// Every state has a dense row, and `dense` holds row offsets.
    full: bool = false,
    /// Every state: trie edges edge_start[s]..edge_start[s + 1].
    edge_start: []u32,
    edge_class: []u8,
    edge_to: []u32, // with match_bit
    fail: []u32,
    /// Length of the term that ends at the state, or 0.
    term: []u32,
    /// The nearest state on the failure chain (not itself) where a term
    /// ends, or 0 (the root; no term is empty).
    dict: []u32,
    /// With `word`, for each state where a term ends: bit 0 if the term
    /// starts with a word byte, bit 1 if it ends with one.
    edges: []u8,

    /// `terms` must not be empty, nor contain an empty term. Duplicates are
    /// fine.
    pub fn init(gpa: Allocator, terms: []const []const u8, opts: Options) !Set {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Byte classes.
        var used: [256]bool = @splat(false);
        var max_len: usize = 0;
        for (terms) |t| {
            std.debug.assert(t.len > 0);
            max_len = @max(max_len, t.len);
            for (t) |c| used[fold(c, opts.ignore_case)] = true;
        }
        // Class 0 is the bytes in no term, if there are any.
        var classes: [256]u8 = @splat(0);
        var n_classes: usize = @intFromBool(std.mem.indexOfScalar(bool, &used, false) != null);
        for (0..256) |c| if (used[c]) {
            classes[c] = @intCast(n_classes);
            n_classes += 1;
        };
        if (opts.ignore_case) for ('A'..'Z' + 1) |c| {
            classes[c] = classes[c + 32];
        };

        // The trie: children as sibling lists.
        const Node = struct { child: u32 = 0, sibling: u32 = 0, class: u8 = 0, term: u32 = 0, edges: u8 = 0 };
        var nodes: std.ArrayList(Node) = .empty;
        try nodes.append(arena, .{});
        for (terms) |t| {
            var s: u32 = 0;
            for (t) |c| {
                const cl = classes[c];
                var k = nodes.items[s].child;
                while (k != 0 and nodes.items[k].class != cl) k = nodes.items[k].sibling;
                if (k == 0) {
                    if (nodes.items.len >= state_mask) return error.OutOfMemory;
                    k = @intCast(nodes.items.len);
                    try nodes.append(arena, .{ .class = cl, .sibling = nodes.items[s].child });
                    nodes.items[s].child = k;
                }
                s = k;
            }
            nodes.items[s].term = @intCast(t.len);
            nodes.items[s].edges = @as(u8, @intFromBool(isWord(t[0]))) | @as(u8, @intFromBool(isWord(t[t.len - 1]))) << 1;
        }
        const n = nodes.items.len;

        // Breadth-first order: order[new] = old, id[old] = new.
        const order = try arena.alloc(u32, n);
        const id = try arena.alloc(u32, n);
        order[0] = 0;
        var len: usize = 1;
        for (0..n) |i| {
            var k = nodes.items[order[i]].child;
            while (k != 0) : (k = nodes.items[k].sibling) {
                order[len] = k;
                len += 1;
            }
        }
        for (order, 0..) |old, new| id[old] = @intCast(new);

        var set: Set = .{
            .gpa = gpa,
            .word = opts.word,
            .max_len = max_len,
            .classes = classes,
            .n_classes = n_classes,
            .dense = &.{},
            .dense_states = 0,
            .edge_start = &.{},
            .edge_class = &.{},
            .edge_to = &.{},
            .fail = &.{},
            .term = &.{},
            .dict = &.{},
            .edges = &.{},
        };
        errdefer set.deinit();
        set.edge_start = try gpa.alloc(u32, n + 1);
        set.edge_class = try gpa.alloc(u8, n - 1);
        set.edge_to = try gpa.alloc(u32, n - 1);
        set.fail = try gpa.alloc(u32, n);
        set.term = try gpa.alloc(u32, n);
        set.dict = try gpa.alloc(u32, n);
        set.edges = try gpa.alloc(u8, n);

        // Edges, terms and failure links, in the new numbering. A state's
        // failure target is shallower, so it is done before the state.
        var e: u32 = 0;
        for (order, 0..) |old, s| {
            set.term[s] = nodes.items[old].term;
            set.edges[s] = nodes.items[old].edges;
            set.edge_start[s] = e;
            var k = nodes.items[old].child;
            while (k != 0) : (k = nodes.items[k].sibling) {
                set.edge_class[e] = nodes.items[k].class;
                set.edge_to[e] = id[k];
                e += 1;
            }
        }
        set.edge_start[n] = e;
        set.fail[0] = 0;
        set.dict[0] = 0;
        for (0..n) |s| {
            for (set.edge_start[s]..set.edge_start[s + 1]) |i| {
                const to = set.edge_to[i];
                const cl = set.edge_class[i];
                var f: u32 = 0;
                if (s != 0) {
                    var x = set.fail[s];
                    while (true) {
                        if (set.child(x, cl)) |c| {
                            f = c;
                            break;
                        }
                        if (x == 0) break;
                        x = set.fail[x];
                    }
                }
                set.fail[to] = f;
                set.dict[to] = if (set.term[f] > 0) f else set.dict[f];
            }
        }
        // The match bit on every edge.
        for (set.edge_to) |*to| if (set.isOut(to.*)) {
            to.* |= match_bit;
        };

        // Dense rows for the first states, as many as the budget allows
        // (the root always).
        set.dense_states = @max(1, @min(n, opts.dense_bytes / (4 * n_classes)));
        set.dense = try gpa.alloc(u32, set.dense_states * n_classes);
        for (0..set.dense_states) |s| {
            const row = set.dense[s * n_classes ..][0..n_classes];
            if (s == 0) {
                @memset(row, 0);
            } else {
                @memcpy(row, set.dense[set.fail[s] * n_classes ..][0..n_classes]);
            }
            for (set.edge_start[s]..set.edge_start[s + 1]) |i| row[set.edge_class[i]] = set.edge_to[i];
        }
        // Every state dense: targets as row offsets, which saves a multiply
        // per byte.
        if (set.dense_states == n) {
            set.full = true;
            for (set.dense) |*t| t.* = (t.* & state_mask) * @as(u32, @intCast(n_classes)) | (t.* & match_bit);
        }
        return set;
    }

    pub fn deinit(set: *Set) void {
        const gpa = set.gpa;
        gpa.free(set.dense);
        gpa.free(set.edge_start);
        gpa.free(set.edge_class);
        gpa.free(set.edge_to);
        gpa.free(set.fail);
        gpa.free(set.term);
        gpa.free(set.dict);
        gpa.free(set.edges);
    }

    fn isOut(set: *const Set, s: u32) bool {
        return set.term[s] > 0 or set.dict[s] != 0;
    }

    // The trie child of `s` for class `cl`, without failure links.
    fn child(set: *const Set, s: u32, cl: u8) ?u32 {
        for (set.edge_start[s]..set.edge_start[s + 1]) |i| {
            if (set.edge_class[i] == cl) return set.edge_to[i] & state_mask;
        }
        return null;
    }

    // The scan loops hold a state as a "cursor": with `full`, the offset of
    // its row in `dense`, else its number; either way with match_bit. The
    // root is 0 both ways.
    inline fn next(set: *const Set, comptime full: bool, cursor: u32, c: u8) u32 {
        if (full) return set.dense[(cursor & state_mask) + set.classes[c]];
        return set.step(cursor & state_mask, c);
    }

    fn stateOf(set: *const Set, comptime full: bool, cursor: u32) u32 {
        return if (full) (cursor & state_mask) / @as(u32, @intCast(set.n_classes)) else cursor & state_mask;
    }

    // The state after reading byte `c` in state `s`, with match_bit, when
    // not every state is dense.
    inline fn step(set: *const Set, s: u32, c: u8) u32 {
        const cl = set.classes[c];
        var x = s;
        while (true) {
            if (x < set.dense_states) return set.dense[x * set.n_classes + cl];
            for (set.edge_start[x]..set.edge_start[x + 1]) |i| {
                if (set.edge_class[i] == cl) return set.edge_to[i];
            }
            x = set.fail[x];
        }
    }

    // Terms end at `pos` (state `s`): does one count, lying inside
    // value[from..] (and, with `word`, standing as a word)?
    fn accept(set: *const Set, value: []const u8, pos: usize, s: u32, from: usize) bool {
        var x = if (set.term[s] > 0) s else set.dict[s];
        while (x != 0) : (x = set.dict[x]) {
            if (set.wordAt(value, pos, x, from) != null) return true;
        }
        return false;
    }

    // The start of the term of state `x` ending at `pos`, if it lies in
    // value[from..] and, with `word`, stands as a word there.
    fn wordAt(set: *const Set, value: []const u8, pos: usize, x: u32, from: usize) ?usize {
        if (set.term[x] > pos + 1 - from) return null;
        const start = pos + 1 - set.term[x];
        if (!set.word) return start;
        if (set.edges[x] & 1 != 0 and start > 0 and isWord(value[start - 1])) return null;
        if (set.edges[x] & 2 != 0 and pos + 1 < value.len and isWord(value[pos + 1])) return null;
        return start;
    }

    /// Does `value` contain one of the terms?
    pub fn matches(set: *const Set, value: []const u8) bool {
        switch (set.full) {
            inline else => |full| {
                var s: u32 = 0;
                for (value, 0..) |c, i| {
                    s = set.next(full, s, c);
                    if (s & match_bit != 0 and set.accept(value, i, set.stateOf(full, s), 0)) return true;
                }
                return false;
            },
        }
    }

    /// Could a value stored somewhere in `bytes` match? False only if no
    /// term occurs in them (word boundaries aside: in raw bytes, the bytes
    /// around a value are not the value's).
    pub fn mayMatch(set: *const Set, bytes: []const u8) bool {
        switch (set.full) {
            inline else => |full| {
                var s: u32 = 0;
                for (bytes) |c| {
                    s = set.next(full, s, c);
                    if (s & match_bit != 0) return true;
                }
                return false;
            },
        }
    }

    /// Calls `sink.onValue(i, value)` for each value of a string array
    /// (validated offsets into `data`, as in match.findValues) that
    /// contains a term, in order.
    ///
    /// The values' bytes are scanned in one run, as the SIMD search does:
    /// values are short, and restarting at each would cost more than the
    /// scan. Where terms end, the offsets say which value that is, and
    /// only a term that lies inside it counts.
    pub fn findValues(set: *const Set, comptime O: type, off: []align(1) const O, data: []const u8, sink: anytype) !void {
        if (off.len < 2) return;
        switch (set.full) {
            inline else => |full| {
                const last: usize = @intCast(off[off.len - 1]);
                var row: usize = 0;
                var i: usize = @intCast(off[0]);
                var s: u32 = 0;
                while (i < last) : (i += 1) {
                    s = set.next(full, s, data[i]);
                    if (s & match_bit == 0) continue;
                    row = match.rowOf(O, off, row, i);
                    const start: usize = @intCast(off[row]);
                    const end: usize = @intCast(off[row + 1]);
                    const value = data[start..end];
                    if (!set.accept(value, i - start, set.stateOf(full, s), 0)) continue;
                    try sink.onValue(row, value);
                    // One report per value: on to the next, from the root.
                    s = 0;
                    i = end - 1;
                }
            },
        }
    }

    /// The leftmost match in `value` starting at or after `from`, the
    /// longest there, as [start, end). For highlighting.
    pub fn span(set: *const Set, value: []const u8, from: usize) ?[2]usize {
        switch (set.full) {
            inline else => |full| {
                var best: ?[2]usize = null;
                var s: u32 = 0;
                var i = from;
                while (i < value.len) : (i += 1) {
                    // A match ending later starts after `best`'s start.
                    if (best) |b| if (i + 1 > b[0] + set.max_len) break;
                    s = set.next(full, s, value[i]);
                    if (s & match_bit == 0) continue;
                    const st = set.stateOf(full, s);
                    var x = if (set.term[st] > 0) st else set.dict[st];
                    while (x != 0) : (x = set.dict[x]) {
                        const start = set.wordAt(value, i, x, from) orelse continue;
                        if (best == null or start < best.?[0] or (start == best.?[0] and i + 1 > best.?[1])) best = .{ start, i + 1 };
                    }
                }
                return best;
            },
        }
    }
};

fn fold(c: u8, ignore_case: bool) u8 {
    return if (ignore_case) std.ascii.toLower(c) else c;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const testing = std.testing;

// Reference: every term at every position.
fn naiveSpan(terms: []const []const u8, value: []const u8, from: usize, opts: Options) ?[2]usize {
    var best: ?[2]usize = null;
    for (terms) |t| {
        var at = from;
        while (at + t.len <= value.len) : (at += 1) {
            const eq = if (opts.ignore_case) std.ascii.eqlIgnoreCase(value[at..][0..t.len], t) else std.mem.eql(u8, value[at..][0..t.len], t);
            if (!eq) continue;
            if (opts.word) {
                if (isWord(t[0]) and at > 0 and isWord(value[at - 1])) continue;
                if (isWord(t[t.len - 1]) and at + t.len < value.len and isWord(value[at + t.len])) continue;
            }
            const end = at + t.len;
            if (best == null or at < best.?[0] or (at == best.?[0] and end > best.?[1])) best = .{ at, end };
        }
    }
    return best;
}

test "the automaton agrees with a naive search" {
    var prng: std.Random.DefaultPrng = .init(0xac);
    const r = prng.random();
    const alphabet = "abAB_ -\x80";
    var term_bufs: [12][5]u8 = undefined;
    var terms: [12][]const u8 = undefined;
    var value_buf: [24]u8 = undefined;
    for (0..3000) |iter| {
        const nt = 1 + r.uintLessThan(usize, terms.len);
        for (terms[0..nt], term_bufs[0..nt]) |*t, *b| {
            t.* = b[0 .. 1 + r.uintLessThan(usize, b.len)];
            for (@constCast(t.*)) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        }
        const opts: Options = .{
            .ignore_case = r.boolean(),
            .word = r.uintLessThan(u8, 3) == 0,
            // Sometimes only the root has a dense row.
            .dense_bytes = if (iter % 3 == 0) 0 else 64 << 20,
        };
        var set = try Set.init(testing.allocator, terms[0..nt], opts);
        defer set.deinit();
        // The values back to back, as a column, for findValues.
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(testing.allocator);
        var off: std.ArrayList(i64) = .empty;
        defer off.deinit(testing.allocator);
        var want: std.ArrayList(usize) = .empty;
        defer want.deinit(testing.allocator);
        try data.appendSlice(testing.allocator, "ab"[0..r.uintAtMost(usize, 2)]); // not at offset 0
        try off.append(testing.allocator, @intCast(data.items.len));
        for (0..20) |row| {
            const value = value_buf[0..r.uintAtMost(usize, value_buf.len)];
            for (value) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
            try data.appendSlice(testing.allocator, value);
            try off.append(testing.allocator, @intCast(data.items.len));
            if (naiveSpan(terms[0..nt], value, 0, opts) != null) try want.append(testing.allocator, row);
            try testing.expectEqual(naiveSpan(terms[0..nt], value, 0, opts) != null, set.matches(value));
            for (0..value.len + 1) |from| {
                try testing.expectEqual(naiveSpan(terms[0..nt], value, from, opts), set.span(value, from));
            }
            // Ignoring word boundaries, any occurrence.
            var any = opts;
            any.word = false;
            try testing.expectEqual(naiveSpan(terms[0..nt], value, 0, any) != null, set.mayMatch(value));
        }
        try data.appendSlice(testing.allocator, "ab"); // past the last value
        const Rows = struct {
            rows: std.ArrayList(usize) = .empty,
            pub fn onValue(c: *@This(), i: usize, _: []const u8) !void {
                try c.rows.append(testing.allocator, i);
            }
        };
        var got: Rows = .{};
        defer got.rows.deinit(testing.allocator);
        try set.findValues(i64, off.items, data.items, &got);
        try testing.expectEqualSlices(usize, want.items, got.rows.items);
    }
}

test "values: one report each, never across two" {
    var set = try Set.init(testing.allocator, &.{ "obar", "ba", "zz" }, .{});
    defer set.deinit();
    const Rows = struct {
        rows: std.ArrayList(usize) = .empty,
        pub fn onValue(c: *@This(), i: usize, _: []const u8) !void {
            try c.rows.append(testing.allocator, i);
        }
    };
    var got: Rows = .{};
    defer got.rows.deinit(testing.allocator);
    // "foo" + "bar": "obar" is in the buffer but in no value.
    const off = [_]i32{ 0, 3, 6, 9, 9 };
    try set.findValues(i32, &off, "foobarbaz", &got);
    try testing.expectEqualSlices(usize, &.{ 1, 2 }, got.rows.items);
}
