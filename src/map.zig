//! A file's bytes, read-only, for as long as it is searched: mapped into
//! memory (read whole on Windows). Parts that won't be read again can be
//! handed back early with `release`; what that does depends on the OS,
//! and OS-specific code lives in its own file (linux.zig).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const linux = @import("linux.zig");

pub const Map = struct {
    bytes: []const u8,

    pub fn open(io: Io, gpa: std.mem.Allocator, file: Io.File) !Map {
        const size = try file.length(io);
        if (size == 0) return .{ .bytes = "" };
        if (size > std.math.maxInt(usize)) return error.FileTooBig;
        if (builtin.os.tag == .windows) {
            const buf = try gpa.alloc(u8, @intCast(size));
            errdefer gpa.free(buf);
            if (try file.readPositionalAll(io, buf, 0) != buf.len) return error.EndOfStream;
            return .{ .bytes = buf };
        }
        return .{ .bytes = try std.posix.mmap(null, @intCast(size), .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0) };
    }

    pub fn close(m: Map, gpa: std.mem.Allocator) void {
        if (m.bytes.len == 0) return;
        if (builtin.os.tag == .windows) return gpa.free(m.bytes);
        std.posix.munmap(@alignCast(m.bytes));
    }

    /// Says that `part` (a slice of `bytes`) won't be read again. Reading
    /// it anyway stays correct; it may only be slower.
    pub fn release(m: Map, part: []const u8) void {
        if (part.len == 0) return; // nothing to release (and maybe not in the map)
        std.debug.assert(@intFromPtr(part.ptr) >= @intFromPtr(m.bytes.ptr) and
            @intFromPtr(part.ptr) + part.len <= @intFromPtr(m.bytes.ptr) + m.bytes.len);
        if (builtin.os.tag == .linux) linux.dropPages(part);
        // Elsewhere: nothing. Pages are freed when the map is closed.
    }
};
