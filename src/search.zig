//! Per-file search: map an Arrow file, read its messages, search every
//! string array of every record batch, and report matches. `Searcher` is
//! the visitor passed to `walk.walk`; `run` sets up threads and the walk,
//! and is shared by the CLI and the C API.
//!
//! The string arrays are found from the schema: every `utf8`, `large_utf8`
//! and `utf8_view` field, dictionary-encoded or not, at the top level or
//! inside structs, lists, fixed-size lists and maps. A match in a nested
//! array is reported as the top-level row that holds it, under a column
//! path such as `user.name` or `tags[]`.
//!
//! A file's messages are read in order on one thread (dictionaries must be
//! searched before the batches that use them), and its record batches are
//! cut into pieces of similar size: a range of rows of one top-level
//! string column (about `Options.piece_bytes` of strings), or a whole nested,
//! dictionary-encoded or compressed array. Pieces are searched in
//! parallel, so the threads finish together, and their matches are
//! reported in order: by batch, column, then row. When a batch's last piece
//! is done, its part of the file is released (`map.Map.release`).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const arrow = @import("arrow.zig");
const Map = @import("map.zig").Map;
const match = @import("match.zig");
const regex = @import("regex.zig");
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
    /// About how many bytes of strings one piece of a column holds (see
    /// the top of this file). Tests make it small to cut columns finely.
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

/// The files searched under a directory: Arrow IPC files and streams.
pub fn isArrowFile(name: []const u8) bool {
    for ([_][]const u8{ ".arrow", ".feather", ".arrows" }) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    }
    return false;
}

/// Searches every Arrow file under `opts.root_path`, or that one file if
/// it is a file (whatever its name).
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
        if (s.stopped.load(.monotonic) or !isArrowFile(f.name)) return;
        local.path.clearRetainingCapacity();
        try local.path.print(s.gpa, "{s}/{s}", .{ s.opts.root_path, f.path });
        try s.searchFile(f.dir, f.name, local.path.items);
    }

    /// Searches one file. Files that can't be read or parsed are reported
    /// on stderr and skipped; matches found before the problem are kept.
    pub fn searchFile(s: *Searcher, dir: Io.Dir, name: []const u8, path: []const u8) !void {
        const file = dir.openFile(s.io, name, .{}) catch |err| return warn(path, err);
        defer file.close(s.io);
        const map = Map.open(s.io, s.gpa, file) catch |err| return warn(path, err);
        defer map.close(s.gpa);
        s.searchMap(path, map) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => warn(path, err),
        };
    }

    fn searchMap(s: *Searcher, path: []const u8, map: Map) !void {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var vm: ?regex.Vm = if (s.opts.regex) |re| try .init(s.gpa, re) else null;
        defer if (vm) |*v| v.deinit(s.gpa);

        var f: FileSearch = .{ .s = s, .path = path, .map = map };
        defer for (f.pieces.items) |*p| p.deinit(s.gpa);
        // On an error, the batches read before it are still searched.
        const read_err = f.read(arena, .{ .opts = &s.opts, .vm = if (vm) |*v| v else null });
        if (f.pieces.items.len == 1) {
            s.runPiece(&f, &f.pieces.items[0]);
        } else if (f.pieces.items.len > 1) {
            var group: Io.Group = .init;
            defer group.cancel(s.io);
            for (f.pieces.items) |*p| group.async(s.io, runPieceTask, .{ s, &f, p });
            try group.await(s.io);
        }
        try s.report(&f);
        return read_err;
    }

    fn runPieceTask(s: *Searcher, f: *const FileSearch, piece: *Piece) Io.Cancelable!void {
        s.runPiece(f, piece);
    }

    fn runPiece(s: *Searcher, f: *const FileSearch, piece: *Piece) void {
        defer {
            // The batch's last piece: nothing reads its body any more
            // (matches were copied out, dictionaries live elsewhere).
            if (piece.batch.pending.fetchSub(1, .acq_rel) == 1) f.map.release(piece.batch.batch.body);
        }
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        var vm: ?regex.Vm = if (s.opts.regex) |re| regex.Vm.init(s.gpa, re) catch |err| {
            piece.err = err;
            return;
        } else null;
        defer if (vm) |*v| v.deinit(s.gpa);
        const matcher: Matcher = .{ .opts = &s.opts, .vm = if (vm) |*v| v else null };
        s.searchPiece(scratch.allocator(), f, piece, matcher) catch |err| {
            piece.err = err;
        };
    }

    fn searchPiece(s: *Searcher, arena: std.mem.Allocator, f: *const FileSearch, piece: *Piece, matcher: Matcher) !void {
        if (s.stopped.load(.monotonic)) return;
        const b = piece.batch;
        const t = &f.targets[piece.target];
        const levels = try arena.alloc(arrow.Level, t.path.len);
        for (t.path, levels) |field, *l| l.* = try b.batch.level(arena, field, b.columns[field.index]);
        const cursors = try arena.alloc(usize, t.path.len);
        @memset(cursors, 0);
        var sink: Sink = .{ .s = s, .f = f, .piece = piece, .levels = levels, .cursors = cursors };

        const col = b.columns[t.leaf.index];
        if (t.leaf.dict) |d| {
            const ix = try b.batch.indices(arena, d, col);
            const values = b.dicts[piece.target] orelse return error.Malformed; // no dictionary batch for it
            if (!values.any) return;
            for (0..ix.len) |i| {
                if (!arrow.validBit(ix.validity, i)) continue;
                const key = ix.get(i) orelse return error.Malformed;
                if (key >= values.len) return error.Malformed;
                if (values.matches.isSet(@intCast(key))) try sink.onValue(i, values.get(@intCast(key)));
            }
        } else {
            const strings = if (piece.rows) |r|
                try b.batch.stringRange(arena, t.leaf.type, col, r.from, r.to)
            else
                try b.batch.strings(arena, t.leaf.type, col);
            sink.strings = strings;
            try matcher.findStrings(strings, &sink);
        }
    }

    // Reports a file's matches in one piece so files never interleave.
    fn report(s: *Searcher, f: *FileSearch) !void {
        try s.out_mutex.lock(s.io);
        defer s.out_mutex.unlock(s.io);
        for (f.pieces.items) |*j| {
            switch (s.output) {
                .print => try s.writer.writeAll(j.out.written()),
                .callback => |cb| for (j.hits.items) |h| {
                    if (s.stopped.load(.monotonic)) return;
                    const hit: Hit = .{
                        .path = f.path,
                        .column = f.targets[j.target].name,
                        .row = h.row,
                        .text = j.out.written()[h.start..][0..h.len],
                    };
                    if (!cb.f(cb.ctx, hit)) s.stopped.store(true, .monotonic);
                },
            }
            // A piece that failed: later pieces are not reported.
            if (j.err) |err| return warn(f.path, err);
        }
    }
};

// One file being searched.
const FileSearch = struct {
    s: *Searcher,
    path: []const u8,
    map: Map,
    schema: arrow.Schema = undefined,
    targets: []const Target = &.{},
    pieces: std.ArrayList(Piece) = .empty, // in output order

    // Reads the file's messages: the schema, then dictionaries (searched
    // here) and record batches (cut into pieces).
    fn read(f: *FileSearch, arena: std.mem.Allocator, matcher: Matcher) !void {
        var reader = try arrow.Reader.init(f.map.bytes);
        var have_schema = false;
        var dicts: std.AutoHashMapUnmanaged(i64, *const Dictionary) = .empty;
        var rows: u64 = 0;
        while (try reader.next()) |msg| switch (msg.kind) {
            .schema => {
                if (have_schema) return error.Malformed;
                have_schema = true;
                f.schema = try arrow.parseSchema(arena, msg.header);
                f.targets = try findTargets(arena, f.schema, f.s.opts.columns);
                if (f.targets.len == 0) return; // no string values to search
            },
            .dictionary => {
                if (!have_schema) return error.Malformed;
                const db = try arrow.DictionaryBatch.parse(msg.header, msg.body);
                // Only dictionaries of string columns being searched.
                const value_type = for (f.targets) |t| {
                    if (t.leaf.dict) |d| if (d.id == db.id) break t.leaf.type;
                } else continue;
                const strings = try db.batch.strings(arena, value_type, try db.batch.dictionaryColumn(value_type));
                const prev = if (db.delta) dicts.get(db.id) else null;
                try dicts.put(arena, db.id, try Dictionary.add(arena, prev, strings, matcher));
            },
            .record_batch => {
                if (!have_schema) return error.Malformed;
                const batch = try arrow.Batch.parse(msg.header, msg.body);
                // The dictionaries as of this batch: a later replacement
                // or delta makes a new `Dictionary`, never changes this one.
                const snapshot = try arena.alloc(?*const Dictionary, f.targets.len);
                for (f.targets, snapshot) |t, *d| d.* = if (t.leaf.dict) |dd| dicts.get(dd.id) else null;
                const b = try arena.create(BatchWork);
                b.* = .{ .batch = batch, .first_row = rows, .dicts = snapshot, .columns = try batch.layout(arena, f.schema) };
                try f.cut(arena, b);
                rows += batch.length;
            },
            .other => {},
        };
    }

    // Adds the pieces of a batch, in output order.
    fn cut(f: *FileSearch, arena: std.mem.Allocator, b: *BatchWork) !void {
        const first = f.pieces.items.len;
        for (f.targets, 0..) |t, ti| {
            const rows = rowsPerPiece(b, t, f.s.opts.piece_bytes) orelse {
                try f.pieces.append(arena, .{ .batch = b, .target = ti, .rows = null, .out = .init(f.s.gpa) });
                continue;
            };
            const n = b.batch.len(b.columns[t.leaf.index]) catch unreachable; // rowsPerPiece checked it
            var from: usize = 0;
            while (from < n) : (from += rows) {
                const range: Rows = .{ .from = from, .to = @min(n, from + rows) };
                try f.pieces.append(arena, .{ .batch = b, .target = ti, .rows = range, .out = .init(f.s.gpa) });
            }
        }
        b.pending = .init(f.pieces.items.len - first);
        // No pieces (no rows): nothing will release the batch, which is fine.
    }

};

// How many rows of the target go in one piece, or null to search the array
// whole: nested and dictionary-encoded arrays (their rows don't map to
// ranges of the leaf array), compressed ones (each piece would decompress
// all of it), small ones, and anything malformed (the error then comes from
// the search).
fn rowsPerPiece(b: *const BatchWork, t: Target, piece_bytes: usize) ?usize {
    if (t.path.len > 0 or t.leaf.dict != null or b.batch.codec != null) return null;
    const col = b.columns[t.leaf.index];
    const n = b.batch.len(col) catch return null;
    // The array's bytes: offsets and data, or views and their data buffers.
    const buffers: usize = if (t.leaf.type == .utf8_view) 1 + col.variadic else 2;
    var bytes: usize = 0;
    for (0..buffers) |i| bytes += b.batch.bufferLen(col.buffer + 1 + i) catch return null;
    const pieces = bytes / piece_bytes;
    if (pieces < 2 or n < 2) return null;
    return std.math.divCeil(usize, n, pieces) catch unreachable;
}

// A string array to search, found in the schema.
const Target = struct {
    name: []const u8, // column path for output: "a", "a.b", "tags[]", "m[].key"
    leaf: *const arrow.Field,
    path: []const *const arrow.Field, // nested fields above `leaf`, outermost first
};

fn findTargets(arena: std.mem.Allocator, schema: arrow.Schema, columns: []const []const u8) ![]const Target {
    var all: std.ArrayList(Target) = .empty;
    for (schema.fields) |*f| try addTargets(arena, &all, f, f.name, &.{});
    if (columns.len == 0) return all.items;
    var kept: std.ArrayList(Target) = .empty;
    for (all.items) |t| {
        const top = if (t.path.len > 0) t.path[0].name else t.leaf.name;
        for (columns) |c| {
            if (std.mem.eql(u8, c, top) or std.mem.eql(u8, c, t.name)) break;
        } else continue;
        try kept.append(arena, t);
    }
    return kept.items;
}

fn addTargets(arena: std.mem.Allocator, list: *std.ArrayList(Target), f: *const arrow.Field, name: []const u8, path: []const *const arrow.Field) !void {
    // A dictionary-encoded field's type is the type of its values.
    if (f.type.isString()) return list.append(arena, .{ .name = name, .leaf = f, .path = path });
    if (f.dict != null) return;
    const list_like = switch (f.type) {
        .list, .large_list, .fixed_size_list, .map => true,
        .@"struct" => false,
        else => return, // no strings searched in unions, run-end encoded or list views
    };
    const sub = try std.mem.concat(arena, *const arrow.Field, &.{ path, &.{f} });
    for (f.children) |*c| {
        const child_name = if (list_like)
            try std.fmt.allocPrint(arena, "{s}[]", .{name})
        else
            try std.fmt.allocPrint(arena, "{s}.{s}", .{ name, c.name });
        try addTargets(arena, list, c, child_name, sub);
    }
}

// The values of one dictionary, with the keys whose value matches. Values
// arrive in chunks: the first batch, then deltas.
const Dictionary = struct {
    chunks: []const arrow.Strings,
    first: []const usize, // first key of each chunk
    len: usize,
    matches: std.DynamicBitSetUnmanaged,
    any: bool,

    // A new dictionary: `prev` (for a delta) plus `strings`, searched now.
    fn add(arena: std.mem.Allocator, prev: ?*const Dictionary, strings: arrow.Strings, matcher: Matcher) !*const Dictionary {
        const base = if (prev) |p| p.len else 0;
        const d = try arena.create(Dictionary);
        d.* = .{
            .chunks = try std.mem.concat(arena, arrow.Strings, &.{ if (prev) |p| p.chunks else &.{}, &.{strings} }),
            .first = try std.mem.concat(arena, usize, &.{ if (prev) |p| p.first else &.{}, &.{base} }),
            .len = base + strings.len,
            .matches = try .initEmpty(arena, base + strings.len),
            .any = false,
        };
        if (prev) |p| {
            var it = p.matches.iterator(.{});
            while (it.next()) |k| d.matches.set(k);
        }
        try matcher.findStrings(strings, DictSink{ .d = d, .base = base, .strings = strings });
        d.any = d.matches.count() > 0;
        return d;
    }

    fn get(d: *const Dictionary, key: usize) []const u8 {
        var i = d.chunks.len - 1;
        while (d.first[i] > key) i -= 1;
        return d.chunks[i].get(key - d.first[i]);
    }

    const DictSink = struct {
        d: *Dictionary,
        base: usize,
        strings: arrow.Strings,
        pub fn onValue(k: DictSink, i: usize, _: []const u8) !void {
            if (k.strings.isValid(i)) k.d.matches.set(k.base + i);
        }
    };
};

// The search for the term, literal or regex, over one string array.
const Matcher = struct {
    opts: *const Options,
    vm: ?*regex.Vm, // with a regex only

    fn findStrings(m: Matcher, strings: arrow.Strings, sink: anytype) !void {
        switch (strings.values) {
            .small => |v| try m.findValues(i32, v.off, v.data, sink),
            .large => |v| try m.findValues(i64, v.off, v.data, sink),
            // Views are not stored back to back: one search per value.
            .view => for (0..strings.len) |i| {
                const value = strings.get(i);
                if (m.matches(value)) try sink.onValue(i, value);
            },
        }
    }

    fn findValues(m: Matcher, comptime O: type, off: []align(1) const O, data: []const u8, sink: anytype) !void {
        if (m.opts.regex) |re| return regex.findValues(re, m.vm.?, O, off, data, sink);
        if (m.opts.ignore_case) return match.findValues(.insensitive, O, off, data, m.opts.term, sink);
        return match.findValues(.sensitive, O, off, data, m.opts.term, sink);
    }

    fn matches(m: Matcher, value: []const u8) bool {
        if (m.opts.regex) |re| return regex.matches(re, m.vm.?, value);
        if (m.opts.ignore_case) return match.contains(.insensitive, value, m.opts.term);
        return match.contains(.sensitive, value, m.opts.term);
    }
};

// One record batch, shared by its pieces.
const BatchWork = struct {
    batch: arrow.Batch,
    first_row: u64, // file row of the batch's row 0
    dicts: []const ?*const Dictionary, // per target
    columns: []const arrow.Column, // `batch.layout`
    pending: std.atomic.Value(usize) = .init(0), // pieces not finished yet
};

const Rows = struct { from: usize, to: usize };

// A part of a batch to search, and its results.
const Piece = struct {
    batch: *BatchWork,
    target: usize,
    rows: ?Rows, // a range of a top-level array, or null for all of it
    out: Io.Writer.Allocating, // `.print` lines, or `.callback` value texts
    hits: std.ArrayList(Collected) = .empty, // with `.callback` only
    err: ?anyerror = null,

    fn deinit(p: *Piece, gpa: std.mem.Allocator) void {
        p.out.deinit();
        p.hits.deinit(gpa);
    }
};

const Collected = struct { row: u64, start: usize, len: usize };

// Receives the matching values of one string array, maps them up to their
// top-level row and records them.
const Sink = struct {
    s: *Searcher,
    f: *const FileSearch,
    piece: *Piece,
    levels: []const arrow.Level,
    cursors: []usize,
    strings: ?arrow.Strings = null, // null: dictionary values, already checked for nulls
    last_row: ?u64 = null,

    pub fn onValue(k: *Sink, i: usize, value: []const u8) !void {
        var j = i;
        if (k.strings) |strings| {
            if (!strings.isValid(i)) return;
            j = strings.first + i; // index in the whole array
        }
        var level = k.levels.len;
        while (level > 0) {
            level -= 1;
            j = k.levels[level].parent(j, &k.cursors[level]) orelse return;
        }
        const row = k.piece.batch.first_row + j;
        // Several list elements of one row: the row is reported once.
        if (k.last_row == row) return;
        k.last_row = row;

        const name = k.f.targets[k.piece.target].name;
        const out = &k.piece.out.writer;
        switch (k.s.output) {
            .print => |p| {
                try out.print("{s}:{s}:{d}", .{ k.f.path, name, row });
                if (p.content) {
                    try out.writeByte(':');
                    try writeEscaped(out, value);
                }
                try out.writeByte('\n');
            },
            .callback => {
                const start = k.piece.out.written().len;
                try out.writeAll(value);
                try k.piece.hits.append(k.s.gpa, .{ .row = row, .start = start, .len = value.len });
            },
        }
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

fn warn(path: []const u8, err: anyerror) void {
    if (builtin.is_test) return; // `zig build test` fails on stderr output
    const why = switch (err) {
        error.Malformed => "not a valid Arrow IPC file",
        error.Unsupported => "uses an Arrow feature fds does not support",
        else => @errorName(err),
    };
    std.debug.print("fds: {s}: {s}\n", .{ path, why });
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
    // deltas; notes.txt is skipped and truncated.arrow is reported.
    var expected: std.ArrayList([]const u8) = .empty;
    defer {
        for (expected.items) |e| testing.allocator.free(e);
        expected.deinit(testing.allocator);
    }
    for ([_][]const u8{ "s:1:needle", "s:4:needle!", "s:5:needle", "s:7:needle-x" }) |h| {
        try expected.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, "testdata/tree/deltas.arrows:{s}", .{h}));
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
