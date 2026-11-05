//! # zicro.window (Linux backend) — the Wayland window
//!
//! The ONE Wayland transport of the stack: zicro's own apps (shell, demo), Zart's
//! multi-window backend and zrame's glass window all sit on it. It owns everything the
//! protocol owns — connection, globals, xdg toplevel, wl_shm double buffer, HiDPI,
//! input (xkbcommon text, client-side key repeat, touch-as-pointer), IME
//! (`zwp_text_input_v3`), popups, clipboard, the dmabuf video plane, frame pacing —
//! and nothing a client paints: a client with its own chrome (zrame) sets `margin`,
//! `blur` and `on_compose` and draws every pixel itself.
//!
//! Several windows share ONE connection (window-server shape, see `initChild` /
//! `initSub`): the root owns the display, the globals and the seat; children are driven
//! by the root's `run` loop and input is routed to the surface it lands on.
//!
//! Threading: everything Wayland happens on the thread that calls `run`. The
//! cross-thread doors are `presentRgba`, `presentDmabuf*`, `requestRedraw`,
//! `requestClose`, `requestResize`, `requestClipboardSet`, `hideVideo`,
//! `requestToggleVisible`, `wake` and `waitFrame`: they stage under a lock and poke an
//! eventfd; the loop applies them.
//!
//! Coordinates: with `hidpi` the buffer is physical (logical × scale, shown at logical
//! size by `wp_viewport`) and the canvas, the pointer and every rect handed to the
//! client are in buffer pixels; without it everything is logical. What the compositor
//! sees — window geometry, regions, configure sizes — is always logical.

const std = @import("std");
const builtin = @import("builtin");

pub const Window = if (builtin.os.tag != .linux) struct {} else struct {
    const wl = @import("wl.zig");
    const xkb = @import("xkb.zig");
    const paint = @import("paint.zig");
    const window = @import("window.zig");
    const posix = std.posix;
    const linux = std.os.linux;
    const Allocator = std.mem.Allocator;
    const PxRect = window.PxRect;

    gpa: Allocator,
    io: std.Io,
    opts: window.Options,

    // --- connection + globals (the root's; children read them through `rt()`) --------
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    subcompositor: ?*wl.Subcompositor = null,
    shm: ?*wl.Shm = null,
    dmabuf: ?*wl.LinuxDmabuf = null,
    wm_base: ?*wl.XdgWmBase = null,
    seat: ?*wl.Seat = null,
    decoration_manager: ?*wl.ZxdgDecorationManager = null,
    cursor_shapes: ?*wl.CursorShapeManager = null,
    appmenu_manager: ?*wl.OrgKdeKwinAppmenuManager = null,
    blur_manager: ?*wl.BackgroundEffectManager = null,
    viewporter: ?*wl.Viewporter = null,
    fractional_manager: ?*wl.FractionalScaleManager = null,
    text_input_manager: ?*wl.ZwpTextInputManagerV3 = null,
    data_device_manager: ?*wl.DataDeviceManager = null,
    outputs: std.ArrayList(*OutputInfo) = .empty,
    /// Shared by the root and its children: one loop, one wake.
    wake_fd: posix.fd_t,
    /// Extra fds the root loop polls for the client (sd-bus tray/menu, a timer).
    pollers: [8]Poller = undefined,
    n_pollers: usize = 0,
    /// True once `run` is pumping (root). Before that, a configure redraws at once so
    /// the window maps during `init`'s roundtrip.
    running: bool = false,

    // --- this window's surface ----------------------------------------------------------
    parent: ?*Window = null,
    children: std.ArrayList(*Window) = .empty,
    surface: ?*wl.Surface = null,
    xdg_surface: ?*wl.XdgSurface = null,
    toplevel: ?*wl.XdgToplevel = null,
    subsurface: ?*wl.Subsurface = null, // anchored children (initSub) only
    /// The window an anchored child sits on (its position latches on that commit).
    sub_parent: ?*Window = null,
    decoration: ?*wl.ZxdgToplevelDecoration = null,
    appmenu: ?*wl.OrgKdeKwinAppmenu = null,
    blur: ?*wl.BackgroundEffectSurface = null,
    viewport: ?*wl.Viewport = null,
    fractional: ?*wl.FractionalScale = null,
    entered_outputs: std.ArrayList(*OutputInfo) = .empty,
    has_fractional_scale: bool = false,
    /// Preferred surface scale in 120ths (fractional-scale, else the largest integer
    /// scale of the outputs the surface is on): 120 = 1.0.
    scale120: u32 = 120,

    /// Window geometry, logical px — what the compositor configures. The buffer adds
    /// `margin` on every side.
    width: u32,
    height: u32,
    /// The buffer is ARGB with per-pixel alpha (always, on Wayland; Win32 has an
    /// opaque mode). Clients that paint their own background read it.
    layered: bool = true,
    margin: u32 = 0,
    blur_shape: ?window.Blur = null,
    min_size: u32 = 0,
    configured: bool = false,
    needs_redraw: bool = false,
    closed: bool = false,
    fullscreen: bool = false,
    maximized: bool = false,
    saved_w: u32 = 0,
    saved_h: u32 = 0,
    /// Usable area suggested by `configure_bounds` (0 = unknown): resizes stay inside.
    bounds_w: u32 = 0,
    bounds_h: u32 = 0,

    // wl_shm double buffer, one pool + mapping shared by both slots, over-allocated so
    // a drag-resize re-slices the buffers instead of re-creating the memfd every frame.
    shm_fd: posix.fd_t = -1,
    shm_map: []align(std.heap.page_size_min) u8 = &.{},
    pool: ?*wl.ShmPool = null,
    pool_cap: usize = 0,
    slots: [2]BufferSlot = .{ .{}, .{} },
    buf_w: u32 = 0,
    buf_h: u32 = 0,
    /// Damage declared for the next redraw (`damage`/`damageAll`), buffer px.
    damage_full: bool = false,
    damage_rect: ?PxRect = null,

    /// Guards the cross-thread mailboxes below.
    mutex: SpinLock = .{},
    staged: Staged = .{},
    front: Staged = .{},
    pending_resize: ?[2]u32 = null,
    pending_clip: ?[]u8 = null,
    staged_dma: ?StagedDma = null,
    pending_hide_video: std.atomic.Value(bool) = .init(false),
    pending_toggle_visible: std.atomic.Value(bool) = .init(false),
    /// Unmapped by `setVisible(false)` (hidden to tray).
    hidden: std.atomic.Value(bool) = .init(false),

    // --- frame pacing (`waitFrame`) -------------------------------------------------------
    /// Counter of the main surface's frame callbacks; `waitFrame` futex-waits on it.
    frame_seq: std.atomic.Value(u32) = .init(0),
    frame_cb: ?*wl.Callback = null,
    /// A frame callback is in flight: the next redraw waits for it (one commit per
    /// refresh, never more).
    frame_cb_pending: bool = false,
    /// Raised at teardown: `waitFrame` returns false instead of waiting forever.
    frame_teardown: std.atomic.Value(bool) = .init(false),

    // --- the dmabuf video plane: a desynced subsurface over `video_area` ------------------
    video_surface: ?*wl.Surface = null,
    video_subsurface: ?*wl.Subsurface = null,
    video_viewport: ?*wl.Viewport = null,
    video_buffers: [8]?*wl.Buffer = @splat(null),
    video_buf_sizes: [8][2]u32 = @splat(.{ 0, 0 }),
    video_pending: std.atomic.Value(bool) = .init(false),
    /// Where the video plane sits (buffer px); null = the window geometry.
    video_area: ?PxRect = null,
    /// Where the last dmabuf frame landed (buffer px), null while no plane is up.
    video_rect: ?PxRect = null,

    active_popups: std.ArrayList(PopupState) = .empty,
    next_popup_id: u32 = 1,

    // --- seat (the root's: the seat is connection-global) -------------------------------
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    touch: ?*wl.Touch = null,
    cursor_device: ?*wl.CursorShapeDevice = null,
    /// The shape the window wants; re-sent on every pointer enter.
    cursor_shape: u32 = wl.CursorShapeDevice.SHAPE_DEFAULT,
    /// The shape last sent to the compositor (skip redundant requests).
    cursor_sent: u32 = std.math.maxInt(u32),
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    /// Latest pointer serial (enter/button): move/resize/popup grabs need it.
    pointer_serial: u32 = 0,
    /// Latest key/button serial: `set_selection` needs it.
    input_serial: u32 = 0,
    pointer_target: ?*Window = null,
    keyboard_target: ?*Window = null,
    touch_target: ?*Window = null,
    touch_id: i32 = -1,

    xkb_context: ?*xkb.Context = null,
    xkb_keymap: ?*xkb.Keymap = null,
    xkb_state: ?*xkb.State = null,

    // Wayland leaves key repeat to the client: the compositor sends one press/release
    // pair plus rate/delay; a timerfd synthesizes the repeats.
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 400,
    repeat_key: u32 = 0,
    repeat_target: ?*Window = null,
    repeat_fd: posix.fd_t = -1,
    /// True while `on_key` is delivering a synthetic repeat (not a real press).
    key_repeating: bool = false,
    /// True while `on_text` delivers the text of the key just sent to `on_key` (false
    /// for an IME commit): a client that swallowed the key can drop its text too.
    text_from_key: bool = false,
    /// Keys down and not yet released: when focus leaves, the releases are delivered
    /// here, or the app would think Ctrl is still held.
    held_keys: std.StaticBitSet(256) = .empty,

    text_input: ?*wl.ZwpTextInputV3 = null,
    text_input_enabled: bool = false,
    /// The field the app enabled the IME for; `enter` re-sends it (an enable is void
    /// without keyboard focus, and `leave` drops it).
    text_input_spec: ?window.TextInputSpec = null,
    text_input_owner: ?*Window = null,
    preedit_buf: [256]u8 = undefined,
    preedit_len: usize = 0,
    preedit_cursor_begin: i32 = -1,
    preedit_cursor_end: i32 = -1,
    pending_commit_buf: [256]u8 = undefined,
    pending_commit_len: usize = 0,

    data_device: ?*wl.DataDevice = null,
    /// Our selection source; non-null = WE own the clipboard.
    data_source: ?*wl.DataSource = null,
    clip_text: []u8 = &.{},
    pending_offer: ?*wl.DataOffer = null,
    pending_mime: TextMime = .none,
    selection_offer: ?*wl.DataOffer = null,
    selection_mime: TextMime = .none,

    pub const OutputInfo = struct {
        name: u32,
        output: *wl.Output,
        scale: i32 = 1,
        root: *Window,
    };

    /// An extra fd for the root loop: `process` runs when it is readable, `flush`
    /// (optional) right before the loop blocks.
    pub const Poller = struct {
        fd: posix.fd_t,
        ctx: ?*anyopaque,
        process: *const fn (ctx: ?*anyopaque) void,
        flush: ?*const fn (ctx: ?*anyopaque) void = null,
    };

    const BufferSlot = struct {
        buffer: ?*wl.Buffer = null,
        pixels: []u32 = &.{},
        busy: bool = false,
        /// Damage accumulated since this slot was last composed: it holds the frame of
        /// two commits ago, so on its turn it repaints everything changed meanwhile.
        pending: SlotDamage = .{},
    };

    const SlotDamage = struct {
        full: bool = true,
        rect: ?PxRect = null,

        fn add(self: *SlotDamage, full: bool, rect: ?PxRect) void {
            if (full) {
                self.full = true;
                self.rect = null;
                return;
            }
            if (self.full) return;
            if (rect) |r| self.rect = if (self.rect) |cur| unionOf(cur, r) else r;
        }
    };

    const Staged = struct {
        pixels: std.ArrayList(u8) = .empty,
        width: u32 = 0,
        height: u32 = 0,
        fresh: bool = false,
    };

    const StagedDma = struct {
        slot: u8,
        width: u32,
        height: u32,
        fourcc: u32,
        plane_count: u8 = 1,
        planes: [4]window.DmabufPlane = undefined,
    };

    /// The staging handoffs are short bounded copies at frame cadence: a spin on an
    /// atomic flag needs no `std.Io`.
    const SpinLock = struct {
        flag: std.atomic.Value(bool) = .init(false),
        fn lock(self: *SpinLock) void {
            while (self.flag.swap(true, .acquire)) std.atomic.spinLoopHint();
        }
        fn unlock(self: *SpinLock) void {
            self.flag.store(false, .release);
        }
    };

    const PopupState = struct {
        id: u32,
        surface: *wl.Surface,
        xdg_surface: *wl.XdgSurface,
        popup: *wl.XdgPopup,
        configured: bool = false,
        x: i32 = 0,
        y: i32 = 0,
        w: u32 = 0,
        h: u32 = 0,

        fn destroy(self: PopupState) void {
            self.popup.destroy();
            wl.wl_proxy_destroy(@ptrCast(self.xdg_surface));
            self.surface.destroy();
        }
    };

    /// Best text flavor a clipboard offer advertises, ascending preference.
    const TextMime = enum(u8) {
        none = 0,
        plain = 1,
        utf8_string = 2,
        utf8 = 3,

        fn mime(self: TextMime) [*:0]const u8 {
            return switch (self) {
                .utf8 => "text/plain;charset=utf-8",
                .utf8_string => "UTF8_STRING",
                .plain => "text/plain",
                .none => unreachable,
            };
        }
    };

    fn unionOf(a: PxRect, b: PxRect) PxRect {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x + a.w, b.x + b.w);
        const y1 = @max(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// The window owning the connection, the globals and the seat.
    fn rt(self: *Window) *Window {
        return self.parent orelse self;
    }

    // =====================================================================================
    // Creation
    // =====================================================================================

    pub fn init(gpa: Allocator, io: std.Io, opts: window.Options) !*Window {
        const display = wl.wl_display_connect(null) orelse return error.NoWaylandDisplay;
        errdefer wl.wl_display_disconnect(display);

        const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(efd) != .SUCCESS) return error.EventFdFailed;
        const wake_fd: posix.fd_t = @intCast(efd);
        errdefer _ = linux.close(wake_fd);

        const rfd = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
        if (linux.errno(rfd) != .SUCCESS) return error.TimerFdFailed;
        const repeat_fd: posix.fd_t = @intCast(rfd);
        errdefer _ = linux.close(repeat_fd);

        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .display = display,
            .registry = wl.displayGetRegistry(display),
            .width = @max(opts.width, opts.min_size),
            .height = @max(opts.height, opts.min_size),
            .margin = opts.margin,
            .blur_shape = opts.blur,
            .min_size = opts.min_size,
            .wake_fd = wake_fd,
            .repeat_fd = repeat_fd,
        };

        self.registry.setListener(&registry_listener, self);
        if (wl.wl_display_roundtrip(display) < 0) return error.WaylandIo;
        if (self.compositor == null or self.shm == null or self.wm_base == null)
            return error.MissingWaylandGlobals;
        self.wm_base.?.setListener(&wm_base_listener, self);

        // Clipboard endpoint: the manager and the seat come in the same registry burst.
        if (self.data_device_manager) |ddm| {
            if (self.seat) |seat| {
                const dev = ddm.getDataDevice(seat);
                dev.setListener(&data_device_listener, self);
                self.data_device = dev;
            }
        }

        try self.createToplevel(null);
        // First commit carries no buffer; the compositor answers with configure.
        self.surface.?.commit();
        if (wl.wl_display_roundtrip(display) < 0) return error.WaylandIo;
        return self;
    }

    /// The xdg toplevel (and its per-surface extras) for a root or a child window.
    fn createToplevel(self: *Window, parent: ?*Window) !void {
        const r = self.rt();
        const surface = r.compositor.?.createSurface();
        surface.setListener(&surface_listener, self);
        self.surface = surface;
        self.attachSurfaceExtras();
        const xdg_surface = r.wm_base.?.getXdgSurface(surface);
        xdg_surface.setListener(&xdg_surface_listener, self);
        self.xdg_surface = xdg_surface;
        const toplevel = xdg_surface.getToplevel();
        toplevel.setListener(&toplevel_listener, self);
        toplevel.setTitle(self.opts.title.ptr);
        if (self.opts.app_id.len > 0) toplevel.setAppId(self.opts.app_id.ptr);
        if (self.min_size > 0) toplevel.setMinSize(@intCast(self.min_size), @intCast(self.min_size));
        if (parent) |p| toplevel.setParent(p.toplevel);
        self.toplevel = toplevel;

        // Server-side frame: negotiate BEFORE the first commit (a decoration created
        // after a buffer is attached is a protocol error). No manager = borderless.
        if (self.opts.decorations) {
            if (r.decoration_manager) |manager| {
                const decoration = manager.getToplevelDecoration(toplevel);
                decoration.setListener(&decoration_listener, self);
                decoration.setMode(wl.DECORATION_MODE_SERVER_SIDE);
                self.decoration = decoration;
            }
        }
    }

    /// Fractional scale, viewport and blur for `self.surface`.
    fn attachSurfaceExtras(self: *Window) void {
        const r = self.rt();
        const surface = self.surface.?;
        if (r.fractional_manager) |mgr| {
            const fs = mgr.getFractionalScale(surface);
            fs.setListener(&fractional_scale_listener, self);
            self.fractional = fs;
        }
        if (self.opts.hidpi) {
            if (r.viewporter) |vpr| self.viewport = vpr.getViewport(surface);
        }
        if (self.blur_shape != null) {
            if (r.blur_manager) |mgr| self.blur = mgr.getBackgroundEffect(surface);
        }
    }

    fn initShared(parent: *Window, opts: window.Options) !*Window {
        const self = try parent.gpa.create(Window);
        self.* = .{
            .gpa = parent.gpa,
            .io = parent.io,
            .opts = opts,
            .display = parent.display,
            .registry = parent.registry,
            .width = @max(opts.width, opts.min_size),
            .height = @max(opts.height, opts.min_size),
            .margin = opts.margin,
            .blur_shape = opts.blur,
            .min_size = opts.min_size,
            .wake_fd = parent.wake_fd,
            .parent = parent,
        };
        return self;
    }

    /// Create a window on the PARENT's connection, driven by the parent's run() loop,
    /// with `xdg_toplevel.set_parent` so the compositor keeps it above and near its
    /// parent (dialogs, panels). Call it on the parent's loop thread (e.g. from
    /// `on_tick`): proxy creation interleaves with the loop's dispatch.
    pub fn initChild(parent: *Window, opts: window.Options) !*Window {
        // Every window hangs off the root: its globals, its loop, its children list.
        const root = parent.rt();
        const self = try initShared(root, opts);
        errdefer root.gpa.destroy(self);
        try self.createToplevel(parent);
        self.surface.?.commit();
        try root.children.append(root.gpa, self);
        // No roundtrip: the running loop dispatches the configure.
        _ = wl.wl_display_flush(self.display);
        return self;
    }

    /// Create an ANCHORED child: a wl_subsurface of the parent at an exact offset
    /// (parent surface coordinates, y-down), moving with its window. No xdg role: the
    /// compositor never resizes or closes it. Same loop-thread contract as initChild;
    /// falls back to initChild when wl_subcompositor is missing.
    pub fn initSub(parent: *Window, opts: window.Options, x: i32, y: i32) !*Window {
        const root = parent.rt();
        const subcompositor = root.subcompositor orelse return initChild(parent, opts);
        const self = try initShared(root, opts);
        errdefer root.gpa.destroy(self);
        // No configure ever arrives for a subsurface: it is drawable at once.
        self.configured = true;
        self.needs_redraw = true;

        const surface = root.compositor.?.createSurface();
        surface.setListener(&surface_listener, self);
        self.surface = surface;
        self.attachSurfaceExtras();
        const sub = subcompositor.getSubsurface(surface, parent.surface.?);
        sub.setPosition(x, y);
        sub.setDesync(); // panels repaint on their own cadence
        self.subsurface = sub;
        self.sub_parent = parent;

        try root.children.append(root.gpa, self);
        // set_position latches on the PARENT's next commit.
        parent.needs_redraw = true;
        _ = wl.wl_display_flush(self.display);
        return self;
    }

    /// Move an anchored child (parent-relative, y-down). Loop thread only.
    pub fn setSubPosition(self: *Window, x: i32, y: i32) void {
        const sub = self.subsurface orelse return;
        sub.setPosition(x, y);
        (self.sub_parent orelse self.rt()).requestRedraw();
        _ = wl.wl_display_flush(self.display);
    }

    // =====================================================================================
    // Teardown
    // =====================================================================================

    /// The per-surface half of the teardown, shared by root and children.
    fn destroySurfaceState(self: *Window) void {
        self.cancelFrameCallback();
        for (self.active_popups.items) |p| p.destroy();
        self.active_popups.deinit(self.gpa);
        for (self.video_buffers) |vb| {
            if (vb) |b| b.destroy();
        }
        if (self.video_viewport) |v| wl.wl_proxy_destroy(@ptrCast(v));
        if (self.video_subsurface) |ss| ss.destroy();
        if (self.video_surface) |vs| vs.destroy();
        if (self.fractional) |fs| fs.destroy();
        if (self.viewport) |v| wl.wl_proxy_destroy(@ptrCast(v));
        if (self.blur) |b| wl.wl_proxy_destroy(@ptrCast(b));
        self.entered_outputs.deinit(self.gpa);
        self.dropBuffers();
        self.staged.pixels.deinit(self.gpa);
        self.front.pixels.deinit(self.gpa);
        if (self.pending_clip) |p| self.gpa.free(p);
        if (self.appmenu) |am| am.release();
        if (self.decoration) |d| wl.wl_proxy_destroy(@ptrCast(d));
        if (self.subsurface) |ss| wl.wl_proxy_destroy(@ptrCast(ss));
        if (self.toplevel) |t| wl.wl_proxy_destroy(@ptrCast(t));
        if (self.xdg_surface) |x| wl.wl_proxy_destroy(@ptrCast(x));
        if (self.surface) |s| s.destroy();
        self.children.deinit(self.gpa);
    }

    /// Tear down a child: destroy its proxies and remove it from the parent. Loop
    /// thread (run() reaps closed children with it).
    fn deinitChild(self: *Window) void {
        const parent = self.parent.?;
        if (parent.pointer_target == self) parent.pointer_target = null;
        if (parent.keyboard_target == self) parent.keyboard_target = null;
        if (parent.touch_target == self) parent.touch_target = null;
        if (parent.text_input_owner == self) parent.text_input_owner = null;
        if (parent.repeat_target == self) parent.cancelRepeat();
        for (parent.children.items, 0..) |child, i| {
            if (child == self) {
                _ = parent.children.orderedRemove(i);
                break;
            }
        }
        // An unmapped subsurface leaves a hole until its parent recomposites.
        if (self.sub_parent) |sp| sp.needs_redraw = true;
        parent.needs_redraw = true;
        for (parent.children.items) |c| {
            if (c.sub_parent == self) c.sub_parent = null;
        }
        self.destroySurfaceState();
        _ = wl.wl_display_flush(self.display);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Root teardown. Threads parked in `waitFrame` must have been joined first.
    pub fn deinit(self: *Window) void {
        self.frame_teardown.store(true, .release);
        self.wakeFrameWaiters();
        // Children die with their root (their proxies live on this connection): notify
        // each — the embedder unregisters its handle — then destroy.
        while (self.children.items.len > 0) {
            const child = self.children.items[self.children.items.len - 1];
            if (child.opts.on_close) |cb| cb(child, child.opts.user);
            child.deinitChild();
        }
        self.destroySurfaceState();
        for (self.outputs.items) |info| {
            info.output.destroy();
            self.gpa.destroy(info);
        }
        self.outputs.deinit(self.gpa);
        if (self.data_source) |s| s.destroy();
        if (self.pending_offer) |o| {
            if (o != self.selection_offer) o.destroy();
        }
        if (self.selection_offer) |o| o.destroy();
        if (self.data_device) |d| d.release();
        if (self.clip_text.len > 0) self.gpa.free(self.clip_text);
        if (self.xkb_state) |st| xkb.xkb_state_unref(st);
        if (self.xkb_keymap) |km| xkb.xkb_keymap_unref(km);
        if (self.xkb_context) |ctx| xkb.xkb_context_unref(ctx);
        if (self.text_input) |ti| ti.destroy();
        if (self.text_input_manager) |tim| tim.destroy();
        if (self.cursor_device) |c| wl.wl_proxy_destroy(@ptrCast(c));
        if (self.keyboard) |k| wl.wl_proxy_destroy(@ptrCast(k));
        if (self.pointer) |p| wl.wl_proxy_destroy(@ptrCast(p));
        if (self.touch) |t| wl.wl_proxy_destroy(@ptrCast(t));
        if (self.fractional_manager) |m| m.destroy();
        if (self.decoration_manager) |m| wl.wl_proxy_destroy(@ptrCast(m));
        if (self.cursor_shapes) |m| wl.wl_proxy_destroy(@ptrCast(m));
        if (self.appmenu_manager) |m| wl.wl_proxy_destroy(@ptrCast(m));
        wl.wl_display_disconnect(self.display);
        _ = linux.close(self.wake_fd);
        if (self.repeat_fd >= 0) _ = linux.close(self.repeat_fd);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    // =====================================================================================
    // Cross-thread doors
    // =====================================================================================

    /// Poke the loop so it applies whatever was just staged. Any thread.
    pub fn wake(self: *Window) void {
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one).ptr, 8);
    }

    /// Repaint this window on the loop's next turn. Any thread.
    pub fn requestRedraw(self: *Window) void {
        @atomicStore(bool, &self.needs_redraw, true, .release);
        self.wake();
    }

    /// Make the loop exit (root) / reap the window (child). Any thread.
    pub fn requestClose(self: *Window) void {
        @atomicStore(bool, &self.closed, true, .release);
        self.wake();
    }

    /// Window-thread `requestClose`.
    pub fn close(self: *Window) void {
        self.closed = true;
    }

    /// Window-thread redraw request: the loop paints at the end of this turn.
    pub fn scheduleRedraw(self: *Window) void {
        self.needs_redraw = true;
    }

    /// `on_tick` at least every `ms` (0 = only when events arrive): the loop's poll
    /// timeout. `on_tick` runs every loop turn regardless. Window thread.
    pub fn setTick(self: *Window, ms: u32) void {
        self.opts.tick_ms = ms;
    }

    /// Stage a straight-alpha RGBA frame for the default composition (centered over
    /// `on_draw`). Any thread; the newest frame wins.
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

    /// Resize the window geometry from any thread: the loop runs `setContentSize`.
    pub fn requestResize(self: *Window, width: u32, height: u32) void {
        self.mutex.lock();
        self.pending_resize = .{ width, height };
        self.mutex.unlock();
        self.wake();
    }

    /// Take the clipboard from any thread: the loop runs `clipboardSet` with a copy.
    pub fn requestClipboardSet(self: *Window, bytes: []const u8) void {
        const copy = self.gpa.dupe(u8, bytes) catch return;
        self.mutex.lock();
        if (self.pending_clip) |old| self.gpa.free(old);
        self.pending_clip = copy;
        self.mutex.unlock();
        self.wake();
    }

    /// Unmap the video plane (the window's own pixels show again). Any thread.
    pub fn hideVideo(self: *Window) void {
        self.pending_hide_video.store(true, .release);
        self.wake();
    }

    /// Toggle hide/show from any thread (tray click, global shortcut).
    pub fn requestToggleVisible(self: *Window) void {
        self.pending_toggle_visible.store(true, .release);
        self.wake();
    }

    // =====================================================================================
    // Geometry, scale, damage
    // =====================================================================================

    /// The preferred scale of the surface (reported even when the buffer is logical).
    pub fn scaleFactor(self: *const Window) f32 {
        return @as(f32, @floatFromInt(self.scale120)) / 120.0;
    }

    /// Kept for callers of the old API: set the scale by hand.
    pub fn setScaleFactor(self: *Window, factor: f32) void {
        if (factor > 0) self.setScale120(@intFromFloat(@round(factor * 120.0)));
    }

    fn setScale120(self: *Window, s: u32) void {
        if (s == 0 or s == self.scale120) return;
        self.scale120 = s;
        // With hidpi the buffer size derives from it: the next redraw resizes.
        self.damageAll();
    }

    /// Buffer px per logical px: the scale with `hidpi` (and a viewport), else 1.
    fn bufScale120(self: *const Window) u32 {
        return if (self.viewport != null) self.scale120 else 120;
    }

    pub fn bufferScale(self: *const Window) f32 {
        return @as(f32, @floatFromInt(self.bufScale120())) / 120.0;
    }

    /// Logical → buffer px, rounded.
    pub fn physPx(self: *const Window, v: u32) u32 {
        const s = self.bufScale120();
        return @intCast((@as(u64, v) * s + 60) / 120);
    }

    /// Buffer → logical px, rounded (subsurface positions, viewport destinations).
    pub fn logiPx(self: *const Window, v: u32) u32 {
        const s = self.bufScale120();
        return @intCast((@as(u64, v) * 120 + s / 2) / s);
    }

    pub fn physPxF(self: *const Window, v: f32) f32 {
        return v * @as(f32, @floatFromInt(self.bufScale120())) / 120.0;
    }

    /// Buffer size: the geometry plus the margin on each side, in buffer px.
    pub fn bufferSize(self: *const Window) [2]u32 {
        return .{ self.physPx(self.width + 2 * self.margin), self.physPx(self.height + 2 * self.margin) };
    }

    /// The window geometry inside the buffer, buffer px. Width/height complement the
    /// buffer exactly (`total − 2·margin`), so independent rounding never drifts.
    pub fn geometryPx(self: *const Window) PxRect {
        const b = self.bufferSize();
        const m = self.physPx(self.margin);
        return .{ .x = m, .y = m, .w = b[0] -| 2 * m, .h = b[1] -| 2 * m };
    }

    /// Change the margin and the blur shape at runtime (fullscreen drops the shadow).
    /// Window thread.
    pub fn setSurfaceShape(self: *Window, margin: u32, blur: ?window.Blur) void {
        self.margin = margin;
        self.blur_shape = blur;
        if (blur != null and self.blur == null) {
            if (self.rt().blur_manager) |mgr| {
                if (self.surface) |s| self.blur = mgr.getBackgroundEffect(s);
            }
        }
        if (self.buf_w != 0) self.applySurfaceMetrics();
        self.damageAll();
    }

    pub fn setMinSize(self: *Window, size: u32) void {
        self.min_size = size;
        if (self.toplevel) |t| t.setMinSize(@intCast(size), @intCast(size));
    }

    /// True once the compositor gave this surface a background blur.
    pub fn hasBlur(self: *const Window) bool {
        return self.blur != null;
    }

    pub fn isTouch(self: *Window) bool {
        return self.rt().touch != null;
    }

    /// Declare a changed rect (buffer px) for the next redraw. Window thread.
    pub fn damage(self: *Window, r: PxRect) void {
        self.damage_rect = if (self.damage_rect) |cur| unionOf(cur, r) else r;
        self.needs_redraw = true;
    }

    /// The next redraw repaints the whole buffer. Window thread.
    pub fn damageAll(self: *Window) void {
        self.damage_full = true;
        self.needs_redraw = true;
    }

    /// Where dmabuf frames go (buffer px); null = the window geometry. Window thread.
    pub fn setVideoArea(self: *Window, area: ?PxRect) void {
        self.video_area = area;
    }

    // =====================================================================================
    // Window management
    // =====================================================================================

    pub fn setTitle(self: *Window, title: [*:0]const u8) void {
        if (self.toplevel) |toplevel| {
            toplevel.setTitle(title);
            if (self.surface) |surface| surface.commit();
        }
    }

    pub fn setAppMenuAddress(self: *Window, service_name: [*:0]const u8, object_path: [*:0]const u8) void {
        const mgr = self.rt().appmenu_manager orelse return;
        if (self.appmenu) |am| {
            am.release();
            self.appmenu = null;
        }
        if (self.surface) |surf| {
            const am = mgr.create(surf);
            am.setAddress(service_name, object_path);
            self.appmenu = am;
        }
        _ = wl.wl_display_flush(self.display);
    }

    /// True when the compositor offers the KDE appmenu protocol.
    pub fn hasAppMenu(self: *Window) bool {
        return self.rt().appmenu_manager != null;
    }

    pub fn toggleFullscreen(self: *Window) void {
        const tl = self.toplevel orelse return;
        if (self.fullscreen) tl.unsetFullscreen() else tl.setFullscreen();
    }

    pub fn toggleMaximized(self: *Window) void {
        const tl = self.toplevel orelse return;
        if (self.maximized) tl.unsetMaximized() else tl.setMaximized();
    }

    pub fn setMinimized(self: *Window) void {
        const tl = self.toplevel orelse return;
        tl.setMinimized();
    }

    pub fn beginMove(self: *Window) void {
        const seat = self.rt().seat orelse return;
        const tl = self.toplevel orelse return;
        tl.move(seat, self.rt().pointer_serial);
    }

    pub fn beginResize(self: *Window, edge: u32) void {
        const seat = self.rt().seat orelse return;
        const tl = self.toplevel orelse return;
        tl.resize(seat, self.rt().pointer_serial, edge);
    }

    /// Set the pointer shape (`wp_cursor_shape_device_v1` id) for this window.
    pub fn setCursorShape(self: *Window, shape: u32) void {
        self.cursor_shape = shape;
        const r = self.rt();
        if (r.pointer_target == self or r.pointer_target == null) r.sendCursor(shape, false);
    }

    fn sendCursor(self: *Window, shape: u32, force: bool) void {
        if (!force and shape == self.cursor_sent) return;
        const device = self.cursor_device orelse return;
        device.setShape(self.pointer_serial, shape);
        self.cursor_sent = shape;
    }

    /// The `xdg_toplevel` resize edge for a pointer at buffer `(x,y)`: an 8 px band
    /// inside the geometry's border, corners combining two edges. NONE elsewhere.
    pub fn resizeEdgeAt(self: *const Window, x: f32, y: f32) u32 {
        const g = self.geometryPx();
        const px = x - @as(f32, @floatFromInt(g.x));
        const py = y - @as(f32, @floatFromInt(g.y));
        const w: f32 = @floatFromInt(g.w);
        const h: f32 = @floatFromInt(g.h);
        if (px < 0 or py < 0 or px >= w or py >= h) return wl.RESIZE_EDGE_NONE;
        const band = self.physPxF(8.0);
        var edge: u32 = 0;
        if (py < band) edge |= wl.RESIZE_EDGE_TOP;
        if (py >= h - band) edge |= wl.RESIZE_EDGE_BOTTOM;
        if (px < band) edge |= wl.RESIZE_EDGE_LEFT;
        if (px >= w - band) edge |= wl.RESIZE_EDGE_RIGHT;
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

    /// Scale `w`×`h` down (aspect kept) into the usable area `configure_bounds`
    /// suggested, minus a small inset. Never enlarges; a no-op while bounds are unknown.
    fn fitBounds(self: *const Window, w: u32, h: u32) [2]u32 {
        if (self.bounds_w == 0 or self.bounds_h == 0) return .{ w, h };
        const inset: u32 = 8;
        const bw: f32 = @floatFromInt(self.bounds_w -| inset);
        const bh: f32 = @floatFromInt(self.bounds_h -| inset);
        const fw: f32 = @floatFromInt(@max(w, 1));
        const fh: f32 = @floatFromInt(@max(h, 1));
        const scale = @min(@as(f32, 1.0), @min(bw / fw, bh / fh));
        if (scale >= 1.0) return .{ w, h };
        return .{
            @max(self.min_size, @as(u32, @intFromFloat(@round(fw * scale)))),
            @max(self.min_size, @as(u32, @intFromFloat(@round(fh * scale)))),
        };
    }

    /// Resize the window geometry to `w`×`h` (logical), kept inside the usable area,
    /// and re-centered: a Wayland client cannot move its toplevel, so the only way to
    /// re-center is to unmap and remap (a brief flash) and let the compositor place it
    /// again. No-op in fullscreen/maximized or at the same size. Window thread.
    pub fn setContentSize(self: *Window, w: u32, h: u32) void {
        if (self.fullscreen or self.maximized) return;
        const fitted = self.fitBounds(w, h);
        const tw = @max(fitted[0], self.min_size);
        const th = @max(fitted[1], self.min_size);
        if (tw == self.width and th == self.height) return;
        self.width = tw;
        self.height = th;
        if (!self.configured or self.toplevel == null) {
            self.damageAll();
            return;
        }
        // xdg remap: attach(null)+commit unmaps; an initial commit without a buffer asks
        // for a new configure, and pixels may only be attached after it.
        const surface = self.surface.?;
        surface.attach(null, 0, 0);
        surface.commit();
        self.configured = false;
        surface.commit();
        self.cancelFrameCallback();
        self.damageAll();
    }

    /// Hide (unmap) or show (remap) the toplevel — "minimize to tray". Window thread;
    /// elsewhere `requestToggleVisible`. While hidden, `configured` stays false (no
    /// redraws) and staged frames wait in their mailbox.
    pub fn setVisible(self: *Window, show: bool) void {
        if (show == !self.hidden.load(.acquire)) return;
        if (show) {
            self.hidden.store(false, .release);
            if (self.surface) |surface| {
                // Unmapping reset the xdg state, geometry included: re-stage it BEFORE
                // the mapping commit, or the remap is sized from the whole buffer and
                // the window grows by 2·margin per hide/show.
                if (self.buf_w != 0) self.applySurfaceMetrics();
                surface.commit();
            }
            self.damageAll();
        } else {
            if (self.surface) |surface| {
                surface.attach(null, 0, 0);
                surface.commit();
            }
            self.configured = false;
            self.cancelFrameCallback();
            self.hidden.store(true, .release);
            // A hidden surface gets no frame callbacks: release the `waitFrame`ers.
            self.wakeFrameWaiters();
        }
    }

    pub fn isVisible(self: *const Window) bool {
        return !self.hidden.load(.acquire);
    }

    /// Register an fd for the root loop (see `Poller`). Window thread.
    pub fn addPoller(self: *Window, p: Poller) !void {
        const r = self.rt();
        if (r.n_pollers == r.pollers.len) return error.TooManyPollers;
        r.pollers[r.n_pollers] = p;
        r.n_pollers += 1;
    }

    pub fn removePoller(self: *Window, fd: posix.fd_t) void {
        const r = self.rt();
        var i: usize = 0;
        while (i < r.n_pollers) {
            if (r.pollers[i].fd == fd) {
                r.pollers[i] = r.pollers[r.n_pollers - 1];
                r.n_pollers -= 1;
            } else i += 1;
        }
    }

    // =====================================================================================
    // Frame pacing
    // =====================================================================================

    /// Block ANY thread until the compositor's next frame callback (the moment to
    /// compose the next frame) or `timeout_ms`. True if woken by the callback; false on
    /// timeout, while hidden, or at teardown (the caller falls back to its own pacer).
    /// No commit since the last callback → no callback: the timeout is the safety net.
    /// Waiters must be gone before `deinit`.
    pub fn waitFrame(self: *Window, timeout_ms: u32) bool {
        if (self.frame_teardown.load(.acquire)) return false;
        const start = self.frame_seq.load(.acquire);
        const deadline = monotonicNs() + @as(i64, timeout_ms) * 1_000_000;
        while (true) {
            const now = monotonicNs();
            if (now >= deadline) return false;
            const left: u64 = @intCast(deadline - now);
            const ts: linux.timespec = .{
                .sec = @intCast(left / 1_000_000_000),
                .nsec = @intCast(left % 1_000_000_000),
            };
            // Sleeps only while `frame_seq` still equals `start`: a callback between the
            // load and the wait fails it with EAGAIN — no lost wake-up.
            const rc = linux.futex_4arg(&self.frame_seq.raw, .{ .cmd = .WAIT, .private = true }, start, &ts);
            switch (linux.errno(rc)) {
                .SUCCESS, .AGAIN, .INTR => {},
                else => return false, // TIMEDOUT or unexpected
            }
            if (self.frame_teardown.load(.acquire)) return false;
            if (self.frame_seq.load(.acquire) != start) return true;
        }
    }

    fn wakeFrameWaiters(self: *Window) void {
        _ = linux.futex_3arg(&self.frame_seq.raw, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
    }

    fn cancelFrameCallback(self: *Window) void {
        if (self.frame_cb) |fcb| {
            fcb.destroy();
            self.frame_cb = null;
        }
        self.frame_cb_pending = false;
    }

    const frame_done_listener = wl.Callback.Listener{ .done = onFrameDone };

    fn onFrameDone(data: ?*anyopaque, callback: *wl.Callback, _: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        callback.destroy();
        self.frame_cb = null;
        self.frame_cb_pending = false;
        _ = self.frame_seq.fetchAdd(1, .release);
        self.wakeFrameWaiters();
    }

    fn monotonicNs() i64 {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1_000_000_000 + ts.nsec;
    }

    // =====================================================================================
    // The dmabuf video plane
    // =====================================================================================

    /// Single-plane `presentDmabufPlanes`.
    pub fn presentDmabuf(self: *Window, slot: u8, fd: posix.fd_t, width: u32, height: u32, stride: u32, fourcc: u32, modifier: u64) bool {
        return self.presentDmabufPlanes(slot, &.{.{ .fd = fd, .offset = 0, .stride = stride, .modifier = modifier }}, width, height, fourcc);
    }

    /// Present a GPU frame (1..4 planes) with zero CPU pixel work, on a desynced
    /// subsurface over the video area. `slot` (0..7) names a persistent image; its
    /// wl_buffer is created once and reused. False when the compositor lacks
    /// linux-dmabuf or subcompositor — fall back to CPU pixels. Any thread.
    pub fn presentDmabufPlanes(self: *Window, slot: u8, planes: []const window.DmabufPlane, width: u32, height: u32, fourcc: u32) bool {
        const r = self.rt();
        if (r.dmabuf == null or r.subcompositor == null or planes.len == 0 or planes.len > 4) return false;
        std.debug.assert(slot < self.video_buffers.len);
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.staged_dma = .{
                .slot = slot,
                .width = width,
                .height = height,
                .fourcc = fourcc,
                .plane_count = @intCast(planes.len),
            };
            @memcpy(self.staged_dma.?.planes[0..planes.len], planes);
        }
        self.wake();
        return true;
    }

    /// True while the compositor owes a frame-done for the last video commit: render
    /// the next frame when it turns false, to run at the refresh rate.
    pub fn videoBusy(self: *const Window) bool {
        return self.video_pending.load(.acquire);
    }

    /// Window-thread half of `presentDmabufPlanes`. True when a frame was committed.
    fn processVideo(self: *Window) bool {
        if (!self.configured) return false;
        self.mutex.lock();
        const req_opt = self.staged_dma;
        self.staged_dma = null;
        self.mutex.unlock();
        const req = req_opt orelse return false;
        const r = self.rt();

        if (self.video_surface == null) {
            const vs = r.compositor.?.createSurface();
            // Input passes through to the window underneath.
            const empty = r.compositor.?.createRegion();
            vs.setInputRegion(empty);
            empty.destroy();
            const ss = r.subcompositor.?.getSubsurface(vs, self.surface.?);
            ss.setDesync();
            self.video_surface = vs;
            self.video_subsurface = ss;
            if (r.viewporter) |vpr| self.video_viewport = vpr.getViewport(vs);
            // Mapping and position are parent state: one parent commit seals them.
            self.damageAll();
        }
        // The frame FILLS the area: its pixel size is a quality knob (resolution tier,
        // dynamic-res) and wp_viewport scales it on the scanout path for free. Without a
        // viewport, or with `video_native`, it sits centered at its own size.
        const area = self.video_area orelse self.geometryPx();
        var vw = area.w;
        var vh = area.h;
        var dx = area.x;
        var dy = area.y;
        if (self.video_viewport == null or self.opts.video_native) {
            vw = @min(req.width, area.w);
            vh = @min(req.height, area.h);
            dx = area.x + (area.w - vw) / 2;
            dy = area.y + (area.h - vh) / 2;
        }
        self.video_rect = .{ .x = dx, .y = dy, .w = vw, .h = vh };
        self.video_subsurface.?.setPosition(@intCast(self.logiPx(dx)), @intCast(self.logiPx(dy)));
        if (self.video_viewport) |vp| {
            vp.setDestination(@intCast(@max(self.logiPx(vw), 1)), @intCast(@max(self.logiPx(vh), 1)));
        }

        // A slot presented at a new size gets a fresh wl_buffer.
        if (self.video_buffers[req.slot]) |b| {
            const sz = self.video_buf_sizes[req.slot];
            if (sz[0] != req.width or sz[1] != req.height) {
                b.destroy();
                self.video_buffers[req.slot] = null;
            }
        }
        if (self.video_buffers[req.slot] == null) {
            self.video_buf_sizes[req.slot] = .{ req.width, req.height };
            const params = r.dmabuf.?.createParams();
            var pi: u32 = 0;
            while (pi < req.plane_count) : (pi += 1) {
                const pl = req.planes[pi];
                params.add(pl.fd, pi, pl.offset, pl.stride, pl.modifier);
            }
            self.video_buffers[req.slot] = params.createImmed(@intCast(req.width), @intCast(req.height), req.fourcc, 0);
            params.destroy();
        }
        const vs = self.video_surface.?;
        vs.attach(self.video_buffers[req.slot], 0, 0);
        vs.damageBuffer(0, 0, @intCast(req.width), @intCast(req.height));
        self.video_pending.store(true, .release);
        const cb = vs.frame();
        cb.setListener(&video_frame_listener, self);
        vs.commit();
        return true;
    }

    const video_frame_listener = wl.Callback.Listener{ .done = onVideoFrameDone };

    fn onVideoFrameDone(data: ?*anyopaque, callback: *wl.Callback, _: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        callback.destroy();
        self.video_pending.store(false, .release);
    }

    // =====================================================================================
    // Popups and IME
    // =====================================================================================

    /// Create an `xdg_popup` (menus, tooltips, dropdowns, IME candidates). Window thread.
    pub fn createPopup(self: *Window, spec: window.PopupSpec) !u32 {
        const r = self.rt();
        const wm_base = r.wm_base orelse return error.NoXdgWmBase;
        const compositor = r.compositor orelse return error.NoCompositor;
        const parent_xdg = self.xdg_surface orelse return error.NoXdgSurface;

        const surface = compositor.createSurface();
        errdefer surface.destroy();
        const positioner = wm_base.createPositioner();
        defer positioner.destroy();
        positioner.setAnchorRect(spec.x, spec.y, 1, 1);
        positioner.setSize(@intCast(@max(1, spec.w)), @intCast(@max(1, spec.h)));
        if (spec.anchor != .none) positioner.setAnchor(@backingInt(spec.anchor));
        if (spec.gravity != .none) positioner.setGravity(@backingInt(spec.gravity));
        positioner.setConstraintAdjustment(15); // slide x/y, flip x/y

        const xdg_surf = wm_base.getXdgSurface(surface);
        errdefer wl.wl_proxy_destroy(@ptrCast(xdg_surf));
        xdg_surf.setListener(&popup_xdg_surface_listener, self);
        const popup = xdg_surf.getPopup(parent_xdg, positioner);
        errdefer popup.destroy();
        popup.setListener(&popup_listener, self);
        surface.commit();

        const id = if (spec.id != 0) spec.id else blk: {
            const auto_id = self.next_popup_id;
            self.next_popup_id += 1;
            break :blk auto_id;
        };
        try self.active_popups.append(self.gpa, .{
            .id = id,
            .surface = surface,
            .xdg_surface = xdg_surf,
            .popup = popup,
            .x = spec.x,
            .y = spec.y,
            .w = spec.w,
            .h = spec.h,
        });
        if (spec.grab) {
            if (r.seat) |seat| popup.grab(seat, r.pointer_serial);
        }
        return id;
    }

    /// Dismiss a popup by id (0 = all).
    pub fn dismissPopup(self: *Window, id: u32) void {
        var i = self.active_popups.items.len;
        while (i > 0) {
            i -= 1;
            const p = self.active_popups.items[i];
            if (p.id == id or id == 0) {
                p.destroy();
                _ = self.active_popups.orderedRemove(i);
                if (id != 0) return;
            }
        }
    }

    const popup_listener = wl.XdgPopup.Listener{ .configure = onPopupConfigure, .popup_done = onPopupDone };

    fn onPopupConfigure(data: ?*anyopaque, popup: *wl.XdgPopup, x: i32, y: i32, width: i32, height: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        for (self.active_popups.items) |*p| {
            if (p.popup == popup) {
                p.configured = true;
                p.x = x;
                p.y = y;
                p.w = @intCast(@max(width, 0));
                p.h = @intCast(@max(height, 0));
                break;
            }
        }
    }

    fn onPopupDone(data: ?*anyopaque, popup: *wl.XdgPopup) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        for (self.active_popups.items, 0..) |p, i| {
            if (p.popup == popup) {
                p.destroy();
                _ = self.active_popups.orderedRemove(i);
                break;
            }
        }
    }

    const popup_xdg_surface_listener = wl.XdgSurface.Listener{ .configure = onPopupXdgConfigure };

    fn onPopupXdgConfigure(_: ?*anyopaque, xdg_surface: *wl.XdgSurface, serial: u32) callconv(.c) void {
        xdg_surface.ackConfigure(serial);
    }

    /// Turn the IME on for a text field of this window (cursor rect in surface coords).
    pub fn enableTextInput(self: *Window, spec: window.TextInputSpec) void {
        const r = self.rt();
        r.text_input_spec = spec;
        r.text_input_owner = self;
        r.sendTextInputEnable(spec);
    }

    pub fn disableTextInput(self: *Window) void {
        const r = self.rt();
        r.text_input_spec = null;
        r.text_input_owner = null;
        const ti = r.text_input orelse return;
        if (r.text_input_enabled) {
            ti.disable();
            ti.commit();
            r.text_input_enabled = false;
        }
    }

    fn setupTextInput(self: *Window) void {
        const tim = self.text_input_manager orelse return;
        const seat = self.seat orelse return;
        if (self.text_input != null) return;
        const ti = tim.getTextInput(seat);
        ti.setListener(&text_input_listener, self);
        self.text_input = ti;
    }

    fn sendTextInputEnable(self: *Window, spec: window.TextInputSpec) void {
        const ti = self.text_input orelse return;
        ti.enable();
        ti.setCursorRectangle(spec.x, spec.y, @intCast(spec.w), @intCast(spec.h));
        const hint = textInputHint(spec.hint);
        const purpose: u32 = @backingInt(spec.purpose);
        if (hint != 0 or purpose != 0) ti.setContentType(hint, purpose);
        ti.commit();
        self.text_input_enabled = true;
    }

    fn textInputHint(hint: window.TextInputSpec.Hint) u32 {
        var val: u32 = 0;
        if (hint.completion) val |= 1;
        if (hint.spellcheck) val |= 2;
        if (hint.auto_capitalization) val |= 4;
        if (hint.lowercase) val |= 8;
        if (hint.uppercase) val |= 16;
        if (hint.titlecase) val |= 32;
        if (hint.hidden_text) val |= 64;
        if (hint.sensitive_data) val |= 128;
        if (hint.latin) val |= 256;
        if (hint.multiline) val |= 512;
        return val;
    }

    /// Who gets IME text: the field's window, else the focused one.
    fn imeTarget(self: *Window) *Window {
        return self.text_input_owner orelse self.keyboard_target orelse self;
    }

    const text_input_listener = wl.ZwpTextInputV3.Listener{
        .enter = onTextInputEnter,
        .leave = onTextInputLeave,
        .preedit_string = onTextInputPreeditString,
        .commit_string = onTextInputCommitString,
        .delete_surrounding_text = onTextInputDeleteSurrounding,
        .done = onTextInputDone,
    };

    /// Focus is back: the field being edited when it left gets its IME back.
    fn onTextInputEnter(data: ?*anyopaque, _: *wl.ZwpTextInputV3, _: *wl.Surface) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.text_input_spec) |spec| self.sendTextInputEnable(spec);
    }

    fn onTextInputLeave(data: ?*anyopaque, _: *wl.ZwpTextInputV3, _: *wl.Surface) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // The compositor disabled it with the focus; `enter` re-enables from the spec.
        self.text_input_enabled = false;
        self.pending_commit_len = 0;
        self.preedit_len = 0;
        self.preedit_cursor_begin = -1;
        self.preedit_cursor_end = -1;
        const t = self.imeTarget();
        if (t.opts.on_preedit) |cb| cb(t, "", -1, -1, t.opts.user);
    }

    fn onTextInputPreeditString(data: ?*anyopaque, _: *wl.ZwpTextInputV3, txt: ?[*:0]const u8, cursor_begin: i32, cursor_end: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (txt) |t| {
            const span = std.mem.span(t);
            const len = utf8Prefix(span, self.preedit_buf.len);
            @memcpy(self.preedit_buf[0..len], span[0..len]);
            self.preedit_len = len;
        } else {
            self.preedit_len = 0;
        }
        self.preedit_cursor_begin = cursor_begin;
        self.preedit_cursor_end = cursor_end;
    }

    fn onTextInputCommitString(data: ?*anyopaque, _: *wl.ZwpTextInputV3, txt: ?[*:0]const u8) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (txt) |t| {
            const span = std.mem.span(t);
            const len = utf8Prefix(span, self.pending_commit_buf.len);
            @memcpy(self.pending_commit_buf[0..len], span[0..len]);
            self.pending_commit_len = len;
        } else {
            self.pending_commit_len = 0;
        }
    }

    fn onTextInputDeleteSurrounding(_: ?*anyopaque, _: *wl.ZwpTextInputV3, _: u32, _: u32) callconv(.c) void {}

    fn onTextInputDone(data: ?*anyopaque, _: *wl.ZwpTextInputV3, _: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        const t = self.imeTarget();
        if (self.pending_commit_len > 0) {
            const bytes = self.pending_commit_buf[0..self.pending_commit_len];
            if (t.opts.on_text) |cb| {
                var i: usize = 0;
                while (i < bytes.len) {
                    const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
                    if (i + n > bytes.len) break;
                    var b: [4]u8 = .{ 0, 0, 0, 0 };
                    @memcpy(b[0..n], bytes[i .. i + n]);
                    cb(t, b, @intCast(n), t.opts.user);
                    i += n;
                }
            }
            self.pending_commit_len = 0;
        }
        if (t.opts.on_preedit) |cb| cb(t, self.preedit_buf[0..self.preedit_len], self.preedit_cursor_begin, self.preedit_cursor_end, t.opts.user);
        // Applied: the preedit is pending state — a batch without one means "none".
        self.preedit_len = 0;
        self.preedit_cursor_begin = -1;
        self.preedit_cursor_end = -1;
        t.damageAll();
    }

    /// The longest prefix of `s` within `cap` bytes that does not split a UTF-8 sequence.
    fn utf8Prefix(s: []const u8, cap: usize) usize {
        if (s.len <= cap) return s.len;
        var n = cap;
        while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
        return n;
    }

    // =====================================================================================
    // Clipboard (the connection's `wl_data_device` selection)
    // =====================================================================================

    /// Take the system selection (ctrl+C): offers a window-owned copy of `bytes` as
    /// UTF-8 text. Needs a recent input serial: call it in response to input. Window
    /// thread.
    pub fn clipboardSet(self: *Window, bytes: []const u8) void {
        const r = self.rt();
        const mgr = r.data_device_manager orelse return;
        const dev = r.data_device orelse return;
        const copy = r.gpa.dupe(u8, bytes) catch return;
        if (r.clip_text.len > 0) r.gpa.free(r.clip_text);
        r.clip_text = copy;
        if (r.data_source) |old| {
            old.destroy();
            r.data_source = null;
        }
        const src = mgr.createDataSource();
        src.setListener(&data_source_listener, r);
        src.offer("text/plain;charset=utf-8");
        src.offer("text/plain");
        dev.setSelection(src, r.input_serial);
        r.data_source = src;
        _ = wl.wl_display_flush(r.display);
    }

    /// Our own selection text while WE own the clipboard, else null. Window-owned slice.
    pub fn clipboardOwn(self: *Window) ?[]const u8 {
        const r = self.rt();
        if (r.data_source == null) return null;
        return if (r.clip_text.len > 0) r.clip_text else null;
    }

    /// Read the system selection as UTF-8 (ctrl+V); null when empty, not text, owned
    /// by us (use `clipboardOwn`) or on I/O failure. Caller frees with `gpa`. Window
    /// thread: a nested roundtrip, then the pipe under a ~250 ms budget, 1 MiB cap.
    pub fn clipboardGet(self: *Window, gpa: Allocator) ?[]u8 {
        const r = self.rt();
        if (r.data_source != null) return null;
        const offer = r.selection_offer orelse return null;
        if (r.selection_mime == .none) return null;
        var pipe_fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true })) != .SUCCESS) return null;
        offer.receive(r.selection_mime.mime(), pipe_fds[1]);
        // Our write end closes now: the source's close after writing becomes our EOF.
        _ = linux.close(pipe_fds[1]);
        _ = wl.wl_display_flush(r.display);
        _ = wl.wl_display_roundtrip(r.display);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        const deadline = monotonicNs() + 250 * 1_000_000;
        var buf: [4096]u8 = undefined;
        while (out.items.len < 1024 * 1024) {
            const left_ns = deadline - monotonicNs();
            if (left_ns <= 0) break;
            var pfd = [_]posix.pollfd{.{ .fd = pipe_fds[0], .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&pfd, @intCast(@divTrunc(left_ns, 1_000_000) + 1)) catch break;
            if (ready == 0) break;
            const n = posix.read(pipe_fds[0], &buf) catch break;
            if (n == 0) break;
            out.appendSlice(gpa, buf[0..n]) catch {
                _ = linux.close(pipe_fds[0]);
                return null;
            };
        }
        _ = linux.close(pipe_fds[0]);
        if (out.items.len == 0) return null;
        return out.toOwnedSlice(gpa) catch null;
    }

    const data_device_listener = wl.DataDevice.Listener{
        .data_offer = onDataOffer,
        .enter = onDndEnter,
        .leave = onDndLeave,
        .motion = onDndMotion,
        .drop = onDndDrop,
        .selection = onSelection,
    };

    fn onDataOffer(data: ?*anyopaque, _: *wl.DataDevice, offer: *wl.DataOffer) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // An earlier offer that never became the selection (an ignored DnD) is dead.
        if (self.pending_offer) |old| {
            if (old != self.selection_offer) old.destroy();
        }
        self.pending_offer = offer;
        self.pending_mime = .none;
        offer.setListener(&data_offer_listener, self);
    }

    // DnD is out of scope: drags are never accepted.
    fn onDndEnter(_: ?*anyopaque, _: *wl.DataDevice, _: u32, _: ?*wl.Surface, _: wl.Fixed, _: wl.Fixed, _: ?*wl.DataOffer) callconv(.c) void {}
    fn onDndLeave(_: ?*anyopaque, _: *wl.DataDevice) callconv(.c) void {}
    fn onDndMotion(_: ?*anyopaque, _: *wl.DataDevice, _: u32, _: wl.Fixed, _: wl.Fixed) callconv(.c) void {}
    fn onDndDrop(_: ?*anyopaque, _: *wl.DataDevice) callconv(.c) void {}

    fn onSelection(data: ?*anyopaque, _: *wl.DataDevice, offer: ?*wl.DataOffer) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.selection_offer) |old| {
            if (old != offer) old.destroy();
        }
        self.selection_offer = offer;
        self.selection_mime = .none;
        if (offer != null and offer == self.pending_offer) {
            self.selection_mime = self.pending_mime;
            self.pending_offer = null;
            self.pending_mime = .none;
        }
    }

    const data_offer_listener = wl.DataOffer.Listener{
        .offer = onOfferMime,
        .source_actions = onOfferSourceActions,
        .action = onOfferAction,
    };

    fn onOfferMime(data: ?*anyopaque, offer: *wl.DataOffer, mime: [*:0]const u8) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (offer != self.pending_offer) return;
        const m = std.mem.span(mime);
        const rank: TextMime = if (std.mem.eql(u8, m, "text/plain;charset=utf-8"))
            .utf8
        else if (std.mem.eql(u8, m, "UTF8_STRING"))
            .utf8_string
        else if (std.mem.eql(u8, m, "text/plain"))
            .plain
        else
            .none;
        if (@backingInt(rank) > @backingInt(self.pending_mime)) self.pending_mime = rank;
    }

    fn onOfferSourceActions(_: ?*anyopaque, _: *wl.DataOffer, _: u32) callconv(.c) void {}
    fn onOfferAction(_: ?*anyopaque, _: *wl.DataOffer, _: u32) callconv(.c) void {}

    const data_source_listener = wl.DataSource.Listener{
        .target = onSourceTarget,
        .send = onSourceSend,
        .cancelled = onSourceCancelled,
        .dnd_drop_performed = onSourceDndDrop,
        .dnd_finished = onSourceDndFinished,
        .action = onSourceAction,
    };

    /// A client wants our selection: write it into the pipe (short writes looped), a
    /// stalled reader abandoned after ~1 s so it cannot wedge the window thread.
    fn onSourceSend(data: ?*anyopaque, _: *wl.DataSource, _: [*:0]const u8, fd: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        defer _ = linux.close(fd);
        const deadline = monotonicNs() + 1_000_000_000;
        var off: usize = 0;
        while (off < self.clip_text.len) {
            const rc = linux.write(fd, self.clip_text.ptr + off, self.clip_text.len - off);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => {
                    if (monotonicNs() >= deadline) return;
                    var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                    const ready = posix.poll(&pfd, 100) catch return;
                    if (ready == 0 and monotonicNs() >= deadline) return;
                    continue;
                },
                else => return,
            }
            if (rc == 0) return;
            off += rc;
        }
    }

    fn onSourceCancelled(data: ?*anyopaque, source: *wl.DataSource) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        source.destroy();
        if (self.data_source == source) self.data_source = null;
    }

    fn onSourceTarget(_: ?*anyopaque, _: *wl.DataSource, _: ?[*:0]const u8) callconv(.c) void {}
    fn onSourceDndDrop(_: ?*anyopaque, _: *wl.DataSource) callconv(.c) void {}
    fn onSourceDndFinished(_: ?*anyopaque, _: *wl.DataSource) callconv(.c) void {}
    fn onSourceAction(_: ?*anyopaque, _: *wl.DataSource, _: u32) callconv(.c) void {}

    // =====================================================================================
    // The loop
    // =====================================================================================

    /// Pump events for this window and its children until it is closed or the
    /// connection drops. Root only.
    pub fn run(self: *Window) !void {
        self.running = true;
        // No frame callback arrives after the loop: release the `waitFrame`ers.
        defer {
            self.frame_teardown.store(true, .release);
            self.wakeFrameWaiters();
            for (self.children.items) |c| {
                c.frame_teardown.store(true, .release);
                c.wakeFrameWaiters();
            }
        }
        while (!@atomicLoad(bool, &self.closed, .acquire)) {
            while (wl.wl_display_prepare_read(self.display) != 0) {
                if (wl.wl_display_dispatch_pending(self.display) < 0) return error.WaylandIo;
            }
            _ = wl.wl_display_flush(self.display);
            for (self.pollers[0..self.n_pollers]) |p| {
                if (p.flush) |f| f(p.ctx);
            }

            const fixed = 3;
            var fds: [fixed + 8]posix.pollfd = undefined;
            fds[0] = .{ .fd = wl.wl_display_get_fd(self.display), .events = posix.POLL.IN, .revents = 0 };
            fds[1] = .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 };
            fds[2] = .{ .fd = self.repeat_fd, .events = posix.POLL.IN, .revents = 0 };
            const n_poll = self.n_pollers;
            var polled: [8]Poller = undefined;
            for (self.pollers[0..n_poll], 0..) |p, i| {
                polled[i] = p;
                fds[fixed + i] = .{ .fd = p.fd, .events = posix.POLL.IN, .revents = 0 };
            }
            const timeout: i32 = if (self.opts.tick_ms > 0) @intCast(self.opts.tick_ms) else -1;
            _ = posix.poll(fds[0 .. fixed + n_poll], timeout) catch |err| {
                wl.wl_display_cancel_read(self.display);
                return err;
            };

            if (fds[0].revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP) != 0) {
                if (wl.wl_display_read_events(self.display) < 0) return error.WaylandIo;
            } else {
                wl.wl_display_cancel_read(self.display);
            }
            if (wl.wl_display_dispatch_pending(self.display) < 0) return error.WaylandIo;
            if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) return error.WaylandIo;

            if (fds[1].revents & posix.POLL.IN != 0) {
                var drained: u64 = 0;
                _ = posix.read(self.wake_fd, std.mem.asBytes(&drained)) catch {};
                self.serviceWake();
                for (self.children.items) |child| child.serviceWake();
            }
            if (fds[2].revents & posix.POLL.IN != 0) self.onRepeatTick();
            for (polled[0..n_poll], 0..) |p, i| {
                if (fds[fixed + i].revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP) != 0) p.process(p.ctx);
            }

            // Outside the read critical section: the tick may redraw, create children…
            if (self.opts.on_tick) |tick| tick(self, self.opts.user);

            // Reap children closed by the compositor or the embedder. `on_close` sees a
            // still-valid window; it dies right after.
            var i: usize = 0;
            while (i < self.children.items.len) {
                const child = self.children.items[i];
                if (@atomicLoad(bool, &child.closed, .acquire)) {
                    if (child.opts.on_close) |cb| cb(child, child.opts.user);
                    child.deinitChild();
                } else i += 1;
            }

            if (self.configured and @atomicLoad(bool, &self.needs_redraw, .acquire)) try self.redraw();
            for (self.children.items) |child| {
                if (child.configured and @atomicLoad(bool, &child.needs_redraw, .acquire)) child.redraw() catch {};
            }
        }
    }

    /// Apply what other threads staged for this window, on the loop thread.
    fn serviceWake(self: *Window) void {
        const video = self.processVideo();
        if (self.opts.on_compose == null) {
            self.mutex.lock();
            const fresh = self.staged.fresh;
            self.mutex.unlock();
            if (fresh) self.damageAll();
        }

        self.mutex.lock();
        const rr = self.pending_resize;
        self.pending_resize = null;
        const pclip = self.pending_clip;
        self.pending_clip = null;
        self.mutex.unlock();
        if (rr) |wh| self.setContentSize(wh[0], wh[1]);
        if (pclip) |clip| {
            self.clipboardSet(clip);
            self.gpa.free(clip);
        }
        if (self.pending_toggle_visible.swap(false, .acquire)) self.setVisible(self.hidden.load(.acquire));
        if (self.pending_hide_video.swap(false, .acquire)) {
            if (self.video_surface) |vs| {
                vs.attach(null, 0, 0);
                vs.commit();
                self.video_rect = null;
                self.damageAll();
            }
        }
        if (self.opts.on_wake) |cb| cb(self, video, self.opts.user);
    }

    /// Compose into a free buffer and commit it. At most one commit per refresh: while
    /// a frame callback is in flight the redraw stays pending.
    fn redraw(self: *Window) !void {
        if (self.frame_cb_pending) return;
        const size = self.bufferSize();
        const bw = size[0];
        const bh = size[1];
        if (bw == 0 or bh == 0) return;
        if (bw != self.buf_w or bh != self.buf_h) {
            try self.resizeBuffers(bw, bh);
            self.damage_full = true;
        }
        const slot = self.freeSlot() orelse return; // both busy: the release wakes us

        if (self.opts.on_compose != null) {
            if (self.opts.on_before_compose) |cb| cb(self, self.opts.user);
        } else {
            self.damage_full = true; // the default composition repaints everything
        }
        const full = self.damage_full or self.damage_rect == null;
        for (&self.slots) |*s| s.pending.add(full, self.damage_rect);
        self.damage_full = false;
        self.damage_rect = null;
        const region: ?PxRect = if (slot.pending.full) null else slot.pending.rect;
        slot.pending = .{ .full = false, .rect = null };
        // Cleared BEFORE composing: a redraw requested while composing (an animating
        // widget's `on_draw`) is for the next frame and must survive this one.
        @atomicStore(bool, &self.needs_redraw, false, .release);

        // The default composition clears and repaints everything: all of it is damage.
        var surface_damage: ?PxRect = null;
        if (self.opts.on_compose) |compose| {
            compose(self, slot.pixels, bw, bh, region, self.opts.user);
            surface_damage = region;
        } else {
            self.composeDefault(slot.pixels, bw, bh);
        }

        const surface = self.surface.?;
        surface.attach(slot.buffer, 0, 0);
        if (surface_damage) |r| {
            const x1 = @min(bw, r.x +| r.w);
            const y1 = @min(bh, r.y +| r.h);
            surface.damageBuffer(@intCast(r.x), @intCast(r.y), @intCast(x1 -| r.x), @intCast(y1 -| r.y));
        } else {
            surface.damageBuffer(0, 0, @intCast(bw), @intCast(bh));
        }
        // The frame request is double-buffered state: before the commit.
        const fcb = surface.frame();
        fcb.setListener(&frame_done_listener, self);
        self.frame_cb = fcb;
        self.frame_cb_pending = true;
        surface.commit();
        slot.busy = true;
    }

    /// Clear, `on_draw` over the geometry, then the staged RGBA frame centered on top.
    fn composeDefault(self: *Window, pixels: []u32, bw: u32, bh: u32) void {
        @memset(pixels, 0x00000000);
        var canvas = paint.Canvas.init(pixels, bw, bh);
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

    fn freeSlot(self: *Window) ?*BufferSlot {
        for (&self.slots) |*slot| {
            if (!slot.busy and slot.buffer != null) return slot;
        }
        return null;
    }

    fn dropBuffers(self: *Window) void {
        for (&self.slots) |*slot| {
            if (slot.buffer) |b| b.destroy();
            slot.* = .{};
        }
        if (self.pool) |p| p.destroy();
        self.pool = null;
        if (self.shm_map.len > 0) posix.munmap(self.shm_map);
        self.shm_map = &.{};
        if (self.shm_fd >= 0) _ = linux.close(self.shm_fd);
        self.shm_fd = -1;
        self.pool_cap = 0;
        self.buf_w = 0;
        self.buf_h = 0;
    }

    fn resizeBuffers(self: *Window, bw: u32, bh: u32) !void {
        const stride = @as(usize, bw) * 4;
        const slot_size = stride * @as(usize, bh);
        const total = slot_size * self.slots.len;

        if (self.pool == null or total > self.pool_cap) {
            // Grow with 50% headroom, so a continuing drag stops re-allocating.
            self.dropBuffers();
            const cap = total + total / 2;
            const fd = try posix.memfd_create("zicro-shm", linux.MFD.CLOEXEC);
            errdefer _ = linux.close(fd);
            if (linux.errno(linux.ftruncate(fd, @intCast(cap))) != .SUCCESS) return error.ShmSetupFailed;
            const map = try posix.mmap(null, cap, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
            self.shm_fd = fd;
            self.shm_map = map;
            self.pool = self.rt().shm.?.createPool(fd, @intCast(cap));
            self.pool_cap = cap;
        } else {
            for (&self.slots) |*slot| {
                if (slot.buffer) |b| b.destroy();
                slot.buffer = null;
            }
        }
        for (&self.slots, 0..) |*slot, i| {
            const off = i * slot_size;
            slot.buffer = self.pool.?.createBuffer(@intCast(off), @intCast(bw), @intCast(bh), @intCast(stride), wl.SHM_FORMAT_ARGB8888);
            slot.buffer.?.setListener(&buffer_listener, slot);
            slot.pixels = @as([*]u32, @ptrCast(@alignCast(self.shm_map.ptr + off)))[0 .. @as(usize, bw) * bh];
            slot.busy = false;
            slot.pending = .{};
        }
        self.buf_w = bw;
        self.buf_h = bh;
        self.applySurfaceMetrics();
    }

    /// Window geometry, input region and blur region describe the GEOMETRY, not the
    /// buffer: the margin is invisible to window management and lets clicks through.
    fn applySurfaceMetrics(self: *Window) void {
        const r = self.rt();
        const m: i32 = @intCast(self.margin);
        const w: i32 = @intCast(self.width);
        const h: i32 = @intCast(self.height);
        if (self.xdg_surface) |xs| xs.setWindowGeometry(m, m, w, h);

        const input = r.compositor.?.createRegion();
        defer input.destroy();
        input.add(m, m, w, h);
        self.surface.?.setInputRegion(input);

        if (self.blur) |blur| {
            const region = r.compositor.?.createRegion();
            defer region.destroy();
            if (self.blur_shape) |shape| {
                const bi = shape.inset;
                if (bi > 0.0 and bi < @as(f32, @floatFromInt(self.width)) / 2.0 and bi < @as(f32, @floatFromInt(self.height)) / 2.0) {
                    const bi_u: u32 = @intFromFloat(bi);
                    addRoundedRegion(region, self.margin + bi_u, self.width - 2 * bi_u, self.height - 2 * bi_u, @max(0.0, shape.radius - bi));
                } else {
                    addRoundedRegion(region, self.margin, self.width, self.height, shape.radius);
                }
            }
            blur.setBlurRegion(region);
        }

        // HiDPI: present the physically-sized buffer at the logical size.
        if (self.viewport) |vp| vp.setDestination(w + 2 * m, h + 2 * m);
    }

    // =====================================================================================
    // Registry, outputs, scale, xdg
    // =====================================================================================

    const registry_listener = wl.Registry.Listener{ .global = onGlobal, .global_remove = onGlobalRemove };

    fn onGlobal(data: ?*anyopaque, registry: *wl.Registry, name: u32, interface: [*:0]const u8, ver: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        const iface = std.mem.span(interface);
        if (std.mem.eql(u8, iface, "wl_compositor")) {
            self.compositor = @ptrCast(registry.bind(name, &wl.wl_compositor_interface, @min(ver, 4)).?);
        } else if (std.mem.eql(u8, iface, "wl_subcompositor")) {
            self.subcompositor = @ptrCast(registry.bind(name, &wl.wl_subcompositor_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(registry.bind(name, &wl.wl_shm_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "zwp_linux_dmabuf_v1")) {
            // v2 has create_immed; nothing past v4 is used.
            if (ver >= 2) self.dmabuf = @ptrCast(registry.bind(name, &wl.zwp_linux_dmabuf_v1_interface, @min(ver, 4)).?);
        } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
            self.wm_base = @ptrCast(registry.bind(name, &wl.xdg_wm_base_interface, @min(ver, 6)).?);
        } else if (std.mem.eql(u8, iface, "zxdg_decoration_manager_v1")) {
            self.decoration_manager = @ptrCast(registry.bind(name, &wl.zxdg_decoration_manager_v1_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wp_cursor_shape_manager_v1")) {
            self.cursor_shapes = @ptrCast(registry.bind(name, &wl.wp_cursor_shape_manager_v1_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            const seat: *wl.Seat = @ptrCast(registry.bind(name, &wl.wl_seat_interface, @min(ver, 5)).?);
            seat.setListener(&seat_listener, self);
            self.seat = seat;
            self.setupTextInput();
        } else if (std.mem.eql(u8, iface, "zwp_text_input_manager_v3")) {
            self.text_input_manager = @ptrCast(registry.bind(name, &wl.zwp_text_input_manager_v3_interface, 1).?);
            self.setupTextInput();
        } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
            self.data_device_manager = @ptrCast(registry.bind(name, &wl.wl_data_device_manager_interface, @min(ver, 3)).?);
        } else if (std.mem.eql(u8, iface, "ext_background_effect_manager_v1")) {
            self.blur_manager = @ptrCast(registry.bind(name, &wl.ext_background_effect_manager_v1_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wp_viewporter")) {
            self.viewporter = @ptrCast(registry.bind(name, &wl.wp_viewporter_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wp_fractional_scale_manager_v1")) {
            self.fractional_manager = @ptrCast(registry.bind(name, &wl.wp_fractional_scale_manager_v1_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "org_kde_kwin_appmenu_manager")) {
            self.appmenu_manager = @ptrCast(registry.bind(name, &wl.org_kde_kwin_appmenu_manager_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wl_output")) {
            const output: *wl.Output = @ptrCast(registry.bind(name, &wl.wl_output_interface, @min(ver, 4)).?);
            const info = self.gpa.create(OutputInfo) catch return;
            info.* = .{ .name = name, .output = output, .root = self };
            output.setListener(&output_listener, info);
            self.outputs.append(self.gpa, info) catch {};
        }
    }

    fn onGlobalRemove(data: ?*anyopaque, _: *wl.Registry, name: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        for (self.outputs.items, 0..) |info, idx| {
            if (info.name == name) {
                _ = self.outputs.orderedRemove(idx);
                removeOutputFromWindow(self, info);
                for (self.children.items) |child| removeOutputFromWindow(child, info);
                info.output.destroy();
                self.gpa.destroy(info);
                break;
            }
        }
    }

    fn removeOutputFromWindow(win: *Window, info: *OutputInfo) void {
        for (win.entered_outputs.items, 0..) |entered, i| {
            if (entered == info) {
                _ = win.entered_outputs.orderedRemove(i);
                win.updateLegacyScale();
                break;
            }
        }
    }

    const surface_listener = wl.Surface.Listener{ .enter = onSurfaceEnter, .leave = onSurfaceLeave };

    fn onSurfaceEnter(data: ?*anyopaque, _: *wl.Surface, output: *wl.Output) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        for (self.rt().outputs.items) |info| {
            if (info.output == output) {
                for (self.entered_outputs.items) |existing| {
                    if (existing == info) return;
                }
                self.entered_outputs.append(self.gpa, info) catch {};
                self.updateLegacyScale();
                break;
            }
        }
    }

    fn onSurfaceLeave(data: ?*anyopaque, _: *wl.Surface, output: *wl.Output) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        for (self.entered_outputs.items, 0..) |info, i| {
            if (info.output == output) {
                _ = self.entered_outputs.orderedRemove(i);
                self.updateLegacyScale();
                break;
            }
        }
    }

    /// Without fractional-scale: the largest integer scale of the outputs we are on.
    fn updateLegacyScale(self: *Window) void {
        if (self.has_fractional_scale) return;
        var max_scale: i32 = 1;
        for (self.entered_outputs.items) |info| max_scale = @max(max_scale, info.scale);
        self.setScale120(@intCast(max_scale * 120));
    }

    const output_listener = wl.Output.Listener{
        .geometry = onOutputGeometry,
        .mode = onOutputMode,
        .done = onOutputDone,
        .scale = onOutputScale,
        .name = onOutputName,
        .description = onOutputDescription,
    };

    fn onOutputGeometry(_: ?*anyopaque, _: *wl.Output, _: i32, _: i32, _: i32, _: i32, _: i32, _: ?[*:0]const u8, _: ?[*:0]const u8, _: i32) callconv(.c) void {}
    fn onOutputMode(_: ?*anyopaque, _: *wl.Output, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}
    fn onOutputDone(_: ?*anyopaque, _: *wl.Output) callconv(.c) void {}
    fn onOutputName(_: ?*anyopaque, _: *wl.Output, _: ?[*:0]const u8) callconv(.c) void {}
    fn onOutputDescription(_: ?*anyopaque, _: *wl.Output, _: ?[*:0]const u8) callconv(.c) void {}

    fn onOutputScale(data: ?*anyopaque, _: *wl.Output, factor: i32) callconv(.c) void {
        const info: *OutputInfo = @ptrCast(@alignCast(data.?));
        info.scale = factor;
        info.root.updateLegacyScale();
        for (info.root.children.items) |child| child.updateLegacyScale();
    }

    const fractional_scale_listener = wl.FractionalScale.Listener{ .preferred_scale = onPreferredScale };

    fn onPreferredScale(data: ?*anyopaque, _: *wl.FractionalScale, scale: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.has_fractional_scale = true;
        self.setScale120(scale);
    }

    const wm_base_listener = wl.XdgWmBase.Listener{ .ping = onPing };

    fn onPing(_: ?*anyopaque, wm_base: *wl.XdgWmBase, serial: u32) callconv(.c) void {
        wm_base.pong(serial);
    }

    const decoration_listener = wl.ZxdgToplevelDecoration.Listener{ .configure = onDecorationConfigure };

    /// The compositor may override the requested mode: whatever it picks is fine.
    fn onDecorationConfigure(_: ?*anyopaque, _: *wl.ZxdgToplevelDecoration, _: u32) callconv(.c) void {}

    const xdg_surface_listener = wl.XdgSurface.Listener{ .configure = onXdgConfigure };

    fn onXdgConfigure(data: ?*anyopaque, xdg_surface: *wl.XdgSurface, serial: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        xdg_surface.ackConfigure(serial);
        self.configured = true;
        self.damageAll();
        // A compositing client (`on_compose`) is painted right away during init's
        // roundtrip, so the window maps before `run`; everyone else (and every configure
        // once the loop pumps) is only flagged, so a burst of resizes paints once — and
        // `on_draw` never runs before `init` has returned the window to the app.
        if (!self.rt().running and self.opts.on_compose != null) self.redraw() catch {};
    }

    const toplevel_listener = wl.XdgToplevel.Listener{
        .configure = onToplevelConfigure,
        .close = onToplevelClose,
        .configure_bounds = onConfigureBounds,
        .wm_capabilities = onWmCapabilities,
    };

    fn onToplevelConfigure(data: ?*anyopaque, _: *wl.XdgToplevel, w: i32, h: i32, states_raw: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        var is_fs = false;
        var is_max = false;
        if (states_raw) |sr| {
            const states: *const wl.Array = @ptrCast(@alignCast(sr));
            if (states.data) |raw| {
                const p: [*]const u32 = @ptrCast(@alignCast(raw));
                for (p[0 .. states.size / 4]) |state| {
                    if (state == wl.STATE_FULLSCREEN) is_fs = true;
                    if (state == wl.STATE_MAXIMIZED) is_max = true;
                }
            }
        }
        if (is_fs != self.fullscreen) {
            self.fullscreen = is_fs;
            if (is_fs) {
                self.saved_w = self.width;
                self.saved_h = self.height;
            } else {
                // No suggested size on the way out: back to the pre-fullscreen one.
                if (w <= 0 and self.saved_w > 0) self.width = self.saved_w;
                if (h <= 0 and self.saved_h > 0) self.height = self.saved_h;
            }
        }
        self.maximized = is_max;
        // The suggested size is the window geometry; 0 means "you pick".
        if (w > 0) self.width = @max(@as(u32, @intCast(w)), self.min_size);
        if (h > 0) self.height = @max(@as(u32, @intCast(h)), self.min_size);
        if (self.opts.on_configure) |cb| cb(self, self.opts.user);
        self.damageAll();
    }

    fn onToplevelClose(data: ?*anyopaque, _: *wl.XdgToplevel) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // The app may veto (unsaved changes) and close() itself later.
        if (self.opts.on_close_request) |cb| {
            if (!cb(self, self.opts.user)) {
                self.damageAll();
                return;
            }
        }
        self.closed = true;
    }

    fn onConfigureBounds(data: ?*anyopaque, _: *wl.XdgToplevel, w: i32, h: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (w > 0) self.bounds_w = @intCast(w);
        if (h > 0) self.bounds_h = @intCast(h);
        // A window larger than the usable area is brought back inside it.
        const fitted = self.fitBounds(self.width, self.height);
        if (fitted[0] != self.width or fitted[1] != self.height) {
            if (self.rt().running) {
                self.setContentSize(fitted[0], fitted[1]);
            } else {
                self.width = fitted[0];
                self.height = fitted[1];
            }
        }
    }

    fn onWmCapabilities(_: ?*anyopaque, _: *wl.XdgToplevel, _: ?*anyopaque) callconv(.c) void {}

    const buffer_listener = wl.Buffer.Listener{ .release = onBufferRelease };

    fn onBufferRelease(data: ?*anyopaque, _: *wl.Buffer) callconv(.c) void {
        const slot: *BufferSlot = @ptrCast(@alignCast(data.?));
        slot.busy = false;
    }

    // =====================================================================================
    // Seat: keyboard, pointer, touch (listeners on the root, routed per surface)
    // =====================================================================================

    const seat_listener = wl.Seat.Listener{ .capabilities = onSeatCaps, .name = onSeatName };

    fn onSeatCaps(data: ?*anyopaque, seat: *wl.Seat, caps: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (caps & wl.SEAT_CAPABILITY_POINTER != 0 and self.pointer == null) {
            const pointer = seat.getPointer();
            pointer.setListener(&pointer_listener, self);
            self.pointer = pointer;
            if (self.cursor_shapes) |shapes| self.cursor_device = shapes.getPointer(pointer);
        }
        if (caps & wl.SEAT_CAPABILITY_KEYBOARD != 0 and self.keyboard == null) {
            const keyboard = seat.getKeyboard();
            keyboard.setListener(&keyboard_listener, self);
            self.keyboard = keyboard;
        }
        if (caps & wl.SEAT_CAPABILITY_TOUCH != 0 and self.touch == null) {
            const touch = seat.getTouch();
            touch.setListener(&touch_listener, self);
            self.touch = touch;
        }
    }

    fn onSeatName(_: ?*anyopaque, _: *wl.Seat, _: [*:0]const u8) callconv(.c) void {}

    /// The window a seat event's surface belongs to (root or child).
    fn targetFor(self: *Window, surface: ?*wl.Surface) *Window {
        if (surface) |s| {
            if (self.surface == s) return self;
            for (self.children.items) |child| {
                if (child.surface == s) return child;
            }
        }
        return self;
    }

    const keyboard_listener = wl.Keyboard.Listener{
        .keymap = onKeymap,
        .enter = onKeyEnter,
        .leave = onKeyLeave,
        .key = onKey,
        .modifiers = onKeyModifiers,
        .repeat_info = onKeyRepeatInfo,
    };

    fn onKeymap(data: ?*anyopaque, _: *wl.Keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        defer _ = linux.close(fd);
        // Keys flow to `on_key` as evdev codes regardless; the keymap feeds `on_text`
        // and the repeat table. Any failure leaves `xkb_state` null.
        if (format != wl.KEYBOARD_KEYMAP_FORMAT_XKB_V1 or size == 0) return;
        const map = posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch return;
        defer posix.munmap(map);
        if (self.xkb_context == null) self.xkb_context = xkb.xkb_context_new(xkb.CONTEXT_NO_FLAGS);
        const ctx = self.xkb_context orelse return;
        const keymap = xkb.xkb_keymap_new_from_string(ctx, @ptrCast(map.ptr), xkb.KEYMAP_FORMAT_TEXT_V1, xkb.KEYMAP_COMPILE_NO_FLAGS) orelse return;
        const state = xkb.xkb_state_new(keymap) orelse {
            xkb.xkb_keymap_unref(keymap);
            return;
        };
        if (self.xkb_state) |st| xkb.xkb_state_unref(st);
        if (self.xkb_keymap) |km| xkb.xkb_keymap_unref(km);
        self.xkb_keymap = keymap;
        self.xkb_state = state;
    }

    fn onKeyEnter(data: ?*anyopaque, _: *wl.Keyboard, _: u32, surface: ?*wl.Surface, _: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.keyboard_target = self.targetFor(surface);
    }

    fn onKeyLeave(data: ?*anyopaque, _: *wl.Keyboard, _: u32, _: ?*wl.Surface) callconv(.c) void {
        // Focus gone: held keys will never see their release — stop repeating and
        // deliver the releases ourselves, so no modifier stays stuck in the app.
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.cancelRepeat();
        const t = self.keyboard_target orelse self;
        var it = self.held_keys.iterator(.{});
        while (it.next()) |k| {
            if (t.opts.on_key) |cb| cb(t, @intCast(k), 0, t.opts.user);
        }
        self.held_keys = .empty;
    }

    fn onKey(data: ?*anyopaque, _: *wl.Keyboard, serial: u32, _: u32, key: u32, state: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.input_serial = serial;
        const t = self.keyboard_target orelse self;
        const pressed = state == wl.KEYBOARD_KEY_STATE_PRESSED;
        if (key < 256) self.held_keys.setValue(key, pressed);
        if (!pressed and key == self.repeat_key) self.cancelRepeat();
        if (t.opts.on_key) |cb| cb(t, key, state, t.opts.user);
        t.inputRedraw();
        if (pressed) {
            self.armRepeat(key, t);
            self.emitText(t, key);
        }
    }

    /// Modifiers hold state rather than produce input: never repeated (the fallback
    /// when no keymap says so: ctrl, shift, alt, meta, capslock).
    fn isModifierKey(key: u32) bool {
        return switch (key) {
            29, 42, 54, 56, 58, 97, 100, 125, 126 => true,
            else => false,
        };
    }

    /// Start (or retarget: a newer key steals it) the repeat of `key`.
    fn armRepeat(self: *Window, key: u32, target: *Window) void {
        if (self.repeat_rate <= 0) return;
        if (self.xkb_keymap) |km| {
            if (xkb.xkb_keymap_key_repeats(km, key + 8) == 0) return;
        } else if (isModifierKey(key)) return;
        self.repeat_key = key;
        self.repeat_target = target;
        const delay_ns: isize = @as(isize, self.repeat_delay) * 1_000_000;
        const period_ns: isize = @divTrunc(1_000_000_000, @as(isize, self.repeat_rate));
        const spec = linux.itimerspec{
            .it_value = .{ .sec = @divTrunc(delay_ns, 1_000_000_000), .nsec = @rem(delay_ns, 1_000_000_000) },
            .it_interval = .{ .sec = @divTrunc(period_ns, 1_000_000_000), .nsec = @rem(period_ns, 1_000_000_000) },
        };
        _ = linux.timerfd_settime(self.repeat_fd, .{}, &spec, null);
    }

    fn cancelRepeat(self: *Window) void {
        if (self.repeat_key == 0) return;
        self.repeat_key = 0;
        self.repeat_target = null;
        const spec = std.mem.zeroes(linux.itimerspec);
        _ = linux.timerfd_settime(self.repeat_fd, .{}, &spec, null);
    }

    /// Re-deliver the held key as presses (`key_repeating` set meanwhile). A stalled
    /// loop's backlog is honored but capped so it cannot flood the app.
    fn onRepeatTick(self: *Window) void {
        var expirations: u64 = 0;
        _ = posix.read(self.repeat_fd, std.mem.asBytes(&expirations)) catch return;
        if (self.repeat_key == 0) return;
        const t = self.repeat_target orelse self;
        self.key_repeating = true;
        defer self.key_repeating = false;
        var i: u64 = 0;
        while (i < @min(expirations, 8)) : (i += 1) {
            if (self.repeat_key == 0) break; // a callback released it
            if (t.opts.on_key) |cb| cb(t, self.repeat_key, wl.KEYBOARD_KEY_STATE_PRESSED, t.opts.user);
            t.inputRedraw();
            self.emitText(t, self.repeat_key);
        }
    }

    /// Layout-correct text for a pressed key: 1..4 UTF-8 bytes via xkbcommon
    /// (keycode = evdev + 8), control characters and DEL skipped.
    fn emitText(self: *Window, t: *Window, key: u32) void {
        const cb = t.opts.on_text orelse return;
        const st = self.xkb_state orelse return;
        var buf: [8]u8 = undefined;
        const n = xkb.xkb_state_key_get_utf8(st, key + 8, &buf, buf.len);
        if (n < 1 or n > 4) return;
        const len: u8 = @intCast(n);
        if (len == 1 and (buf[0] < 0x20 or buf[0] == 0x7f)) return;
        var bytes: [4]u8 = .{ 0, 0, 0, 0 };
        @memcpy(bytes[0..len], buf[0..len]);
        self.text_from_key = true;
        defer self.text_from_key = false;
        cb(t, bytes, len, t.opts.user);
    }

    fn onKeyModifiers(data: ?*anyopaque, _: *wl.Keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.xkb_state) |st| _ = xkb.xkb_state_update_mask(st, depressed, latched, locked, 0, 0, group);
    }

    fn onKeyRepeatInfo(data: ?*anyopaque, _: *wl.Keyboard, rate: i32, delay: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.repeat_rate = rate;
        self.repeat_delay = delay;
        if (rate <= 0) self.cancelRepeat();
    }

    const pointer_listener = wl.Pointer.Listener{
        .enter = onPointerEnter,
        .leave = onPointerLeave,
        .motion = onPointerMotion,
        .button = onPointerButton,
        .axis = onPointerAxis,
        .frame = onPointerFrame,
        .axis_source = onPointerAxisSource,
        .axis_stop = onPointerAxisStop,
        .axis_discrete = onPointerAxisDiscrete,
        .axis_value120 = onPointerAxisValue120,
        .axis_relative_direction = onPointerAxisRelativeDirection,
    };

    /// Does this window take resize-band input itself?
    fn bandActive(t: *const Window) bool {
        return t.opts.resize_band and !t.opts.decorations and t.toplevel != null and !t.fullscreen and !t.maximized;
    }

    fn onPointerEnter(data: ?*anyopaque, _: *wl.Pointer, serial: u32, surface: ?*wl.Surface, sx: wl.Fixed, sy: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.pointer_serial = serial;
        const t = self.targetFor(surface);
        self.pointer_target = t;
        const s = t.bufferScale();
        self.pointer_x = wl.fixedToF32(sx) * s;
        self.pointer_y = wl.fixedToF32(sy) * s;
        // A new serial: the shape must be re-sent even if unchanged.
        self.sendCursor(t.cursor_shape, true);
        // The app learns where the pointer is now, not at its first move: hover and
        // the wheel work on a window that appeared (or that the pointer entered) still.
        if (t.opts.on_mouse) |cb| cb(t, .{ .kind = .motion, .x = self.pointer_x, .y = self.pointer_y }, t.opts.user);
    }

    fn onPointerLeave(data: ?*anyopaque, _: *wl.Pointer, _: u32, _: ?*wl.Surface) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        const t = self.pointer_target orelse return;
        if (t.opts.on_mouse) |cb| cb(t, .{ .kind = .leave }, t.opts.user);
    }

    fn onPointerMotion(data: ?*anyopaque, _: *wl.Pointer, _: u32, sx: wl.Fixed, sy: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        const t = self.pointer_target orelse self;
        const s = t.bufferScale();
        self.pointer_x = wl.fixedToF32(sx) * s;
        self.pointer_y = wl.fixedToF32(sy) * s;
        if (bandActive(t)) {
            const edge = t.resizeEdgeAt(self.pointer_x, self.pointer_y);
            self.sendCursor(if (edge != wl.RESIZE_EDGE_NONE) edgeCursor(edge) else t.cursor_shape, false);
        }
        if (t.opts.on_mouse) |cb| cb(t, .{ .kind = .motion, .x = self.pointer_x, .y = self.pointer_y }, t.opts.user);
    }

    fn onPointerButton(data: ?*anyopaque, _: *wl.Pointer, serial: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.pointer_serial = serial;
        self.input_serial = serial;
        const t = self.pointer_target orelse self;
        const pressed = state == wl.POINTER_BUTTON_STATE_PRESSED;
        if (button == wl.BTN_LEFT and pressed and bandActive(t)) {
            const edge = t.resizeEdgeAt(self.pointer_x, self.pointer_y);
            if (edge != wl.RESIZE_EDGE_NONE) {
                if (self.seat) |seat| t.toplevel.?.resize(seat, serial, edge);
                return;
            }
        }
        if (t.opts.on_mouse) |cb| cb(t, .{ .kind = if (pressed) .press else .release, .x = self.pointer_x, .y = self.pointer_y, .button = button }, t.opts.user);
        t.inputRedraw();
    }

    fn onPointerAxis(data: ?*anyopaque, _: *wl.Pointer, _: u32, axis: u32, value: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        const t = self.pointer_target orelse self;
        const v = wl.fixedToF32(value);
        if (t.opts.on_mouse) |cb| cb(t, .{
            .kind = .scroll,
            .x = self.pointer_x,
            .y = self.pointer_y,
            .scroll_dy = if (axis == 0) v else 0,
            .scroll_dx = if (axis == 1) v else 0,
        }, t.opts.user);
        t.inputRedraw();
    }

    fn onPointerFrame(_: ?*anyopaque, _: *wl.Pointer) callconv(.c) void {}
    fn onPointerAxisSource(_: ?*anyopaque, _: *wl.Pointer, _: u32) callconv(.c) void {}
    fn onPointerAxisStop(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: u32) callconv(.c) void {}
    fn onPointerAxisDiscrete(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: i32) callconv(.c) void {}
    fn onPointerAxisValue120(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: i32) callconv(.c) void {}
    fn onPointerAxisRelativeDirection(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: u32) callconv(.c) void {}

    // Touch: the primary finger is a pointer (down → press, motion, up → release), so
    // every app works with touch unchanged.
    const touch_listener = wl.Touch.Listener{
        .down = onTouchDown,
        .up = onTouchUp,
        .motion = onTouchMotion,
        .frame = onTouchFrame,
        .cancel = onTouchCancel,
        .shape = onTouchShape,
        .orientation = onTouchOrientation,
    };

    fn touchMouse(self: *Window, kind: window.MouseEvent.Kind) void {
        const t = self.touch_target orelse self;
        if (t.opts.on_mouse) |cb| cb(t, .{ .kind = kind, .x = self.pointer_x, .y = self.pointer_y, .button = if (kind == .motion) 0 else wl.BTN_LEFT }, t.opts.user);
        if (kind != .motion) t.inputRedraw();
    }

    /// An `on_draw` client is immediate-mode: a key, a click or a scroll may have changed
    /// what it draws, so the frame is redrawn after it (as on every backend). A client
    /// with `on_compose` owns its damage and asks itself.
    fn inputRedraw(self: *Window) void {
        if (self.opts.on_compose == null) self.needs_redraw = true;
    }

    fn onTouchDown(data: ?*anyopaque, _: *wl.Touch, serial: u32, _: u32, surface: ?*wl.Surface, id: i32, x: wl.Fixed, y: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.touch_id != -1) return; // one primary finger at a time
        self.touch_id = id;
        self.input_serial = serial;
        self.pointer_serial = serial;
        const t = self.targetFor(surface);
        self.touch_target = t;
        const s = t.bufferScale();
        self.pointer_x = wl.fixedToF32(x) * s;
        self.pointer_y = wl.fixedToF32(y) * s;
        self.touchMouse(.motion);
        self.touchMouse(.press);
    }

    fn onTouchMotion(data: ?*anyopaque, _: *wl.Touch, _: u32, id: i32, x: wl.Fixed, y: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (id != self.touch_id) return;
        const s = (self.touch_target orelse self).bufferScale();
        self.pointer_x = wl.fixedToF32(x) * s;
        self.pointer_y = wl.fixedToF32(y) * s;
        self.touchMouse(.motion);
    }

    fn onTouchUp(data: ?*anyopaque, _: *wl.Touch, _: u32, _: u32, id: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (id != self.touch_id) return;
        self.touchMouse(.release);
        self.touch_id = -1;
    }

    fn onTouchCancel(data: ?*anyopaque, _: *wl.Touch) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.touch_id == -1) return;
        self.touchMouse(.release);
        self.touch_id = -1;
    }

    fn onTouchFrame(_: ?*anyopaque, _: *wl.Touch) callconv(.c) void {}
    fn onTouchShape(_: ?*anyopaque, _: *wl.Touch, _: i32, _: wl.Fixed, _: wl.Fixed) callconv(.c) void {}
    fn onTouchOrientation(_: ?*anyopaque, _: *wl.Touch, _: i32, _: wl.Fixed) callconv(.c) void {}

    /// The blur region as the rounded geometry: one span per row through the corner
    /// arcs, one rect for the body (wl_region only speaks rectangles).
    fn addRoundedRegion(region: *wl.Region, margin: u32, pw: u32, ph: u32, radius: f32) void {
        const m: i32 = @intCast(margin);
        const w: i32 = @intCast(pw);
        const h: i32 = @intCast(ph);
        const r: i32 = @intFromFloat(@ceil(radius));
        const rows: i32 = @min(r, @divTrunc(h, 2));
        var y: i32 = 0;
        while (y < rows) : (y += 1) {
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const dy = radius - fy;
            const dx = radius - @sqrt(@max(0.0, radius * radius - dy * dy));
            const inset: i32 = @intFromFloat(@ceil(dx));
            const span = w - 2 * inset;
            if (span <= 0) continue;
            region.add(m + inset, m + y, span, 1);
            region.add(m + inset, m + h - 1 - y, span, 1);
        }
        if (h > 2 * rows) region.add(m, m + rows, w, h - 2 * rows);
    }

    test "an IME string over the buffer is cut on a character boundary" {
        const s = "aé€"; // 1 + 2 + 3 bytes
        try std.testing.expectEqual(@as(usize, 6), utf8Prefix(s, 16));
        try std.testing.expectEqual(@as(usize, 3), utf8Prefix(s, 5)); // not inside '€'
        try std.testing.expectEqual(@as(usize, 1), utf8Prefix(s, 2)); // not inside 'é'
        try std.testing.expectEqual(@as(usize, 0), utf8Prefix("€", 2));
    }

    test "damage accumulates per slot: full wins, rects union" {
        var d: SlotDamage = .{ .full = false };
        d.add(false, .{ .x = 10, .y = 10, .w = 5, .h = 5 });
        d.add(false, .{ .x = 0, .y = 20, .w = 4, .h = 4 });
        try std.testing.expectEqual(PxRect{ .x = 0, .y = 10, .w = 15, .h = 14 }, d.rect.?);
        d.add(true, null);
        try std.testing.expect(d.full and d.rect == null);
    }
};
