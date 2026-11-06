//! # zicro.window (Windows backend) — the Win32 window
//!
//! The ONE Win32 transport of the stack, with the same contract as the Wayland window
//! (`window_wayland.zig`): zicro's own apps draw through `on_draw`/`presentRgba`, and a
//! client with its own chrome (zrame) sets `margin`, `on_compose` and `resize_band =
//! false` and paints every pixel itself.
//!
//! Frameless by default: `WM_NCCALCSIZE` collapses the OS frame so the client is the
//! whole window (WS_OVERLAPPEDWINDOW keeps the taskbar entry, min/max and Aero snap),
//! and the window is a *layered* one — every pixel, the transparent margin included, is
//! composed on the CPU and pushed with per-pixel alpha by `UpdateLayeredWindow`, which
//! works even under Wine. `decorations = true` gives a normal framed, opaque window;
//! `ZRAME_OPAQUE=1` (or `ZUER_OPAQUE=1`) a frameless opaque one — fast under Wine, where
//! the layered path composites in software.
//!
//! Input is translated to the Wayland vocabulary — evdev key codes, `BTN_*` buttons,
//! Wayland axis units, `xdg_toplevel` resize edges, cursor-shape ids — so handlers are
//! identical across platforms. Not DPI-aware: the buffer is 1:1 (Windows scales it).
//!
//! Threading: everything runs on the thread that calls `run`; the doors that may be
//! called from any thread (`presentRgba`, `requestRedraw`, `requestClose`, `wake`,
//! `requestResize`, `requestClipboardSet`, `requestToggleVisible`) post a message.

const std = @import("std");
const builtin = @import("builtin");

pub const Window = if (builtin.os.tag != .windows) struct {} else struct {
    const paint = @import("paint.zig");
    const window = @import("window.zig");
    const wl = @import("wl.zig"); // constants only: edges, cursor shapes, BTN_*
    const Allocator = std.mem.Allocator;
    const PxRect = window.PxRect;

    // --- Win32 FFI --------------------------------------------------------------------
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
    const SIZE = extern struct { cx: i32, cy: i32 };
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
    const BLENDFUNCTION = extern struct { BlendOp: u8, BlendFlags: u8, SourceConstantAlpha: u8, AlphaFormat: u8 };

    extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) HINSTANCE;
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
    extern "user32" fn GetSystemMetrics(i32) callconv(.winapi) i32;
    extern "user32" fn AdjustWindowRectEx(*RECT, u32, i32, u32) callconv(.winapi) i32;
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
    extern "user32" fn UpdateLayeredWindow(HWND, HDC, ?*const POINT, ?*const SIZE, HDC, ?*const POINT, u32, *const BLENDFUNCTION, u32) callconv(.winapi) i32;
    extern "gdi32" fn CreateCompatibleDC(HDC) callconv(.winapi) HDC;
    extern "gdi32" fn CreateDIBSection(HDC, *const BITMAPINFO, u32, *?*anyopaque, ?*anyopaque, u32) callconv(.winapi) ?*anyopaque;
    extern "gdi32" fn SelectObject(HDC, ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "gdi32" fn DeleteObject(?*anyopaque) callconv(.winapi) i32;
    extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) i32;
    extern "gdi32" fn SetDIBitsToDevice(HDC, i32, i32, u32, u32, i32, i32, u32, u32, ?*const anyopaque, *const BITMAPINFO, u32) callconv(.winapi) i32;
    extern "user32" fn OpenClipboard(HWND) callconv(.winapi) i32;
    extern "user32" fn CloseClipboard() callconv(.winapi) i32;
    extern "user32" fn EmptyClipboard() callconv(.winapi) i32;
    extern "user32" fn SetClipboardData(u32, ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "user32" fn GetClipboardData(u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalAlloc(u32, usize) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalLock(?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalUnlock(?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GlobalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern fn getenv([*:0]const u8) ?[*:0]const u8;

    const CF_UNICODETEXT: u32 = 13;
    const GMEM_MOVEABLE: u32 = 0x0002;
    const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
    const WS_POPUP: u32 = 0x80000000;
    const WS_VISIBLE: u32 = 0x10000000;
    const WS_EX_LAYERED: u32 = 0x00080000;
    const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
    const GWL_STYLE: i32 = -16;
    const GWLP_USERDATA: i32 = -21;
    const SW_HIDE: i32 = 0;
    const SW_SHOWNORMAL: i32 = 1;
    const SW_MAXIMIZE: i32 = 3;
    const SW_SHOW: i32 = 5;
    const SW_MINIMIZE: i32 = 6;
    const SW_RESTORE: i32 = 9;
    const SW_MAX_STATE: u32 = 3; // SW_SHOWMAXIMIZED as WINDOWPLACEMENT.showCmd reports it
    const SWP_NOSIZE: u32 = 0x0001;
    const SWP_NOMOVE: u32 = 0x0002;
    const SWP_NOZORDER: u32 = 0x0004;
    const SWP_FRAMECHANGED: u32 = 0x0020;
    const SWP_SHOWWINDOW: u32 = 0x0040;
    const ULW_ALPHA: u32 = 0x02;
    const AC_SRC_OVER: u8 = 0x00;
    const AC_SRC_ALPHA: u8 = 0x01;
    const DIB_RGB_COLORS: u32 = 0;

    const WM_CREATE: u32 = 0x0001;
    const WM_DESTROY: u32 = 0x0002;
    const WM_SIZE: u32 = 0x0005;
    const WM_KILLFOCUS: u32 = 0x0008;
    const WM_PAINT: u32 = 0x000F;
    const WM_CLOSE: u32 = 0x0010;
    const WM_ERASEBKGND: u32 = 0x0014;
    const WM_SETCURSOR: u32 = 0x0020;
    const WM_NCCALCSIZE: u32 = 0x0083;
    const WM_NCLBUTTONDOWN: u32 = 0x00A1;
    const WM_KEYDOWN: u32 = 0x0100;
    const WM_KEYUP: u32 = 0x0101;
    const WM_CHAR: u32 = 0x0102;
    const WM_SYSKEYDOWN: u32 = 0x0104;
    const WM_SYSKEYUP: u32 = 0x0105;
    const WM_SYSCOMMAND: u32 = 0x0112;
    const WM_TIMER: u32 = 0x0113;
    const WM_MOUSEMOVE: u32 = 0x0200;
    const WM_LBUTTONDOWN: u32 = 0x0201;
    const WM_LBUTTONUP: u32 = 0x0202;
    const WM_RBUTTONDOWN: u32 = 0x0204;
    const WM_RBUTTONUP: u32 = 0x0205;
    const WM_MBUTTONDOWN: u32 = 0x0207;
    const WM_MBUTTONUP: u32 = 0x0208;
    const WM_MOUSEWHEEL: u32 = 0x020A;
    const WM_MOUSEHWHEEL: u32 = 0x020E;
    const WM_MOUSELEAVE: u32 = 0x02A3;
    /// WM_APP + 1: the loop has work (a staged frame, a redraw, a cross-thread request).
    const WM_APP_WAKE: u32 = 0x8001;
    const HTCLIENT = 1;
    const HTCAPTION = 2;
    const SC_SIZE: WPARAM = 0xF000;
    const TME_LEAVE: u32 = 0x00000002;
    const TICK_TIMER_ID: usize = 1;
    const BTN_RIGHT: u32 = 0x111;
    const BTN_MIDDLE: u32 = 0x112;

    gpa: Allocator,
    io: std.Io,
    opts: window.Options,
    hwnd: HWND = null,

    /// Window geometry (client minus the margin on each side), px.
    width: u32,
    height: u32,
    margin: u32 = 0,
    min_size: u32 = 0,
    /// Per-pixel-alpha layered window (the frameless default). False = opaque blit.
    layered: bool,
    /// The OS frame is collapsed (`decorations` off).
    frameless: bool,
    closed: bool = false,
    fullscreen: bool = false,
    maximized: bool = false,
    hidden: bool = false,
    needs_redraw: bool = false,
    /// `init` has returned the window to the app: before that only a compositing client
    /// (`on_compose`) is painted — `on_draw` must not run before the app holds its window.
    ready: bool = false,
    saved_style: u32 = 0,
    saved_rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    tracking_leave: bool = false,
    cursor_shape: u32 = wl.CursorShapeDevice.SHAPE_DEFAULT,
    /// True while `on_key` delivers an auto-repeat (WM_KEYDOWN with the previous-state bit).
    key_repeating: bool = false,
    /// True while `on_text` delivers text typed on the keyboard (always, on Win32: WM_CHAR).
    text_from_key: bool = false,
    held_keys: std.StaticBitSet(256) = .empty,
    /// WM_CHAR splits astral text over two messages: the high surrogate waits here.
    high_surrogate: u16 = 0,

    /// No video plane on Windows (API parity with Wayland: always null).
    video_rect: ?PxRect = null,

    // Compose into `frame` (heap RAM: composing straight into DIB memory is
    // pathologically slow under Wine), then move it out in one pass.
    mem_dc: HDC = null,
    dib: ?*anyopaque = null,
    dib_px: []u32 = &.{},
    frame: []u32 = &.{},
    buf_w: u32 = 0,
    buf_h: u32 = 0,
    /// One persistent frame: the damage since the last compose is exactly what to redo.
    damage_full: bool = true,
    damage_rect: ?PxRect = null,

    mutex: SpinLock = .{},
    staged: Staged = .{},
    front: Staged = .{},
    pending_clip: ?[]u8 = null,
    pending_toggle_visible: std.atomic.Value(bool) = .init(false),
    wake_posted: std.atomic.Value(bool) = .init(false),

    const Staged = struct {
        pixels: std.ArrayList(u8) = .empty,
        width: u32 = 0,
        height: u32 = 0,
        fresh: bool = false,
    };

    const SpinLock = struct {
        flag: std.atomic.Value(bool) = .init(false),
        fn lock(self: *SpinLock) void {
            while (self.flag.swap(true, .acquire)) std.atomic.spinLoopHint();
        }
        fn unlock(self: *SpinLock) void {
            self.flag.store(false, .release);
        }
    };

    fn unionOf(a: PxRect, b: PxRect) PxRect {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x + a.w, b.x + b.w);
        const y1 = @max(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    fn opaqueRequested() bool {
        const val = getenv("ZRAME_OPAQUE") orelse getenv("ZUER_OPAQUE") orelse return false;
        return val[0] != '0' and val[0] != 0;
    }

    pub fn init(gpa: Allocator, io: std.Io, opts: window.Options) !*Window {
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        const frameless = !opts.decorations;
        const layered = frameless and !opaqueRequested();
        self.* = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .width = @max(opts.width, opts.min_size),
            .height = @max(opts.height, opts.min_size),
            .margin = if (layered) opts.margin else 0,
            .min_size = opts.min_size,
            .layered = layered,
            .frameless = frameless,
        };

        const hinst = GetModuleHandleW(null);
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZicroWindowClass");
        const wc = WNDCLASSEXW{
            .style = 0x0003, // CS_HREDRAW | CS_VREDRAW
            .lpfnWndProc = wndProc,
            .hInstance = hinst,
            .hCursor = LoadCursorW(null, 32512), // IDC_ARROW
            .lpszClassName = class_name,
        };
        _ = RegisterClassExW(&wc);

        const title = try std.unicode.utf8ToUtf16LeAllocZ(gpa, opts.title);
        defer gpa.free(title);
        const m = self.margin;
        // Framed: the size asked for is the client area, the OS frame grows around it.
        var outer = RECT{ .left = 0, .top = 0, .right = @intCast(self.width + 2 * m), .bottom = @intCast(self.height + 2 * m) };
        if (!frameless) _ = AdjustWindowRectEx(&outer, WS_OVERLAPPEDWINDOW, 0, 0);
        const hwnd = CreateWindowExW(
            if (layered) WS_EX_LAYERED else 0,
            class_name,
            title.ptr,
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            outer.right - outer.left,
            outer.bottom - outer.top,
            null,
            null,
            hinst,
            self,
        ) orelse return error.WindowCreationFailed;
        self.hwnd = hwnd;
        // Re-run the frame calculation now that the window exists (frameless takes hold).
        _ = SetWindowPos(hwnd, null, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_FRAMECHANGED);
        self.syncClientSize();
        if (opts.tick_ms > 0) self.setTick(opts.tick_ms);
        // A layered window shows nothing until its first UpdateLayeredWindow: present
        // BEFORE ShowWindow, or the first paint flashes empty.
        self.redraw();
        _ = ShowWindow(hwnd, SW_SHOWNORMAL);
        self.ready = true;
        if (opts.on_compose == null) self.scheduleRedraw();
        return self;
    }

    pub fn deinit(self: *Window) void {
        if (self.frame.len > 0) self.gpa.free(self.frame);
        if (self.dib) |d| _ = DeleteObject(d);
        if (self.mem_dc != null) _ = DeleteDC(self.mem_dc);
        self.staged.pixels.deinit(self.gpa);
        self.front.pixels.deinit(self.gpa);
        if (self.pending_clip) |p| self.gpa.free(p);
        if (self.hwnd) |h| _ = DestroyWindow(h);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    // --- cross-thread doors -----------------------------------------------------------

    /// Wake the loop (coalesced: one pending message at a time). Any thread.
    pub fn wake(self: *Window) void {
        if (self.wake_posted.swap(true, .acq_rel)) return;
        _ = PostMessageW(self.hwnd, WM_APP_WAKE, 0, 0);
    }

    pub fn requestRedraw(self: *Window) void {
        @atomicStore(bool, &self.needs_redraw, true, .release);
        self.wake();
    }

    /// Window-thread redraw request: the loop paints once it is idle again.
    pub fn scheduleRedraw(self: *Window) void {
        self.needs_redraw = true;
        self.wake();
    }

    pub fn requestClose(self: *Window) void {
        self.close();
    }

    pub fn close(self: *Window) void {
        // `closed` is raised BEFORE WM_CLOSE: the handler then knows it is ours, not
        // the system's (which the app may veto).
        @atomicStore(bool, &self.closed, true, .release);
        _ = PostMessageW(self.hwnd, WM_CLOSE, 0, 0);
    }

    pub fn presentRgba(self: *Window, width: u32, height: u32, rgba: []const u8) void {
        const need = @as(usize, width) * @as(usize, height) * 4;
        if (rgba.len < need) return;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.staged.pixels.clearRetainingCapacity();
            self.staged.pixels.appendSlice(self.gpa, rgba[0..need]) catch {
                self.staged.width = 0;
                self.staged.height = 0;
                self.staged.fresh = false;
                return;
            };
            self.staged.width = width;
            self.staged.height = height;
            self.staged.fresh = true;
        }
        self.wake();
    }

    /// SetWindowPos marshals itself to the window thread: safe from any thread.
    pub fn requestResize(self: *Window, width: u32, height: u32) void {
        self.setContentSize(width, height);
    }

    pub fn requestClipboardSet(self: *Window, bytes: []const u8) void {
        const copy = self.gpa.dupe(u8, bytes) catch return;
        self.mutex.lock();
        if (self.pending_clip) |old| self.gpa.free(old);
        self.pending_clip = copy;
        self.mutex.unlock();
        self.wake();
    }

    pub fn requestToggleVisible(self: *Window) void {
        self.pending_toggle_visible.store(true, .release);
        self.wake();
    }

    // --- geometry ---------------------------------------------------------------------

    pub fn scaleFactor(_: *const Window) f32 {
        return 1.0;
    }

    pub fn bufferScale(_: *const Window) f32 {
        return 1.0;
    }

    pub fn physPx(_: *const Window, v: u32) u32 {
        return v;
    }

    pub fn logiPx(_: *const Window, v: u32) u32 {
        return v;
    }

    pub fn physPxF(_: *const Window, v: f32) f32 {
        return v;
    }

    pub fn bufferSize(self: *const Window) [2]u32 {
        return .{ self.width + 2 * self.margin, self.height + 2 * self.margin };
    }

    pub fn geometryPx(self: *const Window) PxRect {
        return .{ .x = self.margin, .y = self.margin, .w = self.width, .h = self.height };
    }

    /// Change the margin at runtime (fullscreen drops the shadow): the window keeps its
    /// size, the geometry inside it changes. No blur on GDI. Window thread.
    pub fn setSurfaceShape(self: *Window, margin: u32, _: ?window.Blur) void {
        self.margin = if (self.layered) margin else 0;
        self.syncClientSize();
        self.damageAll();
    }

    pub fn setMinSize(self: *Window, size: u32) void {
        self.min_size = size;
    }

    pub fn hasBlur(_: *const Window) bool {
        return false;
    }

    pub fn isTouch(_: *const Window) bool {
        return false;
    }

    pub fn damage(self: *Window, r: PxRect) void {
        self.damage_rect = if (self.damage_rect) |cur| unionOf(cur, r) else r;
        self.needs_redraw = true;
    }

    pub fn damageAll(self: *Window) void {
        self.damage_full = true;
        self.needs_redraw = true;
    }

    // --- window management ------------------------------------------------------------

    pub fn setTitle(self: *Window, title: [*:0]const u8) void {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(self.gpa, std.mem.span(title)) catch return;
        defer self.gpa.free(wide);
        _ = SetWindowTextW(self.hwnd, wide.ptr);
    }

    pub fn toggleFullscreen(self: *Window) void {
        const h = self.hwnd orelse return;
        self.fullscreen = !self.fullscreen;
        if (self.fullscreen) {
            self.saved_style = @bitCast(GetWindowLongW(h, GWL_STYLE));
            _ = GetWindowRect(h, &self.saved_rect);
            _ = SetWindowLongW(h, GWL_STYLE, @bitCast(WS_POPUP | WS_VISIBLE));
            const sw = GetSystemMetrics(0); // SM_CXSCREEN
            const sh = GetSystemMetrics(1); // SM_CYSCREEN
            _ = SetWindowPos(h, null, 0, 0, sw, sh, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        } else {
            _ = SetWindowLongW(h, GWL_STYLE, @bitCast(self.saved_style));
            const r = self.saved_rect;
            _ = SetWindowPos(h, null, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        }
        self.configureChanged();
    }

    pub fn toggleMaximized(self: *Window) void {
        _ = ShowWindow(self.hwnd, if (self.maximized) SW_RESTORE else SW_MAXIMIZE);
    }

    pub fn setMinimized(self: *Window) void {
        _ = ShowWindow(self.hwnd, SW_MINIMIZE);
    }

    /// Hand the drag to the OS move loop (Aero snap included), as from a title bar.
    pub fn beginMove(self: *Window) void {
        _ = ReleaseCapture();
        _ = SendMessageW(self.hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    }

    /// Hand the drag to the OS resize loop from an `xdg_toplevel` edge bitmask.
    pub fn beginResize(self: *Window, edge: u32) void {
        const dir: WPARAM = switch (edge) {
            wl.RESIZE_EDGE_LEFT => 1,
            wl.RESIZE_EDGE_RIGHT => 2,
            wl.RESIZE_EDGE_TOP => 3,
            wl.RESIZE_EDGE_TOP_LEFT => 4,
            wl.RESIZE_EDGE_TOP_RIGHT => 5,
            wl.RESIZE_EDGE_BOTTOM => 6,
            wl.RESIZE_EDGE_BOTTOM_LEFT => 7,
            wl.RESIZE_EDGE_BOTTOM_RIGHT => 8,
            else => return,
        };
        _ = ReleaseCapture();
        _ = SendMessageW(self.hwnd, WM_SYSCOMMAND, SC_SIZE + dir, 0);
    }

    /// Set the pointer shape (a `wp_cursor_shape_device_v1` id, the portable vocabulary).
    pub fn setCursorShape(self: *Window, shape: u32) void {
        if (shape == self.cursor_shape) return;
        self.cursor_shape = shape;
        _ = SetCursor(LoadCursorW(null, cursorId(shape)));
    }

    fn cursorId(shape: u32) usize {
        return switch (shape) {
            wl.CursorShapeDevice.SHAPE_POINTER => 32649, // IDC_HAND
            wl.CursorShapeDevice.SHAPE_MOVE => 32646, // IDC_SIZEALL
            wl.CursorShapeDevice.SHAPE_EW_RESIZE => 32644, // IDC_SIZEWE
            wl.CursorShapeDevice.SHAPE_NS_RESIZE => 32645, // IDC_SIZENS
            wl.CursorShapeDevice.SHAPE_NESW_RESIZE => 32643, // IDC_SIZENESW
            wl.CursorShapeDevice.SHAPE_NWSE_RESIZE => 32642, // IDC_SIZENWSE
            else => 32512, // IDC_ARROW
        };
    }

    /// The resize edge for a point in buffer px: an 8 px band inside the geometry.
    pub fn resizeEdgeAt(self: *const Window, x: f32, y: f32) u32 {
        const g = self.geometryPx();
        const px = x - @as(f32, @floatFromInt(g.x));
        const py = y - @as(f32, @floatFromInt(g.y));
        const w: f32 = @floatFromInt(g.w);
        const h: f32 = @floatFromInt(g.h);
        if (px < 0 or py < 0 or px >= w or py >= h) return wl.RESIZE_EDGE_NONE;
        var edge: u32 = 0;
        if (py < 8) edge |= wl.RESIZE_EDGE_TOP;
        if (py >= h - 8) edge |= wl.RESIZE_EDGE_BOTTOM;
        if (px < 8) edge |= wl.RESIZE_EDGE_LEFT;
        if (px >= w - 8) edge |= wl.RESIZE_EDGE_RIGHT;
        return edge;
    }

    pub fn edgeCursor(edge: u32) u32 {
        return switch (edge) {
            wl.RESIZE_EDGE_TOP, wl.RESIZE_EDGE_BOTTOM => wl.CursorShapeDevice.SHAPE_NS_RESIZE,
            wl.RESIZE_EDGE_LEFT, wl.RESIZE_EDGE_RIGHT => wl.CursorShapeDevice.SHAPE_EW_RESIZE,
            wl.RESIZE_EDGE_TOP_LEFT, wl.RESIZE_EDGE_BOTTOM_RIGHT => wl.CursorShapeDevice.SHAPE_NWSE_RESIZE,
            wl.RESIZE_EDGE_TOP_RIGHT, wl.RESIZE_EDGE_BOTTOM_LEFT => wl.CursorShapeDevice.SHAPE_NESW_RESIZE,
            else => wl.CursorShapeDevice.SHAPE_DEFAULT,
        };
    }

    fn bandActive(self: *const Window) bool {
        return self.opts.resize_band and self.frameless and !self.fullscreen and !self.maximized;
    }

    /// Resize the geometry to `w`×`h`, keeping the top-left corner put. No-op in
    /// fullscreen/maximized.
    pub fn setContentSize(self: *Window, w: u32, h: u32) void {
        if (self.fullscreen or self.maximized) return;
        const tw = @max(w, self.min_size);
        const th = @max(h, self.min_size);
        if (tw == self.width and th == self.height) return;
        const m = self.margin;
        var outer = RECT{ .left = 0, .top = 0, .right = @intCast(tw + 2 * m), .bottom = @intCast(th + 2 * m) };
        if (!self.frameless) _ = AdjustWindowRectEx(&outer, @bitCast(GetWindowLongW(self.hwnd, GWL_STYLE)), 0, 0);
        _ = SetWindowPos(self.hwnd, null, 0, 0, outer.right - outer.left, outer.bottom - outer.top, SWP_NOMOVE | SWP_NOZORDER);
    }

    pub fn setVisible(self: *Window, show: bool) void {
        self.hidden = !show;
        _ = ShowWindow(self.hwnd, if (show) SW_SHOW else SW_HIDE);
        if (show) self.scheduleRedraw();
    }

    pub fn isVisible(self: *const Window) bool {
        return !self.hidden;
    }

    /// Periodic `on_tick` every `ms` (0 = off). Window thread.
    pub fn setTick(self: *Window, ms: u32) void {
        self.opts.tick_ms = ms;
        if (ms > 0) _ = SetTimer(self.hwnd, TICK_TIMER_ID, ms, null) else _ = KillTimer(self.hwnd, TICK_TIMER_ID);
    }

    // --- Wayland-only features: API parity --------------------------------------------

    /// No compositor vsync hook: returns false at once (the caller paces itself).
    pub fn waitFrame(_: *Window, _: u32) bool {
        return false;
    }

    pub fn presentDmabuf(_: *Window, _: u8, _: i32, _: u32, _: u32, _: u32, _: u32, _: u64) bool {
        return false;
    }

    pub fn presentDmabufPlanes(_: *Window, _: u8, _: []const window.DmabufPlane, _: u32, _: u32, _: u32) bool {
        return false;
    }

    pub fn videoBusy(_: *const Window) bool {
        return false;
    }
    /// No video plane here: no slot is ever free (`presentDmabuf` returns false).
    pub fn videoSlotFree(_: *Window, _: u8) bool {
        return false;
    }

    pub fn hideVideo(_: *Window) void {}

    pub fn setVideoArea(_: *Window, _: ?PxRect) void {}

    pub fn createPopup(_: *Window, _: window.PopupSpec) !u32 {
        return error.Unsupported;
    }

    pub fn dismissPopup(_: *Window, _: u32) void {}

    pub fn enableTextInput(_: *Window, _: window.TextInputSpec) void {}

    pub fn disableTextInput(_: *Window) void {}

    // --- clipboard (CF_UNICODETEXT) ----------------------------------------------------

    pub fn clipboardSet(self: *Window, bytes: []const u8) void {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(self.gpa, bytes) catch return;
        defer self.gpa.free(wide);
        const size = (wide.len + 1) * 2; // with the NUL
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
        // On success the system owns the handle.
        if (SetClipboardData(CF_UNICODETEXT, handle) == null) _ = GlobalFree(handle);
    }

    /// No ownership notion here: `clipboardGet` reads back our own text too.
    pub fn clipboardOwn(_: *Window) ?[]const u8 {
        return null;
    }

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

    // --- the loop -----------------------------------------------------------------------

    pub fn run(self: *Window) !void {
        var msg: MSG = undefined;
        while (!@atomicLoad(bool, &self.closed, .acquire)) {
            const r = GetMessageW(&msg, null, 0, 0);
            if (r == 0 or r == -1) break; // WM_QUIT or error
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
    }

    fn serviceWake(self: *Window) void {
        self.wake_posted.store(false, .release);
        if (self.opts.on_compose == null) {
            self.mutex.lock();
            const fresh = self.staged.fresh;
            self.mutex.unlock();
            if (fresh) self.damageAll();
        }
        self.mutex.lock();
        const pclip = self.pending_clip;
        self.pending_clip = null;
        self.mutex.unlock();
        if (pclip) |clip| {
            self.clipboardSet(clip);
            self.gpa.free(clip);
        }
        if (self.pending_toggle_visible.swap(false, .acquire)) self.setVisible(self.hidden);
        if (self.opts.on_wake) |cb| cb(self, false, self.opts.user);
        if (@atomicLoad(bool, &self.needs_redraw, .acquire)) self.redraw();
    }

    /// Pull the client size from the OS; the geometry is it minus the margin.
    fn syncClientSize(self: *Window) void {
        const h = self.hwnd orelse return;
        var rc: RECT = undefined;
        if (GetClientRect(h, &rc) == 0) return;
        const cw: u32 = @intCast(@max(rc.right - rc.left, 1));
        const ch: u32 = @intCast(@max(rc.bottom - rc.top, 1));
        const gutter = 2 * self.margin;
        self.width = if (cw > gutter) cw - gutter else 1;
        self.height = if (ch > gutter) ch - gutter else 1;
    }

    fn refreshMaximized(self: *Window) void {
        var wp = WINDOWPLACEMENT{};
        if (GetWindowPlacement(self.hwnd, &wp) != 0) self.maximized = wp.showCmd == SW_MAX_STATE;
    }

    /// Size or state changed: resync, tell the client, repaint now.
    fn configureChanged(self: *Window) void {
        self.refreshMaximized();
        self.syncClientSize();
        if (self.opts.on_configure) |cb| cb(self, self.opts.user);
        self.damageAll();
        self.redraw();
    }

    /// Size the heap frame and (layered) the DIB section to `bw`×`bh`.
    fn ensureBuffers(self: *Window, bw: u32, bh: u32) bool {
        const len = @as(usize, bw) * bh;
        if (self.buf_w == bw and self.buf_h == bh and self.frame.len == len and (!self.layered or self.dib != null)) return true;
        if (self.frame.len != len) {
            const nf = self.gpa.alloc(u32, len) catch return false;
            if (self.frame.len > 0) self.gpa.free(self.frame);
            self.frame = nf;
        }
        if (self.layered) {
            if (self.mem_dc == null) self.mem_dc = CreateCompatibleDC(null);
            if (self.dib) |d| _ = DeleteObject(d);
            self.dib = null;
            var bmi = bitmapInfo(bw, bh);
            var bits: ?*anyopaque = null;
            const hbmp = CreateDIBSection(self.mem_dc, &bmi, DIB_RGB_COLORS, &bits, null, 0) orelse return false;
            _ = SelectObject(self.mem_dc, hbmp);
            self.dib = hbmp;
            self.dib_px = @as([*]u32, @ptrCast(@alignCast(bits)))[0..len];
        }
        self.buf_w = bw;
        self.buf_h = bh;
        self.damage_full = true;
        return true;
    }

    fn bitmapInfo(w: u32, h: u32) BITMAPINFO {
        return .{ .bmiHeader = .{ .biWidth = @intCast(w), .biHeight = -@as(i32, @intCast(h)), .biBitCount = 32 } };
    }

    /// Compose the frame and push it to the screen.
    fn redraw(self: *Window) void {
        if (self.hwnd == null) return;
        if (!self.ready and self.opts.on_compose == null) return;
        const size = self.bufferSize();
        const bw = size[0];
        const bh = size[1];
        if (!self.ensureBuffers(bw, bh)) return;
        if (self.opts.on_compose != null) {
            if (self.opts.on_before_compose) |cb| cb(self, self.opts.user);
        } else {
            self.damage_full = true;
        }
        const region: ?PxRect = if (self.damage_full or self.damage_rect == null) null else self.damage_rect;
        self.damage_full = false;
        self.damage_rect = null;
        // Cleared before composing: a redraw requested while composing is for the next one.
        @atomicStore(bool, &self.needs_redraw, false, .release);
        if (self.opts.on_compose) |compose| {
            compose(self, self.frame, bw, bh, region, self.opts.user);
        } else {
            self.composeDefault(bw, bh);
        }
        self.blit();
    }

    fn composeDefault(self: *Window, bw: u32, bh: u32) void {
        @memset(self.frame, if (self.layered) 0x00000000 else 0xFF000000);
        var canvas = paint.Canvas.init(self.frame, bw, bh);
        const g = self.geometryPx();
        const content = window.Rect{ .x = @intCast(g.x), .y = @intCast(g.y), .w = @intCast(g.w), .h = @intCast(g.h) };
        if (self.opts.on_draw) |draw| draw(&canvas, content, self.opts.user);
        self.mutex.lock();
        if (self.staged.fresh) {
            std.mem.swap(Staged, &self.staged, &self.front);
            self.staged.fresh = false;
        }
        self.mutex.unlock();
        if (self.front.width > 0) {
            const fw = @min(self.front.width, g.w);
            const fh = @min(self.front.height, g.h);
            const dx: i32 = @intCast(g.x + (g.w - fw) / 2);
            const dy: i32 = @intCast(g.y + (g.h - fh) / 2);
            canvas.blitImage(dx, dy, fw, fh, self.front.pixels.items, self.front.width, self.front.height);
        }
    }

    /// The composed frame to the screen: layered → DIB + UpdateLayeredWindow (per-pixel
    /// alpha, premultiplied); opaque → a straight blit into the window DC.
    fn blit(self: *Window) void {
        if (self.frame.len == 0) return;
        if (!self.layered) {
            const hdc = GetDC(self.hwnd);
            defer _ = ReleaseDC(self.hwnd, hdc);
            var bmi = bitmapInfo(self.buf_w, self.buf_h);
            _ = SetDIBitsToDevice(hdc, 0, 0, self.buf_w, self.buf_h, 0, 0, 0, self.buf_h, self.frame.ptr, &bmi, 0);
            return;
        }
        if (self.dib == null) return;
        @memcpy(self.dib_px, self.frame); // heap → DIB in one linear pass
        const screen = GetDC(null);
        defer _ = ReleaseDC(null, screen);
        var sz = SIZE{ .cx = @intCast(self.buf_w), .cy = @intCast(self.buf_h) };
        var src = POINT{ .x = 0, .y = 0 };
        const blend = BLENDFUNCTION{ .BlendOp = AC_SRC_OVER, .BlendFlags = 0, .SourceConstantAlpha = 255, .AlphaFormat = AC_SRC_ALPHA };
        _ = UpdateLayeredWindow(self.hwnd, screen, null, &sz, self.mem_dc, &src, 0, &blend, ULW_ALPHA);
    }

    // --- input --------------------------------------------------------------------------

    /// An `on_draw` client is immediate-mode: a key, a click or a scroll may have changed
    /// what it draws, so the frame is redrawn after it (as on every backend). A client
    /// with `on_compose` owns its damage and asks itself.
    fn inputRedraw(self: *Window) void {
        if (self.opts.on_compose == null) self.needs_redraw = true;
    }

    fn mouse(self: *Window, ev: window.MouseEvent) void {
        if (self.opts.on_mouse) |cb| cb(self, ev, self.opts.user);
    }

    /// WM_CHAR → `on_text`: TranslateMessage already applied the layout. Surrogate pairs
    /// are joined; control characters and DEL skipped (the Wayland xkb path's rule).
    fn onChar(self: *Window, cu: u16) void {
        const cb = self.opts.on_text orelse return;
        var cp: u21 = cu;
        if (cu >= 0xD800 and cu <= 0xDBFF) {
            self.high_surrogate = cu;
            return;
        }
        if (cu >= 0xDC00 and cu <= 0xDFFF) {
            const hi = self.high_surrogate;
            self.high_surrogate = 0;
            if (hi == 0) return;
            cp = 0x10000 + ((@as(u21, hi - 0xD800) << 10) | (cu - 0xDC00));
        } else {
            self.high_surrogate = 0;
        }
        if (cp < 0x20 or cp == 0x7f) return;
        var bytes: [4]u8 = .{ 0, 0, 0, 0 };
        const len: u8 = std.unicode.utf8Encode(cp, &bytes) catch return;
        self.text_from_key = true;
        defer self.text_from_key = false;
        cb(self, bytes, len, self.opts.user);
    }

    fn lparamPoint(lparam: LPARAM) [2]f32 {
        const v: usize = @bitCast(lparam);
        const lo: i16 = @bitCast(@as(u16, @truncate(v & 0xFFFF)));
        const hi: i16 = @bitCast(@as(u16, @truncate((v >> 16) & 0xFFFF)));
        return .{ @floatFromInt(lo), @floatFromInt(hi) };
    }

    fn wndProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
        if (msg == WM_CREATE) {
            // lpCreateParams is the first field of CREATESTRUCTW on every ABI.
            const create: *const extern struct { lpCreateParams: ?*anyopaque } = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(create.lpCreateParams)));
            if (create.lpCreateParams) |p| {
                const w: *Window = @ptrCast(@alignCast(p));
                w.hwnd = hwnd;
            }
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
                // Not raised by `close()`: the system asks (Alt+F4, the taskbar) and the
                // app may refuse ("save changes?") and close later itself.
                if (!self.closed) {
                    if (self.opts.on_close_request) |cb| {
                        if (!cb(self, self.opts.user)) {
                            self.scheduleRedraw();
                            return 0;
                        }
                    }
                }
                self.closed = true;
                PostQuitMessage(0);
                return 0;
            },
            WM_ERASEBKGND => return 1, // every pixel is ours
            WM_NCCALCSIZE => {
                // Frameless: the client area is the whole window.
                if (wparam == 0 or !self.frameless) return DefWindowProcW(hwnd, msg, wparam, lparam);
                return 0;
            },
            WM_SETCURSOR => {
                if (@as(u16, @truncate(@as(usize, @bitCast(lparam)))) != HTCLIENT)
                    return DefWindowProcW(hwnd, msg, wparam, lparam);
                var shape = self.cursor_shape;
                var pt: POINT = undefined;
                if (self.bandActive() and GetCursorPos(&pt) != 0 and ScreenToClient(hwnd, &pt) != 0) {
                    const edge = self.resizeEdgeAt(@floatFromInt(pt.x), @floatFromInt(pt.y));
                    if (edge != wl.RESIZE_EDGE_NONE) shape = edgeCursor(edge);
                }
                _ = SetCursor(LoadCursorW(null, cursorId(shape)));
                return 1;
            },
            WM_SIZE => {
                self.configureChanged();
                return 0;
            },
            WM_PAINT => {
                // Layered surfaces are retained by the system; an opaque window DC is not,
                // so an expose re-blits the last frame.
                var ps: PAINTSTRUCT = undefined;
                _ = BeginPaint(hwnd, &ps);
                if (!self.layered) self.blit();
                _ = EndPaint(hwnd, &ps);
                return 0;
            },
            WM_APP_WAKE => {
                self.serviceWake();
                return 0;
            },
            WM_TIMER => {
                if (wparam == TICK_TIMER_ID) {
                    if (self.opts.on_tick) |tick| tick(self, self.opts.user);
                    if (self.needs_redraw) self.redraw();
                }
                return 0;
            },
            WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP => {
                const down = msg == WM_KEYDOWN or msg == WM_SYSKEYDOWN;
                const bits: usize = @bitCast(lparam);
                // bit 24: an "extended" key (right Ctrl/Alt, keypad Enter); bit 30: it was
                // already down — an auto-repeat.
                const key = mapVkExt(wparam, (bits >> 24) & 1 == 1);
                if (key != 0) {
                    if (key < 256) self.held_keys.setValue(key, down);
                    self.key_repeating = down and (bits >> 30) & 1 == 1;
                    defer self.key_repeating = false;
                    if (self.opts.on_key) |cb| cb(self, key, @intFromBool(down), self.opts.user);
                }
                // Alt+… stays the system's (Alt+F4 → WM_CLOSE, Alt+Space → window menu).
                self.inputRedraw();
                if (self.needs_redraw) self.redraw();
                if (msg == WM_SYSKEYDOWN or msg == WM_SYSKEYUP) return DefWindowProcW(hwnd, msg, wparam, lparam);
                return 0;
            },
            WM_KILLFOCUS => {
                // The releases of held keys go to the new focus: deliver them here, or the
                // app would think Ctrl is still down.
                var it = self.held_keys.iterator(.{});
                while (it.next()) |k| {
                    if (self.opts.on_key) |cb| cb(self, @intCast(k), 0, self.opts.user);
                }
                self.held_keys = .empty;
                return DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            WM_CHAR => {
                self.onChar(@truncate(wparam));
                self.inputRedraw();
                if (self.needs_redraw) self.redraw();
                return 0;
            },
            WM_MOUSEMOVE => {
                const p = lparamPoint(lparam);
                self.pointer_x = p[0];
                self.pointer_y = p[1];
                if (!self.tracking_leave) {
                    var tme = TRACKMOUSEEVENT{ .dwFlags = TME_LEAVE, .hwndTrack = hwnd };
                    _ = TrackMouseEvent(&tme);
                    self.tracking_leave = true;
                }
                self.mouse(.{ .kind = .motion, .x = p[0], .y = p[1] });
                if (self.needs_redraw) self.redraw();
                return 0;
            },
            WM_MOUSELEAVE => {
                self.tracking_leave = false;
                self.mouse(.{ .kind = .leave });
                if (self.needs_redraw) self.redraw();
                return 0;
            },
            WM_LBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP => {
                const pressed = msg == WM_LBUTTONDOWN or msg == WM_RBUTTONDOWN or msg == WM_MBUTTONDOWN;
                const button: u32 = switch (msg) {
                    WM_LBUTTONDOWN, WM_LBUTTONUP => wl.BTN_LEFT,
                    WM_RBUTTONDOWN, WM_RBUTTONUP => BTN_RIGHT,
                    else => BTN_MIDDLE,
                };
                if (msg == WM_LBUTTONDOWN and self.bandActive()) {
                    const edge = self.resizeEdgeAt(self.pointer_x, self.pointer_y);
                    if (edge != wl.RESIZE_EDGE_NONE) {
                        self.beginResize(edge);
                        return 0;
                    }
                }
                // No mouse handler and no frame to grab: the window drags from anywhere.
                if (self.opts.on_mouse == null) {
                    if (msg == WM_LBUTTONDOWN and self.frameless and !self.fullscreen) self.beginMove();
                    return 0;
                }
                self.mouse(.{ .kind = if (pressed) .press else .release, .x = self.pointer_x, .y = self.pointer_y, .button = button });
                self.inputRedraw();
                if (self.needs_redraw) self.redraw();
                return 0;
            },
            WM_MOUSEWHEEL, WM_MOUSEHWHEEL => {
                // A signed notch count (×120) in the high word. Wayland axis units: about
                // 40 px a notch, positive = content up, so wheel-up is negative.
                const raw: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
                const v = -@as(f32, @floatFromInt(raw)) / 120.0 * 40.0;
                if (msg == WM_MOUSEHWHEEL)
                    self.mouse(.{ .kind = .scroll, .x = self.pointer_x, .y = self.pointer_y, .scroll_dx = v })
                else
                    self.mouse(.{ .kind = .scroll, .x = self.pointer_x, .y = self.pointer_y, .scroll_dy = v });
                self.inputRedraw();
                if (self.needs_redraw) self.redraw();
                return 0;
            },
            else => return DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    /// `mapVk` plus lparam's "extended" flag: right Ctrl/Alt and keypad Enter.
    fn mapVkExt(vk: WPARAM, extended: bool) u32 {
        if (extended) switch (vk) {
            0x11 => return 97, // right Ctrl → KEY_RIGHTCTRL
            0x12 => return 100, // right Alt (AltGr) → KEY_RIGHTALT
            0x0D => return 96, // keypad Enter → KEY_KPENTER
            else => {},
        };
        return mapVk(vk);
    }

    /// Win32 virtual-key code → the evdev code the Wayland path emits.
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
            0x1B => 1, // VK_ESCAPE
            0x20 => 57, // VK_SPACE
            0x0D => 28, // VK_RETURN
            0x08 => 14, // VK_BACK
            0x09 => 15, // VK_TAB
            0x25 => 105, // VK_LEFT
            0x26 => 103, // VK_UP
            0x27 => 106, // VK_RIGHT
            0x28 => 108, // VK_DOWN
            0x21 => 104, // VK_PRIOR → PAGEUP
            0x22 => 109, // VK_NEXT → PAGEDOWN
            0xBD => 12, // VK_OEM_MINUS
            0xBB => 13, // VK_OEM_PLUS (=)
            0x10, 0xA0 => 42, // VK_SHIFT / VK_LSHIFT
            0xA1 => 54, // VK_RSHIFT
            0x11, 0xA2 => 29, // VK_CONTROL / VK_LCONTROL
            0xA3 => 97, // VK_RCONTROL
            0x12, 0xA4 => 56, // VK_MENU / VK_LMENU
            0xA5 => 100, // VK_RMENU
            0x5B => 125, // VK_LWIN
            0x5C => 126, // VK_RWIN
            0x14 => 58, // VK_CAPITAL
            0x2E => 111, // VK_DELETE
            0x2D => 110, // VK_INSERT
            0x24 => 102, // VK_HOME
            0x23 => 107, // VK_END
            0x70...0x79 => @as(u32, @intCast(vk - 0x70)) + 59, // VK_F1..F10
            0x7A => 87, // VK_F11
            0x7B => 88, // VK_F12
            0xC0 => 41, // VK_OEM_3 (` ~)
            0xBA => 39, // VK_OEM_1 (; :)
            0xDE => 40, // VK_OEM_7 (' ")
            0xDB => 26, // VK_OEM_4 ([ {)
            0xDD => 27, // VK_OEM_6 (] })
            0xDC => 43, // VK_OEM_5 (\ |)
            0xE2 => 86, // VK_OEM_102 (ISO < >)
            0xBC => 51, // VK_OEM_COMMA
            0xBE => 52, // VK_OEM_PERIOD
            0xBF => 53, // VK_OEM_2 (/ ?)
            0x60 => 82, // VK_NUMPAD0
            0x61 => 79,
            0x62 => 80,
            0x63 => 81,
            0x64 => 75,
            0x65 => 76,
            0x66 => 77,
            0x67 => 71,
            0x68 => 72,
            0x69 => 73, // VK_NUMPAD9
            0x6A => 55, // VK_MULTIPLY
            0x6B => 78, // VK_ADD
            0x6D => 74, // VK_SUBTRACT
            0x6E => 83, // VK_DECIMAL
            0x6F => 98, // VK_DIVIDE
            else => 0,
        };
    }
};
