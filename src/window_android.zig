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
const gesture = @import("gesture.zig");

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
extern fn AMotionEvent_getPointerCount(e: *const AInputEvent) usize;
extern fn AMotionEvent_getPointerId(e: *const AInputEvent, pointer_index: usize) i32;
extern fn ALooper_pollOnce(timeout_ms: i32, out_fd: ?*i32, out_events: ?*i32, out_data: ?*?*anyopaque) i32;
extern fn AConfiguration_getDensity(config: ?*anyopaque) i32;
extern fn __android_log_print(prio: c_int, tag: [*:0]const u8, fmt: [*:0]const u8, ...) c_int;

const WINDOW_FORMAT_RGBA_8888: i32 = 1;
const AINPUT_EVENT_TYPE_KEY: i32 = 1;
const AINPUT_EVENT_TYPE_MOTION: i32 = 2;
const AKEY_EVENT_ACTION_DOWN: i32 = 0;
const AMOTION_EVENT_ACTION_MASK: i32 = 0xff;
const AMOTION_EVENT_ACTION_DOWN: i32 = 0;
const AMOTION_EVENT_ACTION_UP: i32 = 1;
const AMOTION_EVENT_ACTION_MOVE: i32 = 2;
const AMOTION_EVENT_ACTION_CANCEL: i32 = 3;
const AMOTION_EVENT_ACTION_POINTER_DOWN: i32 = 5;
const AMOTION_EVENT_ACTION_POINTER_UP: i32 = 6;
const AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT: u5 = 8;
const APP_CMD_INIT_WINDOW: i32 = 1;
const APP_CMD_TERM_WINDOW: i32 = 2;
const APP_CMD_WINDOW_RESIZED: i32 = 3;
const APP_CMD_CONFIG_CHANGED: i32 = 8;

const BTN_LEFT: u32 = 272; // touch maps to the left-button contract the toolkit expects

/// Monotonic clock in nanoseconds (std.time lost its timestamp helpers; the syscall is
/// right there). Used only for the frame profile.
fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Recognizer gesti condiviso (una sola activity/finestra su Android).
var touch_recognizer: gesture.Recognizer = .{};

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
    /// Display width in pixels, BEFORE any `surface_max_dim` reduction — the denominator of
    /// the scale correction in `scaleFactor` and of the touch coordinate mapping.
    display_w: u32 = 0,
    /// A frame is only drawn (and posted) when something changed: input, a resize, or an app
    /// that asked for another one (`requestRedraw`, e.g. mid-animation). A CPU-rasterized UI
    /// that repaints an unchanged screen 60 times a second is pure battery burn — and on this
    /// hardware it also starves the very touch handling it is redrawing for.
    dirty: bool = true,
    // Contatori del profilo di frame (vedi il log in `run`).
    frame_ns: u64 = 0,
    present_ns: u64 = 0,
    frames: u32 = 0,

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
        // Reset to the window's native size (0,0) with our pixel format, THEN read the size —
        // so after a rotation we pick up the new dimensions, not the stale ones.
        _ = ANativeWindow_setBuffersGeometry(nw, 0, 0, WINDOW_FORMAT_RGBA_8888);
        const dw: u32 = @intCast(@max(ANativeWindow_getWidth(nw), 1));
        const dh: u32 = @intCast(@max(ANativeWindow_getHeight(nw), 1));
        self.display_w = dw;
        _ = __android_log_print(4, "zicro", "setNative: display=%dx%d cap=%d", dw, dh, self.opts.surface_max_dim);

        // Render surface: the display's own resolution unless the app capped it
        // (`surface_max_dim`). A smaller buffer means proportionally fewer pixels for the CPU
        // rasterizer — the display scaler blows it back up for free. The aspect ratio is
        // preserved, or the image would be stretched.
        var w = dw;
        var h = dh;
        const cap = self.opts.surface_max_dim;
        if (cap > 0 and @max(dw, dh) > cap) {
            const s = @as(f32, @floatFromInt(cap)) / @as(f32, @floatFromInt(@max(dw, dh)));
            w = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(dw)) * s)));
            h = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(dh)) * s)));
            _ = ANativeWindow_setBuffersGeometry(nw, @intCast(w), @intCast(h), WINDOW_FORMAT_RGBA_8888);
        }
        self.width = w;
        self.height = h;
        self.ensureBackbuf(@as(usize, w) * h);
        self.dirty = true;
    }

    fn ensureBackbuf(self: *Window, n: usize) void {
        if (self.backbuf.len >= n) return;
        if (self.backbuf.len > 0) self.gpa.free(self.backbuf);
        self.backbuf = self.gpa.alloc(u32, n) catch &.{};
    }

    /// Ask for one more frame. An app calls this while something is animating; when it stops,
    /// the loop goes quiet by itself (see `dirty`).
    pub fn requestRedraw(self: *Window) void {
        self.dirty = true;
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

    /// Pixels per dp IN THE RENDER SURFACE: the display density (density/160 — 1.0 at mdpi,
    /// ~2.75 at 440 dpi) scaled down by whatever `surface_max_dim` shrank the buffer to. An
    /// app multiplies its dp sizes by this and gets physically-correct UI either way; the
    /// reduced-resolution surface stays an invisible implementation detail.
    pub fn scaleFactor(self: *const Window) f32 {
        const app = self.app orelse return 1;
        const cfg = app.config orelse return 1;
        const d = AConfiguration_getDensity(cfg);
        if (d <= 0 or d == 0xffff) return 1; // 0 = default/unset, 0xffff = ACONFIGURATION_DENSITY_NONE
        var s = @as(f32, @floatFromInt(d)) / 160.0;
        if (self.display_w > 0 and self.width > 0 and self.width != self.display_w) {
            s *= @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.display_w));
        }
        return s;
    }

    /// Touch coordinates arrive in DISPLAY pixels; the app draws in SURFACE pixels. When the
    /// surface is smaller, every pointer position must be scaled or the taps land off-target.
    fn touchScale(self: *const Window) f32 {
        if (self.display_w == 0 or self.width == 0) return 1;
        return @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.display_w));
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
            // Nothing changed since the last frame: don't rasterize an identical screen.
            if (!self.dirty) continue;
            self.dirty = false;

            if (self.opts.on_tick) |tick| tick(self, self.opts.user);
            self.ensureBackbuf(@as(usize, self.width) * self.height);
            if (self.backbuf.len < @as(usize, self.width) * self.height) {
                _ = __android_log_print(6, "zicro", "backbuf insufficiente: %d < %dx%d", @as(c_int, @intCast(self.backbuf.len)), self.width, self.height);
                continue;
            }
            if (self.frames == 0) _ = __android_log_print(4, "zicro", "primo frame: %dx%d user=%d", self.width, self.height, @as(c_int, @intFromBool(self.opts.user != null)));
            const t0 = nowNs();
            var canvas = paint.Canvas.initRgba8(self.backbuf[0 .. self.width * self.height], self.width, self.height);
            if (self.opts.on_draw) |draw| draw(&canvas, self.contentRect(), self.opts.user);
            const t1 = nowNs();
            const bytes: [*]const u8 = @ptrCast(self.backbuf.ptr);
            self.presentRgba(self.width, self.height, bytes[0 .. @as(usize, self.width) * self.height * 4]);
            const t2 = nowNs();
            // Profilo del frame (ZICRO_FRAME_LOG): quanto costa DAVVERO disegnare e quanto
            // postare. Senza questi due numeri, ottimizzare un rasterizzatore è tirare a
            // indovinare; con questi, si sa subito da che parte sta il collo di bottiglia.
            self.frame_ns += t1 - t0;
            self.present_ns += t2 - t1;
            self.frames += 1;
            if (self.frames == 60) {
                _ = __android_log_print(4, "zicro", "frame: draw %.1f ms · present %.1f ms (%dx%d)", @as(f64, @floatFromInt(self.frame_ns)) / 60e6, @as(f64, @floatFromInt(self.present_ns)) / 60e6, self.width, self.height);
                self.frames = 0;
                self.frame_ns = 0;
                self.present_ns = 0;
            }
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
            // Rotation / resize: re-read the surface geometry (and re-set the buffer format),
            // otherwise we present at the old dimensions and the image is skewed.
            APP_CMD_WINDOW_RESIZED, APP_CMD_CONFIG_CHANGED => if (app.window) |nw| self.setNative(nw),
            else => {},
        }
    }

    /// Un campione touch nel recognizer condiviso; ne inoltra gli eventi (un dito → mouse,
    /// due dita → pinch su `on_gesture`).
    fn feedTouch(self: *Window, id: i32, phase: gesture.Phase, raw_x: f32, raw_y: f32) void {
        // Ogni tocco muove qualcosa: il prossimo frame va disegnato.
        self.dirty = true;
        const s = self.touchScale();
        const x = raw_x * s;
        const y = raw_y * s;
        var out: [2]gesture.Out = undefined;
        for (touch_recognizer.push(id, phase, x, y, &out)) |ev| switch (ev) {
            .pointer_down => |p| if (self.opts.on_mouse) |cb| {
                cb(self, .{ .kind = .motion, .x = p.x, .y = p.y }, self.opts.user);
                cb(self, .{ .kind = .press, .x = p.x, .y = p.y, .button = BTN_LEFT }, self.opts.user);
            },
            .pointer_move => |p| if (self.opts.on_mouse) |cb| cb(self, .{ .kind = .motion, .x = p.x, .y = p.y }, self.opts.user),
            .pointer_up => |p| if (self.opts.on_mouse) |cb| {
                cb(self, .{ .kind = .motion, .x = p.x, .y = p.y }, self.opts.user);
                cb(self, .{ .kind = .release, .x = p.x, .y = p.y, .button = BTN_LEFT }, self.opts.user);
            },
            .pinch => |g| if (self.opts.on_gesture) |cb| cb(self, g, self.opts.user),
        };
    }

    fn onInputEvent(app: *android_app, event: *AInputEvent) callconv(.c) i32 {
        const self: *Window = @ptrCast(@alignCast(app.userData orelse return 0));
        switch (AInputEvent_getType(event)) {
            AINPUT_EVENT_TYPE_MOTION => {
                // Multi-touch attraverso il recognizer condiviso `gesture.zig` (stesso di web):
                // un dito → eventi mouse, due dita → pinch su `on_gesture`.
                const raw = AMotionEvent_getAction(event);
                const action = raw & AMOTION_EVENT_ACTION_MASK;
                const idx: usize = @intCast((raw >> AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT) & 0xff);
                switch (action) {
                    AMOTION_EVENT_ACTION_DOWN, AMOTION_EVENT_ACTION_POINTER_DOWN => self.feedTouch(
                        AMotionEvent_getPointerId(event, idx),
                        .down,
                        AMotionEvent_getX(event, idx),
                        AMotionEvent_getY(event, idx),
                    ),
                    AMOTION_EVENT_ACTION_UP, AMOTION_EVENT_ACTION_POINTER_UP, AMOTION_EVENT_ACTION_CANCEL => self.feedTouch(
                        AMotionEvent_getPointerId(event, idx),
                        .up,
                        AMotionEvent_getX(event, idx),
                        AMotionEvent_getY(event, idx),
                    ),
                    else => { // MOVE: aggiorna tutti i pointer
                        var i: usize = 0;
                        const count = AMotionEvent_getPointerCount(event);
                        while (i < count) : (i += 1) self.feedTouch(
                            AMotionEvent_getPointerId(event, i),
                            .move,
                            AMotionEvent_getX(event, i),
                            AMotionEvent_getY(event, i),
                        );
                    },
                }
                return 1;
            },
            AINPUT_EVENT_TYPE_KEY => {
                const pressed = AKeyEvent_getAction(event) == AKEY_EVENT_ACTION_DOWN;
                const code: u32 = @intCast(@max(AKeyEvent_getKeyCode(event), 0));
                self.dirty = true;
                if (self.opts.on_key) |cb| cb(self, code, @intFromBool(pressed), self.opts.user);
                return 1;
            },
            else => return 0,
        }
    }
};
