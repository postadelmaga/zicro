//! libc shims for the `wasm32-freestanding` web build: the handful of symbols
//! stb_truetype needs (malloc/free + a few libm functions) that freestanding has no
//! libc to provide. `vendor/stb/stb_truetype_web.c` maps its `STBTT_*` hooks to these,
//! and the inlinable math (floor/ceil/sqrt/fabs → wasm opcodes) is handled with
//! `__builtin_*` there, so this is the whole non-inline surface. Native builds link real
//! libc and never see this file.

const std = @import("std");

// A general-purpose heap over wasm memory.grow. C `free`/`realloc` carry no size, so
// each block is prefixed with its total length (16-byte header keeps the payload
// 16-aligned — enough for every stb struct).
const gpa = std.heap.wasm_allocator;
const hdr_bytes: usize = 16;

export fn zig_malloc(n: usize) ?*anyopaque {
    const total = n + hdr_bytes;
    const block = gpa.alignedAlloc(u8, .@"16", total) catch return null;
    @as(*usize, @ptrCast(@alignCast(block.ptr))).* = total;
    return @ptrCast(block.ptr + hdr_bytes);
}

export fn zig_free(p: ?*anyopaque) void {
    const raw = p orelse return;
    const base = @as([*]u8, @ptrCast(raw)) - hdr_bytes;
    const total = @as(*usize, @ptrCast(@alignCast(base))).*;
    gpa.free(@as([*]align(16) u8, @alignCast(base))[0..total]);
}

// libm surface stb calls that has no wasm opcode (so `__builtin_*` would emit a libcall).
export fn zig_pow(a: f64, b: f64) f64 {
    return std.math.pow(f64, a, b);
}
export fn zig_cos(x: f64) f64 {
    return @cos(x);
}
export fn zig_acos(x: f64) f64 {
    return std.math.acos(x);
}
export fn zig_fmod(a: f64, b: f64) f64 {
    return @rem(a, b); // C fmod: remainder with the sign of the dividend
}
