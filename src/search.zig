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
const multi = @import("multi.zig");
const pattern = @import("pattern.zig");
const parquet = @import("parquet.zig");
const regex = @import("re.zig");
const search_arrow = @import("search_arrow.zig");
const search_parquet = @import("search_parquet.zig");
const walk = @import("walk.zig");

pub const Options = struct {
    root_path: []const u8,
    /// A literal, or the source of `regex`. Not empty.
    term: []const u8,
    /// With no regex: several literals, any of which may match (`-e`). If
    /// empty, just `term`. From `pattern.many` of them on, they are
    /// searched together, with an Aho-Corasick automaton (multi.zig).
    terms: []const []const u8 = &.{},
    /// With `terms`: each must match as a whole word (`-w`, many terms).
    word: bool = false,
    /// Worker threads.
    jobs: usize,
    /// ASCII case-insensitive matching.
    ignore_case: bool = false,
    /// Search for this compiled regex instead of the literal `term`.
    regex: ?*const regex.Regex = null,
    /// Search only these columns: a top-level name, or a full path such as
    /// `user.name`. Empty: every string column.
    columns: []const []const u8 = &.{},
    /// Stop after this many matches in each file (`-m`).
    max_count: ?u64 = null,
    /// About how many bytes of strings one piece of an Arrow column holds
    /// (see search_arrow.zig). Tests make it small to cut columns finely.
    piece_bytes: usize = 8 << 20,
    /// The automaton for `terms`, built by `run`.
    set: ?*const multi.Set = null,
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
    /// Printed to a file (stdout); see `Print`.
    print: Print,
    /// One call per match; see `Callback`.
    callback: Callback,
};

pub const Print = struct {
    file: Io.File,
    mode: Mode = .matches,
    /// With `.matches`: add the value, `<path>:<column>:<row>:<value>`.
    content: bool = false,
    /// JSON Lines instead of `:`-separated text.
    json: bool = false,
    /// ANSI colors, and matches highlighted in values.
    color: bool = false,
};

pub const Mode = enum {
    /// One line per match: `<path>:<column>:<row>`.
    matches,
    /// One line per file with a match: `<path>` (`-l`).
    files_with_matches,
    /// One line per column with matches: `<path>:<column>:<count>`.
    count,
};

/// What a search found, for the exit status.
pub const Summary = struct {
    matched: bool,
    /// A file could not be opened or read, or was malformed.
    errors: bool,
};

/// Called once per matching value, never concurrently, with the
/// matches of one file in order and files never interleaved. Strings are
/// valid only during the call. Return false to stop the search.
pub const Callback = struct {
    ctx: ?*anyopaque,
    f: *const fn (ctx: ?*anyopaque, hit: Hit) bool,
};

pub const Hit = struct {
    path: []const u8, // "<root>/<relative path>", or the root if it is a file
    column: []const u8, // column path: "tags[]", "m[].value"
    at: []const u8, // the value's place in its row: "tags[1]", "m[key]"; = column at the top level
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
pub fn run(gpa: std.mem.Allocator, options: Options, output: Output) !Summary {
    var opts = options;
    var set: ?multi.Set = null;
    defer if (set) |*st| st.deinit();
    if (opts.regex == null and (opts.terms.len >= pattern.many or opts.word)) {
        set = try .init(gpa, if (opts.terms.len > 0) opts.terms else (&opts.term)[0..1], .{ .ignore_case = opts.ignore_case, .word = opts.word });
        opts.set = &set.?;
    }

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
    if (output == .print) file_writer.interface.flush() catch {
        searcher.write_failed.store(true, .monotonic);
    };
    // The output closed early (`fds ... | head`): quietly done, as grep.
    // Any other write error (a full disk) is the search's error.
    if (searcher.write_failed.load(.monotonic)) {
        const err = file_writer.err orelse error.WriteFailed;
        if (err != error.BrokenPipe) return err;
    }
    return .{ .matched = searcher.matched.load(.monotonic), .errors = searcher.errors.load(.monotonic) };
}

pub const Searcher = struct {
    io: Io,
    gpa: std.mem.Allocator,
    opts: Options,
    output: Output,
    writer: *Io.Writer, // with `.print` only
    out_mutex: Io.Mutex = .init,
    stopped: std.atomic.Value(bool) = .init(false), // a callback returned false
    matched: std.atomic.Value(bool) = .init(false),
    errors: std.atomic.Value(bool) = .init(false),
    write_failed: std.atomic.Value(bool) = .init(false), // the output; stops the search

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
        const file = openRegular(s.io, dir, name) catch |err| return s.warn(path, null, err);
        defer file.close(s.io);
        const map = Map.open(s.io, s.gpa, file) catch |err| return s.warn(path, null, err);
        defer map.close(s.gpa);
        const format: Format = if (parquet.isParquet(map.bytes)) .parquet else .arrow;
        s.searchMap(path, map, format) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // Writing the output failed: no use searching on (see `run`).
            // Only matches are written, so something matched.
            error.WriteFailed => {
                s.matched.store(true, .monotonic);
                s.write_failed.store(true, .monotonic);
                s.stopped.store(true, .monotonic);
            },
            else => s.warn(path, format, err),
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
        const matcher: Matcher = .{ .opts = &s.opts, .vm = if (vm) |*v| v else null, .arena = arena };
        var plan_err: anyerror!void = switch (format) {
            .arrow => search_arrow.plan(&f, arena, matcher),
            .parquet => search_parquet.plan(&f, arena, matcher),
        };
        // A dictionary entry whose result is unknown may have skipped a page.
        if (vm) |*v| if (regex.limitHit(v)) {
            plan_err = error.RegexLimit;
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
        // -l: once any piece of the file matched, the rest needn't run.
        if (s.mode() == .files_with_matches and f.found.load(.monotonic)) return;
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        var vm: ?regex.Vm = if (s.opts.regex) |re| regex.Vm.init(s.gpa, re) catch |err| {
            piece.err = err;
            return;
        } else null;
        defer if (vm) |*v| v.deinit(s.gpa);
        const matcher: Matcher = .{ .opts = &s.opts, .vm = if (vm) |*v| v else null, .arena = scratch.allocator() };
        const result = switch (piece.job) {
            inline else => |*j| j.search(scratch.allocator(), f, piece, matcher),
        };
        result catch |err| switch (err) {
            error.Enough => {}, // the piece found all the matches it may report
            else => piece.err = err,
        };
        // PCRE2 gave up on a value: whether it matched is unknown.
        if (vm) |*v| if (piece.err == null and regex.limitHit(v)) {
            piece.err = error.RegexLimit;
        };
    }

    // Reports a file's matches in one piece so files never interleave.
    // Pieces are reported in order, so `-m` keeps the file's first matches.
    fn report(s: *Searcher, f: *FileSearch) !void {
        try s.out_mutex.lock(s.io);
        defer s.out_mutex.unlock(s.io);
        var left: u64 = s.opts.max_count orelse std.math.maxInt(u64);
        var counts: std.ArrayList(struct { column: []const u8, n: u64 }) = .empty;
        defer counts.deinit(s.gpa);
        var any = false;
        for (f.pieces.items) |*p| {
            const n = @min(p.count, left);
            left -= n;
            any = any or n > 0;
            switch (s.output) {
                .print => |o| switch (o.mode) {
                    .matches => try s.writer.writeAll(firstLines(p.out.written(), n)),
                    .count => {
                        // Columns in schema order: the order of the pieces.
                        for (counts.items) |*c| {
                            if (std.mem.eql(u8, c.column, p.column)) {
                                c.n += n;
                                break;
                            }
                        } else try counts.append(s.gpa, .{ .column = p.column, .n = n });
                    },
                    .files_with_matches => {},
                },
                .callback => |cb| for (p.hits.items[0..@min(n, p.hits.items.len)]) |h| {
                    if (s.stopped.load(.monotonic)) return;
                    const out = p.out.written();
                    const hit: Hit = .{ .path = f.path, .column = p.column, .at = out[h.at_start..][0..h.at_len], .row = h.row, .text = out[h.start..][0..h.len] };
                    if (!cb.f(cb.ctx, hit)) s.stopped.store(true, .monotonic);
                },
            }
            // A piece that failed: later pieces are not reported.
            if (p.err) |err| {
                s.warn(f.path, f.format, err);
                break;
            }
        }
        if (any) s.matched.store(true, .monotonic);
        if (s.output != .print) return;
        const o = s.output.print;
        const w = s.writer;
        switch (o.mode) {
            .matches => {},
            .files_with_matches => if (any) {
                if (o.json) {
                    try w.writeAll("{");
                    try writeJsonField(w, "path", f.path);
                    try w.writeAll("}\n");
                } else {
                    try w.print("{s}{f}{s}\n", .{ color(o, .path), esc(f.path), color(o, .reset) });
                }
            },
            .count => for (counts.items) |c| {
                if (c.n == 0) continue;
                if (o.json) {
                    try w.writeAll("{");
                    try writeJsonField(w, "path", f.path);
                    try w.writeAll(",");
                    try writeJsonField(w, "column", c.column);
                    try w.print(",\"count\":{d}}}\n", .{c.n});
                } else {
                    try w.print("{s}{f}{s}:{s}{f}{s}:{d}\n", .{ color(o, .path), esc(f.path), color(o, .reset), color(o, .column), esc(c.column), color(o, .reset), c.n });
                }
            },
        }
    }

    fn mode(s: *const Searcher) Mode {
        return if (s.output == .print) s.output.print.mode else .matches;
    }

    /// Reports strings in a file that fds can't search, on stderr. The
    /// search is not complete, so it counts as an error for the exit
    /// status, as an unreadable file does.
    pub fn notSearched(s: *Searcher, path: []const u8, column: []const u8, why: []const u8) void {
        s.errors.store(true, .monotonic);
        if (builtin.is_test) return;
        std.debug.print("fds: {f}: column {f} not searched ({s})\n", .{ esc(path), esc(column), why });
    }

    /// Reports a file that can't be searched, on stderr.
    fn warn(s: *Searcher, path: []const u8, format: ?Format, err: anyerror) void {
        s.errors.store(true, .monotonic);
        if (builtin.is_test) return; // `zig build test` fails on stderr output
        const name = if (format) |fm| switch (fm) {
            .arrow => "Arrow IPC",
            .parquet => "Parquet",
        } else "";
        switch (err) {
            error.Malformed => std.debug.print("fds: {f}: not a valid {s} file\n", .{ esc(path), name }),
            error.Unsupported => std.debug.print("fds: {f}: uses a {s} feature fds does not support\n", .{ esc(path), name }),
            error.NotRegularFile => std.debug.print("fds: {f}: not a regular file\n", .{esc(path)}),
            else => std.debug.print("fds: {f}: {t}\n", .{ esc(path), err }),
        }
    }
};

// The first `n` lines of `text` (each match's output is one line).
fn firstLines(text: []const u8, n: u64) []const u8 {
    var end: usize = 0;
    var k: u64 = 0;
    while (k < n) : (k += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, end, '\n') orelse return text;
        end = nl + 1;
    }
    return text[0..end];
}

pub const Format = enum { arrow, parquet };

/// One file being searched.
pub const FileSearch = struct {
    s: *Searcher,
    path: []const u8,
    map: Map,
    format: Format,
    pieces: std.ArrayList(Piece) = .empty, // in output order
    found: std.atomic.Value(bool) = .init(false), // some piece matched (for -l)

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
    count: u64 = 0, // matches recorded: values, or rows with --count

    /// Records a match: `value`, at `at` in `row` (see `Hit.at`). Rows
    /// arrive in order; a row's several matching values (list elements)
    /// are each a match, except for --count, which counts rows. Returns
    /// error.Enough when the piece has recorded all it could ever report,
    /// which stops its search.
    pub fn record(p: *Piece, f: *const FileSearch, matcher: Matcher, row: u64, at: []const u8, value: []const u8) !void {
        const s = f.s;
        const same_row = p.last_row == row;
        p.last_row = row;
        if (same_row and s.mode() == .count) return;
        switch (s.output) {
            .print => |o| switch (o.mode) {
                .matches => {
                    const out = &p.out.writer;
                    if (o.json) {
                        try out.writeAll("{");
                        try writeJsonField(out, "path", f.path);
                        try out.writeAll(",");
                        try writeJsonField(out, "column", p.column);
                        try out.writeAll(",");
                        try writeJsonField(out, "at", at);
                        try out.print(",\"row\":{d},", .{row});
                        try writeJsonField(out, "value", value);
                        try out.writeAll("}\n");
                    } else {
                        try out.print("{s}{f}{s}:{s}{f}{s}:{s}{d}{s}", .{
                            color(o, .path),   esc(f.path), color(o, .reset),
                            color(o, .column), esc(at),     color(o, .reset),
                            color(o, .row),    row,         color(o, .reset),
                        });
                        if (o.content) {
                            try out.writeByte(':');
                            try writeContent(out, value, matcher, o.color);
                        }
                        try out.writeByte('\n');
                    }
                },
                .count => {},
                .files_with_matches => {
                    p.count += 1;
                    @constCast(f).found.store(true, .monotonic);
                    return error.Enough; // one match is all -l needs
                },
            },
            .callback => {
                const at_start = p.out.written().len;
                try p.out.writer.writeAll(at);
                try p.out.writer.writeAll(value);
                try p.hits.append(s.gpa, .{ .row = row, .at_start = at_start, .at_len = at.len, .start = at_start + at.len, .len = value.len });
            },
        }
        // Counted once stored: `report` takes `count` matches, and one that
        // couldn't be stored (out of memory) mustn't be among them.
        p.count += 1;
        if (s.opts.max_count) |max| if (p.count >= max) return error.Enough;
    }

    fn deinit(p: *Piece, gpa: std.mem.Allocator) void {
        p.out.deinit();
        p.hits.deinit(gpa);
    }
};

const Collected = struct { row: u64, at_start: usize, at_len: usize, start: usize, len: usize };

/// A map key in a value's place (`m[key]`), escaped so the place stays one
/// unambiguous, printable line: `\` `]` and line breaks as `\\`, `\]`,
/// `\n`, `\r`, and other control bytes as `\xNN`.
pub fn writeKey(arena: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8) !void {
    for (key) |c| switch (c) {
        '\\' => try out.appendSlice(arena, "\\\\"),
        ']' => try out.appendSlice(arena, "\\]"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        0...9, 11, 12, 14...0x1f, 0x7f => try out.print(arena, "\\x{x:0>2}", .{c}),
        else => try out.append(arena, c),
    };
}

/// Is a column with this top-level name and full path selected by `-c`?
pub fn selected(columns: []const []const u8, top: []const u8, name: []const u8) bool {
    if (columns.len == 0) return true;
    for (columns) |c| {
        if (std.mem.eql(u8, c, top) or std.mem.eql(u8, c, name)) return true;
    }
    return false;
}

/// Opens a regular file to read. Anything else (a FIFO, a device) is
/// error.NotRegularFile: opening is non-blocking, so a FIFO put in a file's
/// place after the directory was listed can't hang the search.
fn openRegular(io: Io, dir: Io.Dir, name: []const u8) !Io.File {
    if (builtin.os.tag == .windows) return dir.openFile(io, name, .{});
    const fd = try std.posix.openat(dir.handle, name, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
    const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    errdefer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.NotRegularFile;
    return file;
}

/// The search for the term, literal or regex.
pub const Matcher = struct {
    opts: *const Options,
    vm: ?*regex.Vm, // with a regex only
    arena: ?std.mem.Allocator = null, // for several literals

    /// Calls `sink.onValue(i, value)` for each matching value of a string
    /// array given as offsets into back-to-back data, in order.
    pub fn findValues(m: Matcher, comptime O: type, off: []align(1) const O, data: []const u8, sink: anytype) !void {
        if (m.opts.regex) |re| return regex.findValues(re, m.vm.?, O, off, data, sink);
        if (m.opts.set) |set| return set.findValues(O, off, data, sink);
        const terms = m.literals();
        if (terms.len == 1) {
            if (m.opts.ignore_case) return match.findValues(.insensitive, O, off, data, terms[0], sink);
            return match.findValues(.sensitive, O, off, data, terms[0], sink);
        }
        // Several literals: one SIMD pass per term marks the matching
        // values, then they go to the sink once each, in order.
        if (off.len < 2) return;
        var hit = try std.DynamicBitSetUnmanaged.initEmpty(m.arena.?, off.len - 1);
        for (terms) |t| {
            const mark: Mark = .{ .bits = &hit };
            if (m.opts.ignore_case) try match.findValues(.insensitive, O, off, data, t, mark) else try match.findValues(.sensitive, O, off, data, t, mark);
        }
        var it = hit.iterator(.{});
        while (it.next()) |i| try sink.onValue(i, data[@intCast(off[i])..@intCast(off[i + 1])]);
    }

    const Mark = struct {
        bits: *std.DynamicBitSetUnmanaged,
        pub fn onValue(k: Mark, i: usize, _: []const u8) !void {
            k.bits.set(i);
        }
    };

    fn literals(m: Matcher) []const []const u8 {
        return if (m.opts.terms.len > 0) m.opts.terms else (&m.opts.term)[0..1];
    }

    /// Does one value match?
    pub fn matches(m: Matcher, value: []const u8) bool {
        if (m.opts.regex) |re| return regex.matches(re, m.vm.?, value);
        if (m.opts.set) |set| return set.matches(value);
        for (m.literals()) |t| {
            if (if (m.opts.ignore_case) match.contains(.insensitive, value, t) else match.contains(.sensitive, value, t)) return true;
        }
        return false;
    }

    /// The next match in `value` at or after `from`, as [start, end), for
    /// highlighting.
    pub fn span(m: Matcher, value: []const u8, from: usize) ?[2]usize {
        if (m.opts.regex) |re| return regex.span(m.vm.?, re, value, from);
        if (m.opts.set) |set| return set.span(value, from);
        // The earliest occurrence of any literal; the longest one there.
        var best: ?[2]usize = null;
        for (m.literals()) |t| {
            const at = (if (m.opts.ignore_case) match.indexOf(.insensitive, value, t, from) else match.indexOf(.sensitive, value, t, from)) orelse continue;
            if (best == null or at < best.?[0] or (at == best.?[0] and at + t.len > best.?[1])) best = .{ at, at + t.len };
        }
        return best;
    }

    /// Could any value stored somewhere in `bytes` match? False only if the
    /// term (or the regex's required literal) appears nowhere in them, so
    /// a page of values can be skipped without decoding it.
    pub fn mayMatch(m: Matcher, bytes: []const u8) bool {
        if (m.opts.regex) |re| {
            if (re.literal.len == 0) return true;
            return if (re.ignore_case) match.contains(.insensitive, bytes, re.literal) else match.contains(.sensitive, bytes, re.literal);
        }
        if (m.opts.set) |set| return set.mayMatch(bytes);
        return m.matches(bytes); // any literal anywhere in the bytes
    }
};

const Color = enum { path, column, row, match, reset };

// ANSI colors, as ripgrep uses them: paths magenta, positions green,
// matches bold red; columns cyan.
fn color(o: Print, c: Color) []const u8 {
    if (!o.color) return "";
    return switch (c) {
        .path => "\x1b[35m",
        .column => "\x1b[36m",
        .row => "\x1b[32m",
        .match => "\x1b[1;31m",
        .reset => "\x1b[0m",
    };
}

// The value of a `--content` line, its matches highlighted with color.
// Values over 1 MB are printed plain: finding regex spans is not linear.
fn writeContent(w: *Io.Writer, value: []const u8, matcher: Matcher, colored: bool) !void {
    if (!colored or value.len > 1 << 20) return writeEscaped(w, value);
    var at: usize = 0;
    while (matcher.span(value, at)) |sp| {
        try writeEscaped(w, value[at..sp[0]]);
        if (sp[1] == sp[0]) { // an empty match: nothing to color
            if (sp[0] == value.len) break;
            try writeEscaped(w, value[sp[0] .. sp[0] + 1]);
            at = sp[0] + 1;
            continue;
        }
        try w.writeAll("\x1b[1;31m");
        try writeEscaped(w, value[sp[0]..sp[1]]);
        try w.writeAll("\x1b[0m");
        at = sp[1];
    }
    try writeEscaped(w, value[at..]);
}

// `"key":"value"`, or `"key_base64":"..."` when the bytes are not UTF-8
// (JSON strings can't hold arbitrary bytes), as ripgrep does.
fn writeJsonField(w: *Io.Writer, key: []const u8, bytes: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        try w.print("\"{s}_base64\":\"", .{key});
        try std.base64.standard.Encoder.encodeWriter(w, bytes);
        return w.writeByte('"');
    }
    try w.print("\"{s}\":\"", .{key});
    for (bytes) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

// Text from a file (a value, a column name, a path) on one output line,
// harmless to a terminal: newlines and carriage returns as \n and \r, and
// other control bytes (escape sequences start with ESC) as \xNN. Tabs stay.
fn writeEscaped(w: *Io.Writer, value: []const u8) !void {
    var start: usize = 0;
    for (value, 0..) |c, i| {
        if (c >= 0x20 and c != 0x7f or c == '\t') continue;
        try w.writeAll(value[start..i]);
        switch (c) {
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            else => try w.print("\\x{x:0>2}", .{c}),
        }
        start = i + 1;
    }
    try w.writeAll(value[start..]);
}

const Escaped = struct {
    bytes: []const u8,
    pub fn format(e: Escaped, w: *Io.Writer) Io.Writer.Error!void {
        return writeEscaped(w, e.bytes);
    }
};

/// For `{f}`: `bytes` as `writeEscaped` prints them.
fn esc(bytes: []const u8) Escaped {
    return .{ .bytes = bytes };
}

const testing = std.testing;

const CollectHits = struct {
    gpa: std.mem.Allocator,
    hits: std.ArrayList([]const u8) = .empty,

    fn onHit(ctx: ?*anyopaque, hit: Hit) bool {
        const c: *CollectHits = @ptrCast(@alignCast(ctx));
        const line = std.fmt.allocPrint(c.gpa, "{s}:{s}:{d}:{s}", .{ hit.path, hit.at, hit.row, hit.text }) catch return false;
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
    _ = try run(testing.allocator, opts, .{ .callback = .{ .ctx = &c, .f = CollectHits.onHit } });
    std.mem.sort([]const u8, c.hits.items, {}, CollectHits.lessThan);
    try testing.expectEqual(expected.len, c.hits.items.len);
    for (expected, c.hits.items) |e, h| try testing.expectEqualStrings(e, h);
}

// testdata/make.py documents why each of these matches.
// A value in a list or map is reported with its place in the row: row 3's
// tags are ["needle", "needle2"], so both match.
const table_hits = [_][]const u8{
    "cat:1:needle",           "cat:4:needle",
    "m[k]:0:needle",          "m[needle].key:1:needle",
    "name:0:needle",          "name:4:a needle here",
    "note:4:needle\nline",    "pair[0]:5:needle",
    "pair[1]:1:needle",       "tags[0]:3:needle",
    "tags[1]:0:needle",       "tags[1]:3:needle2",
    "user.name:0:needle",     "user.name:4:needles",
    "view:1:a long string with needle inside", "view:3:needle",
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
        "st.inner:2:needle", "tags[0]:1:needle",
    };
    for (polars_hits) |h| {
        try expected.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, "testdata/tree/polars.arrow:{s}", .{h}));
    }
    // Parquet: the same table, lists and maps included.
    for ([_][]const u8{ "snappy", "v2_delta", "plain_gzip", "lz4" }) |file| {
        for (table_hits) |h| try expected.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, "testdata/tree/parquet/{s}.parquet:{s}", .{ file, h }));
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
    // A top-level name selects everything under it. A map value's place
    // is its key; a key's is itself, then `.key`.
    try expectHits(.{ .root_path = file, .term = "needle", .jobs = 1, .columns = &.{"m"} }, &.{
        file ++ ":m[k]:0:needle",
        file ++ ":m[needle].key:1:needle",
    });
    try expectHits(.{ .root_path = file, .term = "NEEDLE", .jobs = 1, .ignore_case = true, .columns = &.{"note"} }, &.{
        file ++ ":note:1:NEEDLE",
        file ++ ":note:4:needle\nline",
    });
    var re = try regex.Regex.compile(testing.allocator, "^needle.?$", false);
    defer re.deinit();
    try expectHits(.{ .root_path = file, .term = "^needle.?$", .jobs = 2, .regex = &re, .columns = &.{ "tags", "user", "view" } }, &.{
        file ++ ":tags[0]:3:needle",
        file ++ ":tags[1]:0:needle",
        file ++ ":tags[1]:3:needle2",
        file ++ ":user.name:0:needle",
        file ++ ":user.name:4:needles",
        file ++ ":view:3:needle",
    });
}

test "many terms: the automaton" {
    // From pattern.many terms on, run() searches them with multi.zig.
    const terms = [_][]const u8{ "zz1", "zz2", "zz3", "zz4", "zz5", "zz6", "HERE", "eedles", "needle!" };
    try testing.expect(terms.len >= pattern.many);
    for ([_][]const u8{ "testdata/tree/plain.arrow", "testdata/tree/parquet/snappy.parquet" }) |file| {
        var buf: [2][160]u8 = undefined;
        const want = [_][]const u8{
            try std.fmt.bufPrint(&buf[0], "{s}:name:4:a needle here", .{file}),
            try std.fmt.bufPrint(&buf[1], "{s}:user.name:4:needles", .{file}),
        };
        try expectHits(.{ .root_path = file, .term = terms[0], .terms = &terms, .jobs = 2, .ignore_case = true, .columns = &.{ "name", "user", "tags" } }, &want);
        // Case matters without -i; -w needs whole words.
        try expectHits(.{ .root_path = file, .term = terms[0], .terms = &terms, .jobs = 2, .columns = &.{ "name", "user", "tags" } }, want[1..]);
        const words = [_][]const u8{ "zz1", "zz2", "zz3", "zz4", "zz5", "zz6", "needle", "red", "edle" };
        var wbuf: [6][160]u8 = undefined;
        try expectHits(.{ .root_path = file, .term = words[0], .terms = &words, .word = true, .jobs = 2, .columns = &.{ "name", "cat" } }, &.{
            try std.fmt.bufPrint(&wbuf[0], "{s}:cat:0:red", .{file}),
            try std.fmt.bufPrint(&wbuf[1], "{s}:cat:1:needle", .{file}),
            try std.fmt.bufPrint(&wbuf[2], "{s}:cat:2:red", .{file}),
            try std.fmt.bufPrint(&wbuf[3], "{s}:cat:4:needle", .{file}),
            try std.fmt.bufPrint(&wbuf[4], "{s}:name:0:needle", .{file}),
            try std.fmt.bufPrint(&wbuf[5], "{s}:name:4:a needle here", .{file}),
        });
    }
}

// Runs a search printing into a file, and returns what it printed.
fn printed(opts: Options, print: Print) !struct { text: []u8, summary: Summary } {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "out", .{ .read = true });
    var p = print;
    p.file = file;
    const summary = try run(testing.allocator, opts, .{ .print = p });
    file.close(testing.io);
    return .{ .text = try tmp.dir.readFileAlloc(testing.io, "out", testing.allocator, .unlimited), .summary = summary };
}

test "output modes: -l, --count, -m, --json, colors; the summary" {
    const file = "testdata/tree/plain.arrow";
    const one: Options = .{ .root_path = file, .term = "needle", .jobs = 2 };
    const anyfile: Print = .{ .file = undefined };

    var r = try printed(one, .{ .file = undefined, .mode = .files_with_matches });
    try testing.expectEqualStrings(file ++ "\n", r.text);
    testing.allocator.free(r.text);

    r = try printed(.{ .root_path = file, .term = "needle", .jobs = 2, .columns = &.{ "name", "note", "tags" } }, .{ .file = undefined, .mode = .count });
    try testing.expectEqualStrings(file ++ ":name:2\n" ++ file ++ ":note:1\n" ++ file ++ ":tags[]:2\n", r.text);
    testing.allocator.free(r.text);

    // -m: the file's first matches in output order (batch, column, row).
    r = try printed(.{ .root_path = file, .term = "needle", .jobs = 4, .max_count = 3 }, anyfile);
    try testing.expectEqualStrings(file ++ ":name:0\n" ++ file ++ ":view:1\n" ++ file ++ ":view:3\n", r.text);
    testing.allocator.free(r.text);

    r = try printed(.{ .root_path = file, .term = "needle", .jobs = 1, .columns = &.{"note"} }, .{ .file = undefined, .json = true });
    try testing.expectEqualStrings("{\"path\":\"" ++ file ++ "\",\"column\":\"note\",\"at\":\"note\",\"row\":4,\"value\":\"needle\\nline\"}\n", r.text);
    testing.allocator.free(r.text);

    // In a list: one line per matching element, `column` the list's,
    // `at` the element's; --count counts rows (row 3 has two).
    r = try printed(.{ .root_path = file, .term = "needle", .jobs = 1, .columns = &.{"tags"} }, .{ .file = undefined, .json = true });
    try testing.expectEqualStrings(
        "{\"path\":\"" ++ file ++ "\",\"column\":\"tags[]\",\"at\":\"tags[1]\",\"row\":0,\"value\":\"needle\"}\n" ++
            "{\"path\":\"" ++ file ++ "\",\"column\":\"tags[]\",\"at\":\"tags[0]\",\"row\":3,\"value\":\"needle\"}\n" ++
            "{\"path\":\"" ++ file ++ "\",\"column\":\"tags[]\",\"at\":\"tags[1]\",\"row\":3,\"value\":\"needle2\"}\n",
        r.text,
    );
    testing.allocator.free(r.text);

    r = try printed(.{ .root_path = file, .term = "needle", .jobs = 1, .columns = &.{"note"} }, .{ .file = undefined, .content = true, .color = true });
    try testing.expectEqualStrings("\x1b[35m" ++ file ++ "\x1b[0m:\x1b[36mnote\x1b[0m:\x1b[32m4\x1b[0m:\x1b[1;31mneedle\x1b[0m\\nline\n", r.text);
    try testing.expect(r.summary.matched and !r.summary.errors);
    testing.allocator.free(r.text);

    // Nothing found: not matched. A malformed file, or strings fds can't
    // search (the union `u`): an error.
    r = try printed(.{ .root_path = file, .term = "zqxjv", .jobs = 1, .columns = &.{ "name", "tags", "m" } }, anyfile);
    try testing.expect(!r.summary.matched and !r.summary.errors);
    testing.allocator.free(r.text);
    r = try printed(.{ .root_path = file, .term = "zqxjv", .jobs = 1 }, anyfile);
    try testing.expect(!r.summary.matched and r.summary.errors);
    testing.allocator.free(r.text);
    r = try printed(.{ .root_path = file, .term = "zqxjv", .jobs = 1, .columns = &.{"u"} }, anyfile);
    try testing.expect(r.summary.errors);
    testing.allocator.free(r.text);
    r = try printed(.{ .root_path = "testdata/tree/parquet/snappy.parquet", .term = "zqxjv", .jobs = 1 }, anyfile);
    try testing.expect(!r.summary.matched and !r.summary.errors); // lists and maps are searched
    testing.allocator.free(r.text);
    r = try printed(.{ .root_path = "testdata/tree", .term = "needle", .jobs = 4 }, .{ .file = undefined, .mode = .files_with_matches });
    try testing.expect(r.summary.matched and r.summary.errors); // truncated.arrow
    testing.allocator.free(r.text);
}

test "highlighting and JSON escaping" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const lit: Options = .{ .root_path = "", .term = "ab", .jobs = 1 };
    try writeContent(&w, "xabyab\nab", .{ .opts = &lit, .vm = null }, true);
    try testing.expectEqualStrings("x\x1b[1;31mab\x1b[0my\x1b[1;31mab\x1b[0m\\n\x1b[1;31mab\x1b[0m", w.buffered());

    var re = try regex.Regex.compile(testing.allocator, "b*", false);
    defer re.deinit();
    var vm = try regex.Vm.init(testing.allocator, &re);
    defer vm.deinit(testing.allocator);
    const rx: Options = .{ .root_path = "", .term = "b*", .jobs = 1, .regex = &re };
    w = .fixed(&buf);
    // Empty matches between the b's must not loop forever.
    try writeContent(&w, "abba", .{ .opts = &rx, .vm = &vm }, true);
    try testing.expectEqualStrings("a\x1b[1;31mbb\x1b[0ma", w.buffered());

    w = .fixed(&buf);
    try writeJsonField(&w, "v", "q\"\\\x01é");
    try testing.expectEqualStrings("\"v\":\"q\\\"\\\\\\u0001é\"", w.buffered());
    w = .fixed(&buf);
    try writeJsonField(&w, "v", "\xff\xfe");
    try testing.expectEqualStrings("\"v_base64\":\"//4=\"", w.buffered());

    // Text output can't carry terminal escape sequences or forge lines.
    w = .fixed(&buf);
    try w.print("{f}", .{esc("a\x1b]0;t\x07\tb\nc\r\x7fé")});
    try testing.expectEqualStrings("a\\x1b]0;t\\x07\tb\\nc\\r\\x7fé", w.buffered());
    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(testing.allocator);
    try writeKey(testing.allocator, &key, "a]\\\x1b\n");
    try testing.expectEqualStrings("a\\]\\\\\\x1b\\n", key.items);
}
