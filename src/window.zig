const std = @import("std");
const builtin = @import("builtin");

pub const paint = @import("paint.zig");
pub const gesture = @import("gesture.zig");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// A pointer event in surface (content) coordinates, y growing downward.
pub const MouseEvent = struct {
    kind: Kind,
    x: f32,
    y: f32,
    /// evdev BTN_* code for press/release (272 = left, 273 = right, 274 = middle).
    button: u32 = 0,
    /// Vertical scroll amount for `.scroll` (positive = content up).
    scroll_dy: f32 = 0,

    pub const Kind = enum { motion, press, release, scroll };
};

pub const Options = struct {
    title: [:0]const u8 = "zicro-shell",
    width: u32 = 720,
    height: u32 = 460,
    on_draw: ?*const fn (canvas: *paint.Canvas, content: Rect, user: ?*anyopaque) void = null,
    on_key: ?*const fn (window: *Window, key: u32, state: u32, user: ?*anyopaque) void = null,
    /// When set, pointer events are delivered to the app and the default
    /// drag-anywhere window move is disabled (UI apps own their clicks).
    on_mouse: ?*const fn (window: *Window, event: MouseEvent, user: ?*anyopaque) void = null,
    /// Gesto multi-touch riconosciuto dal substrato (pinch, …). Un dito arriva come
    /// evento mouse su `on_mouse`; due dita qui (vedi `gesture.zig`).
    on_gesture: ?*const fn (window: *Window, g: gesture.Gesture, user: ?*anyopaque) void = null,
    /// Periodic callback from the event loop (runtime pumps: dispatch queues,
    /// timers, animations). 0 disables ticking and the loop blocks on events.
    on_tick: ?*const fn (window: *Window, user: ?*anyopaque) void = null,
    tick_ms: u32 = 0,
    /// Cap on the LONGER side of the render surface, in pixels (0 = render at the display's
    /// native resolution). Only the Android backend honors it, and there it matters: a CPU
    /// canvas on a 1080×2400 phone is 2.6 M pixels per frame, while the same UI drawn into a
    /// smaller buffer and scaled up by the compositor (free, it's the display hardware) costs
    /// a fraction of that and looks the same at arm's length. `scaleFactor()` folds the
    /// reduction in, so an app keeps sizing its UI in dp and needs to know nothing about it.
    surface_max_dim: u32 = 0,
    /// Ask the compositor for a server-side frame (title bar with close/
    /// minimize/maximize) via xdg-decoration. Default off: zicro shells are
    /// borderless drag-anywhere surfaces; app windows (e.g. zart) opt in.
    /// Falls back silently to borderless when the compositor lacks the
    /// protocol.
    decorations: bool = false,
    /// Fired when a CHILD window (see `Window.initChild`) is torn down — the
    /// compositor closed it or the app set `closed`. The window pointer is
    /// valid only for the duration of the callback; it is destroyed right
    /// after. Root windows signal close by `run()` returning, as before.
    on_close: ?*const fn (window: *Window, user: ?*anyopaque) void = null,
    user: ?*anyopaque = null,
};

pub const Window = switch (builtin.os.tag) {
    // Android is os.tag = .linux, abi = .android: the NDK NativeActivity backend, not
    // Wayland. Plain Linux keeps Wayland.
    .linux => if (builtin.abi == .android or builtin.abi == .androideabi)
        @import("window_android.zig").Window
    else
        @import("window_wayland.zig").Window,
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
