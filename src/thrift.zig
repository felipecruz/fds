//! A minimal reader for Thrift's compact protocol, which Parquet uses for
//! its footer and page headers. Structs are read field by field: the caller
//! keeps the fields it knows and skips the rest, so newer writers' extra
//! fields are fine. Every read is bounds-checked, and nesting is capped, so
//! a malformed header is `error.Malformed`, never a crash or a runaway.
//!
//! Spec: https://github.com/apache/thrift/blob/master/doc/specs/thrift-compact-protocol.md

const std = @import("std");

pub const Error = error{Malformed};

pub const Type = enum(u4) {
    stop = 0,
    bool_true = 1,
    bool_false = 2,
    i8 = 3,
    i16 = 4,
    i32 = 5,
    i64 = 6,
    double = 7,
    binary = 8,
    list = 9,
    set = 10,
    map = 11,
    @"struct" = 12,
    _,
};

pub const Field = struct { id: i16, type: Type };

pub const List = struct { len: usize, elem: Type };

const max_depth = 32;

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    /// Iterates the fields of a struct; call after its start (structs have
    /// no header). Returns null at the struct's end.
    pub fn field(r: *Reader, last_id: *i16) Error!?Field {
        const b = try r.byte();
        if (b == 0) return null;
        const delta: i16 = b >> 4;
        const id = if (delta == 0) std.math.cast(i16, try r.zigzag()) orelse return error.Malformed else last_id.* +% delta;
        last_id.* = id;
        return .{ .id = id, .type = @enumFromInt(@as(u4, @truncate(b))) };
    }

    pub fn list(r: *Reader) Error!List {
        const b = try r.byte();
        var len: usize = b >> 4;
        if (len == 15) len = std.math.cast(usize, try r.varint()) orelse return error.Malformed;
        // Every element takes at least a byte: a longer list can't be real.
        if (len > r.buf.len - r.pos) return error.Malformed;
        return .{ .len = len, .elem = @enumFromInt(@as(u4, @truncate(b))) };
    }

    pub fn int(r: *Reader, comptime T: type, t: Type) Error!T {
        if (t != .i8 and t != .i16 and t != .i32 and t != .i64) return error.Malformed;
        if (t == .i8) return std.math.cast(T, @as(i8, @bitCast(try r.byte()))) orelse error.Malformed;
        return std.math.cast(T, try r.zigzag()) orelse error.Malformed;
    }

    pub fn binary(r: *Reader, t: Type) Error![]const u8 {
        if (t != .binary) return error.Malformed;
        const len = std.math.cast(usize, try r.varint()) orelse return error.Malformed;
        if (len > r.buf.len - r.pos) return error.Malformed;
        defer r.pos += len;
        return r.buf[r.pos..][0..len];
    }

    /// A bool field's value is its type.
    pub fn boolean(_: *Reader, t: Type) Error!bool {
        return switch (t) {
            .bool_true => true,
            .bool_false => false,
            else => error.Malformed,
        };
    }

    /// Skips a value of type `t`.
    pub fn skip(r: *Reader, t: Type) Error!void {
        return r.skipDepth(t, 0);
    }

    fn skipDepth(r: *Reader, t: Type, depth: usize) Error!void {
        if (depth > max_depth) return error.Malformed;
        switch (t) {
            .bool_true, .bool_false => {},
            .i8 => _ = try r.byte(),
            .i16, .i32, .i64 => _ = try r.varint(),
            .double => try r.advance(8),
            .binary => _ = try r.binary(.binary),
            .list, .set => {
                const l = try r.list();
                for (0..l.len) |_| try r.skipElement(l.elem, depth + 1);
            },
            .map => {
                const len = std.math.cast(usize, try r.varint()) orelse return error.Malformed;
                if (len == 0) return;
                const kv = try r.byte();
                // Every entry takes at least two bytes: a longer map can't be real.
                if (len > (r.buf.len - r.pos) / 2) return error.Malformed;
                const k: Type = @enumFromInt(@as(u4, @truncate(kv >> 4)));
                const v: Type = @enumFromInt(@as(u4, @truncate(kv)));
                for (0..len) |_| {
                    try r.skipElement(k, depth + 1);
                    try r.skipElement(v, depth + 1);
                }
            },
            .@"struct" => {
                var last: i16 = 0;
                while (try r.field(&last)) |f| try r.skipDepth(f.type, depth + 1);
            },
            .stop, _ => return error.Malformed,
        }
    }

    /// Skips an element of a list, set or map, where a bool takes a byte
    /// (in a struct, a bool field's value is its type).
    fn skipElement(r: *Reader, t: Type, depth: usize) Error!void {
        if (t == .bool_true or t == .bool_false) _ = try r.byte() else try r.skipDepth(t, depth);
    }

    fn byte(r: *Reader) Error!u8 {
        if (r.pos >= r.buf.len) return error.Malformed;
        defer r.pos += 1;
        return r.buf[r.pos];
    }

    fn advance(r: *Reader, n: usize) Error!void {
        if (n > r.buf.len - r.pos) return error.Malformed;
        r.pos += n;
    }

    fn varint(r: *Reader) Error!u64 {
        var v: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try r.byte();
            v |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return v;
            shift += 7;
            if (shift > 63) return error.Malformed;
        }
    }

    fn zigzag(r: *Reader) Error!i64 {
        const v = try r.varint();
        return @as(i64, @bitCast(v >> 1)) ^ -@as(i64, @intCast(v & 1));
    }
};

test "read a struct, skipping unknown fields" {
    // struct { 1: i32 = -3, 2: binary = "ab", 4: list<i32> = [1, 2],
    //          20: struct { 1: bool = true }, 21: i64 = 300 }
    const buf = "\x15\x05" ++ "\x18\x02ab" ++ "\x29\x25\x02\x04" ++ "\x0c\x28" ++ "\x11\x00" ++ "\x16\xd8\x04" ++ "\x00";
    var r: Reader = .{ .buf = buf };
    var last: i16 = 0;
    var seen: [3]bool = @splat(false);
    while (try r.field(&last)) |f| switch (f.id) {
        1 => {
            try std.testing.expectEqual(-3, try r.int(i32, f.type));
            seen[0] = true;
        },
        2 => {
            try std.testing.expectEqualStrings("ab", try r.binary(f.type));
            seen[1] = true;
        },
        21 => {
            try std.testing.expectEqual(300, try r.int(i64, f.type));
            seen[2] = true;
        },
        else => try r.skip(f.type),
    };
    try std.testing.expectEqual([3]bool{ true, true, true }, seen);
    try std.testing.expectEqual(buf.len, r.pos);

    // Truncated anywhere: an error, never a crash.
    for (0..buf.len) |n| {
        var t: Reader = .{ .buf = buf[0..n] };
        try std.testing.expectError(error.Malformed, t.skip(.@"struct"));
    }
}

test "a map longer than its bytes is malformed, not a runaway" {
    // map, 2^63 - 1 entries of bool -> bool, in a few bytes.
    const buf = "\xff\xff\xff\xff\xff\xff\xff\xff\x7f\x11" ++ "\x01\x01";
    var r: Reader = .{ .buf = buf };
    try std.testing.expectError(error.Malformed, r.skip(.map));

    // map<bool, bool> { true: false }: a byte per bool.
    var ok: Reader = .{ .buf = "\x01\x11\x01\x02" };
    try ok.skip(.map);
    try std.testing.expectEqual(4, ok.pos);
}
