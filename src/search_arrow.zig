//! Searching an Arrow IPC file or stream: turns it into pieces for
//! search.zig to run, and searches each piece.
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
//! dictionary-encoded or compressed array. When a batch's last piece is
//! done, its part of the file is released (`map.Map.release`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const arrow = @import("arrow.zig");
const search = @import("search.zig");
const FileSearch = search.FileSearch;
const Matcher = search.Matcher;
const Piece = search.Piece;

/// Reads the file's messages: the schema, then dictionaries (searched
/// here) and record batches (cut into pieces).
pub fn plan(f: *FileSearch, arena: Allocator, matcher: Matcher) !void {
    var reader = try arrow.Reader.init(f.map.bytes);
    var file: ?*File = null;
    var dicts: std.AutoHashMapUnmanaged(i64, *const Dictionary) = .empty;
    var rows: u64 = 0;
    while (try reader.next()) |msg| switch (msg.kind) {
        .schema => {
            if (file != null) return error.Malformed;
            const schema = try arrow.parseSchema(arena, msg.header);
            const fl = try arena.create(File);
            var skipped: std.ArrayList(Skipped) = .empty;
            fl.* = .{ .schema = schema, .targets = try findTargets(arena, schema, f.s.opts.columns, &skipped) };
            file = fl;
            for (skipped.items) |k| f.s.notSearched(f.path, k.name, k.why);
            if (fl.targets.len == 0) return; // no string values to search
        },
        .dictionary => {
            const fl = file orelse return error.Malformed;
            const db = try arrow.DictionaryBatch.parse(msg.header, msg.body);
            // Only dictionaries of string columns being searched.
            const value_type = for (fl.targets) |t| {
                if (t.leaf.dict) |d| if (d.id == db.id) break t.leaf.type;
            } else continue;
            const strings = try db.batch.strings(arena, value_type, try db.batch.dictionaryColumn(value_type));
            const prev = if (db.delta) dicts.get(db.id) else null;
            try dicts.put(arena, db.id, try Dictionary.add(arena, prev, strings, matcher));
        },
        .record_batch => {
            const fl = file orelse return error.Malformed;
            const batch = try arrow.Batch.parse(msg.header, msg.body);
            // The dictionaries as of this batch: a later replacement
            // or delta makes a new `Dictionary`, never changes this one.
            const snapshot = try arena.alloc(?*const Dictionary, fl.targets.len);
            for (fl.targets, snapshot) |t, *d| d.* = if (t.leaf.dict) |dd| dicts.get(dd.id) else null;
            const b = try arena.create(BatchWork);
            b.* = .{ .file = fl, .batch = batch, .first_row = rows, .dicts = snapshot, .columns = try batch.layout(arena, fl.schema) };
            try cut(f, arena, b);
            rows += batch.length;
        },
        .other => {},
    };
}

// Adds the pieces of a batch, in output order.
fn cut(f: *FileSearch, arena: Allocator, b: *BatchWork) !void {
    const first = f.pieces.items.len;
    for (b.file.targets, 0..) |t, ti| {
        const rows = rowsPerPiece(b, t, f.s.opts.piece_bytes) orelse {
            try f.addPiece(arena, .{ .arrow = .{ .batch = b, .target = ti, .rows = null } }, t.name);
            continue;
        };
        const n = b.batch.len(b.columns[t.leaf.index]) catch unreachable; // rowsPerPiece checked it
        var from: usize = 0;
        while (from < n) : (from += rows) {
            const range: Rows = .{ .from = from, .to = @min(n, from + rows) };
            try f.addPiece(arena, .{ .arrow = .{ .batch = b, .target = ti, .rows = range } }, t.name);
        }
    }
    b.pending = .init(f.pieces.items.len - first);
    // No pieces (no rows): nothing will release the batch, which is fine.
}

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

/// A piece of a record batch: one target, or a range of its rows.
pub const Job = struct {
    batch: *BatchWork,
    target: usize,
    rows: ?Rows, // a range of a top-level array, or null for all of it

    pub fn search(job: *Job, arena: Allocator, f: *const FileSearch, piece: *Piece, matcher: Matcher) !void {
        const b = job.batch;
        const t = &b.file.targets[job.target];
        const levels = try arena.alloc(arrow.Level, t.path.len);
        for (t.path, levels) |field, *l| l.* = try b.batch.level(arena, field, b.columns[field.index]);
        const cursors = try arena.alloc(usize, t.path.len);
        @memset(cursors, 0);
        var sink: Sink = .{
            .f = f,
            .piece = piece,
            .matcher = matcher,
            .first_row = b.first_row,
            .levels = levels,
            .cursors = cursors,
            .target = t,
            .batch = b,
            .arena = arena,
            .entries = try arena.alloc(usize, t.path.len),
            .parents = try arena.alloc(usize, t.path.len),
            .keys = try arena.alloc(?arrow.Strings, t.path.len),
            .loaded = try arena.alloc(bool, t.path.len),
        };
        @memset(sink.loaded, false);

        const col = b.columns[t.leaf.index];
        if (t.leaf.dict) |d| {
            const ix = try b.batch.indices(arena, d, col);
            const values = b.dicts[job.target] orelse return error.Malformed; // no dictionary batch for it
            if (!values.any) return;
            for (0..ix.len) |i| {
                if (!arrow.validBit(ix.validity, i)) continue;
                const key = ix.get(i) orelse return error.Malformed;
                if (key >= values.len) return error.Malformed;
                if (values.matches.isSet(@intCast(key))) try sink.onValue(i, values.get(@intCast(key)));
            }
        } else {
            const strings = if (job.rows) |r|
                try b.batch.stringRange(arena, t.leaf.type, col, r.from, r.to)
            else
                try b.batch.strings(arena, t.leaf.type, col);
            sink.strings = strings;
            try findStrings(matcher, strings, &sink);
        }
    }

    /// The batch's last piece releases its body: nothing reads it any more
    /// (matches were copied out, dictionaries live in their own messages).
    pub fn finish(job: *Job, f: *const FileSearch) void {
        if (job.batch.pending.fetchSub(1, .acq_rel) == 1) f.map.release(job.batch.batch.body);
    }
};

// The schema and what to search in it.
const File = struct {
    schema: arrow.Schema,
    targets: []const Target,
};

// One record batch, shared by its pieces.
const BatchWork = struct {
    file: *const File,
    batch: arrow.Batch,
    first_row: u64, // file row of the batch's row 0
    dicts: []const ?*const Dictionary, // per target
    columns: []const arrow.Column, // `batch.layout`
    pending: std.atomic.Value(usize) = .init(0), // pieces not finished yet
};

const Rows = struct { from: usize, to: usize };

// A string array to search, found in the schema.
const Target = struct {
    name: []const u8, // column path for output: "a", "a.b", "tags[]", "m[].key"
    leaf: *const arrow.Field,
    path: []const *const arrow.Field, // nested fields above `leaf`, outermost first
};

// A field holding strings that fds can't search (see `addTargets`).
const Skipped = struct { name: []const u8, why: []const u8 };

// The string arrays to search, among the columns selected by `-c`. Those
// fds can't search go to `skipped`, to be reported.
fn findTargets(arena: Allocator, schema: arrow.Schema, columns: []const []const u8, skipped: *std.ArrayList(Skipped)) ![]const Target {
    var all: std.ArrayList(Target) = .empty;
    var not: std.ArrayList(Skipped) = .empty;
    for (schema.fields) |*f| {
        const from = not.items.len;
        try addTargets(arena, &all, &not, f, f.name, &.{});
        for (not.items[from..]) |k| if (search.selected(columns, f.name, k.name)) try skipped.append(arena, k);
    }
    var kept: std.ArrayList(Target) = .empty;
    for (all.items) |t| {
        const top = if (t.path.len > 0) t.path[0].name else t.leaf.name;
        if (search.selected(columns, top, t.name)) try kept.append(arena, t);
    }
    return kept.items;
}

fn addTargets(arena: Allocator, list: *std.ArrayList(Target), skipped: *std.ArrayList(Skipped), f: *const arrow.Field, name: []const u8, path: []const *const arrow.Field) !void {
    // A dictionary-encoded field's type is the type of its values.
    if (f.type.isString()) return list.append(arena, .{ .name = name, .leaf = f, .path = path });
    if (f.dict != null) return;
    const list_like = switch (f.type) {
        .list, .large_list, .fixed_size_list, .map => true,
        .@"struct" => false,
        // Their rows don't map to their children's entries one to one (or
        // in order), which the search needs: strings in them are reported
        // as not searched instead.
        .@"union", .run_end_encoded, .list_view, .large_list_view => {
            if (hasStrings(f)) try skipped.append(arena, .{ .name = name, .why = switch (f.type) {
                .@"union" => "strings in a union",
                .run_end_encoded => "strings in a run-end encoded array",
                else => "strings in a list view",
            } });
            return;
        },
        else => return,
    };
    const sub = try std.mem.concat(arena, *const arrow.Field, &.{ path, &.{f} });
    for (f.children) |*c| {
        const child_name = if (list_like)
            try std.fmt.allocPrint(arena, "{s}[]", .{name})
        else
            try std.fmt.allocPrint(arena, "{s}.{s}", .{ name, c.name });
        try addTargets(arena, list, skipped, c, child_name, sub);
    }
}

fn hasStrings(f: *const arrow.Field) bool {
    if (f.type.isString()) return true;
    for (f.children) |*c| if (hasStrings(c)) return true;
    return false;
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
    fn add(arena: Allocator, prev: ?*const Dictionary, strings: arrow.Strings, matcher: Matcher) !*const Dictionary {
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
        try findStrings(matcher, strings, DictSink{ .d = d, .base = base, .strings = strings });
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

// The search over one string array, whatever its layout.
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

// Receives the matching values of one string array, maps them up to their
// top-level row and records them, with their place in the row.
const Sink = struct {
    f: *const FileSearch,
    piece: *Piece,
    matcher: Matcher,
    first_row: u64,
    levels: []const arrow.Level,
    cursors: []usize,
    strings: ?arrow.Strings = null, // null: dictionary values, already checked for nulls
    target: *const Target,
    batch: *const BatchWork,
    arena: Allocator,
    // Per level, for the value being recorded: its entry in that level's
    // children, and the entry of the level holding it.
    entries: []usize,
    parents: []usize,
    // Per map level, its keys (loaded at its first match), or null if
    // they are not strings: positions are printed instead.
    keys: []?arrow.Strings,
    loaded: []bool,
    at: std.ArrayList(u8) = .empty,

    pub fn onValue(k: *Sink, i: usize, value: []const u8) !void {
        var j = i;
        if (k.strings) |strings| {
            if (!strings.isValid(i)) return;
            j = strings.first + i; // index in the whole array
        }
        var level = k.levels.len;
        while (level > 0) {
            level -= 1;
            k.entries[level] = j;
            j = k.levels[level].parent(j, &k.cursors[level]) orelse return;
            k.parents[level] = j;
        }
        const at = if (k.levels.len == 0) k.target.name else try k.place();
        try k.piece.record(k.f, k.matcher, k.first_row + j, at, value);
    }

    // The value's place in its row, as `Hit.at`: the target's name with
    // list positions and map keys filled in: "tags[1]", "m[key]",
    // "m[key].key", "a[0].b[2]".
    fn place(k: *Sink) ![]const u8 {
        const t = k.target;
        k.at.clearRetainingCapacity();
        try k.at.appendSlice(k.arena, t.path[0].name);
        for (t.path, 0..) |field, l| {
            const child = if (l + 1 < t.path.len) t.path[l + 1] else t.leaf;
            switch (field.type) {
                // A map's entries are a struct of key and value: the value
                // is the map's entry itself, the key is `.key` of it.
                .@"struct" => if (l == 0 or t.path[l - 1].type != .map or child == &field.children[0]) {
                    try k.at.print(k.arena, ".{s}", .{child.name});
                },
                .map => {
                    const entry = k.entries[l];
                    if (try k.mapKeys(l)) |keys| if (entry < keys.len) {
                        try k.at.append(k.arena, '[');
                        try search.writeKey(k.arena, &k.at, keys.get(entry));
                        try k.at.append(k.arena, ']');
                        continue;
                    };
                    try k.at.print(k.arena, "[#{d}]", .{k.levels[l].position(k.parents[l], entry)});
                },
                else => try k.at.print(k.arena, "[{d}]", .{k.levels[l].position(k.parents[l], k.entries[l])}),
            }
        }
        return k.at.items;
    }

    // The keys of the map at level `l`, if they are plain strings.
    fn mapKeys(k: *Sink, l: usize) !?arrow.Strings {
        if (!k.loaded[l]) {
            k.loaded[l] = true;
            k.keys[l] = null;
            const entries = k.target.path[l].children;
            if (entries.len == 1 and entries[0].children.len == 2) {
                const key = &entries[0].children[0];
                if (key.type.isString() and key.dict == null) {
                    k.keys[l] = try k.batch.batch.strings(k.arena, key.type, k.batch.columns[key.index]);
                }
            }
        }
        return k.keys[l];
    }
};
