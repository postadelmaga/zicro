//! # zicro.window_cocoa — the macOS windowing backend
//!
//! A minimal software-rendered window, the Cocoa sibling of `window_wayland` (Linux) and
//! `window_win32` (Windows). It drives AppKit through the bare Objective-C runtime
//! (`objc_msgSend`) rather than `@cImport`-ing the frameworks, so it type-checks under a
//! cross-compile even without the macOS SDK; presentation is a premultiplied-ARGB
//! `CGImage` pushed into the content view's layer each frame.
//!
//! Linkage (see build.zig): `-framework Cocoa -framework QuartzCore -framework CoreGraphics`.

const std = @import("std");
const builtin = @import("builtin");

// --- Objective-C runtime + CoreGraphics FFI (raw, no framework headers) ------------------

const id = ?*anyopaque;
const SEL = ?*anyopaque;
const Class = ?*anyopaque;

extern "c" fn objc_getClass(name: [*:0]const u8) Class;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
/// The one true message send. Cast to the concrete signature at each call site (the
/// selector never changes the C ABI), which is what the `msg*` helpers below do.
extern "c" fn objc_msgSend() void;

extern "c" fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
extern "c" fn CGColorSpaceRelease(space: ?*anyopaque) void;
extern "c" fn CGDataProviderCreateWithData(info: ?*anyopaque, data: *const anyopaque, size: usize, release: ?*const anyopaque) ?*anyopaque;
extern "c" fn CGDataProviderRelease(provider: ?*anyopaque) void;
extern "c" fn CGImageCreate(
    width: usize,
    height: usize,
    bitsPerComponent: usize,
    bitsPerPixel: usize,
    bytesPerRow: usize,
    space: ?*anyopaque,
    bitmapInfo: u32,
    provider: ?*anyopaque,
    decode: ?*const f64,
    shouldInterpolate: bool,
    intent: u32,
) ?*anyopaque;
extern "c" fn CGImageRelease(image: ?*anyopaque) void;

// Interpret each little-endian 32-bit pixel as 0xAARRGGBB, premultiplied — exactly the
// layout `paint.Canvas` produces (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little).
const kCGImageAlphaPremultipliedFirst: u32 = 2;
const kCGBitmapByteOrder32Little: u32 = 2 << 12;
const bitmap_info: u32 = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;

const CGPoint = extern struct { x: f64, y: f64 };
const CGSize = extern struct { width: f64, height: f64 };
const CGRect = extern struct { origin: CGPoint, size: CGSize };

fn class(name: [*:0]const u8) Class {
    return objc_getClass(name);
}

/// `[obj sel]` → id.
fn msgId(obj: id, sel: [*:0]const u8) id {
    const f: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(obj, sel_registerName(sel));
}
/// `[obj sel]` → void.
fn msgVoid(obj: id, sel: [*:0]const u8) void {
    const f: *const fn (id, SEL) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(obj, sel_registerName(sel));
}
/// `[obj sel]` → bool.
fn msgBool(obj: id, sel: [*:0]const u8) bool {
    const f: *const fn (id, SEL) callconv(.c) bool = @ptrCast(&objc_msgSend);
    return f(obj, sel_registerName(sel));
}
/// `[obj sel:arg]` with an object argument → void.
fn msgVoidId(obj: id, sel: [*:0]const u8, arg: id) void {
    const f: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(obj, sel_registerName(sel), arg);
}
/// `[obj sel:arg]` with a BOOL argument → void.
fn msgVoidBool(obj: id, sel: [*:0]const u8, arg: bool) void {
    const f: *const fn (id, SEL, bool) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(obj, sel_registerName(sel), arg);
}
/// `[obj sel:arg]` with an NSInteger argument → void.
fn msgVoidInt(obj: id, sel: [*:0]const u8, arg: i64) void {
    const f: *const fn (id, SEL, i64) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(obj, sel_registerName(sel), arg);
}
/// `[NSString stringWithUTF8String:s]` (and friends taking a C string) → id.
fn msgStr(cls: id, sel: [*:0]const u8, s: [*:0]const u8) id {
    const f: *const fn (id, SEL, [*:0]const u8) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls, sel_registerName(sel), s);
}

fn nsString(s: [*:0]const u8) id {
    return msgStr(class("NSString"), "stringWithUTF8String:", s);
}

pub const Window = if (builtin.os.tag != .macos) struct {} else struct {
    const paint = @import("paint.zig");
    const window = @import("window.zig");
    const sync = @import("sync.zig");
    const Allocator = std.mem.Allocator;

    gpa: Allocator,
    io: std.Io,
    opts: window.Options,

    app: id = null,
    win: id = null,
    view: id = null,
    layer: id = null,

    pixels: []u32 = &.{},
    width: u32,
    height: u32,
    closed: bool = false,
    fullscreen: bool = false,
    mutex: std.Io.Mutex = .init,

    // NSWindowStyleMask: Titled(1) | Closable(2) | Miniaturizable(4) | Resizable(8).
    const style_mask: u64 = 1 | 2 | 4 | 8;
    const backing_buffered: u64 = 2; // NSBackingStoreBuffered
    const event_mask_any: u64 = std.math.maxInt(u64); // NSEventMaskAny

    pub fn init(gpa: Allocator, io: std.Io, opts: window.Options) !*Window {
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .width = opts.width,
            .height = opts.height,
        };

        self.pixels = try gpa.alloc(u32, opts.width * opts.height);
        errdefer gpa.free(self.pixels);
        @memset(self.pixels, 0);

        const app = msgId(class("NSApplication"), "sharedApplication");
        self.app = app;
        msgVoidInt(app, "setActivationPolicy:", 0); // NSApplicationActivationPolicyRegular

        const frame = CGRect{
            .origin = .{ .x = 100, .y = 100 },
            .size = .{ .width = @floatFromInt(opts.width), .height = @floatFromInt(opts.height) },
        };
        const win_alloc = msgId(class("NSWindow"), "alloc");
        const initFrame: *const fn (id, SEL, CGRect, u64, u64, bool) callconv(.c) id = @ptrCast(&objc_msgSend);
        const win = initFrame(
            win_alloc,
            sel_registerName("initWithContentRect:styleMask:backing:defer:"),
            frame,
            style_mask,
            backing_buffered,
            false,
        ) orelse return error.WindowCreationFailed;
        self.win = win;

        msgVoidId(win, "setTitle:", nsString(opts.title.ptr));

        const view = msgId(win, "contentView");
        self.view = view;
        msgVoidBool(view, "setWantsLayer:", true);
        self.layer = msgId(view, "layer");

        msgVoidBool(app, "activateIgnoringOtherApps:", true);
        msgVoidId(win, "makeKeyAndOrderFront:", null);

        return self;
    }

    pub fn deinit(self: *Window) void {
        if (self.win) |w| msgVoidId(w, "close", null);
        self.gpa.free(self.pixels);
        self.gpa.destroy(self);
    }

    pub fn toggleFullscreen(self: *Window) void {
        const w = self.win orelse return;
        self.fullscreen = !self.fullscreen;
        msgVoidId(w, "toggleFullScreen:", null);
    }

    pub fn setMinimized(self: *Window) void {
        const w = self.win orelse return;
        msgVoidId(w, "miniaturize:", null);
    }

    /// Push an external RGBA frame into the layer (thread-safe against the run loop).
    pub fn presentRgba(self: *Window, w: u32, h: u32, rgba: []const u8) void {
        const need = @as(usize, w) * @as(usize, h) * 4;
        if (rgba.len < need or w != self.width or h != self.height) return;
        sync.lock(&self.mutex, self.io);
        defer sync.unlock(&self.mutex, self.io);
        @memcpy(std.mem.sliceAsBytes(self.pixels)[0..need], rgba[0..need]);
        self.present();
    }

    /// Build a CGImage over the current framebuffer and hand it to the view's layer. The
    /// image is copied by CoreGraphics into the layer, so releasing it here is safe.
    fn present(self: *Window) void {
        const layer = self.layer orelse return;
        const cs = CGColorSpaceCreateDeviceRGB();
        defer CGColorSpaceRelease(cs);
        const bytes = std.mem.sliceAsBytes(self.pixels);
        const provider = CGDataProviderCreateWithData(null, bytes.ptr, bytes.len, null);
        defer CGDataProviderRelease(provider);
        const image = CGImageCreate(
            self.width,
            self.height,
            8,
            32,
            self.width * 4,
            cs,
            bitmap_info,
            provider,
            null,
            false,
            0,
        );
        defer CGImageRelease(image);
        msgVoidId(layer, "setContents:", image);
    }

    pub fn run(self: *Window) !void {
        const app = self.app orelse return;
        const distant_past = msgId(class("NSDate"), "distantPast");
        const default_mode = nsString("kCFRunLoopDefaultMode");
        const nextEvent: *const fn (id, SEL, u64, id, id, bool) callconv(.c) id = @ptrCast(&objc_msgSend);
        const next_sel = sel_registerName("nextEventMatchingMask:untilDate:inMode:dequeue:");

        while (!self.closed) {
            // Drain all pending events without blocking (untilDate: distantPast).
            while (true) {
                const ev = nextEvent(app, next_sel, event_mask_any, distant_past, default_mode, true);
                if (ev == null) break;
                self.dispatch(ev);
                msgVoidId(app, "sendEvent:", ev);
            }
            // The user closed the window (red button) → the window is no longer visible.
            if (self.win) |w| {
                if (!msgBool(w, "isVisible")) self.closed = true;
            }
            if (self.closed) break;

            sync.lock(&self.mutex, self.io);
            @memset(self.pixels, 0);
            var canvas = paint.Canvas.init(self.pixels, self.width, self.height);
            const content = window.Rect{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
            if (self.opts.on_draw) |draw| draw(&canvas, content, self.opts.user);
            self.present();
            sync.unlock(&self.mutex, self.io);

            msgVoid(app, "updateWindows");
            sync.sleepNs(self.io, 16 * std.time.ns_per_ms); // ~60 FPS pacing
        }
    }

    /// Forward key events to the app's `on_key` before AppKit consumes them. `key` is the
    /// raw macOS virtual keycode; mapping it to characters is the caller's concern (same
    /// contract as the other backends, which pass platform-native codes).
    fn dispatch(self: *Window, ev: id) void {
        const cb = self.opts.on_key orelse return;
        const ns_type = msgTypeU64(ev, "type");
        // NSEventTypeKeyDown = 10, NSEventTypeKeyUp = 11.
        const state: u32 = switch (ns_type) {
            10 => 1,
            11 => 0,
            else => return,
        };
        const key: u32 = msgKeyCode(ev, "keyCode");
        cb(self, key, state, self.opts.user);
    }

    fn msgTypeU64(obj: id, sel: [*:0]const u8) u64 {
        const f: *const fn (id, SEL) callconv(.c) u64 = @ptrCast(&objc_msgSend);
        return f(obj, sel_registerName(sel));
    }
    fn msgKeyCode(obj: id, sel: [*:0]const u8) u16 {
        const f: *const fn (id, SEL) callconv(.c) u16 = @ptrCast(&objc_msgSend);
        return f(obj, sel_registerName(sel));
    }
};
