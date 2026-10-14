//! Linux-only code, kept apart from the portable code. Only map.zig calls
//! it, behind a `builtin.os.tag == .linux` check.

const std = @import("std");

/// Unmaps the pages of `part` (a slice of a private, read-only file
/// mapping) now, from the calling thread.
///
/// Why: when a large mapping is closed, `munmap` tears down every page
/// table entry on one thread, holding the mm's lock exclusively: 66 ms
/// for a 2.3 GB file, as long as searching it on 16 threads. `MADV_DONTNEED`
/// takes the lock shared, so the threads can each drop their own part as
/// they finish, in parallel, and the final `munmap` has nothing left to do.
/// The file's data stays in the page cache; a dropped page that is read
/// again is simply faulted back in.
///
/// Only whole pages inside `part` are dropped: a page shared with a
/// neighbouring part is left for the final `munmap`.
pub fn dropPages(part: []const u8) void {
    const page = std.heap.pageSize();
    const start = std.mem.alignForward(usize, @intFromPtr(part.ptr), page);
    const end = std.mem.alignBackward(usize, @intFromPtr(part.ptr) + part.len, page);
    if (end <= start) return;
    // Only a hint: if it fails, the pages go at `munmap` as before.
    std.posix.madvise(@ptrFromInt(start), end - start, std.os.linux.MADV.DONTNEED) catch {};
}
