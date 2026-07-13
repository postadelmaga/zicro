//! # zicro.window (Android backend) — NDK NativeActivity, driven by native_app_glue.
//!
//! Same `zicro.window` contract as the desktop backends (`init`/`run`/`presentRgba` +
//! `on_draw`/`on_key`/`on_mouse`/`on_tick`), over the Android NDK. Presentation is the
//! usual zicro CPU path: the app draws into an RGBA buffer; here `blit` copies it into a
//! locked `ANativeWindow` surface (respecting its stride) and posts it. Input comes from
//! the activity's `AInputQueue` as `AInputEvent`s — touch → pointer motion/press/release,
//! hardware/soft keys → `on_key`.
//!
//! The Android activity lifecycle is inverted (the framework owns the loop and hands us
//! the window asynchronously), so an app's entry is `android_main(*android_app)` from
//! native_app_glue: create the `Window`, `attach` the glue `android_app`, then `run`. The
//! FFI is hand-declared (no `@cImport`) in the same spirit as the Wayland/sd-bus glue —
//! only libandroid needs linking. This file compiles for `aarch64-linux-android`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const window = @import("window.zig");
const paint = @import("paint.zig");
const text = @import("text.zig");

pub const Options = window.Options;
pub const MouseEvent = window.MouseEvent;
pub const Rect = window.Rect;

// --- NDK FFI (hand-declared; libandroid at link time) ------------------------------

pub const ANativeWindow = opaque {};
pub const AInputEvent = opaque {};
pub const ALooper = opaque {};
pub const AInputQueue = opaque {};

const ANativeWindow_Buffer = extern struct {
    width: i32,
    height: i32,
    stride: i32,
    format: i32,
    bits: ?*anyopaque,
    reserved: [6]u32,
};
const ARect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

/// The public prefix of native_app_glue's `struct android_app` (accessed only by pointer,
/// so the omitted private glue fields don't matter for field offsets).
pub const android_app = extern struct {
    userData: ?*anyopaque,
    onAppCmd: ?*const fn (*android_app, i32) callconv(.c) void,
    onInputEvent: ?*const fn (*android_app, *AInputEvent) callconv(.c) i32,
    activity: ?*anyopaque,
    config: ?*anyopaque,
    savedState: ?*anyopaque,
    savedStateSize: usize,
    looper: ?*ALooper,
    inputQueue: ?*AInputQueue,
    window: ?*ANativeWindow,
    contentRect: ARect,
    activityState: c_int,
    destroyRequested: c_int,
};

const android_poll_source = extern struct {
    id: i32,
    app: *android_app,
    process: ?*const fn (*android_app, *android_poll_source) callconv(.c) void,
};

extern fn ANativeWindow_setBuffersGeometry(w: *ANativeWindow, width: i32, height: i32, format: i32) i32;
extern fn ANativeWindow_lock(w: *ANativeWindow, out: *ANativeWindow_Buffer, dirty: ?*ARect) i32;
extern fn ANativeWindow_unlockAndPost(w: *ANativeWindow) i32;
extern fn ANativeWindow_getWidth(w: *ANativeWindow) i32;
extern fn ANativeWindow_getHeight(w: *ANativeWindow) i32;
extern fn AInputEvent_getType(e: *const AInputEvent) i32;
extern fn AKeyEvent_getAction(e: *const AInputEvent) i32;
extern fn AKeyEvent_getKeyCode(e: *const AInputEvent) i32;
extern fn AMotionEvent_getAction(e: *const AInputEvent) i32;
extern fn AMotionEvent_getX(e: *const AInputEvent, pointer_index: usize) f32;
extern fn AMotionEvent_getY(e: *const AInputEvent, pointer_index: usize) f32;
extern fn ALooper_pollOnce(timeout_ms: i32, out_fd: ?*i32, out_events: ?*i32, out_data: ?*?*anyopaque) i32;

const WINDOW_FORMAT_RGBA_8888: i32 = 1;
const AINPUT_EVENT_TYPE_KEY: i32 = 1;
const AINPUT_EVENT_TYPE_MOTION: i32 = 2;
const AKEY_EVENT_ACTION_DOWN: i32 = 0;
const AMOTION_EVENT_ACTION_MASK: i32 = 0xff;
const AMOTION_EVENT_ACTION_DOWN: i32 = 0;
const AMOTION_EVENT_ACTION_UP: i32 = 1;
const AMOTION_EVENT_ACTION_MOVE: i32 = 2;
const APP_CMD_INIT_WINDOW: i32 = 1;
const APP_CMD_TERM_WINDOW: i32 = 2;

const BTN_LEFT: u32 = 272; // touch maps to the left-button contract the toolkit expects

// --- the Window ---------------------------------------------------------------------

pub const Window = struct {
    gpa: Allocator,
    opts: Options,
    app: ?*android_app = null,
    native: ?*ANativeWindow = null,
    width: u32,
    height: u32,
    closed: bool = false,
    font: ?text.Font = null,
    /// Owned RGBA backbuffer the app draws into; `blit` copies it into the locked surface
    /// (whose stride may exceed the width).
    backbuf: []u32 = &.{},

    pub fn init(gpa: Allocator, _: std.Io, opts: Options) !*Window {
        const self = try gpa.create(Window);
        self.* = .{ .gpa = gpa, .opts = opts, .width = opts.width, .height = opts.height };
        return self;
    }

    pub fn deinit(self: *Window) void {
        if (self.font) |*f| f.deinit();
        if (self.backbuf.len > 0) self.gpa.free(self.backbuf);
        self.gpa.destroy(self);
    }

    /// Wire this window into native_app_glue's `android_app`: route its command/input
    /// callbacks here. Call once from `android_main` before `run`.
    pub fn attach(self: *Window, app: *android_app) void {
        self.app = app;
        app.userData = self;
        app.onAppCmd = onAppCmd;
        app.onInputEvent = onInputEvent;
        if (app.window) |nw| self.setNative(nw);
    }

    fn setNative(self: *Window, nw: *ANativeWindow) void {
        self.native = nw;
        const w: u32 = @intCast(@max(ANativeWindow_getWidth(nw), 1));
        const h: u32 = @intCast(@max(ANativeWindow_getHeight(nw), 1));
        self.width = w;
        self.height = h;
        _ = ANativeWindow_setBuffersGeometry(nw, @intCast(w), @intCast(h), WINDOW_FORMAT_RGBA_8888);
        self.ensureBackbuf(@as(usize, w) * h);
    }

    fn ensureBackbuf(self: *Window, n: usize) void {
        if (self.backbuf.len >= n) return;
        if (self.backbuf.len > 0) self.gpa.free(self.backbuf);
        self.backbuf = self.gpa.alloc(u32, n) catch &.{};
    }

    pub fn requestRedraw(self: *Window) void {
        _ = self; // the run loop repaints each iteration while the surface is alive
    }
    pub fn requestClose(self: *Window) void {
        self.closed = true;
    }
    pub fn toggleFullscreen(self: *Window) void {
        _ = self; // Android apps are fullscreen; immersive mode is a Java-side flag
    }
    pub fn setMinimized(self: *Window) void {
        _ = self;
    }

    pub fn textFont(self: *Window) !*text.Font {
        if (self.font == null) self.font = try text.Font.initDefault(self.gpa);
        return &self.font.?;
    }

    /// Copy a straight-RGBA frame into the ANativeWindow surface (honoring its stride).
    pub fn presentRgba(self: *Window, w: u32, h: u32, rgba: []const u8) void {
        const nw = self.native orelse return;
        var buf: ANativeWindow_Buffer = std.mem.zeroes(ANativeWindow_Buffer);
        if (ANativeWindow_lock(nw, &buf, null) != 0) return;
        const bits: [*]u8 = @ptrCast(buf.bits orelse {
            _ = ANativeWindow_unlockAndPost(nw);
            return;
        });
        const rows = @min(h, @as(u32, @intCast(@max(buf.height, 0))));
        const cols = @min(w, @as(u32, @intCast(@max(buf.width, 0))));
        const dst_stride: usize = @as(usize, @intCast(@max(buf.stride, 0))) * 4;
        var y: u32 = 0;
        while (y < rows) : (y += 1) {
            const src = rgba[@as(usize, y) * w * 4 ..][0 .. cols * 4];
            const doff = @as(usize, y) * dst_stride;
            @memcpy(bits[doff .. doff + cols * 4], src);
        }
        _ = ANativeWindow_unlockAndPost(nw);
    }

    /// The NativeActivity loop: pump the glue's looper (which dispatches to `onAppCmd`/
    /// `onInputEvent`), then, while the surface is alive, draw a frame and post it. Returns
    /// when the framework requests destruction.
    pub fn run(self: *Window) !void {
        const app = self.app orelse return error.NotAttached;
        while (!self.closed and app.destroyRequested == 0) {
            // ONE poll per iteration with a *recomputed* timeout: block (-1) while there is no
            // surface, else 16 ms so an idle surface still redraws at ~60 fps. On an event
            // (ident ≥ 0) we process it and re-loop (so `native` set by APP_CMD_INIT_WINDOW is
            // seen immediately); on timeout/wake (< 0) we fall through and draw. The previous
            // code captured the timeout before the inner loop could set `native`, so it blocked
            // forever on pollOnce(-1) and never reached the draw — a black screen.
            const timeout: i32 = if (self.native != null) 16 else -1;
            var events: i32 = 0;
            var source: ?*anyopaque = null;
            if (ALooper_pollOnce(timeout, null, &events, &source) >= 0) {
                if (source) |s| {
                    const ps: *android_poll_source = @ptrCast(@alignCast(s));
                    if (ps.process) |proc| proc(app, ps);
                }
                if (app.destroyRequested != 0) return;
                continue;
            }
            if (self.native == null) continue;

            if (self.opts.on_tick) |tick| tick(self, self.opts.user);
            self.ensureBackbuf(@as(usize, self.width) * self.height);
            if (self.backbuf.len < @as(usize, self.width) * self.height) continue;
            var canvas = paint.Canvas.initRgba8(self.backbuf[0 .. self.width * self.height], self.width, self.height);
            if (self.opts.on_draw) |draw| draw(&canvas, self.contentRect(), self.opts.user);
            const bytes: [*]const u8 = @ptrCast(self.backbuf.ptr);
            self.presentRgba(self.width, self.height, bytes[0 .. @as(usize, self.width) * self.height * 4]);
        }
    }

    fn contentRect(self: *const Window) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
    }

    // --- glue callbacks (framework thread) ------------------------------------------

    fn onAppCmd(app: *android_app, cmd: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(app.userData orelse return));
        switch (cmd) {
            APP_CMD_INIT_WINDOW => if (app.window) |nw| self.setNative(nw),
            APP_CMD_TERM_WINDOW => self.native = null,
            else => {},
        }
    }

    fn onInputEvent(app: *android_app, event: *AInputEvent) callconv(.c) i32 {
        const self: *Window = @ptrCast(@alignCast(app.userData orelse return 0));
        switch (AInputEvent_getType(event)) {
            AINPUT_EVENT_TYPE_MOTION => {
                const action = AMotionEvent_getAction(event) & AMOTION_EVENT_ACTION_MASK;
                const x = AMotionEvent_getX(event, 0);
                const y = AMotionEvent_getY(event, 0);
                const kind: MouseEvent.Kind = switch (action) {
                    AMOTION_EVENT_ACTION_DOWN => .press,
                    AMOTION_EVENT_ACTION_UP => .release,
                    else => .motion, // MOVE and everything else is a drag/hover
                };
                if (self.opts.on_mouse) |cb| {
                    // A touch always reports position; press/release also carry the button.
                    if (kind == .motion) {
                        cb(self, .{ .kind = .motion, .x = x, .y = y }, self.opts.user);
                    } else {
                        cb(self, .{ .kind = .motion, .x = x, .y = y }, self.opts.user);
                        cb(self, .{ .kind = kind, .x = x, .y = y, .button = BTN_LEFT }, self.opts.user);
                    }
                }
                return 1;
            },
            AINPUT_EVENT_TYPE_KEY => {
                const pressed = AKeyEvent_getAction(event) == AKEY_EVENT_ACTION_DOWN;
                const code: u32 = @intCast(@max(AKeyEvent_getKeyCode(event), 0));
                if (self.opts.on_key) |cb| cb(self, code, @intFromBool(pressed), self.opts.user);
                return 1;
            },
            else => return 0,
        }
    }
};
