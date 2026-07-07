const std = @import("std");
const builtin = @import("builtin");

pub const paint = @import("paint.zig");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const Options = struct {
    title: [:0]const u8 = "zicro-shell",
    width: u32 = 720,
    height: u32 = 460,
    on_draw: ?*const fn (canvas: *paint.Canvas, content: Rect, user: ?*anyopaque) void = null,
    on_key: ?*const fn (window: *Window, key: u32, state: u32, user: ?*anyopaque) void = null,
    user: ?*anyopaque = null,
};

pub const Window = switch (builtin.os.tag) {
    .linux => @import("window_wayland.zig").Window,
    .windows => @import("window_win32.zig").Window,
    .macos => @import("window_cocoa.zig").Window,
    // Z-Scenic (Z#76 phase 2): Z's freestanding userspace target. Zicro
    // itself never natively targets `.freestanding` (its own build.zig has
    // no such target), so this branch is only ever selected when Z's
    // build.zig cross-compiles Zicro code with -Dzicro-src — and that build
    // always wires the "zrt"/"scenic_protocol" modules window_z.zig needs,
    // the same way Zisky's build.zig always wires "zrt"/"gfx_config" for
    // its own freestanding programs.
    .freestanding => @import("window_z.zig").Window,
    else => struct {
        gpa: std.mem.Allocator,
        pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) !*@This() {
            _ = opts;
            _ = io;
            const self = try gpa.create(@This());
            self.* = .{ .gpa = gpa };
            return self;
        }
        pub fn deinit(self: *@This()) void {
            self.gpa.destroy(self);
        }
        pub fn run(self: *@This()) !void {
            _ = self;
        }
        pub fn presentRgba(self: *@This(), w: u32, h: u32, rgba: []const u8) void {
            _ = self; _ = w; _ = h; _ = rgba;
        }
        pub fn toggleFullscreen(self: *@This()) void {
            _ = self;
        }
        pub fn setMinimized(self: *@This()) void {
            _ = self;
        }
    },
};
