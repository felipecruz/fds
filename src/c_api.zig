//! C ABI over `search.run`: `fds_search` in include/fds.h. Keep the two in
//! sync; the test at the bottom calls it the way C would.

const std = @import("std");
const build_options = @import("build_options");
const search = @import("search.zig");
const Regex = @import("re.zig").Regex;

const FDS_IGNORE_CASE = 1;
const FDS_REGEX = 2;

const FDS_OK = 0;
const FDS_STOPPED = 1;
const FDS_EARG = -1;
const FDS_EREGEX = -2;
const FDS_EROOT = -3;
const FDS_ENOMEM = -4;

pub const fds_match = extern struct {
    path: [*:0]const u8,
    column: [*:0]const u8,
    row: u64,
    text: [*:0]const u8,
    text_len: usize,
    at: [*:0]const u8,
    at_len: usize,
};

pub const fds_callback = *const fn (ctx: ?*anyopaque, m: *const fds_match) callconv(.c) c_int;

pub export fn fds_search(
    root: ?[*:0]const u8,
    term: ?[*:0]const u8,
    flags: c_uint,
    threads: c_uint,
    cb: ?fds_callback,
    ctx: ?*anyopaque,
) c_int {
    const root_path = std.mem.span(root orelse return FDS_EARG);
    const t = std.mem.span(term orelse return FDS_EARG);
    if (t.len == 0) return FDS_EARG;
    const gpa = std.heap.smp_allocator;
    const ignore_case = flags & FDS_IGNORE_CASE != 0;

    var re: ?Regex = null;
    if (flags & FDS_REGEX != 0) re = Regex.compile(gpa, t, ignore_case) catch |err| return switch (err) {
        error.OutOfMemory => FDS_ENOMEM,
        else => FDS_EREGEX,
    };
    defer if (re) |*r| r.deinit();

    var state: State = .{ .gpa = gpa, .cb = cb orelse return FDS_EARG, .ctx = ctx };
    defer state.buf.deinit(gpa);
    _ = search.run(gpa, .{
        .root_path = root_path,
        .term = t,
        .jobs = if (threads == 0) search.autoJobs() else threads,
        .ignore_case = ignore_case,
        .regex = if (re) |*r| r else null,
    }, .{ .callback = .{ .ctx = &state, .f = State.onHit } }) catch return FDS_EROOT; // the only error left: opening root
    if (state.out_of_memory) return FDS_ENOMEM;
    return if (state.stopped) FDS_STOPPED else FDS_OK;
}

pub export fn fds_version() [*:0]const u8 {
    return std.fmt.comptimePrint("{s}", .{build_options.version}); // NUL-terminated
}

// Turns a `search.Hit` into an `fds_match` with NUL-terminated strings.
// Callbacks are serialized, so one buffer is enough.
const State = struct {
    gpa: std.mem.Allocator,
    cb: fds_callback,
    ctx: ?*anyopaque,
    buf: std.ArrayList(u8) = .empty, // "<path>\0<column>\0<text>\0<at>\0"
    stopped: bool = false,
    out_of_memory: bool = false,

    fn onHit(ptr: ?*anyopaque, hit: search.Hit) bool {
        const s: *State = @ptrCast(@alignCast(ptr));
        s.buf.clearRetainingCapacity();
        for ([_][]const u8{ hit.path, "\x00", hit.column, "\x00", hit.text, "\x00", hit.at, "\x00" }) |part| {
            s.buf.appendSlice(s.gpa, part) catch {
                s.out_of_memory = true;
                return false;
            };
        }
        const column_start = hit.path.len + 1;
        const text_start = column_start + hit.column.len + 1;
        const at_start = text_start + hit.text.len + 1;
        const m: fds_match = .{
            .path = @ptrCast(s.buf.items.ptr),
            .column = @ptrCast(s.buf.items[column_start..].ptr),
            .row = hit.row,
            .text = @ptrCast(s.buf.items[text_start..].ptr),
            .text_len = hit.text.len,
            .at = @ptrCast(s.buf.items[at_start..].ptr),
            .at_len = hit.at.len,
        };
        if (s.cb(s.ctx, &m) != 0) s.stopped = true;
        return !s.stopped;
    }
};

const Rows = struct {
    count: usize = 0,
    stop_after: usize = std.math.maxInt(usize),
    ok: bool = true,

    fn cb(ctx: ?*anyopaque, m: *const fds_match) callconv(.c) c_int {
        const r: *Rows = @ptrCast(@alignCast(ctx));
        r.count += 1;
        r.ok = r.ok and std.mem.eql(u8, std.mem.span(m.path), "testdata/tree/plain.arrow") and
            std.mem.eql(u8, std.mem.span(m.column), "name") and std.mem.eql(u8, std.mem.span(m.at), "name") and m.at_len == 4 and
            std.mem.span(m.text).len == m.text_len;
        return @intFromBool(r.count >= r.stop_after);
    }
};

test "fds_search from C" {
    // Run from the project root by `zig build test`. A file root is
    // searched whatever its name; `name` holds the only "a needle".
    const file = "testdata/tree/plain.arrow";
    var r: Rows = .{};
    try std.testing.expectEqual(FDS_OK, fds_search(file, "a needle", 0, 2, Rows.cb, &r));
    try std.testing.expectEqual(1, r.count);
    try std.testing.expect(r.ok);

    r = .{};
    try std.testing.expectEqual(FDS_OK, fds_search(file, "A NEEDLE", FDS_IGNORE_CASE, 0, Rows.cb, &r));
    try std.testing.expectEqual(1, r.count);

    r = .{};
    try std.testing.expectEqual(FDS_OK, fds_search(file, "^a n[a-z]+ here$", FDS_REGEX, 0, Rows.cb, &r));
    try std.testing.expectEqual(1, r.count);

    // Stop after the first match of a common string.
    r = .{ .stop_after = 1 };
    try std.testing.expectEqual(FDS_STOPPED, fds_search("testdata/tree", "needle", 0, 0, Rows.cb, &r));
    try std.testing.expectEqual(1, r.count);

    try std.testing.expectEqual(FDS_EREGEX, fds_search(file, "a(", FDS_REGEX, 0, Rows.cb, &r));
    try std.testing.expectEqual(FDS_EROOT, fds_search("no/such/dir", "x", 0, 0, Rows.cb, &r));
    try std.testing.expectEqual(FDS_EARG, fds_search(file, "", 0, 0, Rows.cb, &r));
    try std.testing.expectEqual(FDS_EARG, fds_search(null, "x", 0, 0, Rows.cb, &r));
    try std.testing.expectEqual(FDS_EARG, fds_search(file, "x", 0, 0, null, null));
    try std.testing.expectEqualStrings(build_options.version, std.mem.span(fds_version()));
}
