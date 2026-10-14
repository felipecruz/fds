//! Microbenchmark for `match.findValues` alone: no file system, no Arrow
//! parsing, no output. Usage: bench-match <corpus file> [runs]
//! Loads the corpus into memory and makes each line one string value (a
//! data buffer plus i32 offsets, as in an Arrow `utf8` array), then for
//! each term reports the best of `runs` timings as GB/s, plus the number of
//! matching values. Every term runs twice: case-sensitive, then ignoring case.

const std = @import("std");
const Io = std.Io;
const match = @import("match.zig");

const terms = [_][]const u8{
    "host-4242.example", // rare
    "checkout", // common word
    "zqxjvkwqz", // no match
    "/api/v1/checkout/12345", // long
    "the", // short, common letters: many candidates
    "e", // single byte: matches most values
};

const Count = struct {
    count: *usize,
    pub fn onValue(c: Count, row: usize, value: []const u8) !void {
        _ = row;
        _ = value;
        c.count.* += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: bench-match <corpus file> [runs]\n", .{});
        std.process.exit(2);
    }
    const runs = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 7;
    const corpus = try Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .unlimited);
    defer gpa.free(corpus);

    // Lines become values: the newlines are dropped, as Arrow stores none.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var off: std.ArrayList(i32) = .empty;
    defer off.deinit(gpa);
    try off.append(gpa, 0);
    var it = std.mem.splitScalar(u8, corpus, '\n');
    while (it.next()) |line| {
        try data.appendSlice(gpa, line);
        try off.append(gpa, @intCast(data.items.len));
    }

    std.debug.print("corpus: {d} MB, {d} values, best of {d} runs\n", .{ data.items.len / 1_000_000, off.items.len - 1, runs });
    inline for (.{ match.Case.sensitive, match.Case.insensitive }) |case| {
        std.debug.print("-- case {t}\n", .{case});
        try benchTerms(case, io, off.items, data.items, runs);
    }
}

fn benchTerms(comptime case: match.Case, io: Io, off: []const i32, data: []const u8, runs: usize) !void {
    var total_ns: u64 = 0;
    for (terms) |term| {
        var best: u64 = std.math.maxInt(u64);
        var count: usize = 0;
        for (0..runs) |_| {
            count = 0;
            const start = Io.Timestamp.now(io, .awake);
            try match.findValues(case, i32, off, data, term, Count{ .count = &count });
            const ns: u64 = @intCast(start.untilNow(io, .awake).toNanoseconds());
            best = @min(best, ns);
        }
        total_ns += best;
        const gbps = @as(f64, @floatFromInt(data.len)) / @as(f64, @floatFromInt(best));
        std.debug.print("{s:<28} {d:>8.2} ms  {d:>6.2} GB/s  {d:>9} values\n", .{
            term, @as(f64, @floatFromInt(best)) / 1e6, gbps, count,
        });
    }
    std.debug.print("{s:<28} {d:>8.2} ms\n", .{ "total", @as(f64, @floatFromInt(total_ns)) / 1e6 });
}
