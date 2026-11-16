//! # zrame.window — the public window facade
//!
//! Two adapters over zicro's window, selected at comptime by `Window` below, one per way
//! zicro drives a frame:
//!
//! | os/target              | adapter              | how zicro drives the frame                                   |
//! |------------------------|----------------------|---------------------------------------------------------------|
//! | linux (desktop), windows | `window_native.zig` | composes on damage (`on_compose`): glass chrome cached, dmabuf video plane, IME, popups, tray and global menu (Linux) |
//! | macos, wasm, android   | `window_canvas.zig`  | hands `on_draw` a canvas every frame; the targets differ by a few comptime switches (chrome, margin, text input) |
//!
//! Both expose the SAME core surface (`init`/`run`/`presentRgba`/`waitFrame`/
//! `toggleFullscreen`/`setStyle`/`close` + the `panel_w`/`panel_h`/`closed` fields; see
//! `verifyWindowBackendContract`), so callers — and zrame's own `sink.zig` — are
//! backend-agnostic; the Linux-only extras (tray, dbusmenu) are no-ops elsewhere.
//! `waitFrame(timeout_ms)` blocks any thread until the compositor's next frame callback
//! (Wayland); the other backends answer at once and callers pace themselves.
//!
//! This file owns the platform-independent public *types* every backend shares, so the
//! callback signatures (`fn (window: *Window, …)`) resolve to the selected backend.

const std = @import("std");
const builtin = @import("builtin");

const zicro = @import("zicro");
const paint = zicro.paint;
const plugin = @import("plugin.zig");
const controls = @import("controls.zig");
const dbusmenu = @import("dbusmenu.zig");

pub const Style = paint.Style;
pub const Panel = plugin.Panel;
pub const Host = plugin.Host;
pub const TitlebarStyle = controls.Layout;

/// The panel-content rectangle in canvas coordinates (shared with the plugin seam).
pub const Rect = plugin.Rect;

/// A single memory plane of a dmabuf GPU buffer export (fd, offset, stride, modifier).
pub const DmabufPlane = zicro.window.DmabufPlane;

/// Responsive metrics (`Window.metrics`) are the substrate's: see `zicro.window.Metrics`.
pub const Metrics = zicro.window.Metrics;
pub const FormFactor = zicro.window.FormFactor;

/// The concrete window struct for this target. Selected at comptime; the backends
/// mutually import this file for the shared types below, so `*Window` in a callback
/// signature is exactly the backend struct the caller receives.
pub const Window = if (builtin.cpu.arch.isWasm() or builtin.os.tag == .macos or
    builtin.abi == .android or builtin.abi == .androideabi)
    // zicro hands a canvas every frame: one adapter, a few comptime switches.
    @import("window_canvas.zig").Window
else
    // Wayland and Win32: zicro composes on damage, with the video plane and the
    // desktop integrations.
    @import("window_native.zig").Window;

comptime {
    verifyWindowBackendContract(Window);
}

fn verifyWindowBackendContract(comptime W: type) void {
    const required_fields = [_][]const u8{
        "panel_w",
        "panel_h",
        "closed",
    };
    inline for (required_fields) |name| {
        if (!@hasField(W, name)) {
            @compileError("Window backend missing field '" ++ name ++ "'");
        }
    }

    const required_decls = [_][]const u8{
        "init",
        "deinit",
        "run",
        "requestClose",
        "close",
        "isVisible",
        "setVisible",
        "metrics",
        "physPx",
        "contentPx",
        "contentRect",
        "presentRgba",
        "presentRgbaRegion",
        "dmabufAvailable",
        "presentDmabufPlanes",
        "presentDmabufPlanesIn",
        "waitFrame",
        "toggleFullscreen",
        "setStyle",
        "reserveGutter",
        "textFont",
        "host",
    };
    inline for (required_decls) |name| {
        if (!@hasDecl(W, name)) {
            @compileError("Window backend missing declaration '" ++ name ++ "'");
        }
    }
}

/// Mouse events delivered to the app's `on_mouse` callback — zicro's own `MouseEvent`,
/// the one pointer vocabulary of the stack (`kind` = motion / press / release / scroll /
/// leave; `button` an evdev BTN_* code; `scroll_dy`/`scroll_dx` in Wayland axis units,
/// positive = scrolling down/right). Every kind but `.leave` carries the pointer position.
///
/// Coordinates are in the app's PRESENTATION space, not canvas space: the origin
/// is the top-left of the frame the app last staged with `presentRgba` (zrame centers it
/// in the content rect), or the content rect itself before any frame is staged. So an
/// app hit-tests with the same coordinates it drew with, and never sees the shadow
/// gutter, title bar, or frame-centering offsets — the client-coordinates contract of
/// mainstream toolkits (Win32 client area, Cocoa view coords, SDL logical presentation).
/// Chrome-space input (panels, resize bands) stays inside zrame in canvas coordinates.
pub const MouseEvent = zicro.window.MouseEvent;

/// Multi-touch gesture recognized by the substrate (pinch, …). One finger arrives as a
/// mouse event on `on_mouse`; two fingers land here. `scale` = incremental zoom ratio,
/// `(cx,cy)` the center, `(dx,dy)` the translation — the app zooms/pans however it likes.
/// See `zicro.gesture`. Only fires on the web and Android backends today — Wayland/Win32/
/// Cocoa track at most a single primary finger and never invoke this callback.
pub const GestureEvent = zicro.gesture.Gesture;

/// Declarative tray-icon config (see `tray.zig`). `on_activate` fires on left-click.
/// Linux-only in effect (StatusNotifierItem over DBus); ignored on other platforms.
pub const TrayConfig = struct {
    id: [:0]const u8 = "dev.zrame.window",
    title: [:0]const u8 = "zrame",
    icon_name: [:0]const u8 = "application-x-executable",
    tooltip: [:0]const u8 = "",
    on_activate: ?*const fn (window: *Window, user: ?*anyopaque) void = null,
};

/// How a presented GPU frame (`presentDmabuf`) is placed in the content rect.
pub const VideoFit = enum {
    /// The frame FILLS the content rect (wp_viewport scales it on the scanout
    /// path, for free). Its pixel size is then a quality knob — the resolution
    /// tier, dynamic-res, FSR — and not a statement about how big the window is.
    /// This is what a window whose whole content IS the render wants; anything
    /// else leaves a border of empty glass around it.
    fill,
    /// The frame is presented at its native size, centered. For a window whose
    /// render is a PANEL inside a larger card — the rest of the content rect
    /// belongs to `on_draw` (text, chrome) and must not be painted over.
    native,
    /// The frame is scaled (wp_viewport, free) to the largest rect of its own aspect
    /// ratio inside the content rect, centered: a video in a window or a screen of
    /// another shape, letterboxed. Its pixel size is a quality knob, as with `fill`.
    contain,
};

pub const Options = struct {
    title: [:0]const u8 = "zrame",
    app_id: [:0]const u8 = "dev.zrame.window",
    /// Initial size of the glass panel (the window geometry), in pixels.
    width: u32 = 720,
    height: u32 = 460,
    style: Style = .{},
    /// Draw a client-side title bar with window controls (see [`TitlebarStyle`]). Off by
    /// default so bare content windows keep the whole panel; the content rect shrinks by
    /// `titlebar_height` when on. Ignored on platforms that use native decorations.
    titlebar: bool = false,
    /// Title-bar height in panel pixels.
    titlebar_height: u32 = 38,
    /// Traffic-lights (macOS) or right-aligned buttons (Material). Default macOS.
    titlebar_style: TitlebarStyle = .macos,
    /// Where a staged GPU frame lands in the content rect (see [`VideoFit`]).
    video_fit: VideoFit = .fill,
    /// Client-drawn right-click window menu (Minimize/Maximize/Full Screen/Close).
    context_menu: bool = true,
    /// Close the window on ESC (handy for demo/tool windows). Apps that use ESC
    /// themselves (dialogs, editors) turn this off and decide in `on_key`.
    close_on_esc: bool = true,
    // --- callbacks -------------------------------------------------------------------
    // The ones zicro's window has too keep zicro's meaning (`zicro.window.Options`, the
    // reference doc) and its signature, with zrame's `*Window`; `checkCallbackParity`
    // below fails the build if the two drift. Only what zrame changes is noted here.

    /// Paints app content on the canvas, after the chrome and before any staged frame.
    /// `content` is the content rect in canvas pixels (unsigned: zrame's `Rect`).
    on_draw: ?*const fn (canvas: *paint.Canvas, content: Rect, user: ?*anyopaque) void = null,
    /// A key the panels did not take (evdev code; state 1 pressed / 0 released).
    on_key: ?*const fn (window: *Window, key: u32, state: u32, user: ?*anyopaque) void = null,
    /// Layout-correct text of a key press the panels did not take. On the web and
    /// Android, which give no layout text, zrame types it through the US keymap.
    on_text: ?*const fn (window: *Window, bytes: [4]u8, len: u8, user: ?*anyopaque) void = null,
    /// IME pre-edit (Wayland only).
    on_preedit: ?*const fn (window: *Window, text: []const u8, cursor_begin: i32, cursor_end: i32, user: ?*anyopaque) void = null,
    /// Pointer events the panels did not take, in the app's PRESENTATION space (see
    /// [`MouseEvent`]). Return **true to consume** the event: the window then skips its
    /// own handling (drag-to-move, resize cursor).
    on_mouse: ?*const fn (window: *Window, event: MouseEvent, user: ?*anyopaque) bool = null,
    /// Two-finger gestures (web and Android), center in presentation space.
    on_gesture: ?*const fn (window: *Window, gesture: GestureEvent, user: ?*anyopaque) void = null,
    /// Veto on a close the system asks for (Wayland, Win32, Cocoa).
    on_close_request: ?*const fn (window: *Window, user: ?*anyopaque) bool = null,
    /// A file the system asks the app to open (macOS Finder / Dock; elsewhere argv).
    on_open_file: ?*const fn (window: *Window, path: []const u8, user: ?*anyopaque) void = null,
    /// Optional system-tray icon (StatusNotifierItem over DBus). Linux-only; a no-op
    /// elsewhere.
    tray: ?TrayConfig = null,
    /// Optional KDE global menu (`com.canonical.dbusmenu`). Linux-only; a no-op elsewhere.
    menu: ?[]const dbusmenu.Item = null,
    user: ?*anyopaque = null,
};

comptime {
    checkCallbackParity();
}

/// Every callback both `Options` declare must keep the same shape on both sides: the
/// same parameters, where zicro's `*Window` reads zrame's, and the same result. The only
/// differences allowed are the ones zrame makes on purpose: `on_draw`'s content rect is
/// zrame's unsigned `Rect`, and `on_mouse` answers whether the app consumed the event.
fn checkCallbackParity() void {
    const Z = zicro.window.Options;
    const shared = [_][]const u8{ "on_draw", "on_key", "on_text", "on_preedit", "on_mouse", "on_gesture", "on_close_request", "on_open_file" };
    @setEvalBranchQuota(10_000);
    for (shared) |name| {
        if (!@hasField(Z, name)) @compileError("zicro.window.Options lost '" ++ name ++ "': update zrame.Options");
        const zf = fnInfo(@FieldType(Z, name));
        const rf = fnInfo(@FieldType(Options, name));
        if (zf.param_types.len != rf.param_types.len) @compileError("zrame.Options." ++ name ++ ": parameter count differs from zicro's");
        for (zf.param_types, rf.param_types, 0..) |zp, rp, i| {
            const zt = zp.?;
            const rt = rp.?;
            if (zt == rt) continue;
            if (zt == *zicro.window.Window and rt == *Window) continue;
            if (std.mem.eql(u8, name, "on_draw") and i == 1 and zt == zicro.window.Rect and rt == Rect) continue;
            @compileError("zrame.Options." ++ name ++ ": parameter type differs from zicro's");
        }
        const zr = zf.return_type.?;
        const rr = rf.return_type.?;
        if (zr != rr and !(std.mem.eql(u8, name, "on_mouse") and zr == void and rr == bool))
            @compileError("zrame.Options." ++ name ++ ": result type differs from zicro's");
    }
}

fn fnInfo(comptime Field: type) std.builtin.Type.Fn {
    const ptr = @typeInfo(@typeInfo(Field).optional.child).pointer;
    return @typeInfo(ptr.child).@"fn";
}
