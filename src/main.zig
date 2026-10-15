const std = @import("std");
const build_options = @import("build_options");
const search = @import("search.zig");
const pattern = @import("pattern.zig");
const re_engine = @import("re.zig");
const Regex = re_engine.Regex;

// Usage: fds [options] <path> <term>, or fds [options] -e <term>... <path>
// (see `usage` for the options)
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
    var print: search.Print = .{ .file = .stdout() };
    var color: enum { auto, always, never } = .auto;
    var flags: pattern.Flags = .{};
    var max_count: ?u64 = null;
    var terms: std.ArrayList([]const u8) = .empty; // from -e
    var columns: std.ArrayList([]const u8) = .empty;
    var pos: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) { // the rest are operands
            try pos.appendSlice(arena, args[i + 1 ..]);
            break;
        }
        if (a.len < 2 or a[0] != '-') {
            try pos.append(arena, a);
            continue;
        }
        if (eql(a, "-V", "--version")) {
            std.debug.print("fds {s}{s}\n", .{ build_options.version, if (re_engine.pcre2) " (regex: PCRE2)" else "" });
            std.process.exit(0);
        } else if (eql(a, "-h", "--help")) {
            usage(0);
        } else if (eql(a, "--content", null)) {
            print.content = true;
        } else if (eql(a, "-i", "--ignore-case")) {
            flags.ignore_case = true;
        } else if (eql(a, "-S", "--smart-case")) {
            flags.smart_case = true;
        } else if (eql(a, "-E", "--regex")) {
            flags.regex = true;
        } else if (eql(a, "-w", "--word")) {
            flags.word = true;
        } else if (eql(a, "-l", "--files-with-matches")) {
            print.mode = .files_with_matches;
        } else if (eql(a, "--count", null)) {
            print.mode = .count;
        } else if (eql(a, "--json", null)) {
            print.json = true;
        } else if (eql(a, "-e", "--regexp")) {
            try terms.append(arena, value(args, &i));
        } else if (eql(a, "-c", "--column")) {
            try columns.append(arena, value(args, &i));
        } else if (eql(a, "-m", "--max-count")) {
            max_count = std.fmt.parseInt(u64, value(args, &i), 10) catch usage(2);
        } else if (std.mem.startsWith(u8, a, "--color")) {
            const v = if (std.mem.startsWith(u8, a, "--color=")) a["--color=".len..] else value(args, &i);
            color = std.meta.stringToEnum(@TypeOf(color), v) orelse usage(2);
        } else if (std.mem.startsWith(u8, a, "-j")) {
            const v = if (a.len > 2) a[2..] else value(args, &i);
            jobs = if (std.mem.eql(u8, v, "auto")) 0 else std.fmt.parseInt(usize, v, 10) catch usage(2);
            if (jobs == 0 and !std.mem.eql(u8, v, "auto")) usage(2);
        } else usage(2);
    }

    // `fds <path> <term>`, or `fds -e <term>... <path>`.
    if (terms.items.len == 0) {
        if (pos.items.len != 2) usage(2);
        try terms.append(arena, pos.items[1]);
    } else if (pos.items.len != 1) usage(2);
    const root_path = pos.items[0];
    for (terms.items) |t| if (t.len == 0) usage(2);

    print.color = switch (color) {
        .always => true,
        .never => false,
        // A terminal, unless NO_COLOR is set (https://no-color.org) or
        // TERM says it can't.
        .auto => !print.json and (print.file.isTty(init.io) catch false) and
            init.environ_map.get("NO_COLOR") == null and
            !std.mem.eql(u8, init.environ_map.get("TERM") orelse "", "dumb"),
    };

    const p = try pattern.build(arena, terms.items, flags);
    var re: ?Regex = null;
    if (p.regex) re = Regex.compile(gpa, p.source, p.ignore_case) catch |err| {
        if (re_engine.lastError()) |msg| {
            std.debug.print("fds: invalid regex: {s}\n", .{msg});
        } else std.debug.print("fds: invalid regex: {t}\n", .{err});
        std.process.exit(2);
    };
    defer if (re) |*r| r.deinit();

    const summary = search.run(gpa, .{
        .root_path = root_path,
        .term = p.source,
        .terms = if (p.literals.len > 1) p.literals else &.{},
        .jobs = if (jobs == 0) search.autoJobs() else jobs,
        .ignore_case = p.ignore_case,
        .regex = if (re) |*r| r else null,
        .columns = columns.items,
        .max_count = max_count,
    }, .{ .print = print }) catch |err| {
        std.debug.print("fds: {s}: {t}\n", .{ root_path, err });
        std.process.exit(2);
    };
    // As grep: 0 if something matched, 1 if nothing did, 2 on any error.
    std.process.exit(if (summary.errors) 2 else if (summary.matched) 0 else 1);
}

fn eql(a: []const u8, short: []const u8, long: ?[]const u8) bool {
    return std.mem.eql(u8, a, short) or (long != null and std.mem.eql(u8, a, long.?));
}

// The value of the option at args[i.*], which is the next argument.
fn value(args: []const [:0]const u8, i: *usize) []const u8 {
    i.* += 1;
    if (i.* >= args.len) usage(2);
    return args[i.*];
}

fn usage(status: u8) noreturn {
    std.debug.print(
        \\usage: fds [options] <path> <term>
        \\       fds [options] -e <term> [-e <term>]... <path>
        \\  Searches the string values of every .arrow, .feather, .arrows and
        \\  .parquet file under <path> (or the file <path>), printing
        \\  <path>:<column>:<row> for each match.
        \\
        \\matching:
        \\  -i, --ignore-case    match ASCII letters regardless of case
        \\  -S, --smart-case     ignore case unless a term has an upper-case letter
        \\  -E, --regex          terms are regular expressions (see src/regex.zig)
        \\  -w, --word           match whole words only
        \\  -e, --regexp TERM    a term to search for; repeat for any of several
        \\  -c, --column NAME    search only this column (a top-level name or a
        \\                       path like user.name or tags[]); repeatable
        \\output:
        \\  --content            also print the value: <path>:<column>:<row>:<value>
        \\                       (newlines in it as \n)
        \\  -l, --files-with-matches   print only the files that match
        \\  --count              print <path>:<column>:<count> per matching column
        \\  -m, --max-count N    stop after N matches in each file
        \\  --json               JSON Lines: {{"path","column","row","value"}}
        \\  --color WHEN         auto (a terminal; default), always or never
        \\other:
        \\  -j N|auto            worker threads (default: auto = {d} here, the
        \\                       performance-core count on Apple silicon, else all CPUs)
        \\  -V, --version        print the version
        \\
        \\Exit status: 0 if something matched, 1 if nothing did, 2 on an error.
        \\
    , .{search.autoJobs()});
    std.process.exit(status);
}

test {
    _ = @import("arrow.zig");
    _ = @import("c_api.zig");
    _ = @import("flatbuf.zig");
    _ = @import("lz4.zig");
    _ = @import("map.zig");
    _ = @import("codecs.zig");
    _ = @import("parquet.zig");
    _ = @import("pattern.zig");
    _ = @import("snappy.zig");
    _ = @import("thrift.zig");
    _ = @import("zstd.zig");
    _ = @import("match.zig");
    _ = @import("regex.zig");
    _ = @import("re.zig");
    if (re_engine.pcre2) _ = @import("pcre2.zig");
    _ = @import("search.zig");
    _ = @import("walk.zig");
}
