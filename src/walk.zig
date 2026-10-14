//! Parallel recursive directory walk on `std.Io`.
//!
//! Each directory is a task in one `Io.Group`. A directory task starts a new
//! task for each subdirectory and hands each of its regular files to the
//! visitor, so walking and visiting both run in parallel. When every thread
//! is busy, `Group.async` runs the subdirectory inline (depth-first).
//! Symlinks and special files are skipped; unreadable directories are
//! skipped silently.
//!
//! The walker knows nothing about what is done with a file. A visitor is any
//! struct with:
//!
//!     pub const Local = ...;   // per-directory-task state
//!     pub fn initLocal(v: *Visitor) !Local
//!     pub fn deinitLocal(v: *Visitor, local: *Local) void
//!     pub fn visitFile(v: *Visitor, local: *Local, file: walk.File) !void
//!
//! `visitFile` is called concurrently from different directory tasks, but
//! one `Local` is only ever used by one task at a time. That makes `Local`
//! the place for reusable buffers.

const std = @import("std");
const Io = std.Io;

pub const File = struct {
    /// Open handle of the directory containing the file.
    dir: Io.Dir,
    /// File name inside `dir`. Valid only during the `visitFile` call.
    name: []const u8,
    /// Path relative to the walk root. Valid only during the `visitFile` call.
    path: []const u8,
};

/// Walks every regular file under `root` (opened with `.iterate = true`)
/// and calls `visitor.visitFile` for each. Returns when all tasks finish.
pub fn walk(io: Io, gpa: std.mem.Allocator, root: Io.Dir, visitor: anytype) Io.Cancelable!void {
    const W = Walker(@typeInfo(@TypeOf(visitor)).pointer.child);
    var w: W = .{ .io = io, .gpa = gpa, .root = root, .visitor = visitor };
    defer w.group.cancel(io);
    w.group.async(io, W.walkDir, .{ &w, "" });
    try w.group.await(io);
}

fn Walker(comptime Visitor: type) type {
    return struct {
        const Self = @This();

        io: Io,
        gpa: std.mem.Allocator,
        root: Io.Dir,
        visitor: *Visitor,
        group: Io.Group = .init,

        // One task per directory. `rel` is the directory's path relative to
        // root ("" for root); the task owns it unless it is the root.
        fn walkDir(w: *Self, rel: []const u8) Io.Cancelable!void {
            defer if (rel.len > 0) w.gpa.free(rel);
            w.walkDirFallible(rel) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => std.log.err("{s}: {t}", .{ if (rel.len == 0) "." else rel, err }),
            };
        }

        fn walkDirFallible(w: *Self, rel: []const u8) !void {
            var dir = w.root.openDir(w.io, if (rel.len == 0) "." else rel, .{ .iterate = true }) catch return;
            defer dir.close(w.io);

            var local = try w.visitor.initLocal();
            defer w.visitor.deinitLocal(&local);

            var path: std.ArrayList(u8) = .empty; // "<rel>/<name>"
            defer path.deinit(w.gpa);

            var it = dir.iterate();
            while (it.next(w.io) catch return) |entry| {
                switch (entry.kind) {
                    .directory => {
                        const child = try joinPath(w.gpa, rel, entry.name);
                        w.group.async(w.io, walkDir, .{ w, child });
                    },
                    .file => {
                        path.clearRetainingCapacity();
                        if (rel.len > 0) {
                            try path.appendSlice(w.gpa, rel);
                            try path.append(w.gpa, '/');
                        }
                        try path.appendSlice(w.gpa, entry.name);
                        try w.visitor.visitFile(&local, .{ .dir = dir, .name = entry.name, .path = path.items });
                    },
                    else => {},
                }
            }
        }
    };
}

fn joinPath(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) return gpa.dupe(u8, name);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
}
