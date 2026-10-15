//! The pages of docs/, built into the binary for `fds help <topic>`
//! (src/help.zig prints them). Keep in sync with the table in README.md.

pub const Topic = struct {
    name: []const u8,
    summary: []const u8,
    text: []const u8,
};

pub const topics = [_]Topic{
    .{ .name = "search", .summary = "files and directories, rows, the output line, order", .text = @embedFile("search.md") },
    .{ .name = "matching", .summary = "case, whole words, regexes, several terms", .text = @embedFile("matching.md") },
    .{ .name = "many-terms", .summary = "-f: thousands of terms in one pass", .text = @embedFile("many-terms.md") },
    .{ .name = "columns", .summary = "-c, column paths in structs, lists and maps", .text = @embedFile("columns.md") },
    .{ .name = "output", .summary = "--content, --count, -l, -m, --json, colors", .text = @embedFile("output.md") },
    .{ .name = "scripting", .summary = "exit status, pandas and polars, other tools, the C library", .text = @embedFile("scripting.md") },
    .{ .name = "formats", .summary = "what gets searched, and what fds reports it didn't", .text = @embedFile("formats.md") },
};
