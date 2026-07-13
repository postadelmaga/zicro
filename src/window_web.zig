//! `window_web` — the WebAssembly backend for the `zicro.window` contract.
//!
//! Same public surface as the native backends (Wayland/Win32/Cocoa): an app builds an
//! `Options` with `on_draw`/`on_key`/`on_mouse`/`on_tick` and never learns which OS — or
//! that it's a browser — it runs on. A source using `zicro.window.Window`/`Options`
//! compiles unchanged for native and for the web (the field names match `window.zig`);
//! the web build just swaps this module in as `zicro.window`.
//!
//! The one structural difference is the loop: a native `run()` blocks and pumps the
//! compositor; the browser owns the event loop, so here JS drives — it calls the exported
//! ABI (`zicroFrame`/`zicroPointerMove`/`zicroKey`/…) each requestAnimationFrame, and
//! those dispatch to the single active window's callbacks. `run()` just arms it and
//! returns. `on_draw` gets a `Canvas` over the window's straight-RGBA buffer (exactly a
//! browser `ImageData`), which the JS glue blits with one `putImageData`.
//!
//! The types below mirror `window.zig` field-for-field on purpose — kept separate so the
//! web build never evaluates that file's native-backend `switch` (which would pull in a
//! Wayland/Z backend that can't exist on a wasm page).

const std = @import("std");
const paint = @import("paint.zig");
const widget = @import("widget.zig");

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// A pointer event in content coordinates, y growing downward (mirrors `window.MouseEvent`).
pub const MouseEvent = struct {
    kind: Kind,
    x: f32,
    y: f32,
    button: u32 = 0,
    scroll_dy: f32 = 0,
    pub const Kind = enum { motion, press, release, scroll };
};

pub const Options = struct {
    title: [:0]const u8 = "zicro-web",
    width: u32 = 1000,
    height: u32 = 720,
    on_draw: ?*const fn (canvas: *paint.Canvas, content: Rect, user: ?*anyopaque) void = null,
    on_key: ?*const fn (window: *Window, key: u32, state: u32, user: ?*anyopaque) void = null,
    on_mouse: ?*const fn (window: *Window, event: MouseEvent, user: ?*anyopaque) void = null,
    on_tick: ?*const fn (window: *Window, user: ?*anyopaque) void = null,
    tick_ms: u32 = 0,
    decorations: bool = false,
    on_close: ?*const fn (window: *Window, user: ?*anyopaque) void = null,
    user: ?*anyopaque = null,
};

// One straight-RGBA8888 framebuffer (a browser page is single-window, single-threaded).
// Sized for a 4K drawable so a HiDPI (devicePixelRatio 2) window still renders at native
// physical pixels; JS clamps to whatever `zicroWidth/Height` report if it ever overflows.
const MAX_W: u32 = 3840;
const MAX_H: u32 = 2160;
var backbuf: [MAX_W * MAX_H]u32 = undefined;

/// The window JS is currently driving. Set by `init`/`run`, read by the exported ABI.
var active: ?*Window = null;
/// The latest frame timestamp (ms) JS passed to `zicroFrame` — the browser clock the app
/// reads via `nowMs()` (wasm freestanding has no `std.os` clock).
var frame_now_ms: i64 = 0;
/// The compositor/display scale: `window.devicePixelRatio`. The framebuffer is sized in
/// physical pixels; an app reads this via `scaleFactor()` and passes it to
/// `Theme.scaled(f)` so widgets keep their visual size while rendering crisp at native res.
var frame_scale: f32 = 1;
/// Whether the browser reports a touch-primary device (`navigator.maxTouchPoints > 0`).
/// JS sets it via `zicroSetTouch`; the responsive layer reads it to keep touch targets
/// comfortable. Defaults false (assume pointer) until JS reports.
var frame_touch: bool = false;
var last_x: f32 = -1;
var last_y: f32 = -1;
var singleton: Window = undefined;

/// Display scale (HiDPI): `devicePixelRatio`, 1 on a standard-density screen.
pub fn scaleFactor() f32 {
    return frame_scale;
}

/// True on touch-primary devices (phones/tablets). Read by the responsive layer.
pub fn isTouch() bool {
    return frame_touch;
}

/// Monotonic milliseconds for the app's UI (caret blink, animation): the last value JS
/// handed to `zicroFrame` (i.e. `performance.now()`). The web analogue of the native
/// `widget.nowMs()`, which can't read a clock on wasm freestanding.
pub fn nowMs() i64 {
    return frame_now_ms;
}

pub const Window = struct {
    opts: Options,
    width: u32,
    height: u32,
    closed: bool = false,

    pub fn init(_: std.mem.Allocator, _: std.Io, opts: Options) !*Window {
        const self = &singleton; // one canvas per page → a fixed slot, stable pointer
        self.* = .{ .opts = opts, .width = opts.width, .height = opts.height };
        active = self;
        return self;
    }

    pub fn deinit(self: *Window) void {
        if (active == self) active = null;
    }

    /// Cannot block on the web (the browser owns the loop): arm the window and return.
    /// JS drives frames via the exported ABI until the tab closes.
    pub fn run(self: *Window) !void {
        active = self;
    }

    /// JS repaints every animation frame, so a redraw request is implicit.
    pub fn requestRedraw(self: *Window) void {
        _ = self;
    }
    pub fn requestClose(self: *Window) void {
        self.closed = true;
    }

    /// Copy an externally-rendered straight-RGBA frame into the presented buffer, for apps
    /// that draw outside `on_draw`. `on_draw` apps ignore this — they draw into the buffer
    /// directly through the `Canvas` they're handed.
    pub fn presentRgba(self: *Window, w: u32, h: u32, rgba: []const u8) void {
        const need = @as(usize, w) * @as(usize, h) * 4;
        if (rgba.len < need or need > backbuf.len * 4) return;
        self.width = w;
        self.height = h;
        @memcpy(@as([*]u8, @ptrCast(&backbuf))[0..need], rgba[0..need]);
    }

    // Desktop-only surfaces degrade to no-ops (no compositor to ask).
    pub fn toggleFullscreen(self: *Window) void {
        _ = self;
    }
    pub fn setMinimized(self: *Window) void {
        _ = self;
    }
    pub fn setTitle(self: *Window, title: [*:0]const u8) void {
        _ = self;
        _ = title;
    }

    fn buffer(self: *Window) []u32 {
        return backbuf[0 .. self.width * self.height];
    }
    fn contentRect(self: *const Window) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
    }
};

// --- the exported ABI the JS glue drives ------------------------------------------

export fn zicroPixels() [*]u8 {
    return @ptrCast(&backbuf);
}
export fn zicroWidth() u32 {
    return if (active) |w| w.width else 0;
}
export fn zicroHeight() u32 {
    return if (active) |w| w.height else 0;
}
/// `w`/`h` are PHYSICAL pixels (CSS size × devicePixelRatio); `scale` is that ratio.
export fn zicroResize(w: u32, h: u32, scale: f32) void {
    const win = active orelse return;
    win.width = std.math.clamp(w, 1, MAX_W);
    win.height = std.math.clamp(h, 1, MAX_H);
    frame_scale = if (scale > 0) scale else 1;
}

/// JS reports whether this is a touch-primary device (`navigator.maxTouchPoints > 0`).
export fn zicroSetTouch(touch: u32) void {
    frame_touch = touch != 0;
}

/// One frame: tick, then draw into the window's buffer (which JS blits).
export fn zicroFrame(now_ms: f64) void {
    const win = active orelse return;
    frame_now_ms = @intFromFloat(now_ms);
    widget.web_now_ms = frame_now_ms; // so `widget.nowMs()` (Ui.begin) sees the browser clock
    if (win.opts.on_tick) |tick| tick(win, win.opts.user);
    if (win.opts.on_draw) |draw| {
        var canvas = paint.Canvas.initRgba8(win.buffer(), win.width, win.height);
        draw(&canvas, win.contentRect(), win.opts.user);
    }
}

fn dispatchMouse(ev: MouseEvent) void {
    const win = active orelse return;
    if (win.opts.on_mouse) |on_mouse| on_mouse(win, ev, win.opts.user);
}

export fn zicroPointerMove(x: f32, y: f32) void {
    last_x = x;
    last_y = y;
    dispatchMouse(.{ .kind = .motion, .x = x, .y = y });
}
export fn zicroPointerButton(button: u32, pressed: i32) void {
    dispatchMouse(.{ .kind = if (pressed != 0) .press else .release, .x = last_x, .y = last_y, .button = button });
}
export fn zicroScroll(dy: f32) void {
    dispatchMouse(.{ .kind = .scroll, .x = last_x, .y = last_y, .scroll_dy = dy });
}
export fn zicroKey(code: u32, pressed: i32) void {
    const win = active orelse return;
    if (win.opts.on_key) |on_key| on_key(win, code, if (pressed != 0) 1 else 0, win.opts.user);
}
