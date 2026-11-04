//! # zrame.window (Win32 backend) — a frameless, client-decorated *layered* window
//!
//! The Windows counterpart to `window_wayland.zig`, with the same **frameless glass**
//! experience: no OS title bar or borders — `WM_NCCALCSIZE` collapses the non-client area so
//! the client fills the whole window — and the *entire* window (rounded glass panel, drop
//! shadow, translucency, plus the app's own chrome: title-bar controls when enabled, floating
//! scrollbars, right-click menu) is composited client-side into a DIB and pushed with
//! per-pixel alpha via `UpdateLayeredWindow`. It uses the very same `paint.drawChrome` the
//! Wayland backend paints, over a shadow-gutter margin, so the look matches 1:1 — and because
//! the compositing is client-side it shows **even under Wine**, where DWM acrylic cannot. The
//! one piece reserved for real Windows is the *frosted blur behind* the glass (needs the DWM
//! compositor, exactly as the Wayland blur needs KWin).
//!
//! Interaction mirrors the Wayland path exactly: near-edge drags resize (8px band → the OS
//! `SC_SIZE` loop, with native cursors + Aero snap), an unconsumed border drag moves the
//! window (30px band → a synthetic `HTCAPTION`), and panels/`on_mouse` get first dibs on
//! every click so content interactions never fight the move/resize.
//!
//! The public surface matches the Wayland backend exactly (see the facade `window.zig`),
//! so `sink.zig` and every zrame app are backend-agnostic. Key/mouse/scroll
//! events are translated to the **same evdev codes / axis units** the Wayland path emits,
//! so `on_key`/`on_mouse`/`on_scroll` handlers are identical across platforms.
//!
//! Threading contract, same as Wayland: everything windowing happens on the thread that
//! calls `run`; `presentRgba` is the one cross-thread door — it stages pixels under a lock
//! and pokes the UI thread with a thread-safe `PostMessageW`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zicro = @import("zicro");
const paint = zicro.paint;
const text = zicro.text;

const facade = @import("window.zig");
const plugin = @import("plugin.zig");
const controls = @import("controls.zig");
const menu = @import("menu.zig");
const scroll = @import("scroll.zig");

pub const Style = facade.Style;
pub const Panel = facade.Panel;
pub const Host = facade.Host;
pub const Options = facade.Options;
pub const MouseEvent = facade.MouseEvent;
pub const Rect = facade.Rect;

// --- Win32 FFI ----------------------------------------------------------------------

const HWND = ?*anyopaque;
const HDC = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: HINSTANCE,
    hIcon: HICON = null,
    hCursor: HCURSOR = null,
    hbrBackground: HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: HICON = null,
};

const POINT = extern struct { x: i32, y: i32 };
const MSG = extern struct {
    hwnd: HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
    lPrivate: u32 = 0,
};
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0, // BI_RGB
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};
const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32 = .{0},
};
const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: i32,
    rcPaint: RECT,
    fRestore: i32,
    fIncUpdate: i32,
    rgbReserved: [32]u8 = @splat(0),
};
const TRACKMOUSEEVENT = extern struct {
    cbSize: u32 = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: u32,
    hwndTrack: HWND,
    dwHoverTime: u32 = 0,
};
const WINDOWPLACEMENT = extern struct {
    length: u32 = @sizeOf(WINDOWPLACEMENT),
    flags: u32 = 0,
    showCmd: u32 = 0,
    ptMinPosition: POINT = .{ .x = 0, .y = 0 },
    ptMaxPosition: POINT = .{ .x = 0, .y = 0 },
    rcNormalPosition: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) HINSTANCE;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, ?[*:0]const u16, u32, i32, i32, i32, i32, HWND, ?*anyopaque, HINSTANCE, ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) i32;
extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(*MSG, HWND, u32, u32) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostMessageW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) i32;
extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) i32;
extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) i32;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) i32;
extern "user32" fn InvalidateRect(HWND, ?*const RECT, i32) callconv(.winapi) i32;
extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) HDC;
extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) i32;
extern "user32" fn GetDC(HWND) callconv(.winapi) HDC;
extern "user32" fn ReleaseDC(HWND, HDC) callconv(.winapi) i32;
extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
extern "user32" fn GetWindowLongW(HWND, i32) callconv(.winapi) i32;
extern "user32" fn SetWindowLongW(HWND, i32, i32) callconv(.winapi) i32;
extern "user32" fn SetWindowPos(HWND, HWND, i32, i32, i32, i32, u32) callconv(.winapi) i32;
extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) i32;
extern "user32" fn AdjustWindowRectEx(*RECT, u32, i32, u32) callconv(.winapi) i32;
extern "user32" fn GetSystemMetrics(i32) callconv(.winapi) i32;
extern "user32" fn LoadCursorW(HINSTANCE, usize) callconv(.winapi) HCURSOR;
extern "user32" fn SetCursor(HCURSOR) callconv(.winapi) HCURSOR;
extern "user32" fn SetTimer(HWND, usize, u32, ?*anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(HWND, usize) callconv(.winapi) i32;
extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) i32;
extern "user32" fn GetWindowPlacement(HWND, *WINDOWPLACEMENT) callconv(.winapi) i32;
extern "user32" fn SendMessageW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ReleaseCapture() callconv(.winapi) i32;
extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) i32;
extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.winapi) i32;
// Layered-window presentation: the whole window (glass chrome + content) is composed into a
// DIB section and pushed with per-pixel alpha via UpdateLayeredWindow. So the rounded panel,
// drop shadow and translucency are painted *client-side* — exactly the same `drawChrome` the
// Wayland backend uses — and show even without a compositor (i.e. under Wine, unlike DWM
// acrylic blur which fundamentally needs the real Windows compositor).
extern "user32" fn UpdateLayeredWindow(HWND, HDC, ?*const POINT, ?*const SIZE, HDC, ?*const POINT, u32, *const BLENDFUNCTION, u32) callconv(.winapi) i32;
extern "gdi32" fn CreateCompatibleDC(HDC) callconv(.winapi) HDC;
extern "gdi32" fn CreateDIBSection(HDC, *const BITMAPINFO, u32, *?*anyopaque, ?*anyopaque, u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SelectObject(HDC, ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(?*anyopaque) callconv(.winapi) i32;
extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) i32;
// Opaque fast-path (ZUER_OPAQUE=1): a straight top-down-DIB BitBlt, no per-pixel alpha. Under
// Wine — which has no DWM to GPU-composite the layered glass — this trades the glass for a
// fast blit, so 3D/video stay fluid while testing. The layered glass is the default.
extern "gdi32" fn SetDIBitsToDevice(HDC, i32, i32, u32, u32, i32, i32, u32, u32, ?*const anyopaque, *const BITMAPINFO, u32) callconv(.winapi) i32;
extern fn getenv([*:0]const u8) ?[*:0]const u8;
// System clipboard (CF_UNICODETEXT): the handle passed to SetClipboardData must be
// GMEM_MOVEABLE global memory, whose ownership transfers to the system on success.
extern "user32" fn OpenClipboard(HWND) callconv(.winapi) i32;
extern "user32" fn CloseClipboard() callconv(.winapi) i32;
extern "user32" fn EmptyClipboard() callconv(.winapi) i32;
extern "user32" fn SetClipboardData(u32, ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetClipboardData(u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalAlloc(u32, usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GlobalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;

const CF_UNICODETEXT: u32 = 13;
const GMEM_MOVEABLE: u32 = 0x0002;

const SIZE = extern struct { cx: i32, cy: i32 };
const BLENDFUNCTION = extern struct { BlendOp: u8, BlendFlags: u8, SourceConstantAlpha: u8, AlphaFormat: u8 };

// Window/message constants.
const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
const WS_POPUP: u32 = 0x80000000;
const WS_VISIBLE: u32 = 0x10000000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const GWL_STYLE: i32 = -16;
const GWLP_USERDATA: i32 = -21;

const SW_MINIMIZE: i32 = 6;
const SW_MAXIMIZE: i32 = 3;
const SW_RESTORE: i32 = 9;
const SW_SHOWNORMAL: i32 = 1;
const SW_MAX_STATE: u32 = 3; // SW_SHOWMAXIMIZED value seen in WINDOWPLACEMENT.showCmd

const SWP_NOSIZE: u32 = 0x0001;
const SWP_NOMOVE: u32 = 0x0002;
const SWP_NOZORDER: u32 = 0x0004;
const SWP_FRAMECHANGED: u32 = 0x0020;
const SWP_SHOWWINDOW: u32 = 0x0040;

// Layered window (WS_EX_LAYERED) + UpdateLayeredWindow per-pixel alpha.
const WS_EX_LAYERED: u32 = 0x00080000;
const ULW_ALPHA: u32 = 0x02;
const AC_SRC_OVER: u8 = 0x00;
const AC_SRC_ALPHA: u8 = 0x01;
const DIB_RGB_COLORS: u32 = 0;

const WM_DESTROY: u32 = 0x0002;
const WM_SIZE: u32 = 0x0005;
const WM_PAINT: u32 = 0x000F;
const WM_CLOSE: u32 = 0x0010;
const WM_ERASEBKGND: u32 = 0x0014;
const WM_KEYDOWN: u32 = 0x0100;
const WM_KEYUP: u32 = 0x0101;
const WM_SYSKEYDOWN: u32 = 0x0104; // tasti con Alt premuto (e F10)
const WM_SYSKEYUP: u32 = 0x0105;
const WM_CHAR: u32 = 0x0102;
const WM_MOUSEMOVE: u32 = 0x0200;
const WM_LBUTTONDOWN: u32 = 0x0201;
const WM_LBUTTONUP: u32 = 0x0202;
const WM_RBUTTONDOWN: u32 = 0x0204;
const WM_RBUTTONUP: u32 = 0x0205;
const WM_MOUSEWHEEL: u32 = 0x020A;
const WM_MOUSEHWHEEL: u32 = 0x020E;
const WM_MOUSELEAVE: u32 = 0x02A3;
const WM_TIMER: u32 = 0x0113;
const WM_NCCALCSIZE: u32 = 0x0083;
const WM_NCLBUTTONDOWN: u32 = 0x00A1;
const WM_SETCURSOR: u32 = 0x0020;
const WM_KILLFOCUS: u32 = 0x0008;
const WM_SYSCOMMAND: u32 = 0x0112;
const WM_APP_PRESENT: u32 = 0x8001; // WM_APP + 1: a freshly staged frame is ready

// Frameless move/resize: hand a client drag to the OS via a synthetic caption hit
// (WM_NCLBUTTONDOWN) or a sizing command (SC_SIZE + edge). Same modal loops the native
// title bar/borders use, so Aero snap and cursors come for free.
const HTCLIENT = 1;
const HTCAPTION = 2;
const SC_SIZE: WPARAM = 0xF000;
// SC_SIZE + these directions = the border the OS starts sizing from.
const WMSZ_LEFT: WPARAM = 1;
const WMSZ_RIGHT: WPARAM = 2;
const WMSZ_TOP: WPARAM = 3;
const WMSZ_TOPLEFT: WPARAM = 4;
const WMSZ_TOPRIGHT: WPARAM = 5;
const WMSZ_BOTTOM: WPARAM = 6;
const WMSZ_BOTTOMLEFT: WPARAM = 7;
const WMSZ_BOTTOMRIGHT: WPARAM = 8;

const IDC_ARROW: usize = 32512;
const IDC_SIZENWSE: usize = 32642;
const IDC_SIZENESW: usize = 32643;
const IDC_SIZEWE: usize = 32644;
const IDC_SIZENS: usize = 32645;

// Resize-edge band (px) and window-move border band (px), mirroring the Wayland backend
// (`resizeEdgeAt` = 8px, the titlebar-less move grab = 30px).
const RESIZE_BAND: f32 = 8.0;
const MOVE_BAND: f32 = 30.0;

const TME_LEAVE: u32 = 0x00000002;
const ANIM_TIMER_ID: usize = 1;

/// Which window border a pointer is over, for frameless resize.
const Edge = enum { none, left, right, top, bottom, top_left, top_right, bottom_left, bottom_right };

// evdev button codes, matching the Wayland path (`BTN_LEFT`/`BTN_RIGHT`).
const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;

// The cross-thread frame mailbox and its composition are shared with the Wayland backend.
const chrome = @import("chrome.zig");
const SpinLock = chrome.SpinLock;
const Staged = chrome.Staged;

pub const Window = struct {
    gpa: Allocator,
    opts: Options,
    hwnd: HWND = null,

    /// Client-area size in pixels — the public geometry the app reads and presents into.
    panel_w: u32,
    panel_h: u32,
    closed: bool = false,
    fullscreen: bool = false,
    maximized: bool = false,
    /// ZUER_OPAQUE=1: skip WS_EX_LAYERED + the glass, present with a plain opaque BitBlt.
    /// A perf escape hatch for Wine (no DWM → the layered glass composites in software).
    opaque_mode: bool = false,
    saved_style: u32 = 0,
    saved_margin: u32 = 0,
    saved_content_radius: f32 = 0,
    saved_rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

    font: ?text.Font = null,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    tracking_leave: bool = false,
    /// WM_CHAR delivers astral-plane text as a surrogate pair split over two messages;
    /// the high half parks here until its low half arrives (0 = none pending).
    high_surrogate: u16 = 0,

    panels: plugin.Registry,
    scrollbars: scroll.Scroll = .{ .follow_content = true },
    timer_armed: bool = false,
    /// Tasti (evdev) premuti e non ancora rilasciati: alla perdita del focus (dialog
    /// modale aperto da Ctrl+S, Alt+Tab…) il WM_KEYUP va alla finestra che ha il focus,
    /// non a noi; senza i rilasci sintetici l'app crederebbe Ctrl ancora premuto.
    held_keys: std.StaticBitSet(256) = .empty,
    /// Un ridisegno chiesto (app o pannelli) non ancora servito dal timer: il tick non
    /// deve spegnere il timer finché c'è, anche se la richiesta arriva DENTRO il frame.
    redraw_pending: bool = false,
    last_tick_ms: u64 = 0,

    // Cross-thread frame mailbox (same shape as the Wayland backend): producers write
    // `staged` under the lock; the UI thread swaps it into `front` and composites.
    mailbox: chrome.FrameMailbox = .{},

    // Presentation buffers. We compose into `frame`, a plain gpa heap buffer — composing
    // straight into DIB-section memory is pathologically slow under Wine (blitRgba's per-pixel
    // read-modify-write hits GDI-synced memory), so we keep composition on fast heap RAM and
    // move the finished frame out in one bulk transfer: opaque BitBlts `frame` directly, glass
    // memcpy's it into the DIB `buf` once, then UpdateLayeredWindow. `decor` is the pre-painted
    // glass chrome (rounded panel + drop shadow) copied in as the background each frame.
    mem_dc: HDC = null,
    dib: ?*anyopaque = null,
    buf: []u32 = &.{}, // aliases the DIB section (glass only; owned by the HBITMAP, not the gpa)
    frame: []u32 = &.{}, // gpa heap compose target
    decor: []u32 = &.{},
    buf_w: u32 = 0,
    buf_h: u32 = 0,

    pub fn init(gpa: Allocator, opts: Options) !*Window {
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .opts = opts,
            .panel_w = @max(opts.width, 160),
            .panel_h = @max(opts.height, 120),
            .panels = plugin.Registry.init(gpa),
            .opaque_mode = isOpaqueRequested(),
        };

        const hinst = GetModuleHandleW(null);
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZrameWindowClass");
        const wc = WNDCLASSEXW{
            .style = 0x0003, // CS_HREDRAW | CS_VREDRAW
            .lpfnWndProc = wndProc,
            .hInstance = hinst,
            .hCursor = LoadCursorW(null, IDC_ARROW),
            .lpszClassName = class_name,
        };
        _ = RegisterClassExW(&wc);

        // Frameless *layered* window: WS_EX_LAYERED so UpdateLayeredWindow drives every pixel
        // (glass chrome + shadow + content) with per-pixel alpha; WS_OVERLAPPEDWINDOW keeps
        // the taskbar entry + min/max/snap, and `WM_NCCALCSIZE` collapses the OS frame so the
        // client fills the whole window. The window is sized panel + a shadow-gutter margin on
        // every side (same as the Wayland buffer), so the drop shadow has room to fall. In the
        // opaque escape-hatch there is no gutter and no WS_EX_LAYERED — a plain square window.
        const m = self.curMargin();
        const ex_style: u32 = if (self.opaque_mode) 0 else WS_EX_LAYERED;
        const title = try std.unicode.utf8ToUtf16LeAllocZ(gpa, opts.title);
        defer gpa.free(title);

        const hwnd = CreateWindowExW(
            ex_style,
            class_name,
            title.ptr,
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            @intCast(self.panel_w + 2 * m),
            @intCast(self.panel_h + 2 * m),
            null,
            null,
            hinst,
            self,
        ) orelse return error.WindowCreationFailed;
        self.hwnd = hwnd;

        // Re-run frame calc now that the window exists, so the frameless client takes hold.
        // NOSIZE|NOMOVE: only trigger WM_NCCALCSIZE, don't actually move/resize the window.
        _ = SetWindowPos(hwnd, null, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_FRAMECHANGED);

        // Floating scrollbars are the bottom-most panel (borrowed: the Window owns the
        // field instance, so the registry must not free it). Mirrors the Wayland backend.
        try self.panels.add(Panel.of(scroll.Scroll, &self.scrollbars), false);
        if (opts.titlebar) {
            const c = try controls.Controls.create(gpa, opts.titlebar_style, opts.titlebar_height, opts.title);
            try self.panels.add(Panel.of(controls.Controls, c), true);
        }
        if (opts.context_menu) {
            const mnu = try menu.Menu.create(gpa);
            try self.panels.add(Panel.of(menu.Menu, mnu), true);
        }

        self.syncClientSize();
        // A layered window shows nothing until its first UpdateLayeredWindow, so compose and
        // push one frame *before* ShowWindow — otherwise the first paint flashes empty.
        self.present();
        _ = ShowWindow(hwnd, SW_SHOWNORMAL);
        return self;
    }

    pub fn deinit(self: *Window) void {
        self.panels.deinit();
        if (self.font) |*f| f.deinit();
        if (self.frame.len > 0) self.gpa.free(self.frame);
        if (self.decor.len > 0) self.gpa.free(self.decor);
        if (self.dib) |d| _ = DeleteObject(d);
        if (self.mem_dc != null) _ = DeleteDC(self.mem_dc);
        self.mailbox.deinit(self.gpa);
        if (self.hwnd) |h| _ = DestroyWindow(h);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn requestClose(self: *Window) void {
        self.close();
    }

    pub fn isVisible(self: *Window) bool {
        return !self.closed;
    }

    pub fn setVisible(self: *Window, visible: bool) void {
        if (!visible) self.close();
    }

    pub fn reserveGutter(_: *Window, _: u32) void {}

    /// No compositor blur on GDI.
    pub fn hasBlur(_: *Window) bool {
        return false;
    }

    /// Per-monitor DPI awareness is not wired yet on Win32 — the buffer is 1:1.
    pub fn scaleFactor(_: *const Window) f32 {
        return 1.0;
    }

    pub fn physPx(self: *Window, logical_dp: u32) u32 {
        return facade.physPxScale(self.scaleFactor(), logical_dp);
    }

    /// Responsive metrics — desktop, pointer-driven (no touch).
    pub fn metrics(self: *Window) facade.Metrics {
        const c = self.contentPx();
        return facade.computeMetrics(self.scaleFactor(), c.w, c.h, false);
    }

    /// Stage a straight-alpha RGBA frame for presentation. Safe from any thread; newest
    /// frame wins. Wakes the UI thread with a thread-safe PostMessageW.
    pub fn presentRgba(self: *Window, width: u32, height: u32, rgba: []const u8) void {
        if (self.mailbox.stage(self.gpa, width, height, rgba)) {
            _ = PostMessageW(self.hwnd, WM_APP_PRESENT, 0, 0);
        }
    }

    /// dmabuf zero-copy present is a Linux/Wayland path; on Windows there is no equivalent,
    /// so callers fall back to `presentRgba`.
    /// No video plane on this backend (`presentDmabuf` is a no-op): nothing to hide.
    pub fn hideVideo(_: *Window) void {}

    pub fn presentDmabuf(_: *Window, _: u8, _: i32, _: u32, _: u32, _: u32, _: u32, _: u64) bool {
        return false;
    }

    pub fn presentDmabufPlanes(_: *Window, _: u8, _: []const facade.DmabufPlane, _: u32, _: u32, _: u32) bool {
        return false;
    }

    pub fn videoBusy(_: *const Window) bool {
        return false;
    }

    /// API parity with the Wayland backend: on Win32 there is not (yet) a hook
    /// into the compositor's vsync, so it returns `false` IMMEDIATELY without blocking —
    /// the caller falls back to its own software pacer (same contract as the
    /// timed-out case on Wayland).
    pub fn waitFrame(_: *Window, _: u32) bool {
        return false;
    }

    /// The event loop: pumps Win32 messages until the window is closed.
    pub fn run(self: *Window) !void {
        var msg: MSG = undefined;
        while (!self.closed) {
            const r = GetMessageW(&msg, null, 0, 0);
            if (r == 0 or r == -1) break; // WM_QUIT or error
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
    }

    pub fn close(self: *Window) void {
        self.closed = true;
        _ = PostMessageW(self.hwnd, WM_CLOSE, 0, 0);
    }

    pub fn setStyle(self: *Window, style: Style) !void {
        self.opts.style = style;
        self.requestRedraw();
    }

    pub fn toggleFullscreen(self: *Window) void {
        const h = self.hwnd orelse return;
        self.fullscreen = !self.fullscreen;
        if (self.fullscreen) {
            // Drop the shadow gutter so the content fills the whole screen edge-to-edge
            // (mirrors the Wayland backend zeroing style.margin on fullscreen).
            self.saved_margin = self.opts.style.margin;
            self.saved_content_radius = self.opts.style.content_radius;
            self.opts.style.margin = 0;
            self.opts.style.content_radius = 0;
            self.saved_style = @bitCast(GetWindowLongW(h, GWL_STYLE));
            _ = GetWindowRect(h, &self.saved_rect);
            _ = SetWindowLongW(h, GWL_STYLE, @bitCast(WS_POPUP | WS_VISIBLE));
            const sw = GetSystemMetrics(0); // SM_CXSCREEN
            const sh = GetSystemMetrics(1); // SM_CYSCREEN
            _ = SetWindowPos(h, null, 0, 0, sw, sh, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        } else {
            self.opts.style.margin = self.saved_margin;
            self.opts.style.content_radius = self.saved_content_radius;
            _ = SetWindowLongW(h, GWL_STYLE, @bitCast(self.saved_style));
            const rw = self.saved_rect.right - self.saved_rect.left;
            const rh = self.saved_rect.bottom - self.saved_rect.top;
            _ = SetWindowPos(h, null, self.saved_rect.left, self.saved_rect.top, rw, rh, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        }
        self.syncClientSize();
        self.present();
    }

    /// Resize the window so its client area becomes `target_w`×`target_h`, keeping the
    /// top-left corner put. No-op in fullscreen/maximized. (The Wayland backend re-centers
    /// via the compositor; on Windows the app keeps its position.)
    pub fn animateResize(self: *Window, target_w: u32, target_h: u32) void {
        if (self.fullscreen or self.maximized) return;
        const h = self.hwnd orelse return;
        const tw = @max(target_w, 160);
        const th = @max(target_h, 120);
        if (tw == self.panel_w and th == self.panel_h) return;
        // Frameless layered: the window is the panel plus the shadow-gutter margin on each
        // side, so size it to target + 2·margin (margin is 0 in opaque mode). WM_SIZE then
        // re-syncs and re-presents.
        const m = self.curMargin();
        _ = SetWindowPos(h, null, 0, 0, @intCast(tw + 2 * m), @intCast(th + 2 * m), SWP_NOMOVE | SWP_NOZORDER);
        self.syncClientSize();
    }

    /// API parity with the Wayland backend: there the resize must be deferred to
    /// the window thread; on Win32 `SetWindowPos` marshals itself to the window
    /// thread, so it can be called directly.
    pub fn requestResize(self: *Window, width: u32, height: u32) void {
        self.animateResize(width, height);
    }

    pub fn textFont(self: *Window) !*text.Font {
        if (self.font == null) self.font = try text.Font.initDefault(self.gpa);
        return &self.font.?;
    }

    pub fn setFont(self: *Window, ttf: []const u8) !void {
        const f = try self.textFont();
        try f.setFace(.regular, ttf, false);
    }

    pub fn loadFont(self: *Window, path: []const u8) !void {
        const f = try self.textFont();
        try f.loadFace(.regular, path);
    }

    pub fn addPanel(self: *Window, panel: Panel, owned: bool) !void {
        try self.panels.add(panel, owned);
        self.requestRedraw();
    }

    pub fn removePanel(self: *Window, ptr: *anyopaque) void {
        self.panels.remove(ptr);
        self.requestRedraw();
    }

    pub fn loadPlugin(self: *Window, path: []const u8) !void {
        _ = try plugin.loadPlugin(&self.panels, path);
        self.requestRedraw();
    }

    pub fn loadPluginDir(self: *Window, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |ent| {
            if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".dll")) continue;
            const full = std.fs.path.join(self.gpa, &.{ dir_path, ent.name }) catch continue;
            defer self.gpa.free(full);
            self.loadPlugin(full) catch |e| std.log.warn("zrame: plugin {s} failed to load: {}", .{ ent.name, e });
        }
    }

    // --- host seam (panels reach back into the window) --------------------------------

    pub fn host(self: *Window) Host {
        return .{ .ptr = self, .vtable = &host_vtable };
    }

    const host_vtable = Host.VTable{ .do = hostDo, .info = hostInfo, .font = hostFont };

    fn hostDo(ptr: *anyopaque, action: plugin.Action) void {
        const self: *Window = @ptrCast(@alignCast(ptr));
        const h = self.hwnd;
        switch (action) {
            .minimize => _ = ShowWindow(h, SW_MINIMIZE),
            .toggle_maximize => _ = ShowWindow(h, if (self.maximized) SW_RESTORE else SW_MAXIMIZE),
            .toggle_fullscreen => self.toggleFullscreen(),
            .close => self.close(),
            // Native borders/title bar already handle interactive move+resize; the panels
            // that request these are the CSD controls, unused with native decorations.
            .begin_move => {},
            .begin_resize => {},
            .set_cursor => {},
            .request_redraw => self.requestRedraw(),
            .create_popup => {},
            .dismiss_popup => {},
            .enable_text_input => {},
            .disable_text_input => {},
        }
    }

    fn hostInfo(ptr: *anyopaque) plugin.Info {
        const self: *Window = @ptrCast(@alignCast(ptr));
        return .{
            .content = self.contentRect(),
            .panel_w = self.panel_w,
            .panel_h = self.panel_h,
            .margin = self.opts.style.margin,
            .maximized = self.maximized,
            .fullscreen = self.fullscreen,
        };
    }

    fn hostFont(ptr: *anyopaque) ?*text.Font {
        const self: *Window = @ptrCast(@alignCast(ptr));
        return self.textFont() catch null;
    }

    // --- geometry / drawing -----------------------------------------------------------

    /// Height the (optional) client-side title bar steals from the top of the content —
    /// mirrors the Wayland backend. A title-bar-less app leaves this at 0.
    fn titlebarHeight(self: *Window) u32 {
        if (!self.opts.titlebar or self.fullscreen) return 0;
        return @min(self.opts.titlebar_height, self.panel_h);
    }

    /// The shadow-gutter margin in effect: the style margin for the layered glass, but 0 in
    /// the opaque escape-hatch (a plain square window with no gutter). Also 0 in fullscreen,
    /// where `toggleFullscreen` already zeros `style.margin`.
    fn curMargin(self: *const Window) u32 {
        return if (self.opaque_mode) 0 else self.opts.style.margin;
    }

    /// The style used for content compositing (`composeContent` → `blitRgba`'s rounded mask).
    /// In opaque mode the mask must not round-clip the square window, so drop the margin and
    /// corner radius; otherwise it's the real glass style (mask hugs the rounded panel).
    fn presentStyle(self: *const Window) Style {
        if (!self.opaque_mode) return self.opts.style;
        var s = self.opts.style;
        // Zero every mask/fade field so blitRgba takes its trivial fast path (no per-pixel
        // SDF): a plain square opaque window doesn't want rounded/faded content clipping.
        s.margin = 0;
        s.corner_radius = 0;
        s.content_radius = 0;
        s.content_fade_width = 0;
        s.corner_fade_width = 0;
        s.edge_ring_alpha = 0;
        s.border_anim_width = 0;
        return s;
    }

    /// The content rect within the layered buffer: the panel sits inset by the shadow-gutter
    /// margin on every side, minus the (optional) title bar band at its top. Same geometry as
    /// the Wayland backend, so the app content lands in the identical spot.
    pub fn contentRect(self: *Window) Rect {
        const m = self.curMargin();
        const tb = self.titlebarHeight();
        return .{ .x = m, .y = m + tb, .w = self.panel_w, .h = self.panel_h - tb };
    }

    /// Physical size of the content rect — mirrors the Wayland backend's `contentPx`
    /// (here 1 buffer px = 1 panel px, so it's just the panel minus the title bar).
    pub fn contentPx(self: *Window) struct { w: u32, h: u32 } {
        const r = self.contentRect();
        return .{ .w = r.w, .h = r.h };
    }

    fn panelLocal(self: *Window, sx: f32, sy: f32) struct { px: f32, py: f32, w: f32, h: f32 } {
        const m: f32 = @floatFromInt(self.curMargin());
        return .{
            .px = sx - m,
            .py = sy - m,
            .w = @floatFromInt(self.panel_w),
            .h = @floatFromInt(self.panel_h),
        };
    }

    /// Which resize border the buffer point (sx,sy) is over (8px band around the panel), or
    /// `.none`. Coords are buffer-space (include the margin), so shift into panel space first
    /// — matching the Wayland `resizeEdgeAt`.
    fn resizeEdgeAt(self: *Window, sx: f32, sy: f32) Edge {
        const p = self.panelLocal(sx, sy);
        if (p.px < 0 or p.py < 0 or p.px >= p.w or p.py >= p.h) return .none;
        const l = p.px < RESIZE_BAND;
        const r = p.px >= p.w - RESIZE_BAND;
        const t = p.py < RESIZE_BAND;
        const b = p.py >= p.h - RESIZE_BAND;
        if (t and l) return .top_left;
        if (t and r) return .top_right;
        if (b and l) return .bottom_left;
        if (b and r) return .bottom_right;
        if (l) return .left;
        if (r) return .right;
        if (t) return .top;
        if (b) return .bottom;
        return .none;
    }

    /// True when the buffer point (sx,sy) is within `band` px of the panel border (the move
    /// grab zone). Buffer coords → shift into panel space, mirroring the Wayland backend.
    fn nearBorder(self: *Window, sx: f32, sy: f32, band: f32) bool {
        const p = self.panelLocal(sx, sy);
        return p.px < band or p.py < band or p.px > p.w - band or p.py > p.h - band;
    }

    /// Hand the drag to the OS interactive-move loop (Aero snap included), as if the click
    /// had landed on a native title bar.
    fn beginMove(self: *Window) void {
        _ = ReleaseCapture();
        _ = SendMessageW(self.hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    }

    /// Hand the drag to the OS interactive-resize loop from the given border.
    fn beginResize(self: *Window, edge: Edge) void {
        const dir: WPARAM = switch (edge) {
            .left => WMSZ_LEFT,
            .right => WMSZ_RIGHT,
            .top => WMSZ_TOP,
            .bottom => WMSZ_BOTTOM,
            .top_left => WMSZ_TOPLEFT,
            .top_right => WMSZ_TOPRIGHT,
            .bottom_left => WMSZ_BOTTOMLEFT,
            .bottom_right => WMSZ_BOTTOMRIGHT,
            .none => return,
        };
        _ = ReleaseCapture();
        _ = SendMessageW(self.hwnd, WM_SYSCOMMAND, SC_SIZE + dir, 0);
    }

    /// Pull the current client size from the OS and derive the panel size from it: the window
    /// is the panel plus the shadow-gutter margin on each side, so subtract 2·margin.
    fn syncClientSize(self: *Window) void {
        const h = self.hwnd orelse return;
        var rc: RECT = undefined;
        if (GetClientRect(h, &rc) == 0) return;
        const cw: u32 = @intCast(@max(rc.right - rc.left, 1));
        const ch: u32 = @intCast(@max(rc.bottom - rc.top, 1));
        const gutter = 2 * self.curMargin();
        self.panel_w = if (cw > gutter) cw - gutter else 1;
        self.panel_h = if (ch > gutter) ch - gutter else 1;
        self.requestRedraw();
    }

    /// Chiede un frame. Una finestra layered (vetro, il default) non riceve WM_PAINT
    /// utili: `InvalidateRect` da solo non ridisegnava mai, quindi tutto ciò che l'app
    /// anima o aggiorna senza input (toast, dialog aperti da un callback, rete, timer)
    /// restava fermo. Il frame passa dal timer d'animazione (~60 Hz, si spegne da solo).
    fn requestRedraw(self: *Window) void {
        const h = self.hwnd orelse return;
        self.redraw_pending = true;
        self.armTimer();
        if (self.opaque_mode) _ = InvalidateRect(h, null, 0);
    }

    /// Ensure the buffers match the current `buf_w`×`buf_h`: the heap compose target `frame`
    /// always, plus (glass only) the DIB section handed to UpdateLayeredWindow and the pre-
    /// painted chrome `decor`. Returns false if allocation fails, so callers skip the frame.
    fn ensureBuffers(self: *Window, bw: u32, bh: u32) bool {
        const ready = self.buf_w == bw and self.buf_h == bh and self.frame.len == @as(usize, bw) * bh and
            (self.opaque_mode or self.dib != null);
        if (ready) return true;
        const len = @as(usize, bw) * bh;

        if (self.frame.len != len) {
            const nf = self.gpa.alloc(u32, len) catch return false;
            if (self.frame.len > 0) self.gpa.free(self.frame);
            self.frame = nf;
        }

        if (!self.opaque_mode) {
            // Pre-paint the glass chrome (rounded panel + drop shadow, premultiplied ARGB) —
            // the exact same `drawChrome` the Wayland backend uses. Only re-run on size change.
            if (self.decor.len != len) {
                const nd = self.gpa.alloc(u32, len) catch return false;
                if (self.decor.len > 0) self.gpa.free(self.decor);
                self.decor = nd;
            }
            var dc = paint.Canvas.init(self.decor, bw, bh);
            dc.drawChrome(self.opts.style);

            // (Re)create the DIB section UpdateLayeredWindow reads from (glass only).
            if (self.mem_dc == null) self.mem_dc = CreateCompatibleDC(null);
            if (self.dib) |d| _ = DeleteObject(d);
            self.dib = null;
            var bmi = makeBitmapInfo(bw, bh);
            var bits: ?*anyopaque = null;
            const hbmp = CreateDIBSection(self.mem_dc, &bmi, DIB_RGB_COLORS, &bits, null, 0) orelse return false;
            _ = SelectObject(self.mem_dc, hbmp);
            self.dib = hbmp;
            self.buf = @as([*]u32, @ptrCast(@alignCast(bits)))[0..len];
        }
        self.buf_w = bw;
        self.buf_h = bh;
        return true;
    }

    /// Composite one full window into the heap `frame`: glass chrome background, the app
    /// `on_draw` overlay, the newest staged content frame (buffer-swapped, lock held only for a
    /// few words), then the panels stack. Same composition as the Wayland `composeFrame`.
    /// Composing into heap RAM (not the DIB) is the whole point — see `frame`'s doc.
    fn compose(self: *Window) void {
        const m = self.curMargin();
        const bw = self.panel_w + 2 * m;
        const bh = self.panel_h + 2 * m;
        if (!self.ensureBuffers(bw, bh)) return;
        // Background: the pre-painted glass chrome, or a flat opaque fill in opaque mode.
        if (self.opaque_mode) @memset(self.frame, 0xFF141414) else @memcpy(self.frame, self.decor);
        var canvas = paint.Canvas.init(self.frame, bw, bh);
        self.mailbox.swap();
        chrome.composeContent(&canvas, self.contentRect(), self.contentRect(), &self.mailbox.front, self.presentStyle(), &self.panels, self.host(), self.opts.on_draw, self.opts.user);
    }

    /// Compose and push the whole window. Glass (default): per-pixel alpha via
    /// UpdateLayeredWindow — `psize` resizes the window to the buffer (a no-op when it already
    /// matches, e.g. after an OS drag), `pptDst = null` keeps the position; under Wine this
    /// composites in software so the rounded panel + shadow + translucency show without DWM.
    /// Opaque (ZRAME_OPAQUE=1 / ZUER_OPAQUE=1): a plain top-down-DIB BitBlt into the window DC — no alpha
    /// compositing, so it stays fast under Wine at the cost of the glass.
    fn present(self: *Window) void {
        self.compose();
        if (self.frame.len == 0) return;
        if (self.opaque_mode) {
            const hdc = GetDC(self.hwnd);
            defer _ = ReleaseDC(self.hwnd, hdc);
            var bmi = makeBitmapInfo(self.buf_w, self.buf_h);
            _ = SetDIBitsToDevice(hdc, 0, 0, self.buf_w, self.buf_h, 0, 0, 0, self.buf_h, self.frame.ptr, &bmi, 0);
            return;
        }
        if (self.dib == null) return;
        @memcpy(self.buf, self.frame); // heap → DIB in one linear pass (the only DIB write)
        const screen = GetDC(null);
        defer _ = ReleaseDC(null, screen);
        var sz = SIZE{ .cx = @intCast(self.buf_w), .cy = @intCast(self.buf_h) };
        var src = POINT{ .x = 0, .y = 0 };
        const blend = BLENDFUNCTION{
            .BlendOp = AC_SRC_OVER,
            .BlendFlags = 0,
            .SourceConstantAlpha = 255,
            .AlphaFormat = AC_SRC_ALPHA, // the DIB is premultiplied (drawChrome / blitRgba)
        };
        _ = UpdateLayeredWindow(self.hwnd, screen, null, &sz, self.mem_dc, &src, 0, &blend, ULW_ALPHA);
    }

    // --- input / animation ------------------------------------------------------------

    fn routeInput(self: *Window, event: plugin.Event) bool {
        const consumed = self.panels.route(event, self.host());
        if (consumed) self.requestRedraw();
        self.armTimer();
        return consumed;
    }

    fn armTimer(self: *Window) void {
        if (self.timer_armed) return;
        _ = SetTimer(self.hwnd, ANIM_TIMER_ID, 16, null); // ~60 Hz
        self.timer_armed = true;
        self.last_tick_ms = GetTickCount64();
    }

    fn disarmTimer(self: *Window) void {
        if (!self.timer_armed) return;
        _ = KillTimer(self.hwnd, ANIM_TIMER_ID);
        self.timer_armed = false;
        self.last_tick_ms = 0;
    }

    fn onTimerTick(self: *Window) void {
        const now = GetTickCount64();
        const dt: f32 = if (self.last_tick_ms != 0)
            @min(@as(f32, @floatFromInt(now - self.last_tick_ms)) / 1000.0, 0.1)
        else
            0.016;
        self.last_tick_ms = now;
        const active = self.panels.tick(dt, self.host());
        self.redraw_pending = false; // servito ora; on_draw può richiederne un altro
        self.present();
        if (!active and !self.redraw_pending) self.disarmTimer();
    }

    /// WM_CHAR → `on_text`: TranslateMessage already ran the active keyboard layout, so
    /// `cu` is layout-correct UTF-16. Surrogate pairs (two WM_CHARs) are joined; control
    /// characters and DEL are skipped — mirroring the Wayland xkb path exactly.
    fn onChar(self: *Window, cu: u16) void {
        const cb = self.opts.on_text orelse return;
        var cp: u21 = cu;
        if (cu >= 0xD800 and cu <= 0xDBFF) { // high half: park it, wait for the low one
            self.high_surrogate = cu;
            return;
        }
        if (cu >= 0xDC00 and cu <= 0xDFFF) {
            const hi = self.high_surrogate;
            self.high_surrogate = 0;
            if (hi == 0) return; // stray low surrogate
            cp = 0x10000 + ((@as(u21, hi - 0xD800) << 10) | (cu - 0xDC00));
        } else {
            self.high_surrogate = 0;
        }
        if (cp < 0x20 or cp == 0x7f) return;
        var bytes: [4]u8 = .{ 0, 0, 0, 0 };
        const len: u8 = std.unicode.utf8Encode(cp, &bytes) catch return;
        cb(self, bytes, len, self.opts.user);
    }

    // --- clipboard ----------------------------------------------------------------------

    /// Put UTF-8 `bytes` on the system clipboard as CF_UNICODETEXT. Same signature and
    /// thread contract as the Wayland backend (call from the window/UI thread); failures
    /// are silently dropped.
    pub fn clipboardSet(self: *Window, bytes: []const u8) void {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(self.gpa, bytes) catch return;
        defer self.gpa.free(wide);
        const size = (wide.len + 1) * 2; // include the NUL terminator
        const handle = GlobalAlloc(GMEM_MOVEABLE, size) orelse return;
        const mem = GlobalLock(handle) orelse {
            _ = GlobalFree(handle);
            return;
        };
        @memcpy(@as([*]u8, @ptrCast(mem))[0..size], @as([*]const u8, @ptrCast(wide.ptr))[0..size]);
        _ = GlobalUnlock(handle);
        if (OpenClipboard(self.hwnd) == 0) {
            _ = GlobalFree(handle);
            return;
        }
        defer _ = CloseClipboard();
        _ = EmptyClipboard();
        // On success the system owns the handle; only free it when the hand-off failed.
        if (SetClipboardData(CF_UNICODETEXT, handle) == null) _ = GlobalFree(handle);
    }

    /// Read the system clipboard as UTF-8 text (CF_UNICODETEXT, converted). Returns null
    /// when the clipboard has no text or on any failure; the caller frees the bytes.
    pub fn clipboardGet(self: *Window, gpa: Allocator) ?[]u8 {
        if (OpenClipboard(self.hwnd) == 0) return null;
        defer _ = CloseClipboard();
        const handle = GetClipboardData(CF_UNICODETEXT) orelse return null;
        const mem = GlobalLock(handle) orelse return null;
        defer _ = GlobalUnlock(handle);
        const wide: [*:0]const u16 = @ptrCast(@alignCast(mem));
        const span = std.mem.span(wide);
        if (span.len == 0) return null;
        return std.unicode.utf16LeToUtf8Alloc(gpa, span) catch null;
    }

    fn refreshMaximized(self: *Window) void {
        const h = self.hwnd orelse return;
        var wp = WINDOWPLACEMENT{};
        if (GetWindowPlacement(h, &wp) != 0) self.maximized = (wp.showCmd == SW_MAX_STATE);
    }

    // --- window procedure -------------------------------------------------------------

    fn wndProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
        // Stash the Window* delivered via CreateWindow's lpParam on WM_CREATE (0x0001).
        // lpCreateParams is the first field of CREATESTRUCTW on every ABI we target.
        if (msg == 0x0001) {
            const create: *const extern struct { lpCreateParams: ?*anyopaque } = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(create.lpCreateParams)));
        }

        const ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if (ptr == 0) return DefWindowProcW(hwnd, msg, wparam, lparam);
        const self: *Window = @ptrFromInt(@as(usize, @bitCast(ptr)));

        switch (msg) {
            WM_DESTROY => {
                self.closed = true;
                PostQuitMessage(0);
                return 0;
            },
            WM_CLOSE => {
                // `close()` imposta `closed` PRIMA di postare WM_CLOSE: se non è impostato la
                // richiesta viene dal sistema (Alt+F4, pulsante, barra delle applicazioni) e
                // l'app può rifiutarla (es. "salvare le modifiche?") e chiudere poi da sé.
                if (!self.closed) {
                    if (self.opts.on_close_request) |cb| {
                        if (!cb(self, self.opts.user)) {
                            self.requestRedraw();
                            return 0;
                        }
                    }
                }
                self.closed = true;
                PostQuitMessage(0);
                return 0;
            },
            WM_ERASEBKGND => return 1, // layered surface owns every pixel; skip the flash-clear
            WM_NCCALCSIZE => {
                if (wparam == 0) return DefWindowProcW(hwnd, msg, wparam, lparam);
                // Collapse the whole non-client frame: the client area becomes the entire
                // window (frameless), so the layered buffer we push covers it 1:1.
                return 0;
            },
            WM_SETCURSOR => {
                // Inside the client, show a resize cursor near the edges; elsewhere the
                // arrow. Outside (shouldn't happen frameless) let the OS decide.
                if (@as(u16, @truncate(@as(usize, @bitCast(lparam)))) != HTCLIENT)
                    return DefWindowProcW(hwnd, msg, wparam, lparam);
                var pt: POINT = undefined;
                if (!self.maximized and !self.fullscreen and GetCursorPos(&pt) != 0 and ScreenToClient(hwnd, &pt) != 0) {
                    const edge = self.resizeEdgeAt(@floatFromInt(pt.x), @floatFromInt(pt.y));
                    if (edge != .none) {
                        _ = SetCursor(LoadCursorW(null, cursorIdForEdge(edge)));
                        return 1;
                    }
                }
                _ = SetCursor(LoadCursorW(null, IDC_ARROW));
                return 1;
            },
            WM_SIZE => {
                self.refreshMaximized();
                self.syncClientSize();
                self.present();
                return 0;
            },
            WM_PAINT => {
                // Layered: the surface is retained by the system, so an expose needs no re-blit
                // — just validate the update region (a fresh present goes through
                // WM_APP_PRESENT / WM_SIZE / the anim timer). Opaque: the window DC is *not*
                // retained across exposes, so re-blit the composed frame on paint.
                var ps: PAINTSTRUCT = undefined;
                _ = BeginPaint(hwnd, &ps);
                if (self.opaque_mode) self.present();
                _ = EndPaint(hwnd, &ps);
                return 0;
            },
            WM_APP_PRESENT => {
                self.present();
                return 0;
            },
            WM_TIMER => {
                if (wparam == ANIM_TIMER_ID) self.onTimerTick();
                return 0;
            },
            WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP => {
                const pressed: u32 = if (msg == WM_KEYDOWN or msg == WM_SYSKEYDOWN) 1 else 0;
                // bit 24 di lparam = tasto "esteso": distingue Ctrl/Alt destri e Invio del
                // tastierino dai gemelli sinistri (stesso VK).
                const extended = (@as(usize, @bitCast(lparam)) >> 24) & 1 == 1;
                const key = mapVkExt(wparam, extended);
                if (key != 0 and key < 256) self.held_keys.setValue(key, pressed == 1);
                if (key != 0) {
                    if (self.routeInput(.{ .key = .{ .key = key, .pressed = pressed == 1 } })) return 0;
                    if (self.opts.on_key) |cb| cb(self, key, pressed, self.opts.user);
                }
                // Alt+… resta al sistema (Alt+F4 → WM_CLOSE, Alt+Spazio → menu finestra)
                if (msg == WM_SYSKEYDOWN or msg == WM_SYSKEYUP) return DefWindowProcW(hwnd, msg, wparam, lparam);
                return 0;
            },
            WM_KILLFOCUS => {
                var it = self.held_keys.iterator(.{});
                while (it.next()) |k| {
                    const key: u32 = @intCast(k);
                    if (!self.routeInput(.{ .key = .{ .key = key, .pressed = false } })) {
                        if (self.opts.on_key) |cb| cb(self, key, 0, self.opts.user);
                    }
                }
                self.held_keys = .empty;
                return DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            WM_CHAR => {
                self.onChar(@truncate(wparam));
                return 0;
            },
            WM_MOUSEMOVE => {
                const p = lparamPoint(lparam);
                self.pointer_x = p.x;
                self.pointer_y = p.y;
                if (!self.tracking_leave) {
                    var tme = TRACKMOUSEEVENT{ .dwFlags = TME_LEAVE, .hwndTrack = hwnd };
                    _ = TrackMouseEvent(&tme);
                    self.tracking_leave = true;
                }
                if (self.routeInput(.{ .motion = .{ .x = p.x, .y = p.y } })) return 0;
                // Mouse in APP coordinates (see `MouseEvent`): canvas minus the origin of the
                // staged frame/content rect — panels and the resize band stay in canvas space.
                if (self.opts.on_mouse) |cb| {
                    const o = chrome.appOrigin(self.contentRect(), &self.mailbox.front);
                    _ = cb(self, .{ .motion = .{ .x = p.x - o.x, .y = p.y - o.y } }, self.opts.user);
                }
                return 0;
            },
            WM_MOUSELEAVE => {
                self.tracking_leave = false;
                _ = self.routeInput(.leave);
                if (self.opts.on_mouse) |cb| _ = cb(self, .leave, self.opts.user);
                return 0;
            },
            WM_LBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONDOWN, WM_RBUTTONUP => {
                const is_left = (msg == WM_LBUTTONDOWN or msg == WM_LBUTTONUP);
                const pressed = (msg == WM_LBUTTONDOWN or msg == WM_RBUTTONDOWN);
                const button: u32 = if (is_left) BTN_LEFT else BTN_RIGHT;
                if (self.routeInput(.{ .button = .{ .x = self.pointer_x, .y = self.pointer_y, .button = button, .pressed = pressed } })) return 0;
                var consumed = false;
                if (self.opts.on_mouse) |cb| consumed = cb(self, .{ .button = .{ .button = button, .state = @intFromBool(pressed) } }, self.opts.user);
                // Unconsumed left-press drives the frameless window's own move/resize, the
                // same order as Wayland: panels/app first, then edge resize, then (title-bar
                // -less only) a border-band move. The OS runs the modal loop from here.
                if (!consumed and msg == WM_LBUTTONDOWN and !self.fullscreen) {
                    const edge = self.resizeEdgeAt(self.pointer_x, self.pointer_y);
                    if (edge != .none and !self.maximized) {
                        self.beginResize(edge);
                    } else if (!self.opts.titlebar and self.nearBorder(self.pointer_x, self.pointer_y, MOVE_BAND)) {
                        self.beginMove();
                    }
                }
                return 0;
            },
            WM_MOUSEWHEEL, WM_MOUSEHWHEEL => {
                // Wheel delta is a signed i16 in the high word of wParam, in units of 120.
                const raw: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
                const notches = @as(f32, @floatFromInt(raw)) / 120.0;
                const axis: u32 = if (msg == WM_MOUSEHWHEEL) 1 else 0;
                // Match the Wayland axis-value scale (1/256 px units). Wheel-up (positive)
                // scrolls content up, i.e. a negative axis value, as on Wayland.
                const value: i32 = @intFromFloat(-notches * 40.0 * 256.0);
                if (self.routeInput(.{ .axis = .{ .x = self.pointer_x, .y = self.pointer_y, .axis = axis, .value = @as(f32, @floatFromInt(value)) / 256.0, .line = true } })) return 0;
                if (self.opts.on_scroll) |cb| cb(self, axis, value, self.opts.user);
                return 0;
            },
            else => return DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
};

fn cursorIdForEdge(edge: Edge) usize {
    return switch (edge) {
        .left, .right => IDC_SIZEWE,
        .top, .bottom => IDC_SIZENS,
        .top_left, .bottom_right => IDC_SIZENWSE,
        .top_right, .bottom_left => IDC_SIZENESW,
        .none => IDC_ARROW,
    };
}

fn lparamPoint(lparam: LPARAM) struct { x: f32, y: f32 } {
    const lo: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) & 0xFFFF)));
    const hi: i16 = @bitCast(@as(u16, @truncate((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF)));
    return .{ .x = @floatFromInt(lo), .y = @floatFromInt(hi) };
}

fn isOpaqueRequested() bool {
    const val = getenv("ZRAME_OPAQUE") orelse getenv("ZUER_OPAQUE") orelse return false;
    return val[0] != '0' and val[0] != 0;
}

fn makeBitmapInfo(w: u32, h: u32) BITMAPINFO {
    return .{
        .bmiHeader = .{
            .biWidth = @intCast(w),
            .biHeight = -@as(i32, @intCast(h)), // negative = top-down
            .biBitCount = 32,
        },
    };
}

/// Come `mapVk`, ma con il flag "esteso" di lparam: Ctrl/Alt destri e Invio del tastierino.
fn mapVkExt(vk: WPARAM, extended: bool) u32 {
    if (extended) switch (vk) {
        0x11 => return 97, // Ctrl destro -> KEY_RIGHTCTRL
        0x12 => return 100, // Alt destro (AltGr) -> KEY_RIGHTALT
        0x0D => return 96, // Invio del tastierino -> KEY_KPENTER
        else => {},
    };
    return mapVk(vk);
}

/// Translate a Win32 virtual-key code to the evdev keycode the Wayland path emits, so
/// `on_key` handlers are identical across platforms.
fn mapVk(vk: WPARAM) u32 {
    return switch (vk) {
        'A' => 30,
        'B' => 48,
        'C' => 46,
        'D' => 32,
        'E' => 18,
        'F' => 33,
        'G' => 34,
        'H' => 35,
        'I' => 23,
        'J' => 36,
        'K' => 37,
        'L' => 38,
        'M' => 50,
        'N' => 49,
        'O' => 24,
        'P' => 25,
        'Q' => 16,
        'R' => 19,
        'S' => 31,
        'T' => 20,
        'U' => 22,
        'V' => 47,
        'W' => 17,
        'X' => 45,
        'Y' => 21,
        'Z' => 44,
        '1' => 2,
        '2' => 3,
        '3' => 4,
        '4' => 5,
        '5' => 6,
        '6' => 7,
        '7' => 8,
        '8' => 9,
        '9' => 10,
        '0' => 11,
        0x1B => 1, // VK_ESCAPE -> KEY_ESC
        0x20 => 57, // VK_SPACE
        0x0D => 28, // VK_RETURN -> KEY_ENTER
        0x08 => 14, // VK_BACK -> KEY_BACKSPACE
        0x09 => 15, // VK_TAB
        0x25 => 105, // VK_LEFT
        0x26 => 103, // VK_UP
        0x27 => 106, // VK_RIGHT
        0x28 => 108, // VK_DOWN
        0x21 => 104, // VK_PRIOR -> PAGEUP
        0x22 => 109, // VK_NEXT  -> PAGEDOWN
        0xBD => 12, // VK_OEM_MINUS
        0xBB => 13, // VK_OEM_PLUS (=)
        0x10, 0xA0 => 42, // VK_SHIFT / VK_LSHIFT -> KEY_LEFTSHIFT
        0xA1 => 54, // VK_RSHIFT
        0x11, 0xA2 => 29, // VK_CONTROL / VK_LCONTROL -> KEY_LEFTCTRL
        0xA3 => 97, // VK_RCONTROL
        0x12, 0xA4 => 56, // VK_MENU / VK_LMENU -> KEY_LEFTALT
        0xA5 => 100, // VK_RMENU -> KEY_RIGHTALT
        0x5B => 125, // VK_LWIN -> KEY_LEFTMETA
        0x5C => 126, // VK_RWIN -> KEY_RIGHTMETA
        0x14 => 58, // VK_CAPITAL -> KEY_CAPSLOCK
        0x2E => 111, // VK_DELETE
        0x2D => 110, // VK_INSERT
        0x24 => 102, // VK_HOME
        0x23 => 107, // VK_END
        0x70...0x79 => @as(u32, @intCast(vk - 0x70)) + 59, // VK_F1..F10 -> KEY_F1..F10
        0x7A => 87, // VK_F11
        0x7B => 88, // VK_F12
        0xC0 => 41, // VK_OEM_3 (` ~) -> KEY_GRAVE
        0xBA => 39, // VK_OEM_1 (; :) -> KEY_SEMICOLON
        0xDE => 40, // VK_OEM_7 (' ") -> KEY_APOSTROPHE
        0xDB => 26, // VK_OEM_4 ([ {) -> KEY_LEFTBRACE
        0xDD => 27, // VK_OEM_6 (] }) -> KEY_RIGHTBRACE
        0xDC => 43, // VK_OEM_5 (\ |) -> KEY_BACKSLASH
        0xE2 => 86, // VK_OEM_102 (< > delle tastiere ISO) -> KEY_102ND
        0xBC => 51, // VK_OEM_COMMA
        0xBE => 52, // VK_OEM_PERIOD
        0xBF => 53, // VK_OEM_2 (/ ?) -> KEY_SLASH
        0x60 => 82, // VK_NUMPAD0 -> KEY_KP0
        0x61 => 79,
        0x62 => 80,
        0x63 => 81,
        0x64 => 75,
        0x65 => 76,
        0x66 => 77,
        0x67 => 71,
        0x68 => 72,
        0x69 => 73, // VK_NUMPAD9 -> KEY_KP9
        0x6A => 55, // VK_MULTIPLY -> KEY_KPASTERISK
        0x6B => 78, // VK_ADD -> KEY_KPPLUS
        0x6D => 74, // VK_SUBTRACT -> KEY_KPMINUS
        0x6E => 83, // VK_DECIMAL -> KEY_KPDOT
        0x6F => 98, // VK_DIVIDE -> KEY_KPSLASH
        else => 0,
    };
}
