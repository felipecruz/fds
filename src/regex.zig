//! Regular expressions for `fds -E`: a recursive-descent parser, a compiler
//! to a Thompson NFA and a Pike VM that answers one question: does this
//! value contain a match?
//!
//! Syntax (byte-oriented, ASCII classes):
//!
//!     x            a byte; \x is x literally for any non-alphanumeric x
//!     .            any byte, newline included
//!     [abc] [^a-z] classes, with ranges and \d \w \s inside
//!     \d \w \s     ASCII digit, word byte [0-9A-Za-z_], whitespace
//!     \D \W \S     their complements
//!     \t \n \r     tab, newline, carriage return
//!     \b           word boundary
//!     ^ $          start and end of the value
//!     e* e+ e?     repetition; also e{n} e{n,} e{n,m}
//!     e|f (e)      alternation, grouping
//!
//! The VM runs in O(value length × program size) time with no
//! backtracking, so no pattern is catastrophically slow. Most values never
//! reach the VM: every regex has a required literal ("PM_" in `PM_[A-Z]+`,
//! "" if none), and the SIMD search in match.zig only hands over values
//! that contain it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const match = @import("match.zig");

pub const Error = error{
    OutOfMemory,
    UnbalancedParen,
    BadClass,
    BadEscape,
    BadRepeat,
    NothingToRepeat,
    TooComplex,
};

/// Programs larger than this are rejected (e.g. `[a-z]{9999}`).
const max_prog = 10_000;
/// Deeper patterns are rejected: groups and quantifiers on quantifiers
/// nest the tree, which is walked recursively.
const max_depth = 256;

const Set = std.bit_set.Integer(256);

const Node = union(enum) {
    set: Set, // one byte from the set
    bol,
    eol,
    word_boundary,
    concat: []const Node, // empty: matches the empty string
    alt: []const Node, // two or more branches
    repeat: Repeat,
};

const Repeat = struct { node: *const Node, min: u32, max: ?u32 }; // null: unbounded

const Inst = union(enum) {
    set: Set, // consume one byte from the set
    split: [2]u32, // try both, first one preferred
    jmp: u32,
    bol,
    eol,
    word_boundary,
    match,
};

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    prog: []const Inst,
    /// Every match contains this ("" if nothing is required). With
    /// `ignore_case`, letters are lower-case and must be compared ignoring case.
    literal: []const u8,
    ignore_case: bool,
    /// Bytes that can start a match, or null if a match can start with an
    /// assertion or be empty. Lets the VM skip bytes while no thread is alive.
    first: ?Set,

    pub fn compile(gpa: Allocator, pattern: []const u8, ignore_case: bool) Error!Regex {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var p: Parser = .{ .arena = a, .src = pattern, .fold = ignore_case };
        const root = try p.alt();
        if (p.i != pattern.len) return error.UnbalancedParen; // stray ')'

        var c: Compiler = .{ .arena = a };
        try c.node(root);
        _ = try c.emit(.match);
        const literal = try required(a, root, ignore_case);
        const first = try firstBytes(a, c.prog.items);

        // Copy the arena last: allocations after the copy would be lost.
        return .{ .arena = arena, .prog = c.prog.items, .literal = literal, .ignore_case = ignore_case, .first = first };
    }

    pub fn deinit(re: *Regex) void {
        re.arena.deinit();
    }
};

/// Like `match.findValues`, for a regex: calls `sink.onValue(row, value)`
/// for each value that contains a match.
pub fn findValues(re: *const Regex, vm: *Vm, comptime O: type, off: []align(1) const O, data: []const u8, sink: anytype) !void {
    const filter: Filter(@TypeOf(sink)) = .{ .re = re, .vm = vm, .sink = sink };
    if (re.literal.len == 0) return everyValue(O, off, data, filter);
    if (re.ignore_case) return match.findValues(.insensitive, O, off, data, re.literal, filter);
    return match.findValues(.sensitive, O, off, data, re.literal, filter);
}

/// Does `value` contain a match? The literal prefilter, then the VM.
pub fn matches(re: *const Regex, vm: *Vm, value: []const u8) bool {
    if (re.literal.len > 0) {
        const case: match.Case = if (re.ignore_case) .insensitive else .sensitive;
        const found = switch (case) {
            inline else => |c| match.contains(c, value, re.literal),
        };
        if (!found) return false;
    }
    return vm.isMatch(re, value);
}

// A sink that passes on only the values the VM accepts.
fn Filter(comptime Sink: type) type {
    return struct {
        re: *const Regex,
        vm: *Vm,
        sink: Sink,

        pub fn onValue(f: @This(), row: usize, value: []const u8) !void {
            if (f.vm.isMatch(f.re, value)) try f.sink.onValue(row, value);
        }
    };
}

// No required literal: every value is a candidate.
fn everyValue(comptime O: type, off: []align(1) const O, data: []const u8, sink: anytype) !void {
    if (off.len < 2) return;
    for (0..off.len - 1) |row| try sink.onValue(row, data[@intCast(off[row])..@intCast(off[row + 1])]);
}

// ---------------------------------------------------------------- parser

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    i: usize = 0,
    fold: bool, // ignore case: letters match both cases
    depth: usize = 0, // nesting of the node being parsed

    fn peek(p: *const Parser) ?u8 {
        return if (p.i < p.src.len) p.src[p.i] else null;
    }

    // alt := concat ('|' concat)*
    fn alt(p: *Parser) Error!Node {
        var branches: std.ArrayList(Node) = .empty;
        try branches.append(p.arena, try p.concat());
        while (p.peek() == '|') {
            p.i += 1;
            try branches.append(p.arena, try p.concat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return .{ .alt = branches.items };
    }

    // concat := repeat*
    fn concat(p: *Parser) Error!Node {
        var items: std.ArrayList(Node) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            try items.append(p.arena, try p.repeat());
        }
        return .{ .concat = items.items };
    }

    // repeat := atom ('*' | '+' | '?' | '{n}' | '{n,}' | '{n,m}')*
    fn repeat(p: *Parser) Error!Node {
        var node = try p.atom();
        const depth = p.depth;
        defer p.depth = depth;
        while (p.peek()) |c| {
            p.depth += 1;
            if (p.depth > max_depth) return error.TooComplex;
            const r: [2]?u32 = switch (c) {
                '*' => .{ 0, null },
                '+' => .{ 1, null },
                '?' => .{ 0, 1 },
                '{' => try p.counted(),
                else => break,
            };
            if (c != '{') p.i += 1;
            const inner = try p.arena.create(Node);
            inner.* = node;
            node = .{ .repeat = .{ .node = inner, .min = r[0].?, .max = r[1] } };
        }
        return node;
    }

    // '{n}', '{n,}' or '{n,m}'.
    fn counted(p: *Parser) Error![2]?u32 {
        p.i += 1; // '{'
        const min = p.number() orelse return error.BadRepeat;
        var max: ?u32 = min;
        if (p.peek() == ',') {
            p.i += 1;
            max = p.number(); // none: unbounded
        }
        if (p.peek() != '}') return error.BadRepeat;
        p.i += 1;
        if (max != null and max.? < min) return error.BadRepeat;
        return .{ min, max };
    }

    fn number(p: *Parser) ?u32 {
        const start = p.i;
        while (p.peek()) |c| : (p.i += 1) if (!std.ascii.isDigit(c)) break;
        return std.fmt.parseInt(u32, p.src[start..p.i], 10) catch null;
    }

    fn atom(p: *Parser) Error!Node {
        const c = p.src[p.i]; // concat checked there is one
        p.i += 1;
        switch (c) {
            '(' => {
                p.depth += 1;
                defer p.depth -= 1;
                if (p.depth > max_depth) return error.TooComplex;
                const inner = try p.alt();
                if (p.peek() != ')') return error.UnbalancedParen;
                p.i += 1;
                return inner;
            },
            '*', '+', '?', '{' => return error.NothingToRepeat,
            '.' => return .{ .set = .full },
            '^' => return .bol,
            '$' => return .eol,
            '[' => return .{ .set = try p.class() },
            '\\' => {
                if (p.peek() == 'b') {
                    p.i += 1;
                    return .word_boundary;
                }
                return .{ .set = try p.escape() };
            },
            else => return .{ .set = p.byte(c) },
        }
    }

    fn byte(p: *const Parser, c: u8) Set {
        var s: Set = .empty;
        s.set(c);
        if (p.fold) s = foldCase(s);
        return s;
    }

    // After a '\': a class (\d \w \s and complements) or a literal byte.
    fn escape(p: *Parser) Error!Set {
        const c = p.peek() orelse return error.BadEscape;
        p.i += 1;
        var s: Set = .empty;
        switch (c) {
            'd', 'D' => s.setRangeValue(.{ .start = '0', .end = '9' + 1 }, true),
            'w', 'W' => for (0..256) |b| {
                if (isWord(@intCast(b))) s.set(b);
            },
            's', 'S' => for (" \t\n\r\x0b\x0c") |b| s.set(b),
            't' => return p.byte('\t'),
            'n' => return p.byte('\n'),
            'r' => return p.byte('\r'),
            else => {
                // Other letter escapes are errors, so they stay free for later.
                if (std.ascii.isAlphanumeric(c)) return error.BadEscape;
                return p.byte(c);
            },
        }
        if (std.ascii.isUpper(c)) s.toggleAll(); // \D \W \S
        return s;
    }

    // After a '[': members up to ']'. A ']' right after '[' or '[^' is a
    // member; so is a '-' that does not form a range. Ranges are between
    // plain bytes only.
    fn class(p: *Parser) Error!Set {
        var s: Set = .empty;
        const negate = p.peek() == '^';
        if (negate) p.i += 1;
        var first = true;
        while (true) : (first = false) {
            const c = p.peek() orelse return error.BadClass;
            if (c == ']' and !first) break;
            p.i += 1;
            if (c == '\\') {
                s.setUnion(try p.escape());
                continue;
            }
            if (p.peek() == '-' and p.i + 1 < p.src.len and p.src[p.i + 1] != ']') {
                const hi = p.src[p.i + 1];
                if (hi == '\\' or hi < c) return error.BadClass;
                p.i += 2;
                s.setRangeValue(.{ .start = c, .end = @as(usize, hi) + 1 }, true);
            } else {
                s.set(c);
            }
        }
        p.i += 1; // ']'
        if (p.fold) s = foldCase(s);
        if (negate) s.toggleAll();
        return s;
    }
};

// Adds the other case of every ASCII letter in `s`.
fn foldCase(s: Set) Set {
    var out = s;
    for ('A'..'Z' + 1) |u| {
        const l = u + ('a' - 'A');
        if (s.isSet(u) or s.isSet(l)) {
            out.set(u);
            out.set(l);
        }
    }
    return out;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// ---------------------------------------------------------------- required literal

// The longest byte string every match must contain, for the SIMD prefilter.
// Only runs of single bytes in a concatenation count (anchors don't break a
// run); alternatives and optional parts contribute nothing.
fn required(a: Allocator, n: Node, fold: bool) Error![]const u8 {
    switch (n) {
        .set => |s| return if (literalByte(s, fold)) |b| a.dupe(u8, &.{b}) else "",
        .repeat => |r| return if (r.min > 0) required(a, r.node.*, fold) else "",
        .concat => |items| {
            var best: []const u8 = "";
            var run: std.ArrayList(u8) = .empty;
            for (items) |item| {
                switch (item) {
                    .set => |s| if (literalByte(s, fold)) |b| {
                        try run.append(a, b);
                        continue;
                    },
                    .bol, .eol, .word_boundary => continue,
                    else => {},
                }
                best = longer(best, run.items);
                run = .empty;
                best = longer(best, try required(a, item, fold));
            }
            return longer(best, run.items);
        },
        .alt, .bol, .eol, .word_boundary => return "",
    }
}

// The byte a set stands for, if it is a single byte (or, ignoring case, a
// single letter in both cases, returned lower-case).
fn literalByte(s: Set, fold: bool) ?u8 {
    const lo: u8 = @intCast(s.findFirstSet() orelse return null);
    if (s.count() == 1) return lo;
    if (fold and s.count() == 2 and std.ascii.isUpper(lo) and s.isSet(std.ascii.toLower(lo))) return std.ascii.toLower(lo);
    return null;
}

fn longer(x: []const u8, y: []const u8) []const u8 {
    return if (y.len > x.len) y else x;
}

// The union of the byte sets reachable from pc 0 without consuming a byte.
fn firstBytes(a: Allocator, prog: []const Inst) Error!?Set {
    var first: Set = .empty;
    const seen = try a.alloc(bool, prog.len);
    @memset(seen, false);
    var stack: std.ArrayList(u32) = .empty;
    try stack.append(a, 0);
    while (stack.pop()) |pc| {
        if (seen[pc]) continue;
        seen[pc] = true;
        switch (prog[pc]) {
            .set => |s| first.setUnion(s),
            .jmp => |t| try stack.append(a, t),
            .split => |t| try stack.appendSlice(a, &t),
            .match, .bol, .eol, .word_boundary => return null,
        }
    }
    return first;
}

// ---------------------------------------------------------------- compiler

const Compiler = struct {
    arena: Allocator,
    prog: std.ArrayList(Inst) = .empty,
    // Nodes compiled, repeats counted each time: an empty body emits
    // nothing, so `max_prog` alone wouldn't stop `(){4000000000}`.
    work: usize = 0,

    fn emit(c: *Compiler, inst: Inst) Error!u32 {
        if (c.prog.items.len >= max_prog) return error.TooComplex;
        try c.prog.append(c.arena, inst);
        return @intCast(c.prog.items.len - 1);
    }

    fn here(c: *const Compiler) u32 {
        return @intCast(c.prog.items.len);
    }

    fn node(c: *Compiler, n: Node) Error!void {
        c.work += 1;
        if (c.work > 4 * max_prog) return error.TooComplex;
        switch (n) {
            .set => |s| _ = try c.emit(.{ .set = s }),
            .bol => _ = try c.emit(.bol),
            .eol => _ = try c.emit(.eol),
            .word_boundary => _ = try c.emit(.word_boundary),
            .concat => |items| for (items) |item| try c.node(item),
            .alt => |branches| {
                // split L1 L2; L1: a; jmp end; L2: split ...; last branch; end:
                var jumps: std.ArrayList(u32) = .empty;
                for (branches[0 .. branches.len - 1]) |b| {
                    const split = try c.emit(.{ .split = undefined });
                    try c.node(b);
                    try jumps.append(c.arena, try c.emit(.{ .jmp = undefined }));
                    c.prog.items[split] = .{ .split = .{ split + 1, c.here() } };
                }
                try c.node(branches[branches.len - 1]);
                for (jumps.items) |j| c.prog.items[j] = .{ .jmp = c.here() };
            },
            .repeat => |r| {
                for (0..r.min) |_| try c.node(r.node.*);
                if (r.max) |max| {
                    // Each optional copy: split body end. Skipping one skips the rest.
                    var splits: std.ArrayList(u32) = .empty;
                    for (r.min..max) |_| {
                        try splits.append(c.arena, try c.emit(.{ .split = undefined }));
                        try c.node(r.node.*);
                    }
                    for (splits.items) |s| c.prog.items[s] = .{ .split = .{ s + 1, c.here() } };
                } else {
                    // L: split body end; body; jmp L; end:
                    const split = try c.emit(.{ .split = undefined });
                    try c.node(r.node.*);
                    _ = try c.emit(.{ .jmp = split });
                    c.prog.items[split] = .{ .split = .{ split + 1, c.here() } };
                }
            },
        }
    }
};

// ---------------------------------------------------------------- VM

/// Scratch space for matching. One per thread; reused for every value.
pub const Vm = struct {
    clist: []u32, // threads at the current position (pcs of `set` instructions)
    nlist: []u32, // threads at the next position
    seen: []usize, // seen[pc] == gen: pc already added at this position
    stack: []u32, // pcs to follow in `add`
    gen: usize = 0,

    pub fn init(gpa: Allocator, re: *const Regex) !Vm {
        const n = re.prog.len;
        const seen = try gpa.alloc(usize, n);
        @memset(seen, 0);
        return .{
            .clist = try gpa.alloc(u32, n),
            .nlist = try gpa.alloc(u32, n),
            .seen = seen,
            .stack = try gpa.alloc(u32, 2 * n + 1),
        };
    }

    pub fn deinit(vm: *Vm, gpa: Allocator) void {
        gpa.free(vm.clist);
        gpa.free(vm.nlist);
        gpa.free(vm.seen);
        gpa.free(vm.stack);
    }

    /// Does `line` (a value) contain a match? Runs all threads in lockstep, one byte
    /// at a time, starting a new thread at every position (skipping ahead
    /// with `first` while none is alive).
    pub fn isMatch(vm: *Vm, re: *const Regex, line: []const u8) bool {
        var n_cur: usize = 0;
        vm.gen += 1;
        var i: usize = 0;
        while (true) : (i += 1) {
            if (n_cur == 0) if (re.first) |first| {
                // No live threads: jump to the next byte that can start a match.
                while (i < line.len and !first.isSet(line[i])) i += 1;
                if (i == line.len) return false;
                vm.gen += 1;
            };
            if (vm.add(re, vm.clist, &n_cur, 0, line, i)) return true;
            if (i == line.len or (n_cur == 0 and isAnchored(re))) return false;
            vm.gen += 1;
            var n_next: usize = 0;
            for (vm.clist[0..n_cur]) |pc| {
                if (re.prog[pc].set.isSet(line[i]) and vm.add(re, vm.nlist, &n_next, pc + 1, line, i + 1)) return true;
            }
            std.mem.swap([]u32, &vm.clist, &vm.nlist);
            n_cur = n_next;
        }
    }

    // Like `add`, but follows every path even after reaching `match`, so
    // `longestAt` keeps the threads that may match longer. Returns true if
    // any path reaches `match`.
    fn addAll(vm: *Vm, re: *const Regex, list: []u32, n: *usize, start: u32, line: []const u8, i: usize) bool {
        var matched = false;
        var sp: usize = 1;
        vm.stack[0] = start;
        while (sp > 0) {
            sp -= 1;
            const pc = vm.stack[sp];
            if (vm.seen[pc] == vm.gen) continue;
            vm.seen[pc] = vm.gen;
            const follow = switch (re.prog[pc]) {
                .match => {
                    matched = true;
                    continue;
                },
                .set => {
                    list[n.*] = pc;
                    n.* += 1;
                    continue;
                },
                .jmp => |t| t,
                .split => |t| {
                    vm.stack[sp] = t[1];
                    vm.stack[sp + 1] = t[0];
                    sp += 2;
                    continue;
                },
                .bol => if (i == 0) pc + 1 else continue,
                .eol => if (i == line.len) pc + 1 else continue,
                .word_boundary => if (wordBoundary(line, i)) pc + 1 else continue,
            };
            vm.stack[sp] = follow;
            sp += 1;
        }
        return matched;
    }

    // Adds the thread at `start` and everything reachable from it without
    // consuming a byte. Returns true if that reaches `match`.
    fn add(vm: *Vm, re: *const Regex, list: []u32, n: *usize, start: u32, line: []const u8, i: usize) bool {
        var sp: usize = 1;
        vm.stack[0] = start;
        while (sp > 0) {
            sp -= 1;
            const pc = vm.stack[sp];
            if (vm.seen[pc] == vm.gen) continue;
            vm.seen[pc] = vm.gen;
            const follow = switch (re.prog[pc]) {
                .match => return true,
                .set => {
                    list[n.*] = pc;
                    n.* += 1;
                    continue;
                },
                .jmp => |t| t,
                .split => |t| {
                    vm.stack[sp] = t[1];
                    vm.stack[sp + 1] = t[0];
                    sp += 2;
                    continue;
                },
                .bol => if (i == 0) pc + 1 else continue,
                .eol => if (i == line.len) pc + 1 else continue,
                .word_boundary => if (wordBoundary(line, i)) pc + 1 else continue,
            };
            vm.stack[sp] = follow;
            sp += 1;
        }
        return false;
    }
};

/// The leftmost match in `line` at or after `from`, as [start, end), taking
/// the longest end at that start. For highlighting a value already known
/// to match, so it trades speed for simplicity: one anchored run per
/// candidate start.
pub fn span(vm: *Vm, re: *const Regex, line: []const u8, from: usize) ?[2]usize {
    var start = from;
    while (start <= line.len) : (start += 1) {
        if (re.first) |first| {
            while (start < line.len and !first.isSet(line[start])) start += 1;
            if (start == line.len) return null;
        }
        if (longestAt(vm, re, line, start)) |end| return .{ start, end };
        if (isAnchored(re)) return null;
    }
    return null;
}

// The end of the longest match starting exactly at `start`, if any.
fn longestAt(vm: *Vm, re: *const Regex, line: []const u8, start: usize) ?usize {
    var best: ?usize = null;
    var n_cur: usize = 0;
    vm.gen += 1;
    if (vm.addAll(re, vm.clist, &n_cur, 0, line, start)) best = start;
    var i = start;
    while (n_cur > 0 and i < line.len) : (i += 1) {
        vm.gen += 1;
        var n_next: usize = 0;
        for (vm.clist[0..n_cur]) |pc| {
            if (re.prog[pc].set.isSet(line[i]) and vm.addAll(re, vm.nlist, &n_next, pc + 1, line, i + 1)) best = i + 1;
        }
        std.mem.swap([]u32, &vm.clist, &vm.nlist);
        n_cur = n_next;
    }
    return best;
}

// A pattern starting with '^' can't match once all threads have died.
fn isAnchored(re: *const Regex) bool {
    return re.prog[0] == .bol;
}

fn wordBoundary(line: []const u8, i: usize) bool {
    const before = i > 0 and isWord(line[i - 1]);
    const after = i < line.len and isWord(line[i]);
    return before != after;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectMatch(pattern: []const u8, line: []const u8, ignore_case: bool, expected: bool) !void {
    var re = try Regex.compile(testing.allocator, pattern, ignore_case);
    defer re.deinit();
    var vm = try Vm.init(testing.allocator, &re);
    defer vm.deinit(testing.allocator);
    if (vm.isMatch(&re, line) != expected) {
        std.debug.print("pattern {s} line \"{s}\": expected {}\n", .{ pattern, line, expected });
        return error.TestUnexpectedResult;
    }
}

test "regex syntax" {
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "abc", "xxabcxx", true },
        .{ "abc", "ab c", false },
        .{ "a.c", "abc", true },
        .{ "a.c", "ac", false },
        .{ "^abc", "abcd", true },
        .{ "^abc", "xabc", false },
        .{ "abc$", "xabc", true },
        .{ "abc$", "abcx", false },
        .{ "^$", "", true },
        .{ "^$", "x", false },
        .{ "ab*c", "ac", true },
        .{ "ab*c", "abbbc", true },
        .{ "ab+c", "ac", false },
        .{ "ab+c", "abbc", true },
        .{ "ab?c", "abc", true },
        .{ "ab?c", "abbc", false },
        .{ "a{3}", "aa", false },
        .{ "a{3}", "aaa", true },
        .{ "^a{2,3}$", "aaaa", false },
        .{ "^a{2,3}$", "aaa", true },
        .{ "^a{2,}$", "aaaaaa", true },
        .{ "^a{2,}$", "a", false },
        .{ "^a{0}b", "b", true },
        .{ "cat|dog", "hotdog", true },
        .{ "cat|dog", "cow", false },
        .{ "^(cat|dog)s?$", "dogs", true },
        .{ "^(cat|dog)s?$", "dogsx", false },
        .{ "(ab)+$", "xababab", true },
        .{ "^(a|)$", "", true },
        .{ "()*x", "x", true },
        .{ "[abc]+", "xxbxx", true },
        .{ "[abc]", "xyz", false },
        .{ "[^abc]", "abc", false },
        .{ "[^abc]", "abcd", true },
        .{ "[a-f0-9]{4}", "zz9f3c", true },
        .{ "[a-f0-9]{4}", "zz9g3c", false },
        .{ "[]a]", "]", true },
        .{ "[^]a]", "]a", false },
        .{ "[a-]", "-", true },
        .{ "[\\d.]+$", "v1.2", true },
        .{ "\\d+", "abc", false },
        .{ "\\d+", "a1", true },
        .{ "^\\D+$", "abc", true },
        .{ "\\w+_lock\\(", "spin_lock(&x)", true },
        .{ "^\\W", "_x", false },
        .{ "\\s", "a\tb", true },
        .{ "^\\S+$", "a b", false },
        .{ "\\t", "a\tb", true },
        .{ "a\\nb", "a\nb", true },
        .{ "^a\\sb$", "a\nb", true },
        .{ "\\bfoo\\b", "a foo b", true },
        .{ "\\bfoo\\b", "afoo", false },
        .{ "\\bfoo\\b", "foo_", false },
        .{ "\\.", "a.b", true },
        .{ "\\.", "ab", false },
        .{ "a\\|b", "a|b", true },
        .{ "\\(x\\)", "f(x)", true },
        .{ "\\[", "[", true },
        .{ "\\\\", "a\\b", true },
        .{ "(a*)*b", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", false }, // no blow-up
        .{ "caf\xc3\xa9", "un caf\xc3\xa9", true }, // UTF-8 as bytes
    };
    for (cases) |c| try expectMatch(c[0], c[1], false, c[2]);
}

test "regex ignore case" {
    try expectMatch("hello", "HeLLo", true, true);
    try expectMatch("hello", "HeLLo", false, false);
    try expectMatch("[a-c]+x", "ABCX", true, true);
    try expectMatch("[^a]", "A", true, false);
    try expectMatch("\\[", "{", true, false); // '[' and '{' are not cases of each other
    try expectMatch("\xc3\xa9", "\xc3\x89", true, false); // é/É: ASCII folding only
}

test "regex errors" {
    const cases = [_]struct { []const u8, Error }{
        .{ "(ab", error.UnbalancedParen },
        .{ "ab)", error.UnbalancedParen },
        .{ "[ab", error.BadClass },
        .{ "[z-a]", error.BadClass },
        .{ "*a", error.NothingToRepeat },
        .{ "a|+", error.NothingToRepeat },
        .{ "a\\", error.BadEscape },
        .{ "\\q", error.BadEscape },
        .{ "a{2,1}", error.BadRepeat },
        .{ "a{x}", error.BadRepeat },
        .{ "a{2", error.BadRepeat },
        .{ "[a-z]{20000}", error.TooComplex },
        .{ "(){4000000000}", error.TooComplex }, // emits nothing, but must not loop
    };
    for (cases) |c| try testing.expectError(c[1], Regex.compile(testing.allocator, c[0], false));

    // Nesting deeper than max_depth is rejected; within it, fine.
    var buf: [2000]u8 = undefined;
    try testing.expectError(error.TooComplex, Regex.compile(testing.allocator, nested(&buf, 300), false));
    var re = try Regex.compile(testing.allocator, nested(&buf, 200), false);
    re.deinit();
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("a");
    for (0..300) |_| try w.writeAll("{1}");
    try testing.expectError(error.TooComplex, Regex.compile(testing.allocator, w.buffered(), false));
}

// `n` groups around an `a`: "((a))" for 2.
fn nested(buf: []u8, n: usize) []const u8 {
    @memset(buf[0..n], '(');
    buf[n] = 'a';
    @memset(buf[n + 1 ..][0..n], ')');
    return buf[0 .. 2 * n + 1];
}

test "regex required literal" {
    const cases = [_]struct { []const u8, bool, []const u8 }{
        .{ "PM_[A-Z]+", false, "PM_" },
        .{ "^\\s*#\\s*define\\s+FOO", false, "define" },
        .{ "\\bERR_PTR\\(", false, "ERR_PTR(" },
        .{ "ab+cd", false, "cd" },
        .{ "(abc)+x", false, "abc" },
        .{ "dict(Find|Delete)\\(", false, "dict" },
        .{ "(spin|mutex)_lock\\(", false, "_lock(" },
        .{ "(abc)*x", false, "x" },
        .{ "abc|abd", false, "" },
        .{ "a?", false, "" },
        .{ "[0-9a-f]{8}", false, "" },
        .{ "Hello", true, "hello" },
        .{ "[Hh]ello", false, "ello" },
    };
    for (cases) |c| {
        var re = try Regex.compile(testing.allocator, c[0], c[1]);
        defer re.deinit();
        try testing.expectEqualStrings(c[2], re.literal);
    }
}

// Reference matcher for the randomized test: backtracking straight over
// the parse tree. `rest` is what must match after the head node.
fn backtrack(a: Allocator, nodes: []const Node, line: []const u8, i: usize) Error!bool {
    if (nodes.len == 0) return true;
    const rest = nodes[1..];
    switch (nodes[0]) {
        .set => |s| return i < line.len and s.isSet(line[i]) and try backtrack(a, rest, line, i + 1),
        .bol => return i == 0 and try backtrack(a, rest, line, i),
        .eol => return i == line.len and try backtrack(a, rest, line, i),
        .word_boundary => return wordBoundary(line, i) and try backtrack(a, rest, line, i),
        .concat => |items| return backtrack(a, try std.mem.concat(a, Node, &[_][]const Node{ items, rest }), line, i),
        .alt => |branches| {
            for (branches) |b| {
                if (try backtrack(a, try std.mem.concat(a, Node, &[_][]const Node{ &.{b}, rest }), line, i)) return true;
            }
            return false;
        },
        .repeat => |r| {
            // The generator only repeats sets, which always consume a byte.
            if (r.min == 0) {
                if (try backtrack(a, rest, line, i)) return true;
                if (r.max != null and r.max.? == 0) return false;
            }
            const fewer: Node = .{ .repeat = .{ .node = r.node, .min = r.min -| 1, .max = if (r.max) |m| m - 1 else null } };
            return backtrack(a, try std.mem.concat(a, Node, &[_][]const Node{ &.{ r.node.*, fewer }, rest }), line, i);
        },
    }
}

fn randomPattern(rand: std.Random, buf: *std.ArrayList(u8), a: Allocator, depth: u32) !void {
    const atoms = [_][]const u8{ "a", "b", "A", ".", "[ab]", "[^a]", "\\w", "_", " ", "ab", "ba" };
    const n = 1 + rand.uintLessThan(usize, 4);
    for (0..n) |_| {
        switch (rand.uintLessThan(u8, 12)) {
            0 => try buf.append(a, '^'),
            1 => try buf.append(a, '$'),
            2 => try buf.appendSlice(a, "\\b"),
            3 => if (depth < 2) {
                try buf.append(a, '(');
                try randomPattern(rand, buf, a, depth + 1);
                try buf.append(a, '|');
                try randomPattern(rand, buf, a, depth + 1);
                try buf.append(a, ')');
            },
            else => {
                const atom = atoms[rand.uintLessThan(usize, atoms.len)];
                try buf.appendSlice(a, atom);
                if (atom.len == 2 and atom[0] != '\\') continue; // two bytes: don't repeat
                const quants = [_][]const u8{ "", "", "*", "+", "?", "{2}", "{1,3}", "{2,}" };
                try buf.appendSlice(a, quants[rand.uintLessThan(usize, quants.len)]);
            },
        }
    }
}

test "regex VM matches backtracking reference" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var prng: std.Random.DefaultPrng = .init(0x7e9e);
    const rand = prng.random();
    var line_buf: [16]u8 = undefined;

    for (0..5_000) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var pattern: std.ArrayList(u8) = .empty;
        try randomPattern(rand, &pattern, a, 0);
        const ignore_case = rand.boolean();

        var re = try Regex.compile(testing.allocator, pattern.items, ignore_case);
        defer re.deinit();
        var vm = try Vm.init(testing.allocator, &re);
        defer vm.deinit(testing.allocator);
        var p: Parser = .{ .arena = a, .src = pattern.items, .fold = ignore_case };
        const root = try p.alt();

        for (0..20) |_| {
            const line = line_buf[0..rand.uintAtMost(usize, line_buf.len)];
            for (line) |*c| c.* = "abAB_ "[rand.uintLessThan(usize, 6)];
            var expected = false;
            for (0..line.len + 1) |i| {
                if (try backtrack(a, &.{root}, line, i)) expected = true;
            }
            if (vm.isMatch(&re, line) != expected) {
                std.debug.print("pattern {s} (ignore case {}) line \"{s}\": expected {}\n", .{ pattern.items, ignore_case, line, expected });
                return error.TestUnexpectedResult;
            }
            // The prefilter must never drop a matching line.
            if (expected) {
                const found = if (ignore_case) std.ascii.findIgnoreCase(line, re.literal) else std.mem.indexOf(u8, line, re.literal);
                try testing.expect(found != null);
            }
        }
    }
}

const CollectRows = struct {
    gpa: Allocator,
    rows: *std.ArrayList(usize),
    pub fn onValue(c: CollectRows, row: usize, value: []const u8) !void {
        _ = value;
        try c.rows.append(c.gpa, row);
    }
};

test "regex findValues: prefiltered and every-value paths agree" {
    const gpa = testing.allocator;
    const values = [_][]const u8{ "foo", "PM_RESUME x", "", "pm_suspend", "PM_", "end PM_FOO", "a\nb" };
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var off: std.ArrayList(i32) = .empty;
    defer off.deinit(gpa);
    try off.append(gpa, 0);
    for (values) |v| {
        try data.appendSlice(gpa, v);
        try off.append(gpa, @intCast(data.items.len));
    }
    const cases = [_]struct { []const u8, bool, []const usize }{
        .{ "PM_[A-Z]+", false, &.{ 1, 5 } },
        .{ "PM_[A-Z]+", true, &.{ 1, 3, 5 } },
        .{ "^$", false, &.{2} },
        .{ "^[a-z_]+$", false, &.{ 0, 3 } },
        .{ "O$", false, &.{5} },
        // `^` and `$` are the value's ends, not lines inside it.
        .{ "^a.b$", false, &.{6} },
        .{ "^b", false, &.{} },
    };
    var got: std.ArrayList(usize) = .empty;
    defer got.deinit(gpa);
    var all: std.ArrayList(usize) = .empty;
    defer all.deinit(gpa);
    for (cases) |c| {
        var re = try Regex.compile(gpa, c[0], c[1]);
        defer re.deinit();
        var vm = try Vm.init(gpa, &re);
        defer vm.deinit(gpa);
        got.clearRetainingCapacity();
        all.clearRetainingCapacity();
        try findValues(&re, &vm, i32, off.items, data.items, CollectRows{ .gpa = gpa, .rows = &got });
        const filter: Filter(CollectRows) = .{ .re = &re, .vm = &vm, .sink = .{ .gpa = gpa, .rows = &all } };
        try everyValue(i32, off.items, data.items, filter);
        try testing.expectEqualSlices(usize, c[2], got.items);
        try testing.expectEqualSlices(usize, c[2], all.items);
        for (values, 0..) |v, row| {
            const expected = std.mem.indexOfScalar(usize, c[2], row) != null;
            try testing.expectEqual(expected, matches(&re, &vm, v));
        }
    }
}

test "span: leftmost match, longest end" {
    const gpa = testing.allocator;
    const cases = [_]struct { []const u8, []const u8, ?[2]usize }{
        .{ "ab+", "xxabbbyab", .{ 2, 6 } },
        .{ "\\bneedle\\b", "needles a needle", .{ 10, 16 } },
        .{ "a|ab", "zab", .{ 1, 3 } },
        .{ "^b", "ab", null },
        .{ "x*", "abc", .{ 0, 0 } },
        .{ "c$", "abc", .{ 2, 3 } },
    };
    for (cases) |c| {
        var re = try Regex.compile(gpa, c[0], false);
        defer re.deinit();
        var vm = try Vm.init(gpa, &re);
        defer vm.deinit(gpa);
        try testing.expectEqual(c[2], span(&vm, &re, c[1], 0));
    }
}
