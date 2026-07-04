const std = @import("std");
const builtin = @import("builtin");

pub const Window = if (builtin.os.tag != .windows) struct {} else struct {
    const paint = @import("paint.zig");
    const window = @import("window.zig");
    const Allocator = std.mem.Allocator;

    // Win32 FFI Types and Constants
    const HWND = ?*anyopaque;
    const HDC = ?*anyopaque;
    const HBITMAP = ?*anyopaque;
    const HINSTANCE = ?*anyopaque;
    const HBRUSH = ?*anyopaque;
    const HFONT = ?*anyopaque;
    const HICON = ?*anyopaque;
    const HCURSOR = ?*anyopaque;
    const LRESULT = isize;
    const WPARAM = usize;
    const LPARAM = isize;
    const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.stdcall) LRESULT;

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

    const BLENDFUNCTION = extern struct {
        BlendOp: u8 = 0, // AC_SRC_OVER
        BlendFlags: u8 = 0,
        SourceConstantAlpha: u8 = 255,
        AlphaFormat: u8 = 1, // AC_SRC_ALPHA
    };

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

    // Win32 APIs (Container-level declarations)
    extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.stdcall) u16;
    extern "user32" fn CreateWindowExW(
        dwExStyle: u32,
        lpClassName: [*:0]const u16,
        lpWindowName: ?[*:0]const u16,
        dwStyle: u32,
        x: i32,
        y: i32,
        nWidth: i32,
        nHeight: i32,
        hWndParent: HWND,
        hMenu: ?*anyopaque,
        hInstance: HINSTANCE,
        lpParam: ?*anyopaque,
    ) callconv(.stdcall) HWND;

    extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.stdcall) i32;
    extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.stdcall) LRESULT;
    extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.stdcall) i32;
    extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: u32, wMsgFilterMax: u32, wRemoveMsg: u32) callconv(.stdcall) i32;
    extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.stdcall) i32;
    extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.stdcall) LRESULT;
    extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.stdcall) void;
    extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.stdcall) i32;
    extern "user32" fn UpdateLayeredWindow(
        hWnd: HWND,
        hdcDst: HDC,
        pptDst: ?*const POINT,
        psize: ?*const SIZE,
        hdcSrc: HDC,
        pptSrc: ?*const POINT,
        crKey: u32,
        pblend: *const BLENDFUNCTION,
        dwFlags: u32,
    ) callconv(.stdcall) i32;

    extern "user32" fn GetDC(hWnd: HWND) callconv(.stdcall) HDC;
    extern "user32" fn ReleaseDC(hWnd: HWND, hDC: HDC) callconv(.stdcall) i32;
    extern "user32" fn GetWindowLongW(hWnd: HWND, nIndex: i32) callconv(.stdcall) i32;
    extern "user32" fn SetWindowLongW(hWnd: HWND, nIndex: i32, dwNewLong: i32) callconv(.stdcall) i32;
    extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: ?*anyopaque) callconv(.stdcall) i32;
    extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: HWND, X: i32, Y: i32, cx: i32, cy: i32, uFlags: u32) callconv(.stdcall) i32;
    extern "user32" fn GetSystemMetrics(nIndex: i32) callconv(.stdcall) i32;
    extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.stdcall) isize;
    extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: isize) callconv(.stdcall) isize;
    extern "user32" fn ReleaseCapture() callconv(.stdcall) i32;
    extern "user32" fn SendMessageW(hWnd: HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.stdcall) LRESULT;

    extern "gdi32" fn CreateCompatibleDC(hdc: HDC) callconv(.stdcall) HDC;
    extern "gdi32" fn CreateDIBSection(
        hdc: HDC,
        pbmi: *const BITMAPINFO,
        usage: u32,
        ppvBits: *?*anyopaque,
        hSection: ?*anyopaque,
        offset: u32,
    ) callconv(.stdcall) HBITMAP;
    extern "gdi32" fn SelectObject(hdc: HDC, h: *anyopaque) callconv(.stdcall) ?*anyopaque;
    extern "gdi32" fn DeleteObject(ho: *anyopaque) callconv(.stdcall) i32;
    extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.stdcall) i32;
    extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.stdcall) HINSTANCE;

    // Constants
    const WS_EX_LAYERED: u32 = 0x00080000;
    const WS_POPUP: u32 = 0x80000000;
    const WS_SYSMENU: u32 = 0x00080000;
    const SW_SHOW: i32 = 5;
    const SW_SHOWMAXIMIZED: i32 = 12;
    const SW_SHOWNORMAL: i32 = 1;
    const ULW_ALPHA: u32 = 2;
    const PM_REMOVE: u32 = 1;

    gpa: Allocator,
    opts: window.Options,
    hwnd: HWND = null,
    closed: bool = false,
    fullscreen: bool = false,
    saved_style: u32 = 0,
    saved_rect: extern struct { left: i32, top: i32, right: i32, bottom: i32 } = undefined,

    // Double buffering pixels
    pixels: []u32 = &.{},
    width: u32,
    height: u32,
    mutex: std.Thread.Mutex = .{},

    pub fn init(gpa: Allocator, opts: window.Options) !*Window {
        const self = try gpa.create(Window);
        self.* = .{
            .gpa = gpa,
            .opts = opts,
            .width = opts.width,
            .height = opts.height,
        };

        const hinst = GetModuleHandleW(null);
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZicroWindowClass");

        const wc = WNDCLASSEXW{
            .style = 3, // CS_HREDRAW | CS_VREDRAW
            .lpfnWndProc = wndProc,
            .hInstance = hinst,
            .lpszClassName = class_name,
        };
        _ = RegisterClassExW(&wc);

        // Borderless popup layered window (transparency via alpha channel)
        const hwnd = CreateWindowExW(
            WS_EX_LAYERED,
            class_name,
            std.unicode.utf8ToUtf16LeStringLiteral("zicro"),
            WS_POPUP | WS_SYSMENU,
            100, 100, @intCast(opts.width), @intCast(opts.height),
            null, null, hinst, self,
        ) orelse return error.WindowCreationFailed;

        self.hwnd = hwnd;
        _ = ShowWindow(hwnd, SW_SHOW);

        self.pixels = try gpa.alloc(u32, opts.width * opts.height);
        @memset(self.pixels, 0);

        return self;
    }

    pub fn deinit(self: *Window) void {
        if (self.hwnd) |h| _ = DestroyWindow(h);
        self.gpa.free(self.pixels);
        self.gpa.destroy(self);
    }

    pub fn toggleFullscreen(self: *Window) void {
        const h = self.hwnd orelse return;
        self.fullscreen = !self.fullscreen;
        // Basic Win32 fullscreen toggle
        if (self.fullscreen) {
            self.saved_style = @intCast(GetWindowLongW(h, -16)); // GWL_STYLE
            _ = GetWindowRect(h, &self.saved_rect);

            _ = SetWindowLongW(h, -16, @intCast(WS_POPUP));
            const w = GetSystemMetrics(0); // SM_CXSCREEN
            const h_scr = GetSystemMetrics(1); // SM_CYSCREEN
            _ = SetWindowPos(h, null, 0, 0, w, h_scr, 0x0040); // SWP_SHOWWINDOW
            self.width = @intCast(w);
            self.height = @intCast(h_scr);
            self.pixels = self.gpa.realloc(self.pixels, self.width * self.height) catch self.pixels;
        } else {
            _ = SetWindowLongW(h, -16, @intCast(self.saved_style));
            const w = self.saved_rect.right - self.saved_rect.left;
            const h_rec = self.saved_rect.bottom - self.saved_rect.top;
            _ = SetWindowPos(h, null, self.saved_rect.left, self.saved_rect.top, w, h_rec, 0x0040);
            self.width = @intCast(w);
            self.height = @intCast(h_rec);
            self.pixels = self.gpa.realloc(self.pixels, self.width * self.height) catch self.pixels;
        }
    }

    pub fn setMinimized(self: *Window) void {
        _ = ShowWindow(self.hwnd, 6); // SW_MINIMIZE / SW_SHOWMINIMIZED
    }

    pub fn presentRgba(self: *Window, w: u32, h: u32, rgba: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const copy_w = @min(w, self.width);
        const copy_h = @min(h, self.height);
        
        var y: u32 = 0;
        while (y < copy_h) : (y += 1) {
            const src_row = rgba[y * w * 4 ..][0 .. copy_w * 4];
            const dst_row = self.pixels[y * self.width ..][0..copy_w];
            for (dst_row, 0..) |*dst, x| {
                const r = src_row[x * 4 + 0];
                const g = src_row[x * 4 + 1];
                const b = src_row[x * 4 + 2];
                const a = src_row[x * 4 + 3];
                // Premultiply
                const alpha = @as(f32, @floatFromInt(a)) / 255.0;
                const rp = @as(u32, @intFromFloat(@as(f32, @floatFromInt(r)) * alpha + 0.5));
                const gp = @as(u32, @intFromFloat(@as(f32, @floatFromInt(g)) * alpha + 0.5));
                const bp = @as(u32, @intFromFloat(@as(f32, @floatFromInt(b)) * alpha + 0.5));
                dst.* = (@as(u32, a) << 24) | (rp << 16) | (gp << 8) | bp;
            }
        }
        self.updateLayered();
    }

    fn updateLayered(self: *Window) void {
        const h = self.hwnd orelse return;
        const screen_dc = GetDC(null);
        defer _ = ReleaseDC(null, screen_dc);

        const mem_dc = CreateCompatibleDC(screen_dc);
        defer _ = DeleteDC(mem_dc);

        var bmi = BITMAPINFO{
            .bmiHeader = .{
                .biWidth = @intCast(self.width),
                .biHeight = -@as(i32, @intCast(self.height)), // Top-down
                .biBitCount = 32,
            },
        };

        var bits: ?*anyopaque = null;
        const hbmp = CreateDIBSection(mem_dc, &bmi, 0, &bits, null, 0);
        defer _ = DeleteObject(hbmp);

        if (bits) |p| {
            const dest = @as([*]u32, @ptrCast(@alignCast(p)));
            @memcpy(dest[0 .. self.width * self.height], self.pixels);
        }

        const old_bmp = SelectObject(mem_dc, hbmp);
        defer _ = SelectObject(mem_dc, old_bmp.?);

        var size = SIZE{ .cx = @intCast(self.width), .cy = @intCast(self.height) };
        var pt_src = POINT{ .x = 0, .y = 0 };
        var blend = BLENDFUNCTION{};

        _ = UpdateLayeredWindow(h, screen_dc, null, &size, mem_dc, &pt_src, 0, &blend, ULW_ALPHA);
    }

    pub fn run(self: *Window) !void {
        var msg = MSG{ .hwnd = null, .message = 0, .wParam = 0, .lParam = 0, .time = 0, .pt = .{ .x = 0, .y = 0 } };
        while (!self.closed) {
            if (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
                _ = TranslateMessage(&msg);
                _ = DispatchMessageW(&msg);
                if (msg.message == 0x0012) { // WM_QUIT
                    self.closed = true;
                }
            } else {
                self.mutex.lock();
                @memset(self.pixels, 0); // transparent background
                var canvas = paint.Canvas.init(self.pixels, self.width, self.height);
                const content = window.Rect{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
                if (self.opts.on_draw) |draw| draw(&canvas, content, self.opts.user);
                self.updateLayered();
                self.mutex.unlock();
                std.Thread.sleep(16 * std.time.ns_per_ms); // 60 FPS pacing
            }
        }
    }

    fn wndProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.stdcall) LRESULT {
        if (msg == 0x0001) { // WM_CREATE
            const create_struct = @as(*const extern struct { lpCreateParams: ?*anyopaque }, @ptrCast(@alignCast(lparam)));
            _ = SetWindowLongPtrW(hwnd, -21, @intCast(@intFromPtr(create_struct.lpCreateParams))); // GWLP_USERDATA
        }

        const ptr = GetWindowLongPtrW(hwnd, -21);
        if (ptr != 0) {
            const self = @as(*Window, @ptrFromInt(@as(usize, @intCast(ptr))));
            switch (msg) {
                0x0002 => { // WM_DESTROY
                    self.closed = true;
                    PostQuitMessage(0);
                    return 0;
                },
                0x0100 => { // WM_KEYDOWN
                    const vk = wparam;
                    var evdev_key: u32 = 0;
                    if (vk >= 'A' and vk <= 'Z') {
                        evdev_key = switch (vk) {
                            'A' => 30, 'B' => 48, 'C' => 46, 'D' => 32, 'E' => 18,
                            'F' => 33, 'G' => 34, 'H' => 35, 'I' => 23, 'J' => 36,
                            'K' => 37, 'L' => 38, 'M' => 50, 'N' => 49, 'O' => 24,
                            'P' => 25, 'Q' => 16, 'R' => 19, 'S' => 31, 'T' => 20,
                            'U' => 22, 'V' => 47, 'W' => 17, 'X' => 45, 'Y' => 21,
                            'Z' => 44,
                            else => 0,
                        };
                    } else {
                        evdev_key = switch (vk) {
                            0x1B => 1, // VK_ESCAPE -> KEY_ESC
                            0x0D => 28, // VK_RETURN -> KEY_ENTER
                            0x20 => 57, // VK_SPACE -> KEY_SPACE
                            0x08 => 14, // VK_BACK -> KEY_BACKSPACE
                            else => 0,
                        };
                    }
                    if (evdev_key != 0 and self.opts.on_key != null) {
                        self.opts.on_key.?(self, evdev_key, 1, self.opts.user);
                    }
                    return 0;
                },
                0x0101 => { // WM_KEYUP
                    return 0;
                },
                0x0201 => { // WM_LBUTTONDOWN
                    _ = ReleaseCapture();
                    _ = SendMessageW(hwnd, 0x00A1, 2, 0); // WM_NCLBUTTONDOWN, HTCAPTION
                    return 0;
                },
                else => {},
            }
        }

        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
};
