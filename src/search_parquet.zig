//! Searching a Parquet file: one piece per column chunk (a string column in
//! one row group), searched by `parquet.searchChunk` and released when done.

const std = @import("std");
const Allocator = std.mem.Allocator;
const parquet = @import("parquet.zig");
const search = @import("search.zig");
const FileSearch = search.FileSearch;
const Matcher = search.Matcher;
const Piece = search.Piece;

/// Reads the footer and adds a piece per string column per row group, in
/// output order: by row group, then column.
pub fn plan(f: *FileSearch, arena: Allocator, _: Matcher) !void {
    const file = try arena.create(parquet.File);
    file.* = try parquet.open(arena, f.map.bytes);
    for (file.row_groups) |*g| {
        for (file.columns) |c| {
            if (!search.selected(f.s.opts.columns, c.top, c.name)) continue;
            try f.addPiece(arena, .{ .parquet = .{ .file = file, .group = g, .column = c } }, c.name);
        }
    }
}

pub const Job = struct {
    file: *const parquet.File,
    group: *const parquet.RowGroup,
    column: parquet.Column,

    pub fn search(job: *Job, arena: Allocator, f: *const FileSearch, piece: *Piece, matcher: Matcher) !void {
        var sink: Sink = .{ .f = f, .piece = piece, .matcher = matcher, .job = job, .arena = arena };
        try parquet.searchChunk(arena, job.group.chunks[job.column.leaf], job.column, matcher, &sink);
    }

    /// Each chunk is its own part of the file: release it right away. (A
    /// map's key chunk, read for the places of matches, may be released
    /// before its own piece runs; that only costs reading it again.)
    pub fn finish(job: *Job, f: *const FileSearch) void {
        f.map.release(job.group.chunks[job.column.leaf].bytes);
    }
};

const Sink = struct {
    f: *const FileSearch,
    piece: *Piece,
    matcher: Matcher,
    job: *const Job,
    arena: Allocator,
    at: std.ArrayList(u8) = .empty,
    // Per level, a map's keys, read at its first match (null: not read
    // yet; empty: keys that aren't strings, so positions are shown).
    keys: [max_levels]?[]const []const u8 = @splat(null),

    const max_levels = 16;

    pub fn onValue(k: *Sink, row: usize, pos: parquet.Position, value: []const u8) !void {
        const c = k.job.column;
        const at = if (c.max_rep == 0) c.name else try k.place(pos, value);
        try k.piece.record(k.f, k.matcher, k.job.group.first_row + row, at, value);
    }

    // The value's place in its row, as `search.Hit.at`: the column's shape
    // with list positions and map keys filled in: "tags[1]", "m[key]",
    // "m[key].key", "a[0].b[2]".
    fn place(k: *Sink, pos: parquet.Position, value: []const u8) ![]const u8 {
        const c = k.job.column;
        k.at.clearRetainingCapacity();
        var level: usize = 0;
        for (c.shape) |ch| {
            if (ch != 0) {
                try k.at.append(k.arena, ch);
                continue;
            }
            if (level >= c.levels.len) return error.Malformed;
            defer level += 1;
            if (c.levels[level].key) |key_leaf| {
                // This column is the map's keys: the value is the key.
                const key = if (key_leaf == c.leaf) value else try k.mapKey(level, key_leaf, pos.entry[level]);
                if (key) |text| {
                    try k.at.append(k.arena, '[');
                    try search.writeKey(k.arena, &k.at, text);
                    try k.at.append(k.arena, ']');
                    continue;
                }
                try k.at.print(k.arena, "[#{d}]", .{pos.index[level]});
            } else try k.at.print(k.arena, "[{d}]", .{pos.index[level]});
        }
        return k.at.items;
    }

    // The key of entry `entry` (counted in the row group) of the map at
    // `level`, whose keys are leaf `key_leaf`: null if they aren't strings.
    fn mapKey(k: *Sink, level: usize, key_leaf: usize, entry: u64) !?[]const u8 {
        if (level >= max_levels) return null;
        if (k.keys[level] == null) {
            k.keys[level] = &.{};
            for (k.job.file.columns) |kc| if (kc.leaf == key_leaf) {
                k.keys[level] = try parquet.chunkValues(k.arena, k.job.group.chunks[key_leaf], kc);
            };
        }
        const keys = k.keys[level].?;
        return if (entry < keys.len) keys[@intCast(entry)] else null;
    }
};
