//! Searching files: the thread pool, the walk, and what every format
//! shares. `Searcher` is the visitor passed to `walk.walk`; `run` sets up
//! threads and the walk, and is shared by the CLI and the C API.
//!
//! Each file is mapped (`map.Map`), and its format module turns it into
//! *pieces* of similar size, in output order: `search_arrow.zig` for Arrow
//! IPC files and streams, `search_parquet.zig` for Parquet. Pieces are
//! searched in parallel, so the threads finish together; each records its
//! matches in its own buffer, and the file's matches are reported in order
//! once all are done. A finished piece's part of the file is released.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Map = @import("map.zig").Map;
const match = @import("match.zig");
const parquet = @import("parquet.zig");
const regex = @import("regex.zig");
const search_arrow = @import("search_arrow.zig");
const search_parquet = @import("search_parquet.zig");
const walk = @import("walk.zig");

pub const Options = struct {
    root_path: []const u8,
    /// A literal, or the source of `regex`. Not empty.
    term: []const u8,
    /// Worker threads.
    jobs: usize,
    /// ASCII case-insensitive matching.
    ignore_case: bool = false,
    /// Search for this compiled regex instead of the literal `term`.
    regex: ?*const regex.Regex = null,
    /// Search only these columns: a top-level name, or a full path such as
    /// `user.name`. Empty: every string column.
    columns: []const []const u8 = &.{},
    /// About how many bytes of strings one piece of an Arrow column holds
    /// (see search_arrow.zig). Tests make it small to cut columns finely.
    piece_bytes: usize = 8 << 20,
};

/// The default thread count: the number of performance cores
/// (`hw.perflevel0.logicalcpu`) on Apple silicon, where efficiency cores
/// would hold back the batches given to them; elsewhere, every CPU.
pub fn autoJobs() usize {
    if (builtin.os.tag == .macos) {
        var n: c_int = 0;
        var len: usize = @sizeOf(c_int);
        if (std.c.sysctlbyname("hw.perflevel0.logicalcpu", &n, &len, null, 0) == 0 and n > 0) return @intCast(n);
    }
    return std.Thread.getCpuCount() catch 1;
}

pub const Output = union(enum) {
    /// `<path>:<column>:<row>` lines (`:<value>` too with `content`).
    print: struct { file: Io.File, content: bool = false },
    /// One call per match; see `Callback`.
    callback: Callback,
};

/// Called once per matching (column, row), never concurrently, with the
/// matches of one file in order and files never interleaved. Strings are
/// valid only during the call. Return false to stop the search.
pub const Callback = struct {
    ctx: ?*anyopaque,
    f: *const fn (ctx: ?*anyopaque, hit: Hit) bool,
};

pub const Hit = struct {
    path: []const u8, // "<root>/<relative path>", or the root if it is a file
    column: []const u8, // column path
    row: u64, // 0-based row in the file
    text: []const u8, // the matching value
};

/// The files searched under a directory: Arrow IPC files and streams, and
/// Parquet files. (A root that is a file is searched whatever its name;
/// the format always comes from the file's first bytes.)
pub fn isDataFile(name: []const u8) bool {
    for ([_][]const u8{ ".arrow", ".feather", ".arrows", ".parquet" }) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    }
    return false;
}

/// Searches every data file under `opts.root_path`, or that one file if it
/// is a file (whatever its name).
pub fn run(gpa: std.mem.Allocator, opts: Options, output: Output) !void {
    // The calling thread only starts the root task and then waits in
    // `group.await`, so all searching happens on the `jobs` pool threads.
    var threaded: Io.Threaded = .init(gpa, .{ .async_limit = .limited(opts.jobs) });
    defer threaded.deinit();
    const io = threaded.io();

    var buffer: [64 * 1024]u8 = undefined;
    var file_writer: Io.File.Writer = switch (output) {
        .print => |p| .init(p.file, io, &buffer),
        .callback => undefined,
    };
    var searcher: Searcher = .{ .io = io, .gpa = gpa, .opts = opts, .output = output, .writer = &file_writer.interface };

    if (Io.Dir.cwd().openDir(io, opts.root_path, .{ .iterate = true })) |root| {
        defer root.close(io);
        try walk.walk(io, gpa, root, &searcher);
    } else |err| switch (err) {
        error.NotDir => try searcher.searchFile(.cwd(), opts.root_path, opts.root_path),
        else => return err,
    }
    if (output == .print) try file_writer.interface.flush();
}

pub const Searcher = struct {
    io: Io,
    gpa: std.mem.Allocator,
    opts: Options,
    output: Output,
    writer: *Io.Writer, // with `.print` only
    out_mutex: Io.Mutex = .init,
    stopped: std.atomic.Value(bool) = .init(false), // a callback returned false

    /// Per-directory-task state, reused for every file in the directory.
    pub const Local = struct {
        path: std.ArrayList(u8) = .empty, // "<root>/<relative path>"
    };

    pub fn initLocal(_: *Searcher) !Local {
        return .{};
    }

    pub fn deinitLocal(s: *Searcher, local: *Local) void {
        local.path.deinit(s.gpa);
    }

    pub fn visitFile(s: *Searcher, local: *Local, f: walk.File) !void {
        if (s.stopped.load(.monotonic) or !isDataFile(f.name)) return;
        local.path.clearRetainingCapacity();
        try local.path.print(s.gpa, "{s}/{s}", .{ s.opts.root_path, f.path });
        try s.searchFile(f.dir, f.name, local.path.items);
    }

    /// Searches one file. Files that can't be read or parsed are reported
    /// on stderr and skipped; matches found before the problem are kept.
    pub fn searchFile(s: *Searcher, dir: Io.Dir, name: []const u8, path: []const u8) !void {
        const file = dir.openFile(s.io, name, .{}) catch |err| return warn(path, null, err);
        defer file.close(s.io);
        const map = Map.open(s.io, s.gpa, file) catch |err| return warn(path, null, err);
        defer map.close(s.gpa);
        const format: Format = if (parquet.isParquet(map.bytes)) .parquet else .arrow;
        s.searchMap(path, map, format) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => warn(path, format, err),
        };
    }

    fn searchMap(s: *Searcher, path: []const u8, map: Map, format: Format) !void {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var vm: ?regex.Vm = if (s.opts.regex) |re| try .init(s.gpa, re) else null;
        defer if (vm) |*v| v.deinit(s.gpa);

        var f: FileSearch = .{ .s = s, .path = path, .map = map, .format = format };
        defer for (f.pieces.items) |*p| p.deinit(s.gpa);
        // On an error, the pieces planned before it are still searched.
        const matcher: Matcher = .{ .opts = &s.opts, .vm = if (vm) |*v| v else null };
        const plan_err = switch (format) {
            .arrow => search_arrow.plan(&f, arena, matcher),
            .parquet => search_parquet.plan(&f, arena, matcher),
        };
        if (f.pieces.items.len == 1) {
            s.runPiece(&f, &f.pieces.items[0]);
        } else if (f.pieces.items.len > 1) {
            var group: Io.Group = .init;
            defer group.cancel(s.io);
            for (f.pieces.items) |*p| group.async(s.io, runPieceTask, .{ s, &f, p });
            try group.await(s.io);
        }
        try s.report(&f);
        return plan_err;
    }

    fn runPieceTask(s: *Searcher, f: *const FileSearch, piece: *Piece) Io.Cancelable!void {
        s.runPiece(f, piece);
    }

    fn runPiece(s: *Searcher, f: *const FileSearch, piece: *Piece) void {
        defer switch (piece.job) {
            inline else => |*j| j.finish(f),
        };
        if (s.stopped.load(.monotonic)) return;
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        var vm: ?regex.Vm = if (s.opts.regex) |re| regex.Vm.init(s.gpa, re) catch |err| {
            piece.err = err;
            return;
        } else null;
        defer if (vm) |*v| v.deinit(s.gpa);
        const matcher: Matcher = .{ .opts = &s.opts, .vm = if (vm) |*v| v else null };
        const result = switch (piece.job) {
            inline else => |*j| j.search(scratch.allocator(), f, piece, matcher),
        };
        result catch |err| {
            piece.err = err;
        };
    }

    // Reports a file's matches in one piece so files never interleave.
    fn report(s: *Searcher, f: *FileSearch) !void {
        try s.out_mutex.lock(s.io);
        defer s.out_mutex.unlock(s.io);
        for (f.pieces.items) |*p| {
            switch (s.output) {
                .print => try s.writer.writeAll(p.out.written()),
                .callback => |cb| for (p.hits.items) |h| {
                    if (s.stopped.load(.monotonic)) return;
                    const hit: Hit = .{ .path = f.path, .column = p.column, .row = h.row, .text = p.out.written()[h.start..][0..h.len] };
                    if (!cb.f(cb.ctx, hit)) s.stopped.store(true, .monotonic);
                },
            }
            // A piece that failed: later pieces are not reported.
            if (p.err) |err| return warn(f.path, f.format, err);
        }
    }
};

pub const Format = enum { arrow, parquet };

/// One file being searched.
pub const FileSearch = struct {
    s: *Searcher,
    path: []const u8,
    map: Map,
    format: Format,
    pieces: std.ArrayList(Piece) = .empty, // in output order

    pub fn addPiece(f: *FileSearch, arena: std.mem.Allocator, job: Job, column: []const u8) !void {
        try f.pieces.append(arena, .{ .job = job, .column = column, .out = .init(f.s.gpa) });
    }
};

/// What a piece searches: up to its format.
pub const Job = union(Format) {
    arrow: search_arrow.Job,
    parquet: search_parquet.Job,
};

/// A part of a file to search, and its results.
pub const Piece = struct {
    job: Job,
    column: []const u8, // column path, for output
    out: Io.Writer.Allocating, // `.print` lines, or `.callback` value texts
    hits: std.ArrayList(Collected) = .empty, // with `.callback` only
    err: ?anyerror = null,
    last_row: ?u64 = null,

    /// Records a match. Rows arrive in order; several matches in one row
    /// (list elements) are recorded once.
    pub fn record(p: *Piece, f: *const FileSearch, row: u64, value: []const u8) !void {
        if (p.last_row == row) return;
        p.last_row = row;
        const out = &p.out.writer;
        switch (f.s.output) {
            .print => |o| {
                try out.print("{s}:{s}:{d}", .{ f.path, p.column, row });
                if (o.content) {
                    try out.writeByte(':');
                    try writeEscaped(out, value);
                }
                try out.writeByte('\n');
            },
            .callback => {
                const start = p.out.written().len;
                try out.writeAll(value);
                try p.hits.append(f.s.gpa, .{ .row = row, .start = start, .len = value.len });
            },
        }
    }

    fn deinit(p: *Piece, gpa: std.mem.Allocator) void {
        p.out.deinit();
        p.hits.deinit(gpa);
    }
};

const Collected = struct { row: u64, start: usize, len: usize };

/// Is a column with this top-level name and full path selected by `-c`?
pub fn selected(columns: []const []const u8, top: []const u8, name: []const u8) bool {
    if (columns.len == 0) return true;
    for (columns) |c| {
        if (std.mem.eql(u8, c, top) or std.mem.eql(u8, c, name)) return true;
    }
    return false;
}

/// The search for the term, literal or regex.
pub const Matcher = struct {
    opts: *const Options,
    vm: ?*regex.Vm, // with a regex only

    /// Calls `sink.onValue(i, value)` for each matching value of a string
    /// array given as offsets into back-to-back data.
    pub fn findValues(m: Matcher, comptime O: type, off: []align(1) const O, data: []const u8, sink: anytype) !void {
        if (m.opts.regex) |re| return regex.findValues(re, m.vm.?, O, off, data, sink);
        if (m.opts.ignore_case) return match.findValues(.insensitive, O, off, data, m.opts.term, sink);
        return match.findValues(.sensitive, O, off, data, m.opts.term, sink);
    }

    /// Does one value match?
    pub fn matches(m: Matcher, value: []const u8) bool {
        if (m.opts.regex) |re| return regex.matches(re, m.vm.?, value);
        if (m.opts.ignore_case) return match.contains(.insensitive, value, m.opts.term);
        return match.contains(.sensitive, value, m.opts.term);
    }

    /// Could any value stored somewhere in `bytes` match? False only if the
    /// term (or the regex's required literal) appears nowhere in them, so
    /// a page of values can be skipped without decoding it.
    pub fn mayMatch(m: Matcher, bytes: []const u8) bool {
        const literal = if (m.opts.regex) |re| re.literal else m.opts.term;
        if (literal.len == 0) return true;
        const fold = if (m.opts.regex) |re| re.ignore_case else m.opts.ignore_case;
        return if (fold) match.contains(.insensitive, bytes, literal) else match.contains(.sensitive, bytes, literal);
    }
};

// A value on one output line: newlines and carriage returns as \n and \r.
fn writeEscaped(w: *Io.Writer, value: []const u8) !void {
    var rest = value;
    while (std.mem.indexOfAny(u8, rest, "\n\r")) |i| {
        try w.writeAll(rest[0..i]);
        try w.writeAll(if (rest[i] == '\n') "\\n" else "\\r");
        rest = rest[i + 1 ..];
    }
    try w.writeAll(rest);
}

fn warn(path: []const u8, format: ?Format, err: anyerror) void {
    if (builtin.is_test) return; // `zig build test` fails on stderr output
    const name = if (format) |f| switch (f) {
        .arrow => "Arrow IPC",
        .parquet => "Parquet",
    } else "";
    switch (err) {
        error.Malformed => std.debug.print("fds: {s}: not a valid {s} file\n", .{ path, name }),
        error.Unsupported => std.debug.print("fds: {s}: uses a {s} feature fds does not support\n", .{ path, name }),
        else => std.debug.print("fds: {s}: {t}\n", .{ path, err }),
    }
}

const testing = std.testing;

const CollectHits = struct {
    gpa: std.mem.Allocator,
    hits: std.ArrayList([]const u8) = .empty,

    fn onHit(ctx: ?*anyopaque, hit: Hit) bool {
        const c: *CollectHits = @ptrCast(@alignCast(ctx));
        const line = std.fmt.allocPrint(c.gpa, "{s}:{s}:{d}:{s}", .{ hit.path, hit.column, hit.row, hit.text }) catch return false;
        c.hits.append(c.gpa, line) catch return false;
        return true;
    }

    fn deinit(c: *CollectHits) void {
        for (c.hits.items) |h| c.gpa.free(h);
        c.hits.deinit(c.gpa);
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }
};

fn expectHits(opts: Options, expected: []const []const u8) !void {
    var c: CollectHits = .{ .gpa = testing.allocator };
    defer c.deinit();
    try run(testing.allocator, opts, .{ .callback = .{ .ctx = &c, .f = CollectHits.onHit } });
    std.mem.sort([]const u8, c.hits.items, {}, CollectHits.lessThan);
    try testing.expectEqual(expected.len, c.hits.items.len);
    for (expected, c.hits.items) |e, h| try testing.expectEqualStrings(e, h);
}

// testdata/make.py documents why each of these matches.
const table_hits = [_][]const u8{
    "cat:1:needle",         "cat:4:needle",
    "m[].key:1:needle",     "m[].value:0:needle",
    "name:0:needle",        "name:4:a needle here",
    "note:4:needle\nline",  "pair[]:1:needle",
    "pair[]:5:needle",      "tags[]:0:needle",
    "tags[]:3:needle",      "user.name:0:needle",
    "user.name:4:needles",  "view:1:a long string with needle inside",
    "view:3:needle",
};

test "search the test files" {
    // Plain, LZ4 and zstd files of the same table, a stream with dictionary
    // deltas, a file written by polars, the table as Parquet four ways (and
    // an empty Parquet file); notes.txt is skipped and truncated.arrow is
    // reported.
    var expected: std.ArrayList([]const u8) = .empty;
    defer {
        for (expected.items) |e| testing.allocator.free(e);
        expected.deinit(testing.allocator);
    }
    for ([_][]const u8{ "s:1:needle", "s:4:needle!", "s:5:needle", "s:7:needle-x" }) |h| {
        try expected.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, "testdata/tree/deltas.arrows:{s}", .{h}));
    }
    const polars_hits = [_][]const u8{
        "cat:1:needle",   "name:0:needle", "name:2:a long needle value past twelve bytes",
        "st.inner:2:needle", "tags[]:1:needle",
    };
    for (polars_hits) |h| {
        try expected.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, "testdata/tree/polars.arrow:{s}", .{h}));
    }
    // Parquet: the same table, minus lists and maps (not searched yet).
    for ([_][]const u8{ "snappy", "v2_delta", "plain_gzip", "lz4" }) |file| {
        for (table_hits) |h| {
            if (std.mem.indexOf(u8, h, "[]") != null) continue;
            try expected.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, "testdata/tree/parquet/{s}.parquet:{s}", .{ file, h }));
        }
    }
    for ([_][]const u8{ "plain.arrow", "sub/lz4.feather", "sub/zstd.arrow" }) |file| {
        for (table_hits) |h| try expected.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, "testdata/tree/{s}:{s}", .{ file, h }));
    }
    std.mem.sort([]const u8, expected.items, {}, CollectHits.lessThan);
    // Whole arrays, then pieces of a few rows, then of one row.
    for ([_]usize{ 8 << 20, 64, 1 }) |piece_bytes| {
        try expectHits(.{ .root_path = "testdata/tree", .term = "needle", .jobs = 4, .piece_bytes = piece_bytes }, expected.items);
    }
}

test "search one file: columns, case, regex" {
    const file = "testdata/tree/plain.arrow";
    try expectHits(.{ .root_path = file, .term = "needle", .jobs = 1, .columns = &.{ "note", "user.name" } }, &.{
        file ++ ":note:4:needle\nline",
        file ++ ":user.name:0:needle",
        file ++ ":user.name:4:needles",
    });
    // A top-level name selects everything under it.
    try expectHits(.{ .root_path = file, .term = "needle", .jobs = 1, .columns = &.{"m"} }, &.{
        file ++ ":m[].key:1:needle",
        file ++ ":m[].value:0:needle",
    });
    try expectHits(.{ .root_path = file, .term = "NEEDLE", .jobs = 1, .ignore_case = true, .columns = &.{"note"} }, &.{
        file ++ ":note:1:NEEDLE",
        file ++ ":note:4:needle\nline",
    });
    var re = try regex.Regex.compile(testing.allocator, "^needle.?$", false);
    defer re.deinit();
    try expectHits(.{ .root_path = file, .term = "^needle.?$", .jobs = 2, .regex = &re, .columns = &.{ "tags", "user", "view" } }, &.{
        file ++ ":tags[]:0:needle",
        file ++ ":tags[]:3:needle",
        file ++ ":user.name:0:needle",
        file ++ ":user.name:4:needles",
        file ++ ":view:3:needle",
    });
}
