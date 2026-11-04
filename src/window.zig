const std = @import("std");
const builtin = @import("builtin");

pub const paint = @import("paint.zig");
pub const gesture = @import("gesture.zig");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// A pointer event in surface (content) coordinates, y growing downward.
pub const MouseEvent = struct {
    kind: Kind,
    x: f32 = 0,
    y: f32 = 0,
    /// evdev BTN_* code for press/release (272 = left, 273 = right, 274 = middle).
    button: u32 = 0,
    /// Vertical scroll amount for `.scroll` (positive = content up).
    scroll_dy: f32 = 0,
    /// Horizontal scroll amount for `.scroll` (positive = content left). Wayland only
    /// for now; the other backends leave it 0.
    scroll_dx: f32 = 0,

    /// `.leave`: the pointer left the window — drop hover state. No position.
    pub const Kind = enum { motion, press, release, scroll, leave };
};

/// A single memory plane of a dmabuf GPU buffer export (fd, offset, stride, modifier).
pub const DmabufPlane = struct {
    fd: i32,
    offset: u32 = 0,
    stride: u32,
    modifier: u64 = 0,
};

/// Platform-neutral popup (`xdg_popup` on Wayland): menus, tooltips, IME candidates.
pub const PopupSpec = struct {
    pub const Anchor = enum { none, top, bottom, left, right, top_left, bottom_left, top_right, bottom_right };
    pub const Gravity = Anchor;

    id: u32 = 0,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    anchor: Anchor = .none,
    gravity: Gravity = .none,
    grab: bool = true,
};

/// Platform-neutral IME request for the focused text field (`zwp_text_input_v3`).
pub const TextInputSpec = struct {
    pub const Hint = struct {
        completion: bool = false,
        spellcheck: bool = false,
        auto_capitalization: bool = false,
        lowercase: bool = false,
        uppercase: bool = false,
        titlecase: bool = false,
        hidden_text: bool = false,
        sensitive_data: bool = false,
        latin: bool = false,
        multiline: bool = false,
    };

    pub const Purpose = enum { normal, alpha, digits, number, phone, url, email, name, password, pin, terminal };

    x: i32 = 0,
    y: i32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    purpose: Purpose = .normal,
    hint: Hint = .{},
};

/// A rectangle in buffer pixels (damage, video placement) — unsigned, unlike `Rect`.
pub const PxRect = struct { x: u32, y: u32, w: u32, h: u32 };

/// Compositor background blur over the window geometry: a rounded rectangle, inset
/// `inset` px from the geometry's edges (Wayland `ext-background-effect-v1`).
pub const Blur = struct { radius: f32 = 0, inset: f32 = 0 };

pub const Options = struct {
    title: [:0]const u8 = "zicro-shell",
    width: u32 = 720,
    height: u32 = 460,
    on_draw: ?*const fn (canvas: *paint.Canvas, content: Rect, user: ?*anyopaque) void = null,
    on_key: ?*const fn (window: *Window, key: u32, state: u32, user: ?*anyopaque) void = null,
    /// When set, pointer events are delivered to the app and the default
    /// drag-anywhere window move is disabled (UI apps own their clicks).
    on_mouse: ?*const fn (window: *Window, event: MouseEvent, user: ?*anyopaque) void = null,
    /// Gesto multi-touch riconosciuto dal substrato (pinch, …). Un dito arriva come
    /// evento mouse su `on_mouse`; due dita qui (vedi `gesture.zig`).
    on_gesture: ?*const fn (window: *Window, g: gesture.Gesture, user: ?*anyopaque) void = null,
    /// Periodic callback from the event loop (runtime pumps: dispatch queues,
    /// timers, animations). 0 disables ticking and the loop blocks on events.
    on_tick: ?*const fn (window: *Window, user: ?*anyopaque) void = null,
    tick_ms: u32 = 0,
    /// Cap on the LONGER side of the render surface, in pixels (0 = render at the display's
    /// native resolution). Only the Android backend honors it, and there it matters: a CPU
    /// canvas on a 1080×2400 phone is 2.6 M pixels per frame, while the same UI drawn into a
    /// smaller buffer and scaled up by the compositor (free, it's the display hardware) costs
    /// a fraction of that and looks the same at arm's length. `scaleFactor()` folds the
    /// reduction in, so an app keeps sizing its UI in dp and needs to know nothing about it.
    surface_max_dim: u32 = 0,
    /// Ask the compositor for a server-side frame (title bar with close/
    /// minimize/maximize) via xdg-decoration. Default off: zicro shells are
    /// borderless drag-anywhere surfaces; app windows (e.g. zart) opt in.
    /// Falls back silently to borderless when the compositor lacks the
    /// protocol.
    decorations: bool = false,
    /// Fired when a CHILD window (see `Window.initChild`) is torn down — the
    /// compositor closed it or the app set `closed`. The window pointer is
    /// valid only for the duration of the callback; it is destroyed right
    /// after. Root windows signal close by `run()` returning, as before.
    on_close: ?*const fn (window: *Window, user: ?*anyopaque) void = null,
    /// Veto sulla chiusura chiesta dall'utente col pulsante della finestra: `false` la
    /// rifiuta (la finestra resta/torna visibile) e l'app chiuderà poi con `close()`.
    /// Solo Cocoa per ora (Wayland/Win32 li gestisce zrame direttamente).
    on_close_request: ?*const fn (window: *Window, user: ?*anyopaque) bool = null,
    /// Layout-correct text of a key press (xkbcommon) or an IME commit: one UTF-8
    /// codepoint, `bytes[0..len]`. Additive to `on_key`. Wayland only for now.
    on_text: ?*const fn (window: *Window, bytes: [4]u8, len: u8, user: ?*anyopaque) void = null,
    /// IME pre-edit (composition in progress): `text` is empty when it ends. Wayland only.
    on_preedit: ?*const fn (window: *Window, text: []const u8, cursor_begin: i32, cursor_end: i32, user: ?*anyopaque) void = null,
    user: ?*anyopaque = null,

    // --- Wayland transport, for a client that paints its own chrome (zrame) -------------
    // Other backends ignore these.

    /// `xdg_toplevel.set_app_id` (the desktop-file id). Empty = not set.
    app_id: [:0]const u8 = "",
    /// Transparent gutter around the window geometry, in logical px (a client-side
    /// shadow): the buffer grows by it on each side, the window geometry and the input
    /// region do not. Change it at runtime with `setSurfaceShape`.
    margin: u32 = 0,
    /// Compositor blur behind the geometry, or none. See `setSurfaceShape`.
    blur: ?Blur = null,
    /// Minimum window geometry, logical px (0 = none).
    min_size: u32 = 0,
    /// Render at PHYSICAL resolution on scaled outputs (`wp_viewporter` +
    /// `wp_fractional_scale_v1`): the canvas, `on_draw`'s rect and pointer coordinates
    /// are then in buffer pixels. Off: the buffer is logical and the compositor scales it.
    hidpi: bool = false,
    /// Borderless windows resize from an 8 px band at their edge, with the matching
    /// cursor. Off for a client that decides itself (zrame routes its panels first).
    resize_band: bool = true,
    /// A dmabuf frame is shown at its own size, centered in the video area, instead of
    /// filling it (see `presentDmabufPlanes`).
    video_native: bool = false,
    /// Called on the window thread before a redraw picks its buffer: the client declares
    /// what changed with `damage`/`damageAll` (no call = the whole buffer).
    on_before_compose: ?*const fn (window: *Window, user: ?*anyopaque) void = null,
    /// Replaces the default composition (clear + `on_draw` + staged frame): paint
    /// `pixels` (premultiplied ARGB, `width`×`height`). `region` null = all of it; else
    /// only that rect needs repainting — the rest still holds this buffer's last frame.
    on_compose: ?*const fn (window: *Window, pixels: []u32, width: u32, height: u32, region: ?PxRect, user: ?*anyopaque) void = null,
    /// The loop was woken (`wake`, a staged frame, a dmabuf present): `video` = a dmabuf
    /// frame was just committed. Window thread.
    on_wake: ?*const fn (window: *Window, video: bool, user: ?*anyopaque) void = null,
    /// After every `xdg_toplevel.configure` (size, fullscreen, maximized). Window thread.
    on_configure: ?*const fn (window: *Window, user: ?*anyopaque) void = null,
};

pub const Window = switch (builtin.os.tag) {
    // Android is os.tag = .linux, abi = .android: the NDK NativeActivity backend, not
    // Wayland. Plain Linux keeps Wayland.
    .linux => if (builtin.abi == .android or builtin.abi == .androideabi)
        @import("window_android.zig").Window
    else
        @import("window_wayland.zig").Window,
    .windows => @import("window_win32.zig").Window,
    .macos => @import("window_cocoa.zig").Window,
    // wasm (freestanding or emscripten) → the browser canvas backend; non-wasm
    // freestanding → Z-Scenic (Z#76 phase 2), Z's userspace target, selected only when
    // Z's build.zig cross-compiles Zicro with -Dzicro-src and wires the
    // "zrt"/"scenic_protocol" modules window_z.zig needs.
    .freestanding, .emscripten => if (builtin.cpu.arch.isWasm())
        @import("window_web.zig").Window
    else
        @import("window_z.zig").Window,
    else => struct {
        gpa: std.mem.Allocator,
        pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) !*@This() {
            _ = opts;
            _ = io;
            const self = try gpa.create(@This());
            self.* = .{ .gpa = gpa };
            return self;
        }
        pub fn deinit(self: *@This()) void {
            self.gpa.destroy(self);
        }
        pub fn run(self: *@This()) !void {
            _ = self;
        }
        pub fn presentRgba(self: *@This(), w: u32, h: u32, rgba: []const u8) void {
            _ = self;
            _ = w;
            _ = h;
            _ = rgba;
        }
        pub fn requestRedraw(self: *@This()) void {
            _ = self;
        }
        pub fn requestClose(self: *@This()) void {
            _ = self;
        }
        pub fn toggleFullscreen(self: *@This()) void {
            _ = self;
        }
        pub fn setMinimized(self: *@This()) void {
            _ = self;
        }
        pub fn setTitle(self: *@This(), title: [*:0]const u8) void {
            _ = self;
            _ = title;
        }
        pub fn scaleFactor(self: *const @This()) f32 {
            _ = self;
            return 1;
        }
        pub fn isTouch(self: *const @This()) bool {
            _ = self;
            return false;
        }
    },
};
