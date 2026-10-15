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
    const file = try parquet.open(arena, f.map.bytes);
    for (file.row_groups) |g| {
        for (file.columns) |c| {
            if (!search.selected(f.s.opts.columns, c.top, c.name)) continue;
            try f.addPiece(arena, .{ .parquet = .{ .chunk = g.chunks[c.leaf], .column = c, .first_row = g.first_row } }, c.name);
        }
    }
}

pub const Job = struct {
    chunk: parquet.Chunk,
    column: parquet.Column,
    first_row: u64, // file row of the row group's first row

    pub fn search(job: *Job, arena: Allocator, f: *const FileSearch, piece: *Piece, matcher: Matcher) !void {
        try parquet.searchChunk(arena, job.chunk, job.column, matcher, Sink{ .f = f, .piece = piece, .matcher = matcher, .first_row = job.first_row });
    }

    /// Each chunk is its own part of the file: release it right away.
    pub fn finish(job: *Job, f: *const FileSearch) void {
        f.map.release(job.chunk.bytes);
    }
};

const Sink = struct {
    f: *const FileSearch,
    piece: *Piece,
    matcher: Matcher,
    first_row: u64,

    pub fn onValue(k: Sink, row: usize, value: []const u8) !void {
        try k.piece.record(k.f, k.matcher, k.first_row + row, value);
    }
};
