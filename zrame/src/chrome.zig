//! # zrame.chrome — the backend-agnostic frame composition
//!
//! Everything a window backend does that is *not* talking to the OS: the cross-thread
//! frame mailbox (`Staged` + `SpinLock`, staged under `presentRgba`, swapped on the window
//! thread) and the composition itself (`composeContent`: the app `on_draw` overlay, the
//! newest staged content frame blitted into the content rect, then the panel stack on
//! top). Both `window_wayland.zig` and `window_win32.zig` share this, so the one thing most
//! likely to drift between platforms — *how a frame is composited* — lives in one place.
//!
//! Backends keep only the transport: acquiring a writable pixel buffer, filling its
//! background (glass chrome on Wayland, an opaque fill on Win32), calling `composeContent`,
//! and presenting the result however the OS allows.

const std = @import("std");
const zicro = @import("zicro");
const paint = zicro.paint;
const plugin = @import("plugin.zig");

const Rect = plugin.Rect;

/// Route a zicro mouse motion/press/release event through the panel stack, then — if no
/// panel claimed it — into the app's `on_mouse`, converting motion into the app's
/// presentation space (subtracting `appOrigin`). Shared by the web/android/macOS thin
/// adapters, which are otherwise identical here; only `.scroll` is left to the caller,
/// since each backend's `scroll_dy` is in a different unit (Wayland's wl_pointer.axis
/// fixed-point vs. a browser/NDK raw delta).
///
/// `self` is `*Window` for whichever backend calls this (comptime duck-typed): it needs
/// `.panels`, `.host()`, `.opts.{on_mouse,user}`, `.contentRect()` and `.mailbox.front`, plus
/// the optional `.pointer_x`/`.pointer_y` tracking fields some backends keep for other uses.
pub fn forwardMouse(self: anytype, event: anytype) void {
    const Self = @TypeOf(self.*);
    switch (event.kind) {
        .motion => {
            if (@hasField(Self, "pointer_x")) self.pointer_x = event.x;
            if (@hasField(Self, "pointer_y")) self.pointer_y = event.y;
            if (self.panels.route(.{ .motion = .{ .x = event.x, .y = event.y } }, self.host())) return;
            if (self.opts.on_mouse) |cb| {
                const o = appOrigin(self.contentRect(), &self.mailbox.front);
                _ = cb(self, .{ .motion = .{ .x = event.x - o.x, .y = event.y - o.y } }, self.opts.user);
            }
        },
        .press, .release => {
            const pressed = event.kind == .press;
            if (self.panels.route(.{ .button = .{ .x = event.x, .y = event.y, .button = event.button, .pressed = pressed } }, self.host())) return;
            if (self.opts.on_mouse) |cb| _ = cb(self, .{ .button = .{ .button = event.button, .state = @intFromBool(pressed) } }, self.opts.user);
        },
        .scroll => {}, // backend-specific scale — the caller handles this case itself
    }
}

/// Route a multi-touch gesture (pinch, …) from the shared `zicro.gesture` recognizer into
/// the app's `on_gesture`, translating its center into the app's presentation space (same
/// origin `forwardMouse` uses). Shared by the web/android adapters — the only backends
/// that feed a touchscreen into the recognizer.
pub fn forwardGesture(self: anytype, g: anytype) void {
    if (self.opts.on_gesture) |cb| {
        const o = appOrigin(self.contentRect(), &self.mailbox.front);
        var gg = g;
        gg.cx -= o.x;
        gg.cy -= o.y;
        cb(self, gg, self.opts.user);
    }
}

/// Route a key event ALREADY TRANSLATED TO EVDEV through the panel stack, the app's
/// `on_key`, and — on press — the shared US-layout keymap into `on_text`. Tracks shift
/// state on `self.shift_down` for that keymap lookup. Shared by the web/android
/// adapters: neither platform hands zrame real layout-aware text (unlike Wayland's
/// xkbcommon or Win32's `WM_CHAR`), so both synthesize it the same way from raw keys.
pub fn forwardKey(self: anytype, evdev: u32, state: u32) void {
    const pressed = state == 1;
    if (evdev == 42 or evdev == 54) self.shift_down = pressed; // Left/Right Shift
    if (self.panels.route(.{ .key = .{ .key = evdev, .pressed = pressed } }, self.host())) return;
    if (self.opts.on_key) |cb| cb(self, evdev, state, self.opts.user);
    if (pressed) {
        if (self.opts.on_text) |cb| {
            if (zicro.keymap.toChar(evdev, self.shift_down)) |ch| cb(self, .{ ch, 0, 0, 0 }, 1, self.opts.user);
        }
    }
}

/// The staged/front RGBA frame. `presentRgba` fills `staged`; the window thread swaps it
/// into `front` before compositing, so per-pixel blitting never runs under the lock.
pub const Staged = struct {
    pixels: std.ArrayList(u8) = .empty,
    width: u32 = 0,
    height: u32 = 0,
    /// Set by `stageFrame`, cleared when `swapFront` moves to front slot.
    fresh: bool = false,

    pub fn deinit(self: *Staged, gpa: std.mem.Allocator) void {
        self.pixels.deinit(gpa);
        self.* = .{};
    }
};

/// Zig 0.16 keeps blocking mutexes behind `std.Io`; the staging handoff is a short,
/// bounded copy at frame cadence, so a spin on a lock-free flag is simpler than threading
/// an `Io` through the window.
pub const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),
    pub fn lock(self: *SpinLock) void {
        while (self.flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

/// Stage a straight-alpha RGBA frame (thread-safe, newest wins). Returns true when a fresh
/// frame is staged — the caller then wakes its window thread (eventfd write / PostMessage).
/// On OOM the staged frame is invalidated (so a stale width can't send a later blit out of
/// bounds) and false is returned.
pub fn stageFrame(gpa: std.mem.Allocator, lock: *SpinLock, staged: *Staged, width: u32, height: u32, rgba: []const u8) bool {
    const need = @as(usize, width) * @as(usize, height) * 4;
    if (rgba.len < need) return false;
    lock.lock();
    defer lock.unlock();
    staged.pixels.clearRetainingCapacity();
    staged.pixels.appendSlice(gpa, rgba[0..need]) catch {
        staged.width = 0;
        staged.height = 0;
        staged.fresh = false;
        return false;
    };
    staged.width = width;
    staged.height = height;
    staged.fresh = true;
    return true;
}

/// Take the newest staged frame with a buffer swap: the lock is held for a few word writes,
/// never for the per-pixel blit, so producers don't spin behind it. The swapped-out front
/// buffer becomes the producer's next staging capacity.
pub fn swapFront(lock: *SpinLock, staged: *Staged, front: *Staged) void {
    lock.lock();
    defer lock.unlock();
    if (staged.fresh) {
        std.mem.swap(Staged, staged, front);
        staged.fresh = false;
    }
}

/// Reusable cross-thread frame mailbox encapsulating a `SpinLock` and `staged`/`front` buffers.
pub const FrameMailbox = struct {
    lock: SpinLock = .{},
    staged: Staged = .{},
    front: Staged = .{},

    pub fn deinit(self: *FrameMailbox, gpa: std.mem.Allocator) void {
        self.staged.deinit(gpa);
        self.front.deinit(gpa);
        self.* = .{};
    }

    pub fn stage(self: *FrameMailbox, gpa: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) bool {
        return stageFrame(gpa, &self.lock, &self.staged, width, height, rgba);
    }

    pub fn swap(self: *FrameMailbox) void {
        swapFront(&self.lock, &self.staged, &self.front);
    }

    pub fn isFresh(self: *const FrameMailbox) bool {
        return self.staged.fresh;
    }
};

/// Top-left, in canvas/pointer pixels, where a staged frame of size `fw`×`fh` lands when
/// centered in `content` — the same math `composeContent` uses for the blit. Apps map
/// pointer coordinates into frame-local space by subtracting this origin, so draw and
/// hit-test stay in the same space.
pub fn frameOrigin(content: Rect, fw: u32, fh: u32) struct { x: u32, y: u32 } {
    const w = @min(fw, content.w);
    const h = @min(fh, content.h);
    return .{ .x = content.x + (content.w - w) / 2, .y = content.y + (content.h - h) / 2 };
}

/// Canvas-space rectangle a staged frame of `fw`×`fh` occupies when composed:
/// `frameOrigin` plus the clamped blit size. Used by the backend damage tracking
/// to recompose only what the frame actually covers.
pub fn frameRect(content: Rect, fw: u32, fh: u32) Rect {
    const o = frameOrigin(content, fw, fh);
    return .{ .x = o.x, .y = o.y, .w = @min(fw, content.w), .h = @min(fh, content.h) };
}

/// Origin of the app's presentation space in canvas pixels: where its staged frame lands
/// (or the bare content origin before any frame is staged). Backends subtract this from
/// pointer coordinates before calling `on_mouse` — the client-coordinates contract of
/// mainstream toolkits (Win32 client area, Cocoa view coords, SDL logical presentation) —
/// so an app hit-tests in the very space it drew. Reading `front` here is safe: both
/// input dispatch and `swapFront` run on the window thread.
pub fn appOrigin(content: Rect, front: *const Staged) struct { x: f32, y: f32 } {
    if (front.width > 0) {
        const o = frameOrigin(content, front.width, front.height);
        return .{ .x = @floatFromInt(o.x), .y = @floatFromInt(o.y) };
    }
    return .{ .x = @floatFromInt(content.x), .y = @floatFromInt(content.y) };
}

/// Composite the app content into a canvas whose background the backend has already filled:
/// the `on_draw` overlay (over the whole `content`), then the newest `front` frame centered
/// in `frame_area` — the content minus any gutter the app reserved for its own overlay, so
/// a side panel doesn't push the frame off-center — then the panel stack on top. No
/// windowing-system call and no lock happens here.
pub fn composeContent(
    canvas: *paint.Canvas,
    content: Rect,
    frame_area: Rect,
    front: *const Staged,
    style: paint.Style,
    panels: *plugin.Registry,
    host: plugin.Host,
    on_draw: ?*const fn (*paint.Canvas, Rect, ?*anyopaque) void,
    user: ?*anyopaque,
) void {
    if (on_draw) |draw| draw(canvas, content, user);

    if (front.width > 0) {
        const fw = @min(front.width, frame_area.w);
        const fh = @min(front.height, frame_area.h);
        const origin = frameOrigin(frame_area, front.width, front.height);
        const dx = origin.x;
        const dy = origin.y;
        if (fw == front.width) {
            // Source rows are contiguous: for a frame taller than the content
            // (a stale frame during a shrink-resize) it's enough to truncate the height,
            // so it never spills below the content rect.
            canvas.blitRgba(dx, dy, front.pixels.items[0 .. @as(usize, fw) * fh * 4], fw, fh, style);
        } else {
            // Frame wider than the content: `blitRgba` uses src_w as the stride too,
            // so the width clip has to be done row by row (without touching
            // zicro). The content radius is lost for those few stale frames:
            // better than spilling onto the chrome.
            var row_style = style;
            row_style.content_radius = 0;
            row_style.content_fade_width = 0;
            row_style.corner_fade_width = 0;
            var sy: u32 = 0;
            while (sy < fh) : (sy += 1) {
                const src_row = front.pixels.items[@as(usize, sy) * front.width * 4 ..][0 .. @as(usize, fw) * 4];
                canvas.blitRgba(dx, dy + sy, src_row, fw, 1, row_style);
            }
        }
    }

    // Definition ring OVER the content: 1px along the panel edge, light on top and
    // darker at the bottom, so a bright frameless window still reads on a bright
    // desktop. Skipped when the style has none (or the content rect is empty).
    if (style.edge_ring_alpha > 0.0 and content.w > 0 and content.h > 0) {
        canvas.strokeRoundedRectGradient(
            @floatFromInt(content.x),
            @floatFromInt(content.y),
            @floatFromInt(content.w),
            @floatFromInt(content.h),
            style.content_radius,
            1.0,
            paint.Color.rgba(255, 255, 255, style.edge_ring_alpha),
            paint.Color.rgba(0, 0, 0, style.edge_ring_alpha * 2.0),
        );
    }

    // Panels (title bar, scrollbars, context menu, plugins) composite last, on top of both
    // the app content and any video frame.
    panels.draw(canvas, host);
}
