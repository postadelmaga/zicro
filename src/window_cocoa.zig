//! # zicro.window_cocoa — the macOS windowing backend
//!
//! A software-rendered window, the Cocoa sibling of `window_wayland` (Linux) and
//! `window_win32` (Windows). It drives AppKit through the bare Objective-C runtime
//! (`objc_msgSend`) rather than `@cImport`-ing the frameworks, so it type-checks under a
//! cross-compile even without the macOS SDK.
//!
//! Presentation is a custom `NSView` subclass (built at runtime with
//! `objc_allocateClassPair`) whose `drawRect:` draws a `CGImage` over the whole bounds via
//! `CGContextDrawImage`. That is deliberately the *lowest common denominator* drawing
//! path: it works on real AppKit **and** on Cocotron/Onyx2D (the AppKit Darling ships,
//! which zart drives as a Linux window server) — unlike `CALayer.setContents:`, which
//! Cocotron does not composite.
//!
//! Input follows the same dual-world rule: key events are decoded from
//! `charactersIgnoringModifiers` (NOT `keyCode` — real macOS puts Apple virtual keycodes
//! there, zart passes raw evdev, so the character is the only portable field) and mapped
//! to the **evdev codes** the Wayland backend emits, so `on_key` handlers are identical
//! across platforms. Modifier keys never arrive as key events on either world
//! (`flagsChanged` on macOS, flag-bits-only under zart), so press/release transitions for
//! Shift/Ctrl/Alt are synthesized from `modifierFlags` deltas — with **Command mapped to
//! Ctrl**, the same normalization zart applies in the other direction.
//!
//! Linkage (see build.zig): `-framework Cocoa -framework QuartzCore -framework CoreGraphics`.

const std = @import("std");
const builtin = @import("builtin");

// --- Objective-C runtime + CoreGraphics FFI (raw, no framework headers) ------------------

const id = ?*anyopaque;
const SEL = ?*anyopaque;
const Class = ?*anyopaque;
const IMP = ?*const anyopaque;

extern "c" fn objc_getClass(name: [*:0]const u8) Class;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
/// The one true message send. Cast to the concrete signature at each call site (the
/// selector never changes the C ABI), which is what the `msg*` helpers below do.
extern "c" fn objc_msgSend() void;
/// x86_64 only: message sends whose return value lands in memory (CGRect & co) must go
/// through the _stret entry point. aarch64 has no such split — see `msgRect`.
extern "c" fn objc_msgSend_stret() void;
extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra: usize) Class;
extern "c" fn objc_registerClassPair(cls: Class) void;
extern "c" fn class_addMethod(cls: Class, name: SEL, imp: IMP, types: [*:0]const u8) bool;

/// AppKit classes are looked up by name at runtime (`objc_getClass`), so nothing from
/// Cocoa is needed at link time — but dyld only maps frameworks with a load command in
/// the binary. Referencing one real Cocoa data symbol keeps that load command alive.
extern "c" var NSApp: id;

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
extern "c" fn CGContextDrawImage(ctx: ?*anyopaque, rect: CGRect, image: ?*anyopaque) void;
extern "c" fn CGBitmapContextGetData(ctx: ?*anyopaque) ?[*]u8;
extern "c" fn CGBitmapContextGetWidth(ctx: ?*anyopaque) usize;
extern "c" fn CGBitmapContextGetHeight(ctx: ?*anyopaque) usize;
extern "c" fn CGBitmapContextGetBytesPerRow(ctx: ?*anyopaque) usize;
extern "c" fn CGContextSetRGBFillColor(ctx: ?*anyopaque, r: f64, g: f64, b: f64, a: f64) void;
extern "c" fn CGContextFillRect(ctx: ?*anyopaque, rect: CGRect) void;
extern "c" fn CGContextSaveGState(ctx: ?*anyopaque) void;
extern "c" fn CGContextRestoreGState(ctx: ?*anyopaque) void;
extern "c" fn CGContextTranslateCTM(ctx: ?*anyopaque, tx: f64, ty: f64) void;
extern "c" fn CGContextScaleCTM(ctx: ?*anyopaque, sx: f64, sy: f64) void;

// Interpret each little-endian 32-bit pixel as 0xAARRGGBB, premultiplied — exactly the
// layout `paint.Canvas` produces (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little).
const kCGImageAlphaPremultipliedFirst: u32 = 2;
const kCGBitmapByteOrder32Little: u32 = 2 << 12;
const bitmap_info: u32 = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;

const CGPoint = extern struct { x: f64, y: f64 };
const CGSize = extern struct { width: f64, height: f64 };
const CGRect = extern struct { origin: CGPoint, size: CGSize };

// NSEvent type numbers (Cocotron matches Apple's).
const NSLeftMouseDown: u64 = 1;
const NSLeftMouseUp: u64 = 2;
const NSRightMouseDown: u64 = 3;
const NSRightMouseUp: u64 = 4;
const NSMouseMoved: u64 = 5;
const NSLeftMouseDragged: u64 = 6;
const NSRightMouseDragged: u64 = 7;
const NSKeyDown: u64 = 10;
const NSKeyUp: u64 = 11;
const NSFlagsChanged: u64 = 12;
const NSScrollWheel: u64 = 22;
const NSOtherMouseDown: u64 = 25;
const NSOtherMouseUp: u64 = 26;
const NSOtherMouseDragged: u64 = 27;

// NSEventModifierFlags bits.
const ModShift: u64 = 1 << 17;
const ModControl: u64 = 1 << 18;
const ModOption: u64 = 1 << 19;
const ModCommand: u64 = 1 << 20;

// evdev codes emitted to `on_key`/`on_mouse` (same values the Wayland backend delivers).
const KEY_LEFTCTRL: u32 = 29;
const KEY_LEFTSHIFT: u32 = 42;
const KEY_LEFTALT: u32 = 56;
const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;

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
/// `[obj sel]` → u64 (NSUInteger).
fn msgU64(obj: id, sel: [*:0]const u8) u64 {
    const f: *const fn (id, SEL) callconv(.c) u64 = @ptrCast(&objc_msgSend);
    return f(obj, sel_registerName(sel));
}
/// `[obj sel]` → f64 (CGFloat).
fn msgF64(obj: id, sel: [*:0]const u8) f64 {
    const f: *const fn (id, SEL) callconv(.c) f64 = @ptrCast(&objc_msgSend);
    return f(obj, sel_registerName(sel));
}
/// `[obj sel]` → CGPoint (two doubles: returned in registers, plain msgSend on both archs).
fn msgPoint(obj: id, sel: [*:0]const u8) CGPoint {
    const f: *const fn (id, SEL) callconv(.c) CGPoint = @ptrCast(&objc_msgSend);
    return f(obj, sel_registerName(sel));
}
/// `[obj sel]` → CGRect. Four doubles land in memory on x86_64 → the _stret entry point;
/// aarch64 returns every struct through x8, one msgSend for everything.
fn msgRect(obj: id, sel: [*:0]const u8) CGRect {
    const entry = if (builtin.cpu.arch == .x86_64) &objc_msgSend_stret else &objc_msgSend;
    const f: *const fn (id, SEL) callconv(.c) CGRect = @ptrCast(entry);
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
/// `[obj sel:size]` with a CGSize argument → void.
fn msgVoidSize(obj: id, sel: [*:0]const u8, arg: CGSize) void {
    const f: *const fn (id, SEL, CGSize) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(obj, sel_registerName(sel), arg);
}
/// `[obj sel:point fromView:v]` → CGPoint (window → view coordinate conversion).
fn msgConvertPoint(obj: id, p: CGPoint, from: id) CGPoint {
    const f: *const fn (id, SEL, CGPoint, id) callconv(.c) CGPoint = @ptrCast(&objc_msgSend);
    return f(obj, sel_registerName("convertPoint:fromView:"), p, from);
}
/// `[NSString stringWithUTF8String:s]` (and friends taking a C string) → id.
fn msgStr(cls: id, sel: [*:0]const u8, s: [*:0]const u8) id {
    const f: *const fn (id, SEL, [*:0]const u8) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(cls, sel_registerName(sel), s);
}
/// `[obj characterAtIndex:i]` → unichar.
fn msgCharAt(obj: id, i: u64) u16 {
    const f: *const fn (id, SEL, u64) callconv(.c) u16 = @ptrCast(&objc_msgSend);
    return f(obj, sel_registerName("characterAtIndex:"), i);
}

fn nsString(s: [*:0]const u8) id {
    return msgStr(class("NSString"), "stringWithUTF8String:", s);
}

// ZICRO_COCOA_TRACE=1: loop/dispatch diagnostics on stderr (dual-world debugging:
// under zart the backend log collects them next to the ZartDisplay trace).
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
var trace_checked: bool = false;
var trace_on: bool = false;
fn traceOn() bool {
    if (!trace_checked) {
        trace_checked = true;
        trace_on = if (getenv("ZICRO_COCOA_TRACE")) |v| v[0] != '0' else false;
    }
    return trace_on;
}
/// Monotonic nanoseconds via raw libc (std.time timestamps live behind std.Io in Zig
/// 0.16; pacing and trace stamps only need a raw monotonic clock).
const Timespec = extern struct { sec: i64, nsec: i64 };
const CLOCK_MONOTONIC_DARWIN: c_int = 6;
extern "c" fn clock_gettime(clockid: c_int, tp: *Timespec) c_int;
fn clockNs() u64 {
    var ts: Timespec = undefined;
    if (clock_gettime(CLOCK_MONOTONIC_DARWIN, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
var trace_t0: u64 = 0;
fn traceMs() u64 {
    const ms = clockNs() / 1_000_000;
    if (trace_t0 == 0) trace_t0 = ms;
    return ms - trace_t0;
}
fn trace(comptime fmt: []const u8, args: anytype) void {
    if (traceOn()) std.debug.print("zicro-cocoa[{d}ms]: " ++ fmt ++ "\n", .{traceMs()} ++ args);
}

// --- the content view subclass (runtime-built, drawRect: presents the framebuffer) -------

/// view instance → Window lookup for `drawRect:` (main-thread only, tiny fixed table).
const MAX_WINDOWS = 8;
var g_views: [MAX_WINDOWS]id = @splat(null);
var g_wins: [MAX_WINDOWS]?*anyopaque = @splat(null);
var g_view_class: Class = null;

fn registerView(view: id, win: *anyopaque) void {
    for (&g_views, &g_wins) |*v, *w| {
        if (v.* == null) {
            v.* = view;
            w.* = win;
            return;
        }
    }
}

fn unregisterView(view: id) void {
    for (&g_views, &g_wins) |*v, *w| {
        if (v.* == view) {
            v.* = null;
            w.* = null;
        }
    }
}

fn windowForView(view: id) ?*anyopaque {
    for (g_views, g_wins) |v, w| {
        if (v == view) return w;
    }
    return null;
}

/// Build the `ZicroContentView` class once: an NSView that presents the window's
/// framebuffer in `drawRect:` and accepts first-responder status for key events.
fn ensureViewClass() Class {
    if (g_view_class != null) return g_view_class;
    const cls = objc_allocateClassPair(class("NSView"), "ZicroContentView", 0) orelse {
        // Already registered by a previous instance in this process.
        g_view_class = class("ZicroContentView");
        return g_view_class;
    };
    _ = class_addMethod(cls, sel_registerName("drawRect:"), @ptrCast(&imp_drawRect), "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    _ = class_addMethod(cls, sel_registerName("acceptsFirstResponder"), @ptrCast(&imp_yes), "c@:");
    _ = class_addMethod(cls, sel_registerName("isOpaque"), @ptrCast(&imp_yes), "c@:");
    objc_registerClassPair(cls);
    g_view_class = cls;
    return cls;
}

fn imp_yes(_: id, _: SEL) callconv(.c) bool {
    return true;
}

fn imp_drawRect(view: id, _: SEL, rect: CGRect) callconv(.c) void {
    const win_ptr = windowForView(view) orelse return;
    if (builtin.os.tag == .macos) {
        trace("drawRect ({d},{d} {d}x{d})", .{ rect.origin.x, rect.origin.y, rect.size.width, rect.size.height });
        const self: *Window = @ptrCast(@alignCast(win_ptr));
        self.drawIntoCurrentContext();
    }
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

    pixels: []u32 = &.{},
    width: u32,
    height: u32,
    closed: bool = false,
    fullscreen: bool = false,
    mutex: std.Io.Mutex = .init,
    /// Modifier state as last synthesized to `on_key` (evdev transitions) — see `syncMods`.
    mods_shift: bool = false,
    mods_ctrl: bool = false,
    mods_alt: bool = false,
    last_tick_ns: u64 = 0,

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
        @memset(self.pixels, 0xFF000000);

        std.mem.doNotOptimizeAway(&NSApp); // keep Cocoa's load command (see the extern above)
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
        msgVoidBool(win, "setAcceptsMouseMovedEvents:", true);

        // Our own content view: drawRect: presents the framebuffer (see the class builder).
        const vcls = ensureViewClass();
        const view_alloc = msgId(vcls, "alloc");
        const initWithFrame: *const fn (id, SEL, CGRect) callconv(.c) id = @ptrCast(&objc_msgSend);
        const view = initWithFrame(
            view_alloc,
            sel_registerName("initWithFrame:"),
            CGRect{ .origin = .{ .x = 0, .y = 0 }, .size = frame.size },
        ) orelse return error.WindowCreationFailed;
        self.view = view;
        registerView(view, self);
        msgVoidId(win, "setContentView:", view);
        msgVoidId(win, "makeFirstResponder:", view);

        msgVoidBool(app, "activateIgnoringOtherApps:", true);
        msgVoidId(win, "makeKeyAndOrderFront:", null);

        return self;
    }

    pub fn deinit(self: *Window) void {
        if (self.view) |v| unregisterView(v);
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

    pub fn close(self: *Window) void {
        self.closed = true;
    }

    /// Resize so the *content* area becomes w×h (the OS frame grows around it).
    pub fn setContentSize(self: *Window, w: u32, h: u32) void {
        const win = self.win orelse return;
        msgVoidSize(win, "setContentSize:", .{ .width = @floatFromInt(w), .height = @floatFromInt(h) });
    }

    /// Push an external ARGB frame (RGBA byte order in memory) into the framebuffer.
    /// Thread-safe: stages under the mutex; the run loop's next present shows it.
    pub fn presentRgba(self: *Window, w: u32, h: u32, rgba: []const u8) void {
        const need = @as(usize, w) * @as(usize, h) * 4;
        if (rgba.len < need or w != self.width or h != self.height) return;
        sync.lock(&self.mutex, self.io);
        defer sync.unlock(&self.mutex, self.io);
        // RGBA bytes → 0xAARRGGBB pixels (paint.Canvas layout).
        for (self.pixels, 0..) |*px, i| {
            const b = rgba[i * 4 ..];
            px.* = (@as(u32, b[3]) << 24) | (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | b[2];
        }
    }

    /// Called from `drawRect:` — wrap the framebuffer in a CGImage and draw it over the
    /// view bounds through the *current* graphics context. The view is flipped (top-left,
    /// y down — see `ensureViewClass`), and `CGContextDrawImage` composes in CG's y-up
    /// space, so the CTM is flipped around the buffer height for the draw: image row 0
    /// lands at the visual top on real AppKit and Cocotron alike.
    fn drawIntoCurrentContext(self: *Window) void {
        const nsctx = msgId(class("NSGraphicsContext"), "currentContext") orelse return;
        const ctx = msgId(nsctx, "graphicsPort") orelse return;
        if (traceOn() and getenv("ZICRO_COCOA_FILL") != null) {
            // Diagnostic lane isolator: a plain vector fill, no CGImage involved. If this
            // shows up where the image did not, the blit path is the culprit.
            CGContextSetRGBFillColor(ctx, 1, 0, 0, 1);
            CGContextFillRect(ctx, .{ .origin = .{ .x = 50, .y = 50 }, .size = .{ .width = 400, .height = 200 } });
            return;
        }
        sync.lock(&self.mutex, self.io);
        defer sync.unlock(&self.mutex, self.io);

        // Present through the CG draw pipeline (CGContextDrawImage). We do NOT memcpy into
        // CGBitmapContextGetData(ctx): under Darling's Onyx2D that returns a scratch/back
        // buffer that is NOT the surface flushWindow ships, so raw writes there never
        // reach the presented window (verified: the rows land in `base` but the window
        // stays blank, while a plain CGContextFillRect on the same ctx DOES show — the
        // pipeline composites into the real surface, the GetData pointer does not).
        // On real macOS the window context isn't a bitmap context anyway, so this was
        // always the effective path there.
        const cs = CGColorSpaceCreateDeviceRGB();
        defer CGColorSpaceRelease(cs);
        const bytes = std.mem.sliceAsBytes(self.pixels);
        const provider = CGDataProviderCreateWithData(null, bytes.ptr, bytes.len, null);
        defer CGDataProviderRelease(provider);
        const image = CGImageCreate(self.width, self.height, 8, 32, self.width * 4, cs, bitmap_info, provider, null, false, 0);
        defer CGImageRelease(image);
        CGContextDrawImage(ctx, .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) },
        }, image);
    }

    /// Run the view's display cycle now, unconditionally, then flush the window backing
    /// to the server. We drive our own loop (no NSRunLoop) and Cocotron's needsDisplay
    /// bookkeeping proved unreliable from outside one (`setNeedsDisplay:` +
    /// `displayIfNeeded` yielded two draws per session under zart); `display` skips the
    /// dirty tracking but — on Cocotron — draws only into the backing, so the explicit
    /// `flushWindow` is what actually ships the frame.
    fn present(self: *Window) void {
        const view = self.view orelse return;
        msgVoid(view, "display");
        if (self.win) |w| msgVoid(w, "flushWindow");
    }

    /// Track the content view size; on change, reallocate the framebuffer.
    fn syncSize(self: *Window) void {
        const view = self.view orelse return;
        const b = msgRect(view, "bounds");
        const w: u32 = @intFromFloat(@max(b.size.width, 1));
        const h: u32 = @intFromFloat(@max(b.size.height, 1));
        if (w == self.width and h == self.height) return;
        sync.lock(&self.mutex, self.io);
        defer sync.unlock(&self.mutex, self.io);
        const np = self.gpa.alloc(u32, @as(usize, w) * h) catch return;
        @memset(np, 0xFF000000);
        self.gpa.free(self.pixels);
        self.pixels = np;
        self.width = w;
        self.height = h;
    }

    pub fn run(self: *Window) !void {
        const app = self.app orelse return;
        trace("run: finishLaunching", .{});
        msgVoid(app, "finishLaunching");
        const distant_past = msgId(class("NSDate"), "distantPast");
        const default_mode = nsString("kCFRunLoopDefaultMode");
        const nextEvent: *const fn (id, SEL, u64, id, id, bool) callconv(.c) id = @ptrCast(&objc_msgSend);
        const next_sel = sel_registerName("nextEventMatchingMask:untilDate:inMode:dequeue:");
        var frames: u64 = 0;

        while (!self.closed) {
            const fine = frames < 5; // per-stage trace on the first frames only
            if (fine) trace("frame {d}: drain", .{frames});
            // Drain all pending events without blocking (untilDate: distantPast).
            while (true) {
                const ev = nextEvent(app, next_sel, event_mask_any, distant_past, default_mode, true);
                if (ev == null) break;
                self.dispatch(ev);
                const send: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
                send(app, sel_registerName("sendEvent:"), ev);
            }
            if (fine) trace("frame {d}: drained", .{frames});
            // The user closed the window (red button) → the window is no longer visible.
            // A miniaturized window also reports !isVisible, so check it too — minimizing
            // must not quit the app.
            if (self.win) |w| {
                if (!msgBool(w, "isVisible") and !msgBool(w, "isMiniaturized")) self.closed = true;
            }
            if (self.closed) break;

            self.syncSize();
            if (fine) trace("frame {d}: size synced", .{frames});

            if (self.opts.on_tick) |tick| {
                const interval_ns = @as(u64, @max(self.opts.tick_ms, 1)) * std.time.ns_per_ms;
                const now = nowNs();
                if (now -% self.last_tick_ns >= interval_ns) {
                    self.last_tick_ns = now;
                    tick(self, self.opts.user);
                }
            }

            if (self.opts.on_draw) |draw| {
                sync.lock(&self.mutex, self.io);
                @memset(self.pixels, 0xFF000000);
                var canvas = paint.Canvas.init(self.pixels, self.width, self.height);
                const content = window.Rect{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
                draw(&canvas, content, self.opts.user);
                if (traceOn() and getenv("ZICRO_COCOA_PROBE") != null) self.paintProbe();
                sync.unlock(&self.mutex, self.io);
            }
            if (fine) trace("frame {d}: drawn", .{frames});
            self.present();
            frames += 1;
            if (frames <= 5 or frames % 120 == 0) trace("frame {d} presented ({d}x{d})", .{ frames, self.width, self.height });

            msgVoid(app, "updateWindows");
            if (fine) trace("frame {d}: updateWindows done, sleeping", .{frames});
            sync.sleepNs(self.io, 16 * std.time.ns_per_ms); // ~60 FPS pacing
        }
    }

    /// ZICRO_COCOA_PROBE=1 (with trace on): overwrite the frame with an orientation
    /// calibration pattern — red band at the TOP, green band at the BOTTOM, blue band on
    /// the LEFT, gray elsewhere. One snapshot then reveals the present transform.
    fn paintProbe(self: *Window) void {
        const w = self.width;
        const h = self.height;
        for (0..h) |y| {
            for (0..w) |x| {
                const px: u32 = if (y < 100) 0xFFFF0000 // top → red
                else if (y >= h - 100) 0xFF00FF00 // bottom → green
                else if (x < 100) 0xFF0000FF // left → blue
                else 0xFF808080;
                self.pixels[y * w + x] = px;
            }
        }
    }

    const nowNs = clockNs;

    // --- input dispatch -----------------------------------------------------------------

    /// Route one NSEvent to the app callbacks, translating to the cross-platform contract
    /// (evdev key/button codes, content coordinates with y growing downward).
    fn dispatch(self: *Window, ev: id) void {
        const ns_type = msgU64(ev, "type");

        // Modifier transitions first, from the flags EVERY event carries: real macOS
        // reports modifier presses only as flagsChanged, zart never posts them at all —
        // the flag delta is the one signal both worlds deliver.
        self.syncMods(msgU64(ev, "modifierFlags"));

        switch (ns_type) {
            NSKeyDown, NSKeyUp => {
                const cb = self.opts.on_key orelse return;
                const code = keyCodeOf(ev);
                if (code == 0) return;
                cb(self, code, if (ns_type == NSKeyDown) 1 else 0, self.opts.user);
            },
            NSLeftMouseDown, NSRightMouseDown, NSOtherMouseDown => {
                const p = self.mouseAt(ev);
                self.emitMouse(.{ .kind = .press, .x = p.x, .y = p.y, .button = buttonOf(ns_type) });
            },
            NSLeftMouseUp, NSRightMouseUp, NSOtherMouseUp => {
                const p = self.mouseAt(ev);
                self.emitMouse(.{ .kind = .release, .x = p.x, .y = p.y, .button = buttonOf(ns_type) });
            },
            NSMouseMoved, NSLeftMouseDragged, NSRightMouseDragged, NSOtherMouseDragged => {
                const p = self.mouseAt(ev);
                self.emitMouse(.{ .kind = .motion, .x = p.x, .y = p.y });
            },
            NSScrollWheel => {
                const p = self.mouseAt(ev);
                // deltaY > 0 = wheel up = content up, the same sign as the Wayland path.
                const dy: f32 = @floatCast(msgF64(ev, "deltaY"));
                self.emitMouse(.{ .kind = .scroll, .x = p.x, .y = p.y, .scroll_dy = dy * 10.0 });
            },
            else => {},
        }
    }

    fn emitMouse(self: *Window, event: window.MouseEvent) void {
        const cb = self.opts.on_mouse orelse return;
        cb(self, event, self.opts.user);
    }

    /// Event location → content coordinates (origin top-left, y down). The view is not
    /// flipped, so view coordinates are y-up: flip against the current content height.
    fn mouseAt(self: *Window, ev: id) struct { x: f32, y: f32 } {
        const view = self.view orelse return .{ .x = 0, .y = 0 };
        const loc = msgPoint(ev, "locationInWindow");
        const p = msgConvertPoint(view, loc, null);
        const h: f64 = @floatFromInt(self.height);
        return .{ .x = @floatCast(p.x), .y = @floatCast(h - p.y) };
    }

    /// Synthesize evdev press/release transitions for Shift/Ctrl/Alt from the modifier
    /// flags. Command counts as Ctrl: it is the primary macOS shortcut modifier, and zart
    /// normalizes Linux Ctrl to Command in the other direction — mapping both onto
    /// KEY_LEFTCTRL makes Cmd+Z and Ctrl+Z the same `on_key` sequence everywhere.
    fn syncMods(self: *Window, flags: u64) void {
        const cb = self.opts.on_key orelse return;
        const shift = flags & ModShift != 0;
        const ctrl = flags & (ModControl | ModCommand) != 0;
        const alt = flags & ModOption != 0;
        if (shift != self.mods_shift) {
            self.mods_shift = shift;
            cb(self, KEY_LEFTSHIFT, @intFromBool(shift), self.opts.user);
        }
        if (ctrl != self.mods_ctrl) {
            self.mods_ctrl = ctrl;
            cb(self, KEY_LEFTCTRL, @intFromBool(ctrl), self.opts.user);
        }
        if (alt != self.mods_alt) {
            self.mods_alt = alt;
            cb(self, KEY_LEFTALT, @intFromBool(alt), self.opts.user);
        }
    }
};

fn buttonOf(ns_type: u64) u32 {
    return switch (ns_type) {
        NSLeftMouseDown, NSLeftMouseUp => BTN_LEFT,
        NSRightMouseDown, NSRightMouseUp => BTN_RIGHT,
        else => BTN_MIDDLE,
    };
}

/// The evdev keycode of a key event, decoded from `charactersIgnoringModifiers` (see the
/// module doc: `keyCode` is not portable between real AppKit and zart). Returns 0 for
/// keys outside the map.
fn keyCodeOf(ev: id) u32 {
    const chars = msgId(ev, "charactersIgnoringModifiers") orelse return 0;
    if (msgU64(chars, "length") == 0) return 0;
    return charToEvdev(msgCharAt(chars, 0));
}

/// US-layout character → evdev keycode. `charactersIgnoringModifiers` applies Shift
/// (Apple semantics: it ignores everything EXCEPT Shift), so shifted symbols map to their
/// physical key — the synthesized Shift state (see `syncMods`) carries the case signal.
fn charToEvdev(c: u16) u32 {
    return switch (c) {
        'a', 'A' => 30,
        'b', 'B' => 48,
        'c', 'C' => 46,
        'd', 'D' => 32,
        'e', 'E' => 18,
        'f', 'F' => 33,
        'g', 'G' => 34,
        'h', 'H' => 35,
        'i', 'I' => 23,
        'j', 'J' => 36,
        'k', 'K' => 37,
        'l', 'L' => 38,
        'm', 'M' => 50,
        'n', 'N' => 49,
        'o', 'O' => 24,
        'p', 'P' => 25,
        'q', 'Q' => 16,
        'r', 'R' => 19,
        's', 'S' => 31,
        't', 'T' => 20,
        'u', 'U' => 22,
        'v', 'V' => 47,
        'w', 'W' => 17,
        'x', 'X' => 45,
        'y', 'Y' => 21,
        'z', 'Z' => 44,
        '1', '!' => 2,
        '2', '@' => 3,
        '3', '#' => 4,
        '4', '$' => 5,
        '5', '%' => 6,
        '6', '^' => 7,
        '7', '&' => 8,
        '8', '*' => 9,
        '9', '(' => 10,
        '0', ')' => 11,
        '-', '_' => 12,
        '=', '+' => 13,
        '[', '{' => 26,
        ']', '}' => 27,
        '\\', '|' => 43,
        ';', ':' => 39,
        '\'', '"' => 40,
        '`', '~' => 41,
        ',', '<' => 51,
        '.', '>' => 52,
        '/', '?' => 53,
        ' ' => 57,
        '\r', '\n', 0x03 => 28, // Return / keypad Enter
        '\t' => 15,
        0x1B => 1, // Escape
        0x7F, 0x08 => 14, // Delete (backspace)
        0xF700 => 103, // NSUpArrowFunctionKey
        0xF701 => 108, // NSDownArrowFunctionKey
        0xF702 => 105, // NSLeftArrowFunctionKey
        0xF703 => 106, // NSRightArrowFunctionKey
        0xF728 => 111, // NSDeleteFunctionKey (forward delete)
        0xF729 => 102, // NSHomeFunctionKey
        0xF72B => 107, // NSEndFunctionKey
        0xF72C => 104, // NSPageUpFunctionKey
        0xF72D => 109, // NSPageDownFunctionKey
        0xF704...0xF70D => 59 + (@as(u32, c) - 0xF704), // F1..F10
        0xF70E => 87, // F11
        0xF70F => 88, // F12
        else => 0,
    };
}
