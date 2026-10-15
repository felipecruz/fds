//! Turning the command line's terms into what the search runs: literals,
//! or a regex. Several literal terms (`-e a -e b`) stay literals: each is
//! searched with the SIMD loop. `-w` (whole words), and several terms with
//! `-E`, are expressed as regexes: `\b` and `|` already exist there, and the
//! SIMD prefilter still runs on a regex's required literal (`needle` in
//! `\bneedle\b`). `-S` (smart case) picks case-insensitive matching when no
//! term has an upper-case letter.
//!
//! From `many` literal terms on, they are searched together by an
//! Aho-Corasick automaton (multi.zig) instead of one SIMD pass each, `-w`
//! included: a regex of thousands of alternatives would be slow.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Flags = struct {
    regex: bool = false, // terms are regexes (-E)
    word: bool = false, // -w
    ignore_case: bool = false, // -i
    smart_case: bool = false, // -S
};

/// From this many literal terms, one automaton beats a SIMD pass per term.
pub const many = 8;

pub const Pattern = struct {
    /// The regex's source with `regex`; else the literals, any of which may
    /// match (usually one).
    source: []const u8,
    literals: []const []const u8,
    regex: bool,
    ignore_case: bool,
    /// With `literals`: each must match as a whole word.
    word: bool = false,
};

pub fn build(arena: Allocator, terms: []const []const u8, flags: Flags) !Pattern {
    std.debug.assert(terms.len > 0);
    var fold = flags.ignore_case;
    if (flags.smart_case and !fold) {
        fold = for (terms) |t| {
            if (hasUpper(t, flags.regex)) break false;
        } else true;
    }
    if (!flags.word and (terms.len == 1 or !flags.regex)) return .{ .source = terms[0], .literals = terms, .regex = flags.regex, .ignore_case = fold };
    if (flags.word and !flags.regex and terms.len >= many) return .{ .source = terms[0], .literals = terms, .regex = false, .ignore_case = fold, .word = true };

    var out: std.ArrayList(u8) = .empty;
    for (terms, 0..) |t, i| {
        if (i > 0) try out.append(arena, '|');
        if (flags.regex) {
            if (flags.word) try out.appendSlice(arena, "\\b(");
            try out.appendSlice(arena, "(");
            try out.appendSlice(arena, t);
            try out.appendSlice(arena, ")");
            if (flags.word) try out.appendSlice(arena, ")\\b");
        } else {
            // A word boundary only where the term starts or ends with a
            // word byte: `-w` on "-x" can't require a word byte before '-'.
            const edge_l = flags.word and t.len > 0 and isWord(t[0]);
            const edge_r = flags.word and t.len > 0 and isWord(t[t.len - 1]);
            if (edge_l) try out.appendSlice(arena, "\\b");
            try escape(arena, &out, t);
            if (edge_r) try out.appendSlice(arena, "\\b");
        }
    }
    return .{ .source = out.items, .literals = &.{}, .regex = true, .ignore_case = fold };
}

/// Appends `t` as a regex that matches it literally.
pub fn escape(arena: Allocator, out: *std.ArrayList(u8), t: []const u8) !void {
    for (t) |c| switch (c) {
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        // Letters and digits stand for themselves; so do non-ASCII bytes.
        // Any other byte is escaped: `\x` is a literal x for those.
        else => if (std.ascii.isAlphanumeric(c) or c >= 0x80) {
            try out.append(arena, c);
        } else {
            try out.appendSlice(arena, &.{ '\\', c });
        },
    };
}

// Does the term have an upper-case letter? In a regex, an escape such as
// \W or \S is not a letter of the term.
fn hasUpper(t: []const u8, regex: bool) bool {
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (regex and t[i] == '\\') {
            i += 1;
            continue;
        }
        if (std.ascii.isUpper(t[i])) return true;
    }
    return false;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const testing = std.testing;
const Regex = @import("regex.zig").Regex;
const Vm = @import("regex.zig").Vm;

fn matches(p: Pattern, value: []const u8) !bool {
    if (!p.regex) {
        for (p.literals) |l| {
            if (if (p.ignore_case) std.ascii.findIgnoreCase(value, l) != null else std.mem.indexOf(u8, value, l) != null) return true;
        }
        return false;
    }
    var re = try Regex.compile(testing.allocator, p.source, p.ignore_case);
    defer re.deinit();
    var vm = try Vm.init(testing.allocator, &re);
    defer vm.deinit(testing.allocator);
    return vm.isMatch(&re, value);
}

test "smart case, words, several terms" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // -S: lower case means ignore case; an upper-case letter means exact.
    try testing.expect((try build(a, &.{"needle"}, .{ .smart_case = true })).ignore_case);
    try testing.expect(!(try build(a, &.{"Needle"}, .{ .smart_case = true })).ignore_case);
    try testing.expect((try build(a, &.{"\\Wneedle"}, .{ .smart_case = true, .regex = true })).ignore_case);

    // -w: whole words only.
    const w = try build(a, &.{"needle"}, .{ .word = true });
    try testing.expect(try matches(w, "a needle here"));
    try testing.expect(!try matches(w, "needles"));
    try testing.expect(!try matches(w, "haystack_needle"));

    // -e: any of the terms, each literal (special characters included);
    // they stay literals.
    const e = try build(a, &.{ "a.b", "(x)", "tab\there" }, .{});
    try testing.expect(!e.regex and e.literals.len == 3);
    try testing.expect(try matches(e, "xx a.b yy"));
    try testing.expect(!try matches(e, "aXb"));
    try testing.expect(try matches(e, "f(x)"));
    try testing.expect(try matches(e, "tab\there"));
    try testing.expect(!try matches(e, "nothing"));

    // -w with many literals: they stay literals, for the automaton.
    const many_words = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
    try testing.expect(many_words.len >= many);
    const mw = try build(a, &many_words, .{ .word = true });
    try testing.expect(!mw.regex and mw.word and mw.literals.len == many_words.len);

    // -e with -E: any of the regexes; with -w, as whole words.
    const ew = try build(a, &.{ "ne+dle", "hay" }, .{ .regex = true, .word = true });
    try testing.expect(try matches(ew, "a neeedle"));
    try testing.expect(try matches(ew, "hay!"));
    try testing.expect(!try matches(ew, "haystack"));
}

test "an escaped term matches exactly what the literal search does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    const alphabet = "ab.*+?()[]{}|^$\\ \n\x80";
    var term_buf: [4]u8 = undefined;
    var value_buf: [12]u8 = undefined;
    for (0..2000) |_| {
        const term = term_buf[0 .. 1 + r.uintLessThan(usize, term_buf.len)];
        for (term) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        const value = value_buf[0..r.uintAtMost(usize, value_buf.len)];
        for (value) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        var src: std.ArrayList(u8) = .empty;
        try escape(a, &src, term);
        const p: Pattern = .{ .source = src.items, .literals = &.{}, .regex = true, .ignore_case = false };
        try testing.expectEqual(std.mem.indexOf(u8, value, term) != null, try matches(p, value));
    }
}
