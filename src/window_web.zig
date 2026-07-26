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

const std = @import("std");
const window = @import("window.zig");
const paint = @import("paint.zig");
const widget = @import("widget.zig");
const gesture = @import("gesture.zig");

pub const Rect = window.Rect;
pub const MouseEvent = window.MouseEvent;
pub const Options = window.Options;

// One straight-RGBA8888 framebuffer (a browser page is single-window, single-threaded),
// allocated at the window's actual size and grown on resize — a phone page must not pay
// for a 4K reservation. Grow-only: resizes are rare and shrinking would only churn the
// wasm heap.
const MAX_DIM: u32 = 8192;
var backbuf: []u32 = &.{};

/// Grow the framebuffer to at least `pixels`; false (buffer unchanged) on OOM.
fn ensureBackbuf(pixels: usize) bool {
    if (backbuf.len >= pixels) return true;
    const gpa = @import("wasm_shim.zig").gpa;
    const grown = gpa.alloc(u32, pixels) catch return false;
    if (backbuf.len > 0) gpa.free(backbuf);
    backbuf = grown;
    return true;
}

/// The window JS is currently driving. Set by `init`/`run`, read by the exported ABI.
var active: ?*Window = null;
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

pub const Window = struct {
    opts: Options,
    width: u32,
    height: u32,
    closed: bool = false,

    pub fn init(_: std.mem.Allocator, _: std.Io, opts: Options) !*Window {
        const self = &singleton; // one canvas per page → a fixed slot, stable pointer
        if (!ensureBackbuf(@as(usize, opts.width) * opts.height)) return error.OutOfMemory;
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
        if (rgba.len < need or !ensureBackbuf(@as(usize, w) * h)) return;
        self.width = w;
        self.height = h;
        @memcpy(@as([*]u8, @ptrCast(backbuf.ptr))[0..need], rgba[0..need]);
    }

    /// Display scale (HiDPI): `devicePixelRatio`, 1 on a standard-density screen.
    pub fn scaleFactor(_: *const Window) f32 {
        return frame_scale;
    }

    /// True on touch-primary devices (phones/tablets). Read by the responsive layer.
    pub fn isTouch(_: *const Window) bool {
        return frame_touch;
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
    return @ptrCast(backbuf.ptr);
}
export fn zicroWidth() u32 {
    return if (active) |w| w.width else 0;
}
export fn zicroHeight() u32 {
    return if (active) |w| w.height else 0;
}
/// `w`/`h` are PHYSICAL pixels (CSS size × devicePixelRatio); `scale` is that ratio.
/// The new size is committed only if the framebuffer could grow to fit it.
export fn zicroResize(w: u32, h: u32, scale: f32) void {
    const win = active orelse return;
    const nw = std.math.clamp(w, 1, MAX_DIM);
    const nh = std.math.clamp(h, 1, MAX_DIM);
    if (ensureBackbuf(@as(usize, nw) * nh)) {
        win.width = nw;
        win.height = nh;
    }
    frame_scale = if (scale > 0) scale else 1;
}

/// JS reports whether this is a touch-primary device (`navigator.maxTouchPoints > 0`).
export fn zicroSetTouch(touch: u32) void {
    frame_touch = touch != 0;
}

/// One frame: tick, then draw into the window's buffer (which JS blits).
export fn zicroFrame(now_ms: f64) void {
    const win = active orelse return;
    widget.web_now_ms = @intFromFloat(now_ms); // so `widget.nowMs()` sees the browser clock
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

// --- multi-touch → gesti (substrato, condiviso web/android via `gesture.zig`) ------------
// JS inoltra QUI i punti touch grezzi (i pointer con `pointerType==='touch'`); mouse/pen
// restano sul path pointer sopra. Il recognizer condiviso traduce un dito negli STESSI
// eventi mouse (tap/drag/spostamento item/pan funzionano identici) e due dita in un PINCH
// semantico consegnato all'app via `on_gesture`.
var recognizer: gesture.Recognizer = .{};

fn dispatchGesture(g: gesture.Gesture) void {
    const win = active orelse return;
    if (win.opts.on_gesture) |cb| cb(win, g, win.opts.user);
}

/// JS: un punto touch. `phase` 0=giù 1=muovi 2=su/annulla; x/y in px fisici (già ×dpr).
export fn zicroTouch(id: i32, phase: u32, x: f32, y: f32) void {
    const ph: gesture.Phase = switch (phase) {
        0 => .down,
        1 => .move,
        else => .up,
    };
    var out: [2]gesture.Out = undefined;
    for (recognizer.push(id, ph, x, y, &out)) |ev| switch (ev) {
        .pointer_down => |p| {
            last_x = p.x;
            last_y = p.y;
            dispatchMouse(.{ .kind = .press, .x = p.x, .y = p.y, .button = 272 });
        },
        .pointer_move => |p| {
            last_x = p.x;
            last_y = p.y;
            dispatchMouse(.{ .kind = .motion, .x = p.x, .y = p.y });
        },
        .pointer_up => |p| {
            last_x = p.x;
            last_y = p.y;
            dispatchMouse(.{ .kind = .release, .x = p.x, .y = p.y, .button = 272 });
        },
        .pinch => |g| dispatchGesture(g),
    };
}
