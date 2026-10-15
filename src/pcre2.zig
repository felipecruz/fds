//! `-E` through PCRE2 (third_party/pcre2, built only with `zig build
//! -Dpcre2`), with the same interface as regex.zig: see re.zig, which picks
//! one of the two.
//!
//! PCRE2 runs in 8-bit, non-UTF mode, so like regex.zig it matches bytes:
//! `.` is any byte (DOTALL), `$` is only the end of the value
//! (DOLLAR_ENDONLY), and \d \w \s \b are ASCII. Everything else in PCRE2's
//! syntax is accepted too (lazy quantifiers, lookaround, backreferences,
//! POSIX classes). Patterns are JIT-compiled where PCRE2 can (x86-64, arm64
//! and others); otherwise PCRE2's interpreter runs them.
//!
//! The SIMD prefilter stays in front: a pattern's required literal comes
//! from regex.zig's parser, when it can read the pattern and the pattern
//! has nothing it would read differently from PCRE2 (see `prefilter`).
//!
//! PCRE2 backtracks, so a pattern like `(a+)+$` can take exponential time
//! on some values. Each match is bounded (`match_limit`); a value that
//! reaches the bound fails the search of its file (error.RegexLimit, exit
//! status 2) instead of being taken as not matching.

const std = @import("std");
const Allocator = std.mem.Allocator;
const match = @import("match.zig");
const own = @import("regex.zig");

pub const Error = error{ OutOfMemory, BadPattern };

const Code = opaque {};
const MatchData = opaque {};
const MatchContext = opaque {};
const JitStack = opaque {};
const GeneralContext = opaque {};

extern fn pcre2_compile_8(pattern: [*]const u8, len: usize, options: u32, err: *c_int, err_offset: *usize, ctx: ?*anyopaque) ?*Code;
extern fn pcre2_code_free_8(code: *Code) void;
extern fn pcre2_jit_compile_8(code: *Code, options: u32) c_int;
extern fn pcre2_match_data_create_from_pattern_8(code: *const Code, ctx: ?*GeneralContext) ?*MatchData;
extern fn pcre2_match_data_free_8(md: *MatchData) void;
extern fn pcre2_match_context_create_8(ctx: ?*GeneralContext) ?*MatchContext;
extern fn pcre2_match_context_free_8(ctx: *MatchContext) void;
extern fn pcre2_set_match_limit_8(ctx: *MatchContext, limit: u32) c_int;
extern fn pcre2_jit_stack_create_8(start: usize, max: usize, ctx: ?*GeneralContext) ?*JitStack;
extern fn pcre2_jit_stack_free_8(stack: *JitStack) void;
extern fn pcre2_jit_stack_assign_8(ctx: *MatchContext, callback: ?*const anyopaque, data: ?*anyopaque) void;
extern fn pcre2_match_8(code: *const Code, subject: [*]const u8, len: usize, start: usize, options: u32, md: *MatchData, ctx: ?*MatchContext) c_int;
extern fn pcre2_jit_match_8(code: *const Code, subject: [*]const u8, len: usize, start: usize, options: u32, md: *MatchData, ctx: ?*MatchContext) c_int;
extern fn pcre2_get_ovector_pointer_8(md: *MatchData) [*]usize;
extern fn pcre2_get_error_message_8(code: c_int, buf: [*]u8, len: usize) c_int;

const CASELESS: u32 = 0x00000008;
const DOLLAR_ENDONLY: u32 = 0x00000010;
const DOTALL: u32 = 0x00000020;
const JIT_COMPLETE: u32 = 0x00000001;
const ERROR_NOMATCH = -1;

/// Steps PCRE2 may take on one value before giving up. PCRE2's default;
/// a linear pattern on a 1 MB value takes about a million.
const match_limit = 10_000_000;

/// Why the last `Regex.compile` failed, e.g. "missing closing parenthesis
/// at 3". For the command line's message; not thread-safe.
pub var last_error: [160]u8 = undefined;
pub var last_error_len: usize = 0;

pub const Regex = struct {
    code: *Code,
    jit: bool,
    /// Every match contains this ("" if nothing is known to be required);
    /// lower-case with `ignore_case`, as in regex.zig.
    literal: []const u8,
    ignore_case: bool,
    gpa: Allocator,

    pub fn compile(gpa: Allocator, pattern: []const u8, ignore_case: bool) Error!Regex {
        var err: c_int = 0;
        var at: usize = 0;
        const options: u32 = DOTALL | DOLLAR_ENDONLY | if (ignore_case) CASELESS else 0;
        const code = pcre2_compile_8(pattern.ptr, pattern.len, options, &err, &at, null) orelse {
            var msg: [120]u8 = undefined;
            const n = pcre2_get_error_message_8(err, &msg, msg.len);
            const text = if (n > 0) msg[0..@intCast(n)] else "error";
            const written: []const u8 = std.fmt.bufPrint(&last_error, "{s} at {d}", .{ text, at }) catch &last_error;
            last_error_len = written.len;
            return error.BadPattern;
        };
        errdefer pcre2_code_free_8(code);
        const jit = pcre2_jit_compile_8(code, JIT_COMPLETE) == 0;
        return .{ .code = code, .jit = jit, .literal = try prefilter(gpa, pattern, ignore_case), .ignore_case = ignore_case, .gpa = gpa };
    }

    pub fn deinit(re: *Regex) void {
        pcre2_code_free_8(re.code);
        re.gpa.free(re.literal);
    }
};

// The literal every match must contain, from regex.zig's parser; "" when
// it can't read the pattern (PCRE2-only syntax such as `(?=`, `\p` or
// `\1`), or when the pattern has a class it reads differently: PCRE2's
// `[[:digit:]]` is a POSIX class and `[]a]` a class with `]`, while
// regex.zig would see other literals there.
fn prefilter(gpa: Allocator, pattern: []const u8, ignore_case: bool) Error![]const u8 {
    if (std.mem.indexOf(u8, pattern, "[:") != null or std.mem.indexOf(u8, pattern, "[]") != null or
        std.mem.indexOf(u8, pattern, "[^]") != null) return gpa.dupe(u8, "");
    var re = own.Regex.compile(gpa, pattern, ignore_case) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return gpa.dupe(u8, ""),
    };
    defer re.deinit();
    return gpa.dupe(u8, re.literal);
}

/// Scratch space for matching. One per thread.
pub const Vm = struct {
    md: *MatchData,
    ctx: *MatchContext,
    stack: ?*JitStack,
    /// A value reached `match_limit` (or the JIT stack's size): whether it
    /// matches is unknown. Set by `isMatch`; the search reports it.
    limit_hit: bool = false,

    pub fn init(_: Allocator, re: *const Regex) !Vm {
        const md = pcre2_match_data_create_from_pattern_8(re.code, null) orelse return error.OutOfMemory;
        errdefer pcre2_match_data_free_8(md);
        const ctx = pcre2_match_context_create_8(null) orelse return error.OutOfMemory;
        errdefer pcre2_match_context_free_8(ctx);
        _ = pcre2_set_match_limit_8(ctx, match_limit);
        // JIT code runs on its own stack: 32 KB, growing up to 1 MB.
        const stack = if (re.jit) pcre2_jit_stack_create_8(32 << 10, 1 << 20, null) orelse return error.OutOfMemory else null;
        if (stack) |s| pcre2_jit_stack_assign_8(ctx, null, s);
        return .{ .md = md, .ctx = ctx, .stack = stack };
    }

    pub fn deinit(vm: *Vm, _: Allocator) void {
        if (vm.stack) |s| pcre2_jit_stack_free_8(s);
        pcre2_match_context_free_8(vm.ctx);
        pcre2_match_data_free_8(vm.md);
    }

    // PCRE2's result for a match in `line` starting at or after `from`:
    // > 0 a match, ERROR_NOMATCH, or another (negative) error.
    fn run(vm: *Vm, re: *const Regex, line: []const u8, from: usize) c_int {
        const f = if (re.jit) &pcre2_jit_match_8 else &pcre2_match_8;
        return f(re.code, line.ptr, line.len, from, 0, vm.md, vm.ctx);
    }

    /// Does `line` (a value) contain a match?
    pub fn isMatch(vm: *Vm, re: *const Regex, line: []const u8) bool {
        const rc = vm.run(re, line, 0);
        if (rc >= 0) return true; // 0: the ovector was too small; still a match
        if (rc != ERROR_NOMATCH) vm.limit_hit = true;
        return false;
    }
};

/// Calls `sink.onValue(row, value)` for each value that contains a match.
/// Values without the required literal never reach PCRE2.
pub fn findValues(re: *const Regex, vm: *Vm, comptime O: type, off: []align(1) const O, data: []const u8, sink: anytype) !void {
    const filter: Filter(@TypeOf(sink)) = .{ .re = re, .vm = vm, .sink = sink };
    if (re.literal.len == 0) {
        if (off.len < 2) return;
        for (0..off.len - 1) |i| try filter.onValue(i, data[@intCast(off[i])..@intCast(off[i + 1])]);
        return;
    }
    if (re.ignore_case) return match.findValues(.insensitive, O, off, data, re.literal, filter);
    return match.findValues(.sensitive, O, off, data, re.literal, filter);
}

/// Does `value` contain a match? The literal prefilter, then PCRE2.
pub fn matches(re: *const Regex, vm: *Vm, value: []const u8) bool {
    if (re.literal.len > 0) {
        const found = if (re.ignore_case) match.contains(.insensitive, value, re.literal) else match.contains(.sensitive, value, re.literal);
        if (!found) return false;
    }
    return vm.isMatch(re, value);
}

fn Filter(comptime Sink: type) type {
    return struct {
        re: *const Regex,
        vm: *Vm,
        sink: Sink,

        pub fn onValue(f: @This(), row: usize, value: []const u8) !void {
            if (f.vm.isMatch(f.re, value)) return f.sink.onValue(row, value);
            if (f.vm.limit_hit) return error.RegexLimit;
        }
    };
}

/// The first match in `line` at or after `from`, as [start, end), for
/// highlighting. PCRE2's match: the leftmost, and at that start the first
/// alternative that matches (not the longest, as in regex.zig).
pub fn span(vm: *Vm, re: *const Regex, line: []const u8, from: usize) ?[2]usize {
    if (from > line.len) return null;
    if (vm.run(re, line, from) <= 0) return null;
    const ov = pcre2_get_ovector_pointer_8(vm.md);
    // A lookbehind or \K can put the start before `from`; never go back.
    if (ov[0] < from or ov[1] < ov[0]) return null;
    return .{ ov[0], ov[1] };
}

const testing = std.testing;

fn isMatch(pattern: []const u8, ignore_case: bool, value: []const u8) !bool {
    var re = try Regex.compile(testing.allocator, pattern, ignore_case);
    defer re.deinit();
    var vm = try Vm.init(testing.allocator, &re);
    defer vm.deinit(testing.allocator);
    return matches(&re, &vm, value);
}

test "PCRE2 matches bytes the way regex.zig does" {
    try testing.expect(try isMatch("a.b", false, "a\nb")); // . is any byte
    try testing.expect(!try isMatch("ab$", false, "ab\n")); // $ only at the end
    try testing.expect(try isMatch("^\\d{3}-\\d{4}$", false, "555-1234"));
    try testing.expect(try isMatch("NEEDLE", true, "a needle"));
    try testing.expect(!try isMatch("\\bneedle\\b", false, "needles"));
    try testing.expect(try isMatch("\xff\\x00?", false, "a\xffb")); // non-UTF bytes
    // PCRE2's own syntax.
    try testing.expect(try isMatch("(?<=user_)\\d+", false, "user_42"));
    try testing.expect(try isMatch("(\\w)\\1", false, "hello"));
    try testing.expect(try isMatch("[[:upper:]]{2}", false, "xAB"));
}

test "the prefilter literal" {
    var re = try Regex.compile(testing.allocator, "PM_[A-Z]+", false);
    defer re.deinit();
    try testing.expectEqualStrings("PM_", re.literal);
    // A POSIX class: regex.zig would take "]" as required.
    var posix = try Regex.compile(testing.allocator, "[[:digit:]]x", false);
    defer posix.deinit();
    try testing.expectEqualStrings("", posix.literal);
    try testing.expect(try isMatch("[[:digit:]]x", false, "7x"));
}

test "a pattern that backtracks without end fails instead of not matching" {
    var re = try Regex.compile(testing.allocator, "(a+)+$", false);
    defer re.deinit();
    var vm = try Vm.init(testing.allocator, &re);
    defer vm.deinit(testing.allocator);
    var value: [41]u8 = @splat('a');
    value[40] = 'b';
    try testing.expect(!vm.isMatch(&re, &value));
    try testing.expect(vm.limit_hit);
}

test "a bad pattern" {
    try testing.expectError(error.BadPattern, Regex.compile(testing.allocator, "(ab", false));
    try testing.expect(std.mem.startsWith(u8, last_error[0..last_error_len], "missing closing parenthesis"));
}
