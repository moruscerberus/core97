// lib/mem.zig - freestanding libc-style memory builtins
// Without libc or Zig's std runtime, we have to define these
// "compiler-generated" functions ourselves, which Zig (and its own
// std.debug) sometimes expects to be available.

pub export fn memset(dest: ?[*]u8, val: c_int, len: usize) callconv(.C) ?[*]u8 {
    if (dest) |d| {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            d[i] = @as(u8, @truncate(@as(c_uint, @bitCast(val))));
        }
    }
    return dest;
}

pub export fn memcpy(dest: ?[*]u8, src: ?[*]const u8, len: usize) callconv(.C) ?[*]u8 {
    if (dest) |d| {
        if (src) |s| {
            var i: usize = 0;
            while (i < len) : (i += 1) {
                d[i] = s[i];
            }
        }
    }
    return dest;
}

pub export fn memmove(dest: ?[*]u8, src: ?[*]const u8, len: usize) callconv(.C) ?[*]u8 {
    if (dest) |d| {
        if (src) |s| {
            if (@intFromPtr(d) < @intFromPtr(s)) {
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    d[i] = s[i];
                }
            } else {
                var i: usize = len;
                while (i > 0) {
                    i -= 1;
                    d[i] = s[i];
                }
            }
        }
    }
    return dest;
}
