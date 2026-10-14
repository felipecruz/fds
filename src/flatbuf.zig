//! A minimal FlatBuffers reader: tables, scalars, strings, vectors and
//! union values, which is all the Arrow metadata needs. Every offset is
//! bounds-checked: a malformed file is `error.Malformed`, never a crash.

const std = @import("std");

pub const Error = error{Malformed};

pub const Table = struct {
    buf: []const u8,
    pos: usize, // the table's start
    vtable: usize,
    vtable_len: usize,

    /// The root table of a buffer.
    pub fn root(buf: []const u8) Error!Table {
        return at(buf, try deref(buf, 0));
    }

    fn at(buf: []const u8, pos: usize) Error!Table {
        const soff = try readInt(i32, buf, pos);
        const vt = @as(i64, @intCast(pos)) - soff;
        if (vt < 0) return error.Malformed;
        const vtable: usize = @intCast(vt);
        const vtable_len = try readInt(u16, buf, vtable);
        if (vtable_len < 4 or vtable_len > buf.len - vtable) return error.Malformed;
        const table_len = try readInt(u16, buf, vtable + 2);
        if (table_len > buf.len - pos) return error.Malformed;
        return .{ .buf = buf, .pos = pos, .vtable = vtable, .vtable_len = vtable_len };
    }

    // Where field `id` is stored, or null if absent (it has its default).
    fn field(t: Table, id: u16) Error!?usize {
        const slot = 4 + 2 * @as(usize, id);
        if (slot + 2 > t.vtable_len) return null;
        const off = try readInt(u16, t.buf, t.vtable + slot);
        return if (off == 0) null else t.pos + off;
    }

    pub fn scalar(t: Table, comptime T: type, id: u16, default: T) Error!T {
        const p = try t.field(id) orelse return default;
        if (T == bool) return try readInt(u8, t.buf, p) != 0;
        return readInt(T, t.buf, p);
    }

    pub fn table(t: Table, id: u16) Error!?Table {
        const p = try t.field(id) orelse return null;
        return try at(t.buf, try deref(t.buf, p));
    }

    pub fn string(t: Table, id: u16) Error!?[]const u8 {
        const p = try t.field(id) orelse return null;
        const s = try deref(t.buf, p);
        const len = try readInt(u32, t.buf, s);
        if (len > t.buf.len - s - 4) return error.Malformed;
        return t.buf[s + 4 ..][0..len];
    }

    /// A vector of `elem_size`-byte elements (4 for tables).
    pub fn vector(t: Table, id: u16, elem_size: usize) Error!?Vector {
        const p = try t.field(id) orelse return null;
        const v = try deref(t.buf, p);
        const len = try readInt(u32, t.buf, v);
        if (len > (t.buf.len - v - 4) / elem_size) return error.Malformed;
        return .{ .buf = t.buf, .start = v + 4, .len = len, .elem_size = elem_size };
    }
};

pub const Vector = struct {
    buf: []const u8,
    start: usize, // first element
    len: usize,
    elem_size: usize,

    pub fn table(v: Vector, i: usize) Error!Table {
        if (i >= v.len) return error.Malformed;
        return Table.at(v.buf, try deref(v.buf, v.start + 4 * i));
    }

    /// The integer at byte `offset` of element `i` (for vectors of structs
    /// or scalars).
    pub fn int(v: Vector, comptime T: type, i: usize, offset: usize) Error!T {
        if (i >= v.len or offset + @sizeOf(T) > v.elem_size) return error.Malformed;
        return readInt(T, v.buf, v.start + i * v.elem_size + offset);
    }
};

// Follows the u32 offset stored at `p`.
fn deref(buf: []const u8, p: usize) Error!usize {
    const off = try readInt(u32, buf, p);
    if (off > buf.len - p) return error.Malformed;
    return p + off;
}

pub fn readInt(comptime T: type, buf: []const u8, p: usize) Error!T {
    if (p > buf.len or buf.len - p < @sizeOf(T)) return error.Malformed;
    return std.mem.readInt(T, buf[p..][0..@sizeOf(T)], .little);
}

test "malformed offsets are errors" {
    const t = std.testing;
    try t.expectError(error.Malformed, Table.root(""));
    try t.expectError(error.Malformed, Table.root("\xff\xff\xff\xff"));
    // Root at 4; its soffset points at a vtable before the buffer.
    try t.expectError(error.Malformed, Table.root("\x04\x00\x00\x00\x00\x01\x00\x00"));
}
