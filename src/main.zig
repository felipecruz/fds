const std = @import("std");
const build_options = @import("build_options");
const search = @import("search.zig");
const Regex = @import("regex.zig").Regex;

// Usage: fds [-j N] [-i] [-E] [-c COLUMN]... [--content] <path> <term>
// Recursively searches every Arrow IPC file (.arrow, .feather, .arrows)
// and Parquet file (.parquet) under <path>, or <path> itself if it is a
// file, and prints `path:column:row` (or `path:column:row:value` with
// --content) for each string value containing <term>. Rows are 0-based.
// `-i` ignores ASCII case. `-E` treats <term> as a regex (see regex.zig).
// `-c` limits the search to some columns. Files come out in no fixed
// order; within a file, by record batch (or row group), column, then row.
//
// Layers:
//   main.zig    command line
//   c_api.zig   the same search as a C library (include/fds.h)
//   walk.zig    parallel recursive directory walk (one task per directory)
//   search.zig  thread pool, pieces, matching, output; per format:
//     search_arrow.zig    Arrow IPC files and streams into pieces
//     search_parquet.zig  Parquet files into pieces (one per column chunk)
//   map.zig     the file's bytes: map, release parts early (linux.zig), close
//   arrow.zig   Arrow IPC messages, schema and buffers (flatbuf.zig)
//   parquet.zig Parquet footer, schema, pages and encodings (thrift.zig)
//   codecs.zig  decompression: LZ4 (lz4.zig), Snappy (snappy.zig), zstd, gzip
//   match.zig   finding the term in a string array (SIMD), no I/O
//   regex.zig   regex: parser, Pike VM, SIMD literal prefilter
//
// `-j N` sets the number of worker threads; `-j 1` is fully serial. The
// default, `-j auto`, is the performance-core count on Apple silicon, else
// the CPU count: see `search.autoJobs`.
//
// std.Io.Evented (Dispatch on macOS) and std.Io.Kqueue do not compile in
// Zig 0.17.0: their vtables are out of sync with std.Io.VTable.
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(arena);
    var jobs: usize = 0; // 0: automatic
    var content = false;
    var ignore_case = false;
    var use_regex = false;
    var columns: std.ArrayList([]const u8) = .empty;
    var pos_args = args[1..];
    while (pos_args.len > 0 and std.mem.startsWith(u8, pos_args[0], "-")) {
        const flag = pos_args[0];
        pos_args = pos_args[1..];
        if (std.mem.eql(u8, flag, "--version") or std.mem.eql(u8, flag, "-V")) {
            std.debug.print("fds {s}\n", .{build_options.version});
            std.process.exit(0);
        } else if (std.mem.eql(u8, flag, "--content")) {
            content = true;
        } else if (std.mem.eql(u8, flag, "-i") or std.mem.eql(u8, flag, "--ignore-case")) {
            ignore_case = true;
        } else if (std.mem.eql(u8, flag, "-E") or std.mem.eql(u8, flag, "--regex")) {
            use_regex = true;
        } else if (std.mem.eql(u8, flag, "-c") or std.mem.eql(u8, flag, "--column")) {
            if (pos_args.len == 0) usage();
            try columns.append(arena, pos_args[0]);
            pos_args = pos_args[1..];
        } else if (std.mem.startsWith(u8, flag, "-j")) {
            var value: []const u8 = flag[2..];
            if (value.len == 0) {
                if (pos_args.len == 0) usage();
                value = pos_args[0];
                pos_args = pos_args[1..];
            }
            if (std.mem.eql(u8, value, "auto")) {
                jobs = 0;
            } else {
                jobs = std.fmt.parseInt(usize, value, 10) catch usage();
                if (jobs == 0) usage();
            }
        } else usage();
    }
    if (pos_args.len != 2 or pos_args[1].len == 0) usage();
    const root_path = pos_args[0];
    const term = pos_args[1];

    var re: ?Regex = null;
    if (use_regex) re = Regex.compile(gpa, term, ignore_case) catch |err| {
        std.debug.print("fds: invalid regex: {t}\n", .{err});
        std.process.exit(2);
    };
    defer if (re) |*r| r.deinit();

    search.run(gpa, .{
        .root_path = root_path,
        .term = term,
        .jobs = if (jobs == 0) search.autoJobs() else jobs,
        .ignore_case = ignore_case,
        .regex = if (re) |*r| r else null,
        .columns = columns.items,
    }, .{ .print = .{ .file = .stdout(), .content = content } }) catch |err| {
        std.debug.print("fds: {s}: {t}\n", .{ root_path, err });
        std.process.exit(2);
    };
}

fn usage() noreturn {
    std.debug.print(
        \\usage: fds [-j N|auto] [-i] [-E] [-c COLUMN]... [--content] <path> <term>
        \\  Searches the string values of every .arrow, .feather, .arrows and
        \\  .parquet file under <path> (or the file <path>), printing
        \\  <path>:<column>:<row>.
        \\  -j N|auto          worker threads (default: auto = {d} here, the
        \\                     performance-core count on Apple silicon, else all CPUs)
        \\  -i, --ignore-case  match ASCII letters regardless of case
        \\  -E, --regex        <term> is a regular expression (see src/regex.zig)
        \\  -c, --column NAME  search only this column (a top-level name or a
        \\                     path like user.name or tags[]); repeatable
        \\  --content          also print the value: <path>:<column>:<row>:<value>
        \\                     (newlines in it as \n)
        \\  -V, --version      print the version
        \\
    , .{search.autoJobs()});
    std.process.exit(2);
}

test {
    _ = @import("arrow.zig");
    _ = @import("c_api.zig");
    _ = @import("flatbuf.zig");
    _ = @import("lz4.zig");
    _ = @import("map.zig");
    _ = @import("codecs.zig");
    _ = @import("parquet.zig");
    _ = @import("snappy.zig");
    _ = @import("thrift.zig");
    _ = @import("zstd.zig");
    _ = @import("match.zig");
    _ = @import("regex.zig");
    _ = @import("search.zig");
    _ = @import("walk.zig");
}
