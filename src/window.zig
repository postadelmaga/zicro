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
    else => struct {
        gpa: std.mem.Allocator,
        pub fn init(gpa: std.mem.Allocator, opts: Options) !*@This() {
            _ = opts;
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
