//! `fds help [topic]`: the pages of docs/ (built in; see docs/help.zig),
//! printed for a terminal.
//!
//! The pages are Markdown, written to read well as plain text too, so
//! rendering is light: headings in bold, code blocks indented, tables
//! aligned, `code` and **bold** markers dropped (bold kept with colors),
//! and links reduced to their text, or `fds help <topic>` for a link to
//! another page.

const std = @import("std");
const Io = std.Io;
const docs = @import("docs");

pub fn find(name: []const u8) ?docs.Topic {
    for (docs.topics) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

/// The list of topics, for `fds help`.
pub fn writeIndex(w: *Io.Writer, color: bool) !void {
    try w.print("{s}fds help <topic>{s}: the documentation, in the terminal\n\n", .{ on(color, bold), on(color, reset) });
    for (docs.topics) |t| try w.print("  {s}{s: <11}{s} {s}\n", .{ on(color, bold), t.name, on(color, reset), t.summary });
    try w.writeAll("\nAlso as a man page (man fds), and on GitHub: docs/README.md.\n");
}

/// Writes a page of Markdown for a terminal.
pub fn render(w: *Io.Writer, text: []const u8, color: bool) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var code = false;
    var table: [64][]const u8 = undefined;
    var rows: usize = 0;
    while (lines.next()) |line| {
        // A table is collected whole, to align its columns.
        if (!code and std.mem.startsWith(u8, line, "|")) {
            if (rows < table.len) table[rows] = line;
            rows += 1;
            continue;
        }
        if (rows > 0) {
            try writeTable(w, table[0..@min(rows, table.len)], color);
            rows = 0;
        }
        if (std.mem.startsWith(u8, line, "```")) {
            code = !code;
            continue;
        }
        if (code) {
            try w.print("    {s}\n", .{line});
        } else if (std.mem.startsWith(u8, line, "#")) {
            const title = std.mem.trimStart(u8, line, "# ");
            try w.writeAll(on(color, bold));
            try writeInline(w, title, false);
            try w.print("{s}\n", .{on(color, reset)});
            // The page title, underlined without colors.
            if (!color and !std.mem.startsWith(u8, line, "##")) {
                for (0..title.len) |_| try w.writeByte('=');
                try w.writeByte('\n');
            }
        } else {
            try writeInline(w, line, color);
            try w.writeByte('\n');
        }
    }
    if (rows > 0) try writeTable(w, table[0..@min(rows, table.len)], color);
}

const bold = "\x1b[1m";
const reset = "\x1b[0m";

fn on(color: bool, code: []const u8) []const u8 {
    return if (color) code else "";
}

// One line of text: `code` and links simplified, **bold** shown as bold
// (or dropped without colors).
fn writeInline(w: *Io.Writer, line: []const u8, color: bool) !void {
    var i: usize = 0;
    var in_bold = false;
    while (i < line.len) {
        const c = line[i];
        if (c == '`') {
            const end = std.mem.indexOfScalarPos(u8, line, i + 1, '`') orelse line.len;
            try w.writeAll(line[i + 1 .. end]);
            i = @min(line.len, end + 1);
        } else if (c == '*' and i + 1 < line.len and line[i + 1] == '*') {
            in_bold = !in_bold;
            try w.writeAll(on(color, if (in_bold) bold else reset));
            i += 2;
        } else if (c == '[') {
            if (link(line, i)) |l| {
                try writeInline(w, l.text, color);
                try writeTarget(w, l.target);
                i = l.end;
            } else {
                try w.writeByte(c);
                i += 1;
            }
        } else {
            try w.writeByte(c);
            i += 1;
        }
    }
}

const Link = struct { text: []const u8, target: []const u8, end: usize };

// `[text](target)` starting at line[i], if there is one.
fn link(line: []const u8, i: usize) ?Link {
    const close = std.mem.indexOfScalarPos(u8, line, i + 1, ']') orelse return null;
    if (close + 1 >= line.len or line[close + 1] != '(') return null;
    const end = std.mem.indexOfScalarPos(u8, line, close + 2, ')') orelse return null;
    return .{ .text = line[i + 1 .. close], .target = line[close + 2 .. end], .end = end + 1 };
}

// After a link's text: where it leads, when the terminal can follow.
fn writeTarget(w: *Io.Writer, target: []const u8) !void {
    if (std.mem.startsWith(u8, target, "http")) return w.print(" <{s}>", .{target});
    const file = target[0 .. std.mem.indexOfScalar(u8, target, '#') orelse target.len];
    if (std.mem.endsWith(u8, file, ".md")) {
        if (find(file[0 .. file.len - 3])) |t| return w.print(" (fds help {s})", .{t.name});
    }
}

// A Markdown table, its columns aligned; the |---| line is dropped.
fn writeTable(w: *Io.Writer, rows: []const []const u8, color: bool) !void {
    var cells: [64][8][]const u8 = undefined;
    var counts: [64]usize = undefined;
    var widths: [8]usize = @splat(0);
    var n: usize = 0;
    for (rows) |row| {
        if (std.mem.trim(u8, row, "|:- ").len == 0) continue; // |:---|---:|
        var k: usize = 0;
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, row, "| "), '|');
        while (it.next()) |cell| : (k += 1) {
            if (k == 8) break;
            cells[n][k] = std.mem.trim(u8, cell, " ");
            widths[k] = @max(widths[k], plainLen(cells[n][k]));
        }
        counts[n] = k;
        n += 1;
    }
    for (cells[0..n], counts[0..n], 0..) |row, k, r| {
        try w.writeAll("  ");
        for (row[0..k], 0..) |cell, j| {
            if (r == 0) try w.writeAll(on(color, bold));
            try writeInline(w, cell, color and r > 0);
            if (r == 0) try w.writeAll(on(color, reset));
            if (j + 1 < k) for (0..widths[j] - plainLen(cell) + 2) |_| try w.writeByte(' ');
        }
        try w.writeByte('\n');
    }
}

// The width of a cell once its markup is dropped.
fn plainLen(cell: []const u8) usize {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    writeInline(&w, cell, false) catch return cell.len;
    return w.buffered().len;
}

const testing = std.testing;

test "rendering" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try render(&w,
        \\# Title
        \\Use `-c` with **care**; see [Columns](columns.md#x) or [it](https://x.y).
        \\
        \\```console
        \\$ fds a b
        \\```
        \\| A | Bee |
        \\|:--|:--|
        \\| `long cell` | b |
    , false);
    try testing.expectEqualStrings(
        \\Title
        \\=====
        \\Use -c with care; see Columns (fds help columns) or it <https://x.y>.
        \\
        \\    $ fds a b
        \\  A          Bee
        \\  long cell  b
        \\
    , w.buffered());
}

test "every page renders, and links between pages name topics" {
    var buf: [64 << 10]u8 = undefined;
    for (docs.topics) |t| {
        var w: Io.Writer = .fixed(&buf);
        try render(&w, t.text, true);
        try testing.expect(w.buffered().len > 0);
    }
}
