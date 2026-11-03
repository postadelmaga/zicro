//! # zrame.window — the frameless glass window
//!
//! One Wayland toplevel, no server decorations: the chrome (rounded glass panel, drop
//! shadow) is painted client-side by [`paint`], the frosted look comes from the
//! compositor via `ext-background-effect-v1` (real background blur, KWin 6.4+), and the
//! shadow gutter is punched out of the input region so clicks fall through it.
//!
//! Threading contract: everything Wayland happens on the thread that calls [`run`].
//! [`presentRgba`] is the one cross-thread door — it stages pixels under a mutex and
//! pokes an eventfd, and the run loop picks them up. That is exactly the shape zicro's
//! `video.FrameSink` needs (see `sink.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const linux = std.os.linux;

const zicro = @import("zicro");
const wl = zicro.wl;
const xkb = @import("xkb.zig");
const paint = zicro.paint;
const text = zicro.text;
const anim = zicro.anim;
const plugin = @import("plugin.zig");
const controls = @import("controls.zig");
const menu = @import("menu.zig");
const scroll = @import("scroll.zig");
const tray_mod = @import("tray.zig");
const dbusmenu = @import("dbusmenu.zig");
// The org_kde_kwin_appmenu wrappers live in zicro.wl (zicro generates and links every
// Wayland protocol table, including this one, so the interface symbol exists once).
const appmenu_global = "org_kde_kwin_appmenu_manager";
const appmenu_interface = &wl.org_kde_kwin_appmenu_manager_interface;

// Public window types (Options, MouseEvent, TrayConfig, Rect, Style, …) live in the
// facade `window.zig` so both backends share them and `*Window` in a callback resolves
// to the selected backend. This file (the Linux/Wayland backend) imports them so its
// existing code keeps referring to them by their short names.
const facade = @import("window.zig");
pub const Style = facade.Style;
pub const Panel = facade.Panel;
pub const Host = facade.Host;
pub const TitlebarStyle = facade.TitlebarStyle;
pub const Options = facade.Options;
pub const TrayConfig = facade.TrayConfig;
pub const MouseEvent = facade.MouseEvent;
pub const Rect = facade.Rect;

// The cross-thread frame mailbox and its composition are shared with the Win32 backend.
const chrome = @import("chrome.zig");
const Staged = chrome.Staged;

pub const DmabufPlane = facade.DmabufPlane;

/// One pending dmabuf present (see `Window.presentDmabuf` / `Window.presentDmabufPlanes`).
const StagedDma = struct {
    slot: u8,
    width: u32,
    height: u32,
    fourcc: u32,
    plane_count: u8 = 1,
    planes: [4]DmabufPlane = undefined,
};

/// Tracked state of an active secondary popup surface (`xdg_popup`).
pub const PopupState = struct {
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

/// Zig 0.16 keeps blocking mutexes behind `std.Io`; the staging handoff is a short,
/// bounded copy at frame cadence, so a spin on the lock-free `std.atomic.Mutex` is
/// simpler than threading an `Io` through the window.
const SpinLock = chrome.SpinLock;

/// Best text flavor a clipboard offer advertises, in ascending preference (utf8 wins).
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

const BufferSlot = struct {
    buffer: ?*wl.Buffer = null,
    pixels: []u32 = &.{},
    busy: bool = false,
    /// Damage accumulated since this slot was last composed
    /// (the back buffer holds the pixels from two commits ago): on its turn it recomposes
    /// the union of everything that changed in the meantime. Starts `full` so the
    /// first compose covers the whole buffer.
    pending: SlotDamage = .{},
};

/// Dirty region accumulated for a slot: `full` covers everything, otherwise the
/// bounding box of the union of the received rects (in buffer pixels).
const SlotDamage = struct {
    full: bool = true,
    rect: ?Rect = null,

    fn add(self: *SlotDamage, full: bool, rect: ?Rect) void {
        if (full) {
            self.full = true;
            self.rect = null;
            return;
        }
        if (self.full) return;
        if (rect) |r| self.rect = if (self.rect) |cur| plugin.unionOf(cur, r) else r;
    }
};

pub const Window = struct {
    gpa: Allocator,
    opts: Options,

    display: *wl.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    subcompositor: ?*wl.Subcompositor = null,
    dmabuf: ?*wl.LinuxDmabuf = null,
    wm_base: ?*wl.XdgWmBase = null,
    seat: ?*wl.Seat = null,
    blur_manager: ?*wl.BackgroundEffectManager = null,
    cursor_shapes: ?*wl.CursorShapeManager = null,
    viewporter: ?*wl.Viewporter = null,
    fractional_manager: ?*wl.FractionalScaleManager = null,
    text_input_manager: ?*wl.ZwpTextInputManagerV3 = null,
    text_input: ?*wl.ZwpTextInputV3 = null,
    data_device_manager: ?*wl.DataDeviceManager = null,
    text_input_enabled: bool = false,
    /// IME preedit staged by `preedit_string` events; `on_preedit` fires from
    /// this same buffer once `done` commits the text-input transaction — the
    /// protocol never reads it in between, so one buffer suffices.
    preedit_buf: [256]u8 = undefined,
    preedit_len: usize = 0,
    preedit_cursor_begin: i32 = -1,
    preedit_cursor_end: i32 = -1,
    pending_commit_buf: [256]u8 = undefined,
    pending_commit_len: usize = 0,
    active_popups: std.ArrayList(PopupState) = .empty,
    /// Monotonic source for auto-assigned popup ids (`PopupSpec.id == 0`):
    /// deriving an id from `active_popups.items.len` collided after a
    /// middle popup was dismissed and a new one created.
    next_popup_id: u32 = 1,

    surface: ?*wl.Surface = null,
    xdg_surface: ?*wl.XdgSurface = null,
    toplevel: ?*wl.XdgToplevel = null,
    blur: ?*wl.BackgroundEffectSurface = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    touch: ?*wl.Touch = null,
    /// Active primary-finger slot (`-1` = none): single-finger touch is synthesized
    /// as a pointer, so apps work with touch without changes.
    touch_id: i32 = -1,
    cursor_device: ?*wl.CursorShapeDevice = null,
    // HiDPI: with both globals present the buffer is rendered at `logical × scale`
    // physical pixels and presented at logical size through the viewport — crisp on
    // fractionally scaled outputs. Without them scale stays 1.0 (previous behavior).
    viewport: ?*wl.Viewport = null,
    fractional: ?*wl.FractionalScale = null,
    /// Compositor-preferred surface scale in 120ths (`wp_fractional_scale_v1`): 120 = 1.0.
    scale120: u32 = 120,

    /// Panel (window-geometry) size; buffer size adds the shadow margin on each side.
    panel_w: u32,
    panel_h: u32,
    configured: bool = false,
    needs_redraw: bool = false,
    // Damage for the next redraw: `dirty_staged` = there's a new app frame (region
    // = the frame's rect); any other trigger (input/panel/style/resize) marks
    // `dirty_full`. With both, full wins. Consumed by `redraw`.
    dirty_full: bool = false,
    dirty_staged: bool = false,
    /// Gutter on the RIGHT of the content that the app keeps for its own overlay
    /// (a side panel drawn in `on_draw`): the frame centers in what is left, so
    /// opening the panel doesn't leave the same width of dead glass on the other
    /// side. See `reserveGutter`.
    gutter_right: std.atomic.Value(u32) = .init(0),
    /// `invalidate` from another thread: the app's `on_draw` overlay changed
    /// outside the frame rect, so the next redraw must be a FULL recompose (a
    /// staged frame alone only damages the frame's own rect).
    overlay_dirty: std.atomic.Value(bool) = .init(false),
    /// Dirty region declared by the panels (union of their `dirtyBounds` on the
    /// animation ticks), in buffer pixels. Consumed by `redraw`.
    dirty_rect: ?Rect = null,
    /// Canvas rect of the last composed app frame: when the frame changes
    /// size/position the damage region is the UNION of old and new
    /// (otherwise the old frame's border would linger as a ghost).
    last_front_rect: ?Rect = null,
    /// Guards `pending_resize`/`pending_clip`/`staged_dma` — cross-thread requests
    /// unrelated to the RGBA frame data `mailbox` already locks on its own.
    mutex: SpinLock = .{},
    // Resize requested by another thread (guarded by `mutex`): operations
    // on the Wayland surface are NOT thread-safe, so `requestResize` only stages
    // the target and the run loop calls `animateResize` on the window thread.
    pending_resize: ?[2]u32 = null,
    // Clipboard text staged by another thread (guarded by `mutex`, owned by the
    // window's gpa): the run loop applies it via `clipboardSet`, which must run
    // on the window thread and wants a recent input serial.
    pending_clip: ?[]u8 = null,
    // `hideVideo` from another thread: same reason — the unmap is a surface op,
    // so it is staged here and performed on the window thread.
    pending_hide_video: std.atomic.Value(bool) = .init(false),
    /// Cross-thread "toggle hide/show" request (tray click, global shortcut).
    pending_toggle_visible: std.atomic.Value(bool) = .init(false),
    /// True while the toplevel is unmapped by `setVisible(false)` (hidden to tray).
    hidden: std.atomic.Value(bool) = .init(false),
    // True once `run` is pumping. Before that (init roundtrips) `onXdgConfigure` must
    // redraw synchronously to map the window; during the loop it only flags a redraw so
    // a burst of resize configures coalesces into one paint per iteration.
    running: bool = false,
    /// Wall-clock ms of the last overlay-triggered parent repaint, to cap it (see
    /// the run loop): a HUD over a dmabuf video must not repaint at video rate.
    last_overlay_ms: i64 = 0,
    closed: bool = false,
    // Fullscreen state: in fullscreen the gutter/shadow/corners are zeroed
    // so the content fills the screen; the original values are restored
    // on exit together with the windowed panel size.
    fullscreen: bool = false,
    saved_panel_w: u32 = 0,
    saved_panel_h: u32 = 0,
    saved_margin: u32 = 0,
    saved_radius: f32 = 0,
    saved_content_radius: f32 = 0,
    // Text engine (stb_truetype), created lazily on first use: default font
    // Hack regular+bold, replaceable with `setFont`/`loadFont`.
    font: ?text.Font = null,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    /// Latest pointer input serial (enter/button), needed by interactive move/resize and
    /// cursor-shape requests, which the compositor authenticates against a recent serial.
    pointer_serial: u32 = 0,
    /// Cursor shape currently requested, so repeated motion doesn't re-issue set_shape.
    cursor_shape: u32 = wl.CursorShapeDevice.SHAPE_DEFAULT,
    // Maximized state, like fullscreen: detected from the configure states,
    // drives the controls' maximize/restore icon.
    maximized: bool = false,

    // --- keyboard layout translation (xkbcommon) --------------------------------------
    // Built from the compositor's `wl_keyboard.keymap` fd; a new keymap (layout switch)
    // replaces all three. Null when setup failed → `on_text` simply never fires.
    xkb_context: ?*xkb.Context = null,
    xkb_keymap: ?*xkb.Keymap = null,
    xkb_state: ?*xkb.State = null,

    // --- client-side key repeat ---------------------------------------------------------
    // Wayland delegates auto-repeat to the client: the compositor only sends one
    // press/release pair plus `repeat_info` (rate/delay). A dedicated timerfd fires
    // the synthetic repeats; the shared animation timer_fd self-disarms and can't
    // hold a steady cadence.
    /// From `wl_keyboard.repeat_info`; rate in keys/sec, delay in ms. rate 0 = disabled.
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 400,
    /// evdev keycode currently held and repeating (0 = none).
    repeat_key: u32 = 0,
    /// Tasti (evdev) premuti e non ancora rilasciati: se il focus se ne va (dialog di
    /// sistema aperto da Ctrl+S, Alt+Tab…) il rilascio non arriverebbe mai e l'app
    /// crederebbe Ctrl ancora giù — la "w" digitata dopo diventerebbe Ctrl+W.
    held_keys: std.StaticBitSet(256) = .empty,
    repeat_fd: posix.fd_t = -1,

    // --- clipboard (wl_data_device selection) -----------------------------------------
    /// Latest keyboard/pointer-button input serial: `set_selection` must be
    /// authenticated against a recent input event, exactly like move/resize.
    input_serial: u32 = 0,
    data_device: ?*wl.DataDevice = null,
    /// Our outstanding selection source; non-null == WE own the clipboard. Cleared by
    /// the `cancelled` event when another client takes the selection over.
    data_source: ?*wl.DataSource = null,
    /// Window-owned copy of the text behind `data_source` (served in `send`).
    clip_text: []u8 = &.{},
    /// Offer introduced by the last `data_offer` event, still collecting mime types;
    /// `selection` (or a DnD `enter` we ignore) will designate it.
    pending_offer: ?*wl.DataOffer = null,
    pending_mime: TextMime = .none,
    /// The current clipboard content offer (null = empty clipboard), and the best text
    /// mime it advertised.
    selection_offer: ?*wl.DataOffer = null,
    selection_mime: TextMime = .none,

    // Panels (title-bar controls, context menu, scrollbars, dlopen plugins) draw over the
    // content, receive input before the app callbacks, and animate off a shared clock.
    panels: plugin.Registry,
    // Floating egui-style scrollbars, auto-mounted on every window as the bottom-most
    // panel. Dormant (invisible) until the app reports its content size via
    // `win.scrollbars.setContent(w, h)`; the viewport tracks the content rect for free.
    scrollbars: scroll.Scroll = .{ .follow_content = true },
    // timerfd that beats the animation clock: armed (~60 Hz) while a panel is
    // animating, disarmed once everything has settled so `poll` blocks idle again.
    timer_fd: posix.fd_t = -1,
    timer_armed: bool = false,
    last_tick_ns: i64 = 0,
    // Maximum usable window-geometry size suggested by the compositor
    // (xdg_toplevel.configure_bounds): the screen area minus panels/reservations.
    // 0 = unknown. Constrains resizes so the window doesn't overflow past
    // the screen (especially at the bottom). The client cannot position itself on
    // Wayland — the compositor places (and usually centers) the window.
    bounds_w: u32 = 0,
    bounds_h: u32 = 0,
    // Optional StatusNotifierItem tray connection; created in `run` when `opts.tray` is set,
    // its bus fd is polled alongside Wayland. Null when no tray or registration failed.
    tray: ?*tray_mod.Tray = null,
    // Optional KDE global menu: the com.canonical.dbusmenu server plus the Wayland
    // appmenu object that tells KWin where to find it. Bus fd polled alongside Wayland.
    menu: ?*dbusmenu.Server = null,
    appmenu_manager: ?*wl.OrgKdeKwinAppmenuManager = null,
    appmenu_obj: ?*wl.OrgKdeKwinAppmenu = null,
    // Open handles of `dlopen`'d plugin `.so`s. Closed after `panels.deinit` in `deinit`,
    // because the panels' `deinit` code lives inside these libraries.
    plugin_libs: std.ArrayList(std.DynLib) = .empty,

    // wl_shm double buffer, one pool + mapping shared by both slots.
    shm_fd: posix.fd_t = -1,
    shm_map: []align(std.heap.page_size_min) u8 = &.{},
    pool: ?*wl.ShmPool = null,
    // Bytes backing `pool`/`shm_map`. Kept over-allocated so a resize only re-slices the
    // two buffers instead of tearing down the memfd/mmap/pool every frame; grown (with
    // headroom) only when the needed size exceeds it.
    pool_cap: usize = 0,
    slots: [2]BufferSlot = .{ .{}, .{} },
    buf_w: u32 = 0,
    buf_h: u32 = 0,

    /// Chrome painted once per resize, memcpy'd under every frame.
    decor: []u32 = &.{},

    // Cross-thread frame mailbox: producers write `staged` under the lock, `redraw`
    // swaps it into `front` (window-thread-only) so the blit runs unlocked.
    mailbox: chrome.FrameMailbox = .{},
    wake_fd: posix.fd_t,

    // The zero-copy video path: GPU frames arrive as dmabufs and go to a
    // desynced subsurface over the content area — no CPU pixels involved.
    // `staged_dma` is the cross-thread mailbox (same wake fd as `staged`);
    // wl_buffers are created once per slot and reused every frame.
    video_surface: ?*wl.Surface = null,
    video_subsurface: ?*wl.Subsurface = null,
    /// Maps the physically-sized video buffer to its logical on-screen size on
    /// fractionally scaled outputs — without it the compositor would present
    /// the buffer 1:1 in logical units, i.e. oversized by the scale factor.
    video_viewport: ?*wl.Viewport = null,
    // 8 slots: enough for a few resolution tiers × double buffering.
    video_buffers: [8]?*wl.Buffer = @splat(null),
    staged_dma: ?StagedDma = null,
    /// True while a frame callback is outstanding on the video surface: the
    /// compositor has not yet consumed the last commit. Producers poll
    /// `videoBusy` to pace themselves to the refresh rate instead of
    /// free-running (mailbox semantics: staging while busy replaces).
    video_pending: std.atomic.Value(bool) = .init(false),
    /// Physical rect the dmabuf frame occupies (window thread only): the app
    /// origin for pointer coordinates while the video plane is live, mirroring
    /// what `chrome.appOrigin` does for staged RGBA frames.
    video_rect: ?Rect = null,
    /// Size each cached slot wl_buffer was created at — a present at a
    /// different size recreates the buffer, so producers may change resolution
    /// (window resize) without exhausting slots.
    video_buf_sizes: [8][2]u32 = @splat(.{ 0, 0 }),
    /// LIFO of dismissable layers: ESC pops the topmost before `close_on_esc`
    /// gets a say (menus still handle their own ESC first, via routeInput).
    /// Window-thread only; apps push from callbacks or before `run`.
    dismissables: [8]Dismissable = undefined,
    n_dismissables: usize = 0,

    // --- vsync wait (`waitFrame`) -----------------------------------------------
    // Counter of the compositor's frame callbacks on the main surface: the
    // dispatch (window thread) increments it and wakes the waiters via futex; the
    // callers of `waitFrame` sleep in FUTEX_WAIT on exactly this address.
    // (Zig 0.16 keeps blocking mutex/condvar behind `std.Io`, see `SpinLock`:
    // for a blocking wait with timeout the raw futex is the right primitive here,
    // and this backend is Linux-only anyway.)
    /// Monotonic counter `waitFrame`/`wakeFrameWaiters` futex on.
    frame_seq: std.atomic.Value(u32) = .init(0),
    /// The outstanding `wl_surface.frame` callback proxy, so a hide mid-flight
    /// (`setVisible(false)`) can destroy it instead of leaking it — the compositor
    /// does not fire `done` for an unmapped surface.
    frame_cb: ?*wl.Callback = null,
    /// Window thread only: true while a `wl_surface.frame` is in flight on the
    /// main surface (at most one pending callback at a time, requested
    /// together with the commit in `redraw`).
    frame_cb_pending: bool = false,
    /// Raised at teardown (exit from the run loop or `deinit`): the waiters are
    /// woken and `waitFrame` returns false instead of waiting for a callback that
    /// will never arrive again.
    frame_teardown: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: Allocator, opts: Options) !*Window {
        const display = wl.wl_display_connect(null) orelse return error.NoWaylandDisplay;
        errdefer wl.wl_display_disconnect(display);

        const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(efd) != .SUCCESS) return error.EventFdFailed;
        const wake_fd: posix.fd_t = @intCast(efd);
        errdefer _ = linux.close(wake_fd);

        const tfd = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
        if (linux.errno(tfd) != .SUCCESS) return error.TimerFdFailed;
        const timer_fd: posix.fd_t = @intCast(tfd);
        errdefer _ = linux.close(timer_fd);

        const rfd = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
        if (linux.errno(rfd) != .SUCCESS) return error.TimerFdFailed;
        const repeat_fd: posix.fd_t = @intCast(rfd);
        errdefer _ = linux.close(repeat_fd);

        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .opts = opts,
            .display = display,
            .registry = wl.displayGetRegistry(display),
            .panel_w = opts.width,
            .panel_h = opts.height,
            .wake_fd = wake_fd,
            .timer_fd = timer_fd,
            .repeat_fd = repeat_fd,
            .panels = plugin.Registry.init(gpa),
        };
        self.panel_w = @max(self.panel_w, self.minPanel());
        self.panel_h = @max(self.panel_h, self.minPanel());

        self.registry.setListener(&registry_listener, self);
        if (wl.wl_display_roundtrip(display) < 0) return error.WaylandIo;
        if (self.compositor == null or self.shm == null or self.wm_base == null)
            return error.MissingWaylandGlobals;

        self.wm_base.?.setListener(&wm_base_listener, self);

        // Clipboard endpoint: needs both the manager and the seat from the same
        // registry burst. Absent either (bare compositor), clipboardSet/Get degrade
        // to no-ops/null.
        if (self.data_device_manager) |ddm| {
            if (self.seat) |seat| {
                const dev = ddm.getDataDevice(seat);
                dev.setListener(&data_device_listener, self);
                self.data_device = dev;
            }
        }

        const surface = self.compositor.?.createSurface();
        self.surface = surface;
        const xdg_surface = self.wm_base.?.getXdgSurface(surface);
        xdg_surface.setListener(&xdg_surface_listener, self);
        self.xdg_surface = xdg_surface;
        const toplevel = xdg_surface.getToplevel();
        toplevel.setListener(&toplevel_listener, self);
        toplevel.setTitle(opts.title.ptr);
        toplevel.setAppId(opts.app_id.ptr);
        const min: i32 = @intCast(self.minPanel());
        toplevel.setMinSize(min, min);
        self.toplevel = toplevel;

        if (self.blur_manager) |mgr| self.blur = mgr.getBackgroundEffect(surface);

        // Fractional HiDPI needs BOTH: the scale preference and the viewport that maps
        // the physically-sized buffer back to the logical window size.
        if (self.viewporter != null and self.fractional_manager != null) {
            self.viewport = self.viewporter.?.getViewport(surface);
            self.fractional = self.fractional_manager.?.getFractionalScale(surface);
            self.fractional.?.setListener(&fractional_listener, self);
        }

        // Floating scrollbars are the bottom-most panel: the title bar and context menu
        // draw over them and grab input first. Borrowed — the Window owns the instance
        // (as a field), so the registry must not deinit/free it.
        try self.panels.add(Panel.of(scroll.Scroll, &self.scrollbars), false);

        // Register the built-in title-bar controls next, then the context menu on top of
        // it so the menu draws over the bar and grabs input first.
        if (opts.titlebar) {
            const c = try controls.Controls.create(gpa, opts.titlebar_style, opts.titlebar_height, opts.title);
            try self.panels.add(Panel.of(controls.Controls, c), true);
        }
        if (opts.context_menu) {
            const mnu = try menu.Menu.create(gpa);
            try self.panels.add(Panel.of(menu.Menu, mnu), true);
        }

        // First commit carries no buffer; the compositor answers with configure and
        // only then may we attach pixels.
        surface.commit();
        if (wl.wl_display_roundtrip(display) < 0) return error.WaylandIo;
        return self;
    }

    pub fn deinit(self: *Window) void {
        // Safety belt for callers that never entered `run`: mark the
        // teardown and wake any `waitFrame` waiters BEFORE tearing down.
        // (The contract still holds: threads that call waitFrame must be joined
        // before deinit — this only narrows the race window.)
        self.cancelFrameCallback();
        self.frame_teardown.store(true, .release);
        self.wakeFrameWaiters();
        if (self.appmenu_obj) |o| o.release();
        if (self.menu) |mnu| mnu.deinit();
        if (self.tray) |t| t.deinit();
        // Panels first (runs plugin `deinit`s), then unload the libraries that hold them.
        self.panels.deinit();
        for (self.plugin_libs.items) |*lib| lib.close();
        self.plugin_libs.deinit(self.gpa);
        self.dropBuffers();
        if (self.font) |*f| f.deinit();
        if (self.decor.len > 0) self.gpa.free(self.decor);
        self.mailbox.deinit(self.gpa);
        for (self.video_buffers) |vb| {
            if (vb) |b| b.destroy();
        }
        if (self.video_viewport) |v| wl.wl_proxy_destroy(@ptrCast(v));
        if (self.video_subsurface) |ss| ss.destroy();
        if (self.video_surface) |vs| vs.destroy();
        if (self.data_source) |s| s.destroy();
        if (self.pending_offer) |o| {
            if (o != self.selection_offer) o.destroy();
        }
        if (self.selection_offer) |o| o.destroy();
        if (self.data_device) |d| d.release();
        if (self.clip_text.len > 0) self.gpa.free(self.clip_text);
        if (self.pending_clip) |p| self.gpa.free(p);
        if (self.xkb_state) |st| xkb.xkb_state_unref(st);
        if (self.xkb_keymap) |km| xkb.xkb_keymap_unref(km);
        if (self.xkb_context) |ctx| xkb.xkb_context_unref(ctx);
        if (self.fractional) |f| wl.wl_proxy_destroy(@ptrCast(f));
        if (self.viewport) |v| wl.wl_proxy_destroy(@ptrCast(v));
        if (self.blur) |b| wl.wl_proxy_destroy(@ptrCast(b));
        for (self.active_popups.items) |p| p.destroy();
        self.active_popups.deinit(self.gpa);
        if (self.text_input) |ti| ti.destroy();
        if (self.text_input_manager) |tim| tim.destroy();
        if (self.cursor_device) |c| wl.wl_proxy_destroy(@ptrCast(c));
        if (self.keyboard) |k| wl.wl_proxy_destroy(@ptrCast(k));
        if (self.pointer) |p| wl.wl_proxy_destroy(@ptrCast(p));
        if (self.toplevel) |t| wl.wl_proxy_destroy(@ptrCast(t));
        if (self.xdg_surface) |x| wl.wl_proxy_destroy(@ptrCast(x));
        if (self.surface) |s| s.destroy();
        wl.wl_display_disconnect(self.display);
        _ = linux.close(self.wake_fd);
        if (self.timer_fd >= 0) _ = linux.close(self.timer_fd);
        if (self.repeat_fd >= 0) _ = linux.close(self.repeat_fd);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// True once the compositor granted background blur.
    pub fn hasBlur(self: *Window) bool {
        return self.blur != null;
    }

    /// Poke `wake_fd` so the run loop's poll() returns immediately to pick up
    /// whatever cross-thread state the caller just staged.
    fn wake(self: *Window) void {
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one).ptr, 8);
    }

    /// Stage a straight-alpha RGBA frame for presentation. Safe from any thread; the
    /// newest frame wins (latest-value semantics, same spirit as zicro's media plane).
    pub fn presentRgba(self: *Window, width: u32, height: u32, rgba: []const u8) void {
        if (self.mailbox.stage(self.gpa, width, height, rgba)) {
            self.wake();
        }
    }

    /// Keep `px` pixels on the right of the content for the app's own overlay:
    /// the staged frame then centers in the rest instead of in the full content.
    /// Safe from any thread; forces a full recompose.
    pub fn reserveGutter(self: *Window, px: u32) void {
        self.gutter_right.store(px, .release);
        self.invalidate();
    }

    /// The rect a staged frame centers in: the content minus the app's gutter.
    fn frameArea(self: *Window) Rect {
        const c = self.contentRect();
        const g = @min(self.gutter_right.load(.acquire), c.w);
        return .{ .x = c.x, .y = c.y, .w = c.w - g, .h = c.h };
    }

    /// Mark the `on_draw` overlay dirty: the next redraw recomposes the whole
    /// panel instead of just the app frame's rect. Safe from any thread — an
    /// app whose HUD lives OUTSIDE the frame (status lines, a side panel) must
    /// call this when that text changes, or the overlay stays frozen on its
    /// last full paint while the frame keeps moving.
    pub fn invalidate(self: *Window) void {
        self.overlay_dirty.store(true, .release);
        self.wake();
    }

    /// Request a window resize from any thread. Stages the
    /// target and wakes the run loop, which will run `animateResize` on the window
    /// thread: operations on the Wayland surface (attach/commit) are not
    /// thread-safe and calling them from a worker during `run` corrupts the protocol
    /// (e.g. `xdg_surface: attached a buffer before configure`).
    pub fn requestResize(self: *Window, width: u32, height: u32) void {
        self.mutex.lock();
        self.pending_resize = .{ width, height };
        self.mutex.unlock();
        self.wake();
    }

    /// Thread-safe `clipboardSet`: stages a copy of `bytes` and wakes the run
    /// loop, which takes the selection on the window thread. Newest wins if
    /// called again before the loop drains. For window-thread callers,
    /// `clipboardSet` directly is simpler and immediate.
    pub fn requestClipboardSet(self: *Window, bytes: []const u8) void {
        const copy = self.gpa.dupe(u8, bytes) catch return;
        self.mutex.lock();
        if (self.pending_clip) |old| self.gpa.free(old);
        self.pending_clip = copy;
        self.mutex.unlock();
        self.wake();
    }

    /// Unmap the video subsurface, so the parent's own staged frame
    /// (`presentRgba`) is what the window shows again.
    ///
    /// A dmabuf frame does not replace the parent's content, it is a SUBSURFACE
    /// stacked above it — so an app that renders 3D on the GPU and then wants to
    /// show something composed in software instead (a picture slide, a still)
    /// would find its last GPU frame still sitting on top of it. This takes the
    /// video plane away; the next `presentDmabuf` puts it straight back.
    /// Thread-safe (the unmap itself happens on the window thread).
    pub fn hideVideo(self: *Window) void {
        self.pending_hide_video.store(true, .release);
        self.wake();
    }

    /// Single-plane dmabuf present (convenience overload for `presentDmabufPlanes`).
    pub fn presentDmabuf(self: *Window, slot: u8, fd: posix.fd_t, width: u32, height: u32, stride: u32, fourcc: u32, modifier: u64) bool {
        return self.presentDmabufPlanes(slot, &.{.{ .fd = fd, .offset = 0, .stride = stride, .modifier = modifier }}, width, height, fourcc);
    }

    /// Present a GPU frame (1..4 planes) with zero CPU pixel work: planes specify the dmabuf
    /// exports (`fourcc`/`stride`/`modifier`/`offset` as reported by exporter/Vulkan). `slot`
    /// (0..7) identifies a persistent image; its wl_buffer is created once and reused. Returns
    /// false when compositor lacks linux-dmabuf/subcompositor support — fall back to `presentRgba`.
    pub fn presentDmabufPlanes(self: *Window, slot: u8, planes: []const DmabufPlane, width: u32, height: u32, fourcc: u32) bool {
        if (self.dmabuf == null or self.subcompositor == null or planes.len == 0 or planes.len > 4) return false;
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
                .planes = undefined,
            };
            @memcpy(self.staged_dma.?.planes[0..planes.len], planes);
        }
        self.wake();
        return true;
    }

    /// Window-thread half of `presentDmabuf`: build the subsurface/buffers
    /// lazily, then attach + commit the requested slot. Returns true when a
    /// staged frame was committed (so the caller can refresh a client overlay).
    fn processVideo(self: *Window) bool {
        if (!self.configured) return false;
        self.mutex.lock();
        const req_opt = self.staged_dma;
        self.staged_dma = null;
        self.mutex.unlock();
        const req = req_opt orelse return false;

        if (self.video_surface == null) {
            const vs = self.compositor.?.createSurface();
            // Input passes through to the glass parent (drag/keys still work).
            const empty = self.compositor.?.createRegion();
            vs.setInputRegion(empty);
            empty.destroy();
            const ss = self.subcompositor.?.getSubsurface(vs, self.surface.?);
            ss.setDesync();
            self.video_surface = vs;
            self.video_subsurface = ss;
            // Fractional HiDPI: the frame is rendered in physical pixels; the
            // viewport presents it at logical size (identity on scale-1).
            if (self.viewporter) |vpr| self.video_viewport = vpr.getViewport(vs);
            // Mapping and position are parent state: one chrome commit seals them.
            self.redrawAll();
        }
        // The content rect is physical (canvas space); everything handed to the
        // compositor — subsurface position, viewport destination — is logical.
        //
        // The frame FILLS the content area. Its pixel size is a quality knob (the
        // resolution tier, dynamic-res, FSR) and has nothing to do with how big
        // the window is: wp_viewport scales the buffer up to the content rect on
        // the compositor's scanout path, for free. Presenting the buffer at its
        // native size instead — which is what we used to do — left a fat border
        // of empty glass around anything rendered below the window's size.
        //
        // Unless the window says otherwise: `video_fit = .native` is for a render
        // that is a PANEL inside a larger card (the rest of the content rect is
        // `on_draw`'s text), where filling would paint over it. Without a
        // viewporter we cannot scale at all, so that is the only thing we can do.
        const content = self.frameArea();
        var vw = content.w;
        var vh = content.h;
        var dx = content.x;
        var dy = content.y;
        if (self.video_viewport == null or self.opts.video_fit == .native) {
            vw = @min(req.width, content.w);
            vh = @min(req.height, content.h);
            dx = content.x + (content.w - vw) / 2;
            dy = content.y + (content.h - vh) / 2;
        }
        self.video_rect = .{ .x = dx, .y = dy, .w = vw, .h = vh };
        self.video_subsurface.?.setPosition(@intCast(self.logiPx(dx)), @intCast(self.logiPx(dy)));
        if (self.video_viewport) |vp| {
            vp.setDestination(@intCast(@max(self.logiPx(vw), 1)), @intCast(@max(self.logiPx(vh), 1)));
        }

        // A slot re-presented at a new size (producer resized) gets a fresh
        // wl_buffer; the compositor keeps the old one alive until released.
        if (self.video_buffers[req.slot]) |b| {
            const sz = self.video_buf_sizes[req.slot];
            if (sz[0] != req.width or sz[1] != req.height) {
                b.destroy();
                self.video_buffers[req.slot] = null;
            }
        }
        if (self.video_buffers[req.slot] == null) {
            self.video_buf_sizes[req.slot] = .{ req.width, req.height };
            const params = self.dmabuf.?.createParams();
            var pi: u32 = 0;
            while (pi < req.plane_count) : (pi += 1) {
                const pl = req.planes[pi];
                params.add(pl.fd, pi, pl.offset, pl.stride, pl.modifier);
            }
            self.video_buffers[req.slot] = params.createImmed(
                @intCast(req.width),
                @intCast(req.height),
                req.fourcc,
                0,
            );
            params.destroy();
        }
        const vs = self.video_surface.?;
        vs.attach(self.video_buffers[req.slot], 0, 0);
        vs.damageBuffer(0, 0, @intCast(req.width), @intCast(req.height));
        // Refresh pacing: one frame callback per commit; producers that honor
        // `videoBusy` settle at the compositor's cadence.
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

    /// True while the compositor still owes a frame-done for the last video
    /// commit — render the next frame when this turns false to run at the
    /// refresh rate instead of burning frames nobody sees.
    pub fn videoBusy(self: *const Window) bool {
        return self.video_pending.load(.acquire);
    }

    /// Blocks the calling thread (ANY thread, typically the app's render
    /// worker) until the compositor's next frame callback — the right
    /// moment to compose the following frame — or until `timeout_ms`.
    /// Returns `true` if woken by the callback, `false` on timeout or with the
    /// window closed/in teardown (the caller falls back to its own pacer).
    ///
    /// Contract:
    /// - The callback is requested only when `redraw` actually commits a
    ///   frame: with no commit since the last callback (e.g. paused video) or with the
    ///   window hidden/occluded (compositors stop frame callbacks)
    ///   the wait expires on the timeout — it's the safety net, not an error.
    /// - Multiple concurrent waiters are allowed (the wake-up is a broadcast).
    /// - On window close the waiters are woken and receive
    ///   `false`; the caller must have left `waitFrame` (i.e. its
    ///   thread reached/joined) before calling `deinit`.
    /// - On Win32 the equivalent method always returns `false` immediately (no
    ///   vsync hook): there the caller uses its software pacer.
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
            // FUTEX_WAIT sleeps only if `frame_seq` still equals `start`: a
            // callback that arrived between the load and the wait makes the wait fail with
            // EAGAIN — no lost wake-up. Relative timeout, monotonic clock.
            const rc = linux.futex_4arg(
                &self.frame_seq.raw,
                .{ .cmd = .WAIT, .private = true },
                start,
                &ts,
            );
            switch (linux.errno(rc)) {
                .SUCCESS, .AGAIN, .INTR => {},
                else => return false, // TIMEDOUT or unexpected error
            }
            if (self.frame_teardown.load(.acquire)) return false;
            if (self.frame_seq.load(.acquire) != start) return true;
            // Spurious wake-up/EINTR: the remaining time is recomputed and we retry.
        }
    }

    /// Broadcast-wakes every thread parked in `waitFrame` (the store is already done
    /// by the caller: here only the wake syscall).
    fn wakeFrameWaiters(self: *Window) void {
        _ = linux.futex_3arg(
            &self.frame_seq.raw,
            .{ .cmd = .WAKE, .private = true },
            std.math.maxInt(i32),
        );
    }

    const frame_done_listener = wl.Callback.Listener{ .done = onFrameDone };

    /// Frame callback of the main surface (dispatched on the window thread):
    /// ONLY store + wake, no heavy work in the Wayland dispatch.
    fn onFrameDone(data: ?*anyopaque, callback: *wl.Callback, _: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        callback.destroy();
        self.frame_cb = null;
        self.frame_cb_pending = false;
        _ = self.frame_seq.fetchAdd(1, .release);
        self.wakeFrameWaiters();
        if (self.mailbox.isFresh() or self.overlay_dirty.load(.monotonic) or self.dirty_full or self.dirty_staged or self.dirty_rect != null) {
            self.needs_redraw = true;
        }
    }

    /// The event loop: blocks until the window is closed or the connection drops.
    pub fn run(self: *Window) !void {
        self.running = true;
        // On exit from the loop (close or connection error) no frame
        // callback will arrive again: wake whoever is parked in `waitFrame`, which then
        // returns false and lets its own thread terminate.
        defer {
            self.frame_teardown.store(true, .release);
            self.wakeFrameWaiters();
        }
        // Bring up the tray icon once, if requested. Registration failure (no tray host on
        // the bus) is non-fatal: log and run without it.
        if (self.tray == null) {
            if (self.opts.tray) |tc| {
                self.tray = tray_mod.Tray.init(self.gpa, .{
                    .id = tc.id,
                    .title = tc.title,
                    .icon_name = tc.icon_name,
                    .tooltip = tc.tooltip,
                    .on_activate = onTrayActivate,
                    .ctx = self,
                }) catch |err| blk: {
                    std.log.warn("zrame: tray icon unavailable ({s})", .{@errorName(err)});
                    break :blk null;
                };
            }
        }

        // Bring up the KDE global menu once: export the dbusmenu on the session bus, then
        // tell KWin its address over the appmenu Wayland protocol. Any failure is non-fatal.
        if (self.menu == null) {
            if (self.opts.menu) |items| self.setupMenu(items);
        }

        while (!self.closed) {
            while (wl.wl_display_prepare_read(self.display) != 0) {
                if (wl.wl_display_dispatch_pending(self.display) < 0) return error.WaylandIo;
            }
            _ = wl.wl_display_flush(self.display);
            if (self.tray) |t| t.flush();
            if (self.menu) |mnu| mnu.flush();

            var fds = [_]posix.pollfd{
                .{ .fd = wl.wl_display_get_fd(self.display), .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.timer_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.repeat_fd, .events = posix.POLL.IN, .revents = 0 },
                // Negative fd = ignored by poll, so these slots are inert when absent.
                .{ .fd = if (self.tray) |t| t.fd() else -1, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = if (self.menu) |mnu| mnu.fd() else -1, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = posix.poll(&fds, -1) catch |err| {
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
                // A staged shm frame needs the full chrome redraw. A dmabuf frame
                // commits its own subsurface; when the client draws an overlay
                // (`on_draw` — e.g. a live HUD) the parent must repaint too, or the
                // overlay freezes on its first paint while the video keeps moving.
                const had_video = self.processVideo();
                if (self.mailbox.isFresh()) {
                    // New app frame: damage = the frame's rect (not full) — the
                    // exact region is derived in `redraw` after the swap.
                    self.needs_redraw = true;
                    self.dirty_staged = true;
                } else if (had_video and self.opts.on_draw != null) {
                    // Cap the overlay repaint at ~15 Hz. Repainting the whole parent
                    // at video rate saturates this thread — which also dispatches
                    // input — making input lag badly under interaction. A HUD reads
                    // fine at 15 Hz; the video keeps its own (full-rate) subsurface.
                    var ts: linux.timespec = undefined;
                    _ = linux.clock_gettime(.MONOTONIC, &ts);
                    const now_ms: i64 = @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
                    if (now_ms - self.last_overlay_ms >= 66) {
                        self.last_overlay_ms = now_ms;
                        self.redrawAll();
                    }
                }
            }

            if (fds[2].revents & posix.POLL.IN != 0) self.onTimerTick();
            if (fds[3].revents & posix.POLL.IN != 0) self.onRepeatTick();

            if (self.tray) |t| {
                if (fds[4].revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP) != 0) t.process();
            }
            if (self.menu) |mnu| {
                if (fds[5].revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP) != 0) mnu.process();
            }

            // Resize and clipboard are both requested cross-thread and staged under
            // the same mutex; grab both under one lock instead of two.
            self.mutex.lock();
            const rr = self.pending_resize;
            self.pending_resize = null;
            const pclip = self.pending_clip;
            self.pending_clip = null;
            self.mutex.unlock();

            // Run it HERE, on the window thread, before the redraw
            // (Wayland surfaces are not thread-safe).
            if (rr) |wh| self.animateResize(wh[0], wh[1]);

            // Same rule for hide/show: the unmap/remap touches the surface,
            // so it must run here on the window thread (see `requestToggleVisible`).
            if (self.pending_toggle_visible.swap(false, .acquire)) self.setVisible(self.hidden.load(.acquire));

            if (pclip) |clip| {
                self.clipboardSet(clip);
                self.gpa.free(clip);
            }

            // Same rule for taking the video plane away (see `hideVideo`).
            if (self.pending_hide_video.swap(false, .acquire)) {
                if (self.video_surface) |vs| {
                    vs.attach(null, 0, 0);
                    vs.commit();
                    self.needs_redraw = true;
                    self.dirty_full = true;
                }
            }

            if (self.overlay_dirty.swap(false, .acquire)) {
                self.dirty_full = true;
                self.needs_redraw = true;
            }

            if (self.configured and self.needs_redraw) try self.redraw();
        }
    }

    /// Hide (unmap) or re-show (remap) the toplevel — the "minimize to tray"
    /// primitive. Window thread only; from other threads use `requestToggleVisible`.
    ///
    /// Hiding follows the `animateResize` unmap recipe but STOPS before the
    /// initial empty commit: that commit is what solicits the configure that
    /// remaps the surface, so it belongs to the show half. While hidden,
    /// `configured` stays false, which keeps the run loop from redrawing, and
    /// staged frames simply accumulate in the mailbox (newest wins) until show.
    pub fn setVisible(self: *Window, show: bool) void {
        if (show == !self.hidden.load(.acquire)) return;
        if (show) {
            self.hidden.store(false, .release);
            if (self.surface) |surface| {
                // Unmapping reset the xdg_surface state, window geometry
                // included: re-stage it BEFORE the mapping commit or the
                // compositor sizes the remap from the full buffer (shadow
                // gutter included) and echoes that as the next configure —
                // the panel would grow by 2*margin per hide/show cycle.
                self.applySurfaceMetrics();
                // Initial commit (no buffer): the compositor answers with a
                // configure; onXdgConfigure raises `configured` and the next
                // redraw re-attaches pixels → the window remaps where it was.
                surface.commit();
            }
            self.redrawAll();
        } else {
            if (self.surface) |surface| {
                surface.attach(null, 0, 0);
                surface.commit();
            }
            self.configured = false;
            self.cancelFrameCallback();
            self.hidden.store(true, .release);
            // A hidden surface gets no frame callbacks: release anyone parked
            // in `waitFrame` so render workers fall back to their own pacer.
            self.wakeFrameWaiters();
        }
    }

    /// True while the window is on screen (not hidden to tray).
    pub fn isVisible(self: *Window) bool {
        return !self.hidden.load(.acquire);
    }

    /// Toggle hide/show from any thread (tray click, global shortcut, RPC):
    /// stages the request and wakes the run loop, which performs the
    /// unmap/remap on the window thread (Wayland surfaces are not thread-safe).
    pub fn requestToggleVisible(self: *Window) void {
        self.pending_toggle_visible.store(true, .release);
        self.wake();
    }

    /// sd-bus `Activate` trampoline: recover the window from the tray's ctx and forward to
    /// the caller's `on_activate` (see `TrayConfig`).
    fn onTrayActivate(ctx: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(ctx.?));
        if (self.opts.tray) |tc| {
            if (tc.on_activate) |cb| cb(self, self.opts.user);
        }
    }

    const menu_object_path = "/MenuBar";

    /// Export the global menu on the bus and publish its address to KWin.
    fn setupMenu(self: *Window, items: []const dbusmenu.Item) void {
        const server = dbusmenu.Server.init(self.gpa, .{
            .items = items,
            .object_path = menu_object_path,
            .ctx = self.opts.user,
        }) catch |err| {
            std.log.warn("zrame: global menu unavailable ({s})", .{@errorName(err)});
            return;
        };
        self.menu = server;

        const mgr = self.appmenu_manager orelse {
            std.log.warn("zrame: compositor has no org_kde_kwin_appmenu — menu is on the bus but not shown", .{});
            return;
        };
        const surface = self.surface orelse return;
        const name = server.uniqueName() orelse return;
        const obj = mgr.create(surface);
        self.appmenu_obj = obj;
        obj.setAddress(name, menu_object_path);
        _ = wl.wl_display_flush(self.display);
    }

    /// Animation heartbeat: drain the timerfd, measure real elapsed `dt`, tick every
    /// panel, and repaint. When nothing wants more frames, disarm so `poll` blocks idle.
    fn onTimerTick(self: *Window) void {
        var expirations: u64 = 0;
        _ = posix.read(self.timer_fd, std.mem.asBytes(&expirations)) catch {};
        const now = monotonicNs();
        const dt: f32 = if (self.last_tick_ns != 0)
            @min(@as(f32, @floatFromInt(now - self.last_tick_ns)) / 1_000_000_000.0, 0.1)
        else
            0.016;
        self.last_tick_ns = now;
        const panels_active = self.panels.tick(dt, self.host());
        // Partial damage if EVERY panel can declare its own area; a single
        // panel without `dirtyBounds` is enough to fall back to the conservative full.
        switch (self.panels.dirtyBounds(self.host())) {
            .rect => |r| {
                self.needs_redraw = true;
                self.dirty_rect = if (self.dirty_rect) |cur| plugin.unionOf(cur, r) else r;
            },
            .unknown => self.redrawAll(),
            .none => if (panels_active) self.redrawAll(),
        }
        if (!panels_active) self.disarmTimer();
    }

    /// Arms a FULL redraw: any trigger other than "a new app frame
    /// arrived" (input, panel, style, resize, configure) redraws everything — the
    /// fine granularity for panels (bbox) is a future extension of the seam.
    inline fn redrawAll(self: *Window) void {
        self.needs_redraw = true;
        self.dirty_full = true;
    }

    fn monotonicNs() i64 {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1_000_000_000 + ts.nsec;
    }

    /// Register a panel to draw over the content and receive input before the app
    /// callbacks. `owned` = the registry runs its `deinit` at teardown. Window thread only.
    pub fn addPanel(self: *Window, panel: Panel, owned: bool) !void {
        try self.panels.add(panel, owned);
        self.redrawAll();
    }

    /// Remove a previously added panel by its instance pointer (runs `deinit` if owned).
    pub fn removePanel(self: *Window, ptr: *anyopaque) void {
        self.panels.remove(ptr);
        self.redrawAll();
    }

    /// Load a single plugin `.so` and let it register its panels (see `plugin.loadPlugin`).
    /// Window thread only. The library stays loaded until `deinit`.
    pub fn loadPlugin(self: *Window, path: []const u8) !void {
        const lib = try plugin.loadPlugin(&self.panels, path);
        try self.plugin_libs.append(self.gpa, lib);
        self.redrawAll();
    }

    /// Load every `*.so` in `dir_path`. Missing directory is a no-op; a plugin that fails
    /// to load is logged and skipped, not fatal. Window thread only.
    pub fn loadPluginDir(self: *Window, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |ent| {
            if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".so")) continue;
            const full = try std.fs.path.join(self.gpa, &.{ dir_path, ent.name });
            defer self.gpa.free(full);
            self.loadPlugin(full) catch |e| std.log.warn("zrame: plugin {s} failed to load: {}", .{ ent.name, e });
        }
    }

    /// The narrow interface panels use to reach back into the window (see `plugin.zig`).
    pub fn host(self: *Window) Host {
        return .{ .ptr = self, .vtable = &host_vtable };
    }

    const host_vtable = Host.VTable{ .do = hostDo, .info = hostInfo, .font = hostFont };

    fn hostDo(ptr: *anyopaque, action: plugin.Action) void {
        const self: *Window = @ptrCast(@alignCast(ptr));
        switch (action) {
            .minimize => if (self.toplevel) |t| t.setMinimized(),
            .toggle_maximize => if (self.toplevel) |t| {
                if (self.maximized) t.unsetMaximized() else t.setMaximized();
            },
            .toggle_fullscreen => self.toggleFullscreen(),
            .close => self.closed = true,
            .begin_move => if (self.toplevel) |t| {
                if (self.seat) |s| t.move(s, self.pointer_serial);
            },
            .begin_resize => |edge| if (self.toplevel) |t| {
                if (self.seat) |s| t.resize(s, self.pointer_serial, edge);
            },
            .set_cursor => |shape| self.setCursorShape(shape),
            .request_redraw => self.redrawAll(),
            .create_popup => |spec| _ = self.createPopup(spec) catch {},
            .dismiss_popup => |id| self.dismissPopup(id),
            .enable_text_input => |spec| self.enableTextInput(spec),
            .disable_text_input => self.disableTextInput(),
        }
    }

    /// Request a `wp_cursor_shape_device` shape, skipping the round-trip when unchanged.
    fn setCursorShape(self: *Window, shape: u32) void {
        if (shape == self.cursor_shape) return;
        self.cursor_shape = shape;
        if (self.cursor_device) |d| d.setShape(self.pointer_serial, shape);
    }

    /// Create a secondary surface (`xdg_popup`) for context menus, tooltips, dropdowns, or IME candidate window.
    pub fn createPopup(self: *Window, spec: plugin.PopupSpec) !u32 {
        const wm_base = self.wm_base orelse return error.NoXdgWmBase;
        const compositor = self.compositor orelse return error.NoCompositor;
        const parent_xdg = self.xdg_surface orelse return error.NoXdgSurface;

        const surface = compositor.createSurface();
        errdefer surface.destroy();

        const positioner = wm_base.createPositioner();
        defer positioner.destroy();

        positioner.setAnchorRect(spec.x, spec.y, 1, 1);
        positioner.setSize(@intCast(@max(1, spec.w)), @intCast(@max(1, spec.h)));
        const anchor_val = toWaylandAnchor(spec.anchor);
        const gravity_val = toWaylandGravity(spec.gravity);
        if (anchor_val != 0) positioner.setAnchor(anchor_val);
        if (gravity_val != 0) positioner.setGravity(gravity_val);
        positioner.setConstraintAdjustment(15);

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
            if (self.seat) |seat| {
                popup.grab(seat, self.pointer_serial);
            }
        }
        return id;
    }

    /// Dismiss a secondary popup surface by ID (0 = dismiss all).
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

    pub fn setupTextInput(self: *Window, seat: *wl.Seat) void {
        if (self.text_input_manager) |tim| {
            if (self.text_input == null) {
                const ti = tim.getTextInput(seat);
                ti.setListener(&text_input_listener, self);
                self.text_input = ti;
            }
        }
    }

    pub fn enableTextInput(self: *Window, spec: plugin.TextInputSpec) void {
        if (self.text_input) |ti| {
            ti.enable();
            ti.setCursorRectangle(spec.x, spec.y, @intCast(spec.w), @intCast(spec.h));
            const hint_val = toWaylandHint(spec.hint);
            const purpose_val = toWaylandPurpose(spec.purpose);
            if (hint_val != 0 or purpose_val != 0) {
                ti.setContentType(hint_val, purpose_val);
            }
            ti.commit();
            self.text_input_enabled = true;
        }
    }

    pub fn disableTextInput(self: *Window) void {
        if (self.text_input) |ti| {
            if (self.text_input_enabled) {
                ti.disable();
                ti.commit();
                self.text_input_enabled = false;
            }
        }
    }

    fn toWaylandAnchor(anchor: plugin.PopupSpec.Anchor) u32 {
        return switch (anchor) {
            .none => 0,
            .top => 1,
            .bottom => 2,
            .left => 3,
            .right => 4,
            .top_left => 5,
            .bottom_left => 6,
            .top_right => 7,
            .bottom_right => 8,
        };
    }

    fn toWaylandGravity(gravity: plugin.PopupSpec.Gravity) u32 {
        return switch (gravity) {
            .none => 0,
            .top => 1,
            .bottom => 2,
            .left => 3,
            .right => 4,
            .top_left => 5,
            .bottom_left => 6,
            .top_right => 7,
            .bottom_right => 8,
        };
    }

    fn toWaylandHint(hint: plugin.TextInputSpec.Hint) u32 {
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

    fn toWaylandPurpose(purpose: plugin.TextInputSpec.Purpose) u32 {
        return switch (purpose) {
            .normal => 0,
            .alpha => 1,
            .digits => 2,
            .number => 3,
            .phone => 4,
            .url => 5,
            .email => 6,
            .name => 7,
            .password => 8,
            .pin => 9,
            .terminal => 10,
        };
    }

    const popup_listener = wl.XdgPopup.Listener{
        .configure = onPopupConfigure,
        .popup_done = onPopupDone,
    };

    fn onPopupConfigure(data: ?*anyopaque, popup: *wl.XdgPopup, x: i32, y: i32, width: i32, height: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        for (self.active_popups.items) |*p| {
            if (p.popup == popup) {
                p.configured = true;
                p.x = x;
                p.y = y;
                p.w = @intCast(width);
                p.h = @intCast(height);
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

    const popup_xdg_surface_listener = wl.XdgSurface.Listener{
        .configure = onPopupXdgConfigure,
    };

    fn onPopupXdgConfigure(data: ?*anyopaque, xdg_surface: *wl.XdgSurface, serial: u32) callconv(.c) void {
        _ = data;
        xdg_surface.ackConfigure(serial);
    }

    const text_input_listener = wl.ZwpTextInputV3.Listener{
        .enter = onTextInputEnter,
        .leave = onTextInputLeave,
        .preedit_string = onTextInputPreeditString,
        .commit_string = onTextInputCommitString,
        .delete_surrounding_text = onTextInputDeleteSurrounding,
        .done = onTextInputDone,
    };

    fn onTextInputEnter(data: ?*anyopaque, text_input: *wl.ZwpTextInputV3, surface: *wl.Surface) callconv(.c) void {
        _ = text_input;
        _ = surface;
        _ = data;
    }

    fn onTextInputLeave(data: ?*anyopaque, text_input: *wl.ZwpTextInputV3, surface: *wl.Surface) callconv(.c) void {
        _ = text_input;
        _ = surface;
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.preedit_len = 0;
        self.preedit_cursor_begin = -1;
        self.preedit_cursor_end = -1;
        if (self.opts.on_preedit) |cb| cb(self, "", -1, -1, self.opts.user);
    }

    fn onTextInputPreeditString(data: ?*anyopaque, text_input: *wl.ZwpTextInputV3, txt: ?[*:0]const u8, cursor_begin: i32, cursor_end: i32) callconv(.c) void {
        _ = text_input;
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (txt) |t| {
            const span = std.mem.span(t);
            const len = @min(span.len, self.preedit_buf.len);
            @memcpy(self.preedit_buf[0..len], span[0..len]);
            self.preedit_len = len;
        } else {
            self.preedit_len = 0;
        }
        self.preedit_cursor_begin = cursor_begin;
        self.preedit_cursor_end = cursor_end;
    }

    fn onTextInputCommitString(data: ?*anyopaque, text_input: *wl.ZwpTextInputV3, txt: ?[*:0]const u8) callconv(.c) void {
        _ = text_input;
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (txt) |t| {
            const span = std.mem.span(t);
            const len = @min(span.len, self.pending_commit_buf.len);
            @memcpy(self.pending_commit_buf[0..len], span[0..len]);
            self.pending_commit_len = len;
        } else {
            self.pending_commit_len = 0;
        }
    }

    fn onTextInputDeleteSurrounding(_: ?*anyopaque, _: *wl.ZwpTextInputV3, _: u32, _: u32) callconv(.c) void {}

    fn onTextInputDone(data: ?*anyopaque, text_input: *wl.ZwpTextInputV3, serial: u32) callconv(.c) void {
        _ = text_input;
        _ = serial;
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.pending_commit_len > 0) {
            const commit_bytes = self.pending_commit_buf[0..self.pending_commit_len];
            if (self.opts.on_text) |cb| {
                var i: usize = 0;
                while (i < commit_bytes.len) {
                    const cp_len = std.unicode.utf8ByteSequenceLength(commit_bytes[i]) catch 1;
                    if (i + cp_len <= commit_bytes.len) {
                        var b: [4]u8 = .{ 0, 0, 0, 0 };
                        @memcpy(b[0..cp_len], commit_bytes[i .. i + cp_len]);
                        cb(self, b, @intCast(cp_len), self.opts.user);
                        i += cp_len;
                    } else break;
                }
            }
            self.pending_commit_len = 0;
        }

        if (self.opts.on_preedit) |cb| {
            cb(self, self.preedit_buf[0..self.preedit_len], self.preedit_cursor_begin, self.preedit_cursor_end, self.opts.user);
        }
        self.redrawAll();
    }

    const PanelCoords = struct { px: f32, py: f32, w: f32, h: f32 };

    fn panelLocal(self: *const Window, sx: f32, sy: f32) PanelCoords {
        const p = self.physPanel();
        return .{ .px = sx - p.m, .py = sy - p.m, .w = p.w, .h = p.h };
    }

    /// The `xdg_toplevel` resize-edge bitmask for a pointer at canvas `(sx,sy)`: an 8px
    /// band around the panel border, corners combining two edges. NONE in the interior.
    fn resizeEdgeAt(self: *const Window, sx: f32, sy: f32) u32 {
        const p = self.panelLocal(sx, sy);
        if (p.px < 0 or p.py < 0 or p.px >= p.w or p.py >= p.h) return wl.RESIZE_EDGE_NONE;
        const band: f32 = self.physPxF(8.0);
        var edge: u32 = 0;
        if (p.py < band) edge |= wl.RESIZE_EDGE_TOP;
        if (p.py >= p.h - band) edge |= wl.RESIZE_EDGE_BOTTOM;
        if (p.px < band) edge |= wl.RESIZE_EDGE_LEFT;
        if (p.px >= p.w - band) edge |= wl.RESIZE_EDGE_RIGHT;
        return edge;
    }

    fn edgeCursor(edge: u32) u32 {
        return switch (edge) {
            wl.RESIZE_EDGE_TOP, wl.RESIZE_EDGE_BOTTOM => wl.CursorShapeDevice.SHAPE_NS_RESIZE,
            wl.RESIZE_EDGE_LEFT, wl.RESIZE_EDGE_RIGHT => wl.CursorShapeDevice.SHAPE_EW_RESIZE,
            wl.RESIZE_EDGE_TOP_LEFT, wl.RESIZE_EDGE_BOTTOM_RIGHT => wl.CursorShapeDevice.SHAPE_NWSE_RESIZE,
            wl.RESIZE_EDGE_TOP_RIGHT, wl.RESIZE_EDGE_BOTTOM_LEFT => wl.CursorShapeDevice.SHAPE_NESW_RESIZE,
            else => wl.CursorShapeDevice.SHAPE_DEFAULT,
        };
    }

    fn hostInfo(ptr: *anyopaque) plugin.Info {
        const self: *Window = @ptrCast(@alignCast(ptr));
        // Physical pixels throughout — consistent with the canvas panels draw on and
        // with the pointer coordinates they hit-test against.
        const p = self.physPanel();
        return .{
            .content = self.contentRect(),
            .panel_w = @intFromFloat(p.w),
            .panel_h = @intFromFloat(p.h),
            .margin = @intFromFloat(p.m),
            .maximized = self.maximized,
            .fullscreen = self.fullscreen,
        };
    }

    fn hostFont(ptr: *anyopaque) ?*text.Font {
        const self: *Window = @ptrCast(@alignCast(ptr));
        return self.textFont() catch null;
    }

    /// Route an input event through the panels; returns true if a panel consumed it.
    /// Any input may have started an animation, so we (cheaply) re-arm the timer, which
    /// self-disarms on the first tick that reports nothing left to animate.
    fn routeInput(self: *Window, event: plugin.Event) bool {
        const consumed = self.panels.route(event, self.host());
        if (consumed) self.redrawAll();
        self.armTimer();
        return consumed;
    }

    fn armTimer(self: *Window) void {
        if (self.timer_armed) return;
        // ~60 Hz repeating tick.
        const spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 16_666_667 },
            .it_value = .{ .sec = 0, .nsec = 16_666_667 },
        };
        _ = linux.timerfd_settime(self.timer_fd, .{}, &spec, null);
        self.timer_armed = true;
        self.last_tick_ns = monotonicNs();
    }

    fn disarmTimer(self: *Window) void {
        if (!self.timer_armed) return;
        const spec = std.mem.zeroes(linux.itimerspec);
        _ = linux.timerfd_settime(self.timer_fd, .{}, &spec, null);
        self.timer_armed = false;
        self.last_tick_ns = 0;
    }

    /// Ask the loop to exit (safe from listeners on the window thread).
    pub fn close(self: *Window) void {
        self.closed = true;
    }

    /// Thread-safe `close`: set the flag and wake the run loop so it exits
    /// even when idle. Safe to call from any thread (e.g. the RPC server).
    pub fn requestClose(self: *Window) void {
        self.closed = true;
        self.wake();
    }

    /// Dynamically update the window's decoration style. Window thread only (it talks
    /// to Wayland objects): call it from an input callback or before [`run`].
    pub fn setStyle(self: *Window, style: Style) !void {
        self.opts.style = style;
        const m = style.margin;
        // Decor in pixel FISICI, come i buffer shm (`redraw` confronta `physPx`
        // del pannello con `buf_w/h`): a dimensione logica, con scala frazionaria
        // del display, `decor.len` divergeva da `pixels.len` e il `@memcpy` del
        // redraw successivo andava in panic ("non-equal lengths"). Se la nuova
        // geometria non coincide con i buffer correnti, `redraw` li ridimensiona
        // e ridipinge di nuovo il decor: qui basta restare coerenti.
        try self.repaintDecor(self.physPx(self.panel_w + 2 * m), self.physPx(self.panel_h + 2 * m));
        self.applySurfaceMetrics();
        self.redrawAll();
    }

    /// Toggles fullscreen mode. It only requests/releases
    /// fullscreen from the compositor: the actual size and state come from the
    /// following `configure` (onToplevelConfigure), which zeroes/restores
    /// gutter/shadow/corners. Window thread only (talks to Wayland objects):
    /// call it from an input callback.
    pub fn toggleFullscreen(self: *Window) void {
        const tl = self.toplevel orelse return;
        if (self.fullscreen) tl.unsetFullscreen() else tl.setFullscreen();
    }

    /// Scales `w`×`h` down (preserving the aspect ratio) so the window
    /// geometry fits the usable area suggested by the compositor (`bounds_*`), with
    /// a small safety margin. Never enlarges. No-op when the bounds
    /// are unknown. Keeps the window from overflowing past the screen.
    fn fitBounds(self: *const Window, w: u32, h: u32) struct { w: u32, h: u32 } {
        if (self.bounds_w == 0 or self.bounds_h == 0) return .{ .w = w, .h = h };
        const inset: u32 = 8;
        const bw: f32 = @floatFromInt(self.bounds_w -| inset);
        const bh: f32 = @floatFromInt(self.bounds_h -| inset);
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        const scale = @min(@as(f32, 1.0), @min(bw / fw, bh / fh));
        if (scale >= 1.0) return .{ .w = w, .h = h };
        return .{
            .w = @max(self.minPanel(), @as(u32, @intFromFloat(@round(fw * scale)))),
            .h = @max(self.minPanel(), @as(u32, @intFromFloat(@round(fh * scale)))),
        };
    }

    /// Resizes the window to the `target_w`×`target_h` panel, capped to the usable area
    /// (`fitBounds` → never off-screen), and re-centers it. On Wayland the client cannot
    /// move its own toplevel: the only way to re-center after a resize is to
    /// unmap and remap the surface (a brief "flash"), so the compositor redoes
    /// the placement and puts it back in the center. No-op in fullscreen/maximized or when the
    /// size doesn't change. Window thread only (input callback or before run).
    pub fn animateResize(self: *Window, target_w: u32, target_h: u32) void {
        if (self.fullscreen or self.maximized) return;
        const fitted = self.fitBounds(target_w, target_h);
        const tw = @max(fitted.w, self.minPanel());
        const th = @max(fitted.h, self.minPanel());
        if (tw == self.panel_w and th == self.panel_h) return; // already at size
        self.panel_w = tw;
        self.panel_h = th;
        // Not yet mapped (init, before the first map): just set it — the first
        // map will center it by itself.
        if (!self.configured or self.surface == null) {
            self.redrawAll();
            return;
        }
        // Unmap and remap so the compositor redoes the placement and re-centers the window
        // (the only hook on Wayland). The xdg protocol mandates the re-map sequence:
        // attach(null)+commit to unmap, then an "initial" commit with no buffer and we
        // WAIT for a new configure before re-attaching pixels (otherwise
        // `unconfigured_buffer`). Marking `configured=false` keeps the loop from redrawing until
        // the configure arrives; onXdgConfigure raises it again and the redraw re-attaches → re-map.
        const surface = self.surface.?;
        surface.attach(null, 0, 0);
        surface.commit();
        self.configured = false;
        surface.commit();
        // A frame callback in flight was tied to the mapped surface: after the unmap
        // it might never arrive. By clearing the flag, the first redraw after the
        // re-map requests a new one; if the old one arrives anyway, handling
        // two is harmless (each `done` destroys only its own wl_callback).
        self.cancelFrameCallback();
        self.redrawAll();
    }

    fn cancelFrameCallback(self: *Window) void {
        if (self.frame_cb) |fcb| {
            fcb.destroy();
            self.frame_cb = null;
        }
        self.frame_cb_pending = false;
    }

    /// The window's text engine, created lazily with the default font
    /// (Hack regular+bold). Use it to draw text in `on_draw`:
    /// `canvas.drawText(try win.textFont(), x, baseline, "…", .{})`.
    pub fn textFont(self: *Window) !*text.Font {
        if (self.font == null) self.font = try text.Font.initDefault(self.gpa);
        return &self.font.?;
    }

    /// Replaces the font's regular face with TTF bytes (e.g. an `@embedFile`).
    pub fn setFont(self: *Window, ttf: []const u8) !void {
        const f = try self.textFont();
        try f.setFace(.regular, ttf, false);
    }

    /// Loads the regular face from a .ttf/.otf file on disk.
    pub fn loadFont(self: *Window, path: []const u8) !void {
        const f = try self.textFont();
        try f.loadFace(.regular, path);
    }

    // --- clipboard --------------------------------------------------------------------

    /// Take ownership of the system selection (the ctrl+C side): copies `bytes` into a
    /// window-owned buffer (replacing any previous copy) and offers it as plain UTF-8
    /// text. Ownership needs a recent input serial, so call it in response to input.
    /// Window thread only (talks to Wayland objects) — call from an input callback.
    pub fn clipboardSet(self: *Window, bytes: []const u8) void {
        const mgr = self.data_device_manager orelse {
            std.log.debug("zrame: clipboardSet senza data_device_manager", .{});
            return;
        };
        const dev = self.data_device orelse {
            std.log.debug("zrame: clipboardSet senza data_device", .{});
            return;
        };
        std.log.debug("zrame: clipboardSet {d} byte, serial {d}", .{ bytes.len, self.input_serial });
        const copy = self.gpa.dupe(u8, bytes) catch return;
        if (self.clip_text.len > 0) self.gpa.free(self.clip_text);
        self.clip_text = copy;
        // Replace any previous source of ours; the compositor would cancel it anyway
        // the moment the new one takes the selection.
        if (self.data_source) |old| {
            old.destroy();
            self.data_source = null;
        }
        const src = mgr.createDataSource();
        src.setListener(&data_source_listener, self);
        src.offer("text/plain;charset=utf-8");
        src.offer("text/plain");
        dev.setSelection(src, self.input_serial);
        self.data_source = src;
        _ = wl.wl_display_flush(self.display);
    }

    /// Our own selection text when WE currently own the clipboard, else null.
    /// The complement of `clipboardGet`'s self-paste hole; the slice is owned
    /// by the window (valid until the next `clipboardSet`/deinit) — copy it to
    /// keep it. Window thread only.
    pub fn clipboardOwn(self: *Window) ?[]const u8 {
        if (self.data_source == null) return null;
        return if (self.clip_text.len > 0) self.clip_text else null;
    }

    /// Read the system selection as UTF-8 text (the ctrl+V side). Returns null when the
    /// clipboard is empty or offers no text, when WE own the selection (use the copy you
    /// passed to `clipboardSet` — it is byte-identical), or on any I/O failure. The
    /// caller frees the returned bytes with `gpa`.
    ///
    /// Window thread only: it performs a nested roundtrip on the display (fine — the
    /// same thread owns it, and our own `send` handler can service another client's
    /// concurrent request during it) and reads the pipe under a ~250 ms poll budget,
    /// capped at 1 MiB.
    pub fn clipboardGet(self: *Window, gpa: Allocator) ?[]u8 {
        if (self.data_source != null) return null; // self-paste: caller's copy is fresher
        const offer = self.selection_offer orelse return null;
        if (self.selection_mime == .none) return null;
        // std.posix.pipe2 doesn't exist in this toolchain: raw syscall like the rest
        // of the file (linux.write/close/eventfd).
        var pipe_fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true })) != .SUCCESS) return null;
        offer.receive(self.selection_mime.mime(), pipe_fds[1]);
        // Close our write end NOW: the source client holds the only other copy, so its
        // close after writing is what turns into our EOF.
        _ = linux.close(pipe_fds[1]);
        // Push the receive out and give the source a chance to answer immediately.
        _ = wl.wl_display_flush(self.display);
        _ = wl.wl_display_roundtrip(self.display);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        const deadline = monotonicNs() + 250 * 1_000_000;
        var buf: [4096]u8 = undefined;
        while (out.items.len < 1024 * 1024) {
            const left_ns = deadline - monotonicNs();
            if (left_ns <= 0) break; // budget exhausted: slow/stuck source
            var pfd = [_]posix.pollfd{.{ .fd = pipe_fds[0], .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&pfd, @intCast(@divTrunc(left_ns, 1_000_000) + 1)) catch break;
            if (ready == 0) break; // timeout
            const n = posix.read(pipe_fds[0], &buf) catch break;
            if (n == 0) break; // EOF: transfer complete
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
        // A previously introduced offer that never became the selection (e.g. a DnD
        // offer we ignored) is dead weight by now — each event introduces a fresh one.
        if (self.pending_offer) |old| {
            if (old != self.selection_offer) old.destroy();
        }
        self.pending_offer = offer;
        self.pending_mime = .none;
        offer.setListener(&data_offer_listener, self);
    }

    // DnD is out of scope: we never accept drags, so enter/leave/motion/drop stay no-ops
    // (an unused DnD offer is reaped by the next data_offer/deinit, see onDataOffer).
    fn onDndEnter(_: ?*anyopaque, _: *wl.DataDevice, _: u32, _: ?*wl.Surface, _: wl.Fixed, _: wl.Fixed, _: ?*wl.DataOffer) callconv(.c) void {}
    fn onDndLeave(_: ?*anyopaque, _: *wl.DataDevice) callconv(.c) void {}
    fn onDndMotion(_: ?*anyopaque, _: *wl.DataDevice, _: u32, _: wl.Fixed, _: wl.Fixed) callconv(.c) void {}
    fn onDndDrop(_: ?*anyopaque, _: *wl.DataDevice) callconv(.c) void {}

    fn onSelection(data: ?*anyopaque, _: *wl.DataDevice, offer: ?*wl.DataOffer) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // The previous selection offer is superseded — the protocol obliges us to
        // destroy it. Null = the clipboard was cleared (its owner quit).
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

    /// A client wants our selection (possibly DURING a `clipboardGet` roundtrip of ours
    /// — fine, this needs no reentrancy into Wayland): write the owned text into the
    /// pipe, looping short writes, then close the fd. A stalled reader is abandoned
    /// after ~1s so a hostile client can't wedge the window thread.
    fn onSourceSend(data: ?*anyopaque, _: *wl.DataSource, _: [*:0]const u8, fd: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        defer _ = linux.close(fd);
        const deadline = monotonicNs() + 1_000_000_000;
        var off: usize = 0;
        while (off < self.clip_text.len) {
            // std.posix.write is absent in this toolchain: raw syscall + errno decode.
            const rc = linux.write(fd, self.clip_text.ptr + off, self.clip_text.len - off);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => {
                    // The receiver made its pipe end non-blocking and it's full: wait
                    // for drain, bounded.
                    if (monotonicNs() >= deadline) return;
                    var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                    const ready = posix.poll(&pfd, 100) catch return;
                    if (ready == 0 and monotonicNs() >= deadline) return;
                    continue;
                },
                else => return, // reader vanished (EPIPE et al.): nothing left to do
            }
            if (rc == 0) return;
            off += rc;
        }
    }

    fn onSourceCancelled(data: ?*anyopaque, source: *wl.DataSource) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // Another client took the selection over: drop ownership. `clip_text` stays —
        // it backs nothing anymore but may be mid-`send` on a concurrent transfer.
        source.destroy();
        if (self.data_source == source) self.data_source = null;
    }

    fn onSourceTarget(_: ?*anyopaque, _: *wl.DataSource, _: ?[*:0]const u8) callconv(.c) void {}
    fn onSourceDndDrop(_: ?*anyopaque, _: *wl.DataSource) callconv(.c) void {}
    fn onSourceDndFinished(_: ?*anyopaque, _: *wl.DataSource) callconv(.c) void {}
    fn onSourceAction(_: ?*anyopaque, _: *wl.DataSource, _: u32) callconv(.c) void {}

    // --- drawing --------------------------------------------------------------------

    /// Smallest panel the chrome stays legible at; also what we advertise as min size.
    fn minPanel(self: *const Window) u32 {
        return 4 * self.opts.style.margin;
    }

    // --- HiDPI helpers -------------------------------------------------------------------
    // The cut: everything that PAINTS (buffer, canvas, panels, pointer coords, app
    // content rect) is in physical pixels; everything the COMPOSITOR sees (window
    // geometry, input/blur regions, configure sizes, viewport destination) stays logical.

    /// The surface's preferred scale (1.0 on non-scaled outputs or without protocol support).
    pub fn scaleFactor(self: *const Window) f32 {
        return @as(f32, @floatFromInt(self.scale120)) / 120.0;
    }
    /// Responsive metrics — desktop is pointer-driven (no touch); dp derives from the
    /// physical content size and the compositor's fractional scale.
    pub fn metrics(self: *Window) facade.Metrics {
        const c = self.contentPx();
        return facade.computeMetrics(self.scaleFactor(), c.w, c.h, self.touch != null);
    }

    /// Logical → physical pixels, rounded.
    pub fn physPx(self: *const Window, v: u32) u32 {
        return @intCast((@as(u64, v) * self.scale120 + 60) / 120);
    }

    /// Physical → logical pixels, rounded — for values handed to the
    /// compositor (subsurface positions, viewport destinations).
    fn logiPx(self: *const Window, v: u32) u32 {
        return @intCast((@as(u64, v) * 120 + self.scale120 / 2) / self.scale120);
    }

    fn physPxF(self: *const Window, v: f32) f32 {
        return v * @as(f32, @floatFromInt(self.scale120)) / 120.0;
    }

    /// Panel geometry in buffer (physical) pixels — the space pointer coords live in.
    /// Width/height are derived as `total − 2·margin` so they always complement the
    /// buffer dimensions exactly (no independent-rounding drift).
    fn physPanel(self: *const Window) struct { m: f32, w: f32, h: f32 } {
        const m = self.opts.style.margin;
        const bw = self.physPx(self.panel_w + 2 * m);
        const bh = self.physPx(self.panel_h + 2 * m);
        const mp = self.physPx(m);
        return .{
            .m = @floatFromInt(mp),
            .w = @floatFromInt(bw - 2 * mp),
            .h = @floatFromInt(bh - 2 * mp),
        };
    }

    /// The chrome style in buffer (physical) pixels — geometry fields only, colors and
    /// alphas untouched. Compositor-facing users (regions, geometry) keep `opts.style`.
    fn paintStyle(self: *const Window) Style {
        var s = self.opts.style;
        s.margin = self.physPx(s.margin);
        s.corner_radius = self.physPxF(s.corner_radius);
        s.shadow_blur = self.physPxF(s.shadow_blur);
        s.shadow_offset_y = self.physPxF(s.shadow_offset_y);
        s.glass_fade_width = self.physPxF(s.glass_fade_width);
        s.content_radius = self.physPxF(s.content_radius);
        s.content_fade_width = self.physPxF(s.content_fade_width);
        s.corner_fade_width = self.physPxF(s.corner_fade_width);
        s.border_anim_width = self.physPxF(s.border_anim_width);
        return s;
    }

    /// Height the title bar steals from the top of the content (0 when disabled or in
    /// fullscreen, where the chrome is hidden).
    fn titlebarHeight(self: *const Window) u32 {
        if (!self.opts.titlebar or self.fullscreen) return 0;
        return @min(self.opts.titlebar_height, self.panel_h);
    }

    pub fn contentRect(self: *Window) Rect {
        // Physical (buffer) pixels — the canvas/panel/pointer space. The title-bar
        // height stays unscaled on purpose: the controls panel draws its bar with its
        // own (unscaled) metrics, and the content must start exactly beneath it.
        const p = self.physPanel();
        const m: u32 = @intFromFloat(p.m);
        const tb = self.titlebarHeight();
        return .{ .x = m, .y = m + tb, .w = @intFromFloat(p.w), .h = @as(u32, @intFromFloat(p.h)) - tb };
    }

    /// Physical (buffer-pixel) size of the content rect — the exact area staged
    /// frames are composed into. Apps that render and `presentRgba` at THIS size
    /// fill the panel edge to edge (no centering gutter on scaled outputs) and
    /// stay 1:1 with the pointer coordinates delivered to `on_mouse`.
    pub fn contentPx(self: *Window) struct { w: u32, h: u32 } {
        const r = self.contentRect();
        return .{ .w = r.w, .h = r.h };
    }

    /// Composite one full window frame into `pixels` (an ARGB8888 buffer sized
    /// `bw`×`bh`). Pure CPU: no windowing-system call happens here. It paints the
    /// chrome decoration, the app `on_draw` overlay, the newest staged content
    /// frame (taken via a lock-light buffer swap), and finally the panels stack.
    ///
    /// This is the platform seam for presentation: every backend — the Wayland
    /// shm path below, or a future Cocoa/Metal path — acquires a writable pixel
    /// buffer its own way, calls this to fill it, then presents it however it can.
    /// `region == null` → full recomposition (historical behavior).
    /// With a region: the decor is copied back only in its rows and
    /// content+panels are redrawn with the canvas clipped to it —
    /// the pixels outside the region keep what's already in the slot (valid
    /// by construction: see `SlotDamage`). The front swap belongs to the caller
    /// (`redraw`), which derives the region itself from the just-arrived frame.
    /// `on_draw` contract note: its output must change only in response to
    /// `request_redraw` (full) — an overlay that changes "on its own" during a
    /// partial redraw would go stale outside the region.
    fn composeFrame(self: *Window, pixels: []u32, bw: u32, bh: u32, region: ?Rect) void {
        var canvas = paint.Canvas.init(pixels, bw, bh);
        if (region) |r0| {
            // Defensive clamp to the buffer (region computed from geometries that a
            // concurrent resize may have outrun).
            const x1 = @min(bw, r0.x +| r0.w);
            const y1 = @min(bh, r0.y +| r0.h);
            if (r0.x < x1 and r0.y < y1) {
                const r = Rect{ .x = r0.x, .y = r0.y, .w = x1 - r0.x, .h = y1 - r0.y };
                var y: u32 = r.y;
                while (y < r.y + r.h) : (y += 1) {
                    const off = @as(usize, y) * bw + r.x;
                    @memcpy(pixels[off .. off + r.w], self.decor[off .. off + r.w]);
                }
                _ = canvas.setClip(r.x, r.y, r.w, r.h);
                chrome.composeContent(&canvas, self.contentRect(), self.frameArea(), &self.mailbox.front, self.paintStyle(), &self.panels, self.host(), self.opts.on_draw, self.opts.user);
            }
            return;
        }
        // Difesa: il decor deve avere esattamente la geometria dei buffer
        // (qualunque percorso l'abbia ridipinto a una taglia diversa).
        if (self.decor.len != pixels.len) self.repaintDecor(bw, bh) catch return;
        @memcpy(pixels, self.decor);
        chrome.composeContent(&canvas, self.contentRect(), self.frameArea(), &self.mailbox.front, self.paintStyle(), &self.panels, self.host(), self.opts.on_draw, self.opts.user);
    }

    /// Wayland present path: size the shm buffers, acquire a free slot, compose
    /// into it, then attach + damage + commit. The composition itself is backend
    /// -agnostic (see `composeFrame`); only the slot acquisition and surface
    /// commit are Wayland-specific.
    fn redraw(self: *Window) !void {
        if (self.frame_cb_pending) {
            self.needs_redraw = true;
            return;
        }
        const m = self.opts.style.margin;
        const bw = self.physPx(self.panel_w + 2 * m);
        const bh = self.physPx(self.panel_h + 2 * m);
        if (bw != self.buf_w or bh != self.buf_h) {
            try self.resizeBuffers(bw, bh);
            // New buffers: the old frame's coordinates are meaningless.
            self.last_front_rect = null;
            self.dirty_full = true;
        }

        const slot = self.freeSlot() orelse return; // both busy: retry on next wake

        // Damage of THIS frame: new app frame → union of the old/new rect
        // (a shrinking frame must clean up the border it uncovers); any
        // other trigger → full. Accumulated on BOTH slots: the back buffer
        // holds the pixels from two commits ago and on its turn will also have to recompose
        // what changed in the meantime.
        self.mailbox.swap();
        var full = self.dirty_full;
        var partial: ?Rect = null;
        if (self.mailbox.front.width > 0) {
            const r = chrome.frameRect(self.frameArea(), self.mailbox.front.width, self.mailbox.front.height);
            if (self.dirty_staged) {
                // First frame (no previous rect) → full.
                if (self.last_front_rect) |prev| partial = plugin.unionOf(prev, r) else full = true;
            }
            self.last_front_rect = r;
        } else if (self.dirty_staged) {
            full = true;
        }
        // Region declared by the panels (animations with `dirtyBounds`).
        if (self.dirty_rect) |dr| partial = if (partial) |p| plugin.unionOf(p, dr) else dr;
        // Redraw with no region information → conservative.
        if (partial == null) full = true;
        self.dirty_full = false;
        self.dirty_staged = false;
        self.dirty_rect = null;
        for (&self.slots) |*s| s.pending.add(full, partial);

        const region: ?Rect = if (slot.pending.full) null else slot.pending.rect;
        slot.pending = .{ .full = false, .rect = null };
        self.composeFrame(slot.pixels, bw, bh, region);

        const surface = self.surface.?;
        surface.attach(slot.buffer, 0, 0);
        if (region) |r| {
            surface.damageBuffer(@intCast(r.x), @intCast(r.y), @intCast(@min(bw -| r.x, r.w)), @intCast(@min(bh -| r.y, r.h)));
        } else {
            surface.damageBuffer(0, 0, @intCast(bw), @intCast(bh));
        }
        // Vsync: request a frame callback for THIS commit (the `frame` request
        // is double-buffered state, it must be emitted before the commit), if there isn't
        // already one in flight. No commit → no callback → the `waitFrame` waiters
        // expire on their timeout (coalescing: paused video doesn't block).
        if (!self.frame_cb_pending) {
            const fcb = surface.frame();
            fcb.setListener(&frame_done_listener, self);
            self.frame_cb = fcb;
            self.frame_cb_pending = true;
        }
        surface.commit();
        slot.busy = true;
        self.needs_redraw = false;
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
            // Grow: tear down the memfd/mmap/pool and reallocate with 50% headroom, so a
            // continuing drag stops re-allocating once it has room.
            self.dropBuffers();
            const cap = total + total / 2;
            const fd = try posix.memfd_create("zrame-shm", linux.MFD.CLOEXEC);
            errdefer _ = linux.close(fd);
            if (linux.errno(linux.ftruncate(fd, @intCast(cap))) != .SUCCESS) return error.ShmSetupFailed;
            const map = try posix.mmap(null, cap, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
            self.shm_fd = fd;
            self.shm_map = map;
            self.pool = self.shm.?.createPool(fd, @intCast(cap));
            self.pool_cap = cap;
        } else {
            // Reuse the existing pool/mapping; only the two buffer objects change geometry.
            for (&self.slots) |*slot| {
                if (slot.buffer) |b| b.destroy();
                slot.buffer = null;
            }
        }

        const map = self.shm_map;
        for (&self.slots, 0..) |*slot, i| {
            const off = i * slot_size;
            slot.buffer = self.pool.?.createBuffer(@intCast(off), @intCast(bw), @intCast(bh), @intCast(stride), wl.SHM_FORMAT_ARGB8888);
            slot.buffer.?.setListener(&buffer_listener, slot);
            slot.pixels = @as([*]u32, @ptrCast(@alignCast(map.ptr + off)))[0 .. @as(usize, bw) * bh];
            slot.busy = false;
        }
        self.buf_w = bw;
        self.buf_h = bh;

        try self.repaintDecor(bw, bh);
        self.applySurfaceMetrics();
    }

    /// (Re)raster the chrome cache at `bw`×`bh`, reusing the allocation when the size
    /// is unchanged (e.g. a pure style swap).
    fn repaintDecor(self: *Window, bw: u32, bh: u32) !void {
        const len = @as(usize, bw) * bh;
        if (self.decor.len != len) {
            if (self.decor.len > 0) self.gpa.free(self.decor);
            self.decor = &.{};
            self.decor = try self.gpa.alloc(u32, len);
        }
        var canvas = paint.Canvas.init(self.decor, bw, bh);
        canvas.drawChrome(self.paintStyle());
    }

    /// Window geometry, input region and blur region all describe the *panel*, not the
    /// buffer: the shadow gutter is invisible to the compositor's window management.
    fn applySurfaceMetrics(self: *Window) void {
        const m: i32 = @intCast(self.opts.style.margin);
        const pw: i32 = @intCast(self.panel_w);
        const ph: i32 = @intCast(self.panel_h);
        self.xdg_surface.?.setWindowGeometry(m, m, pw, ph);

        const input = self.compositor.?.createRegion();
        defer input.destroy();
        input.add(m, m, pw, ph);
        self.surface.?.setInputRegion(input);

        if (self.blur) |blur| {
            const region = self.compositor.?.createRegion();
            defer region.destroy();
            const bi = self.opts.style.blur_inset;
            if (bi > 0.0 and bi < @as(f32, @floatFromInt(self.panel_w)) / 2.0 and bi < @as(f32, @floatFromInt(self.panel_h)) / 2.0) {
                const bi_u: u32 = @intFromFloat(bi);
                const pw_shrunk = self.panel_w - 2 * bi_u;
                const ph_shrunk = self.panel_h - 2 * bi_u;
                const radius = @max(0.0, self.opts.style.corner_radius - bi);
                addRoundedRegion(region, bi_u, pw_shrunk, ph_shrunk, radius);
            } else {
                addRoundedRegion(region, 0, self.panel_w, self.panel_h, self.opts.style.corner_radius);
            }
            blur.setBlurRegion(region);
        }

        // HiDPI: present the physically-sized buffer at the logical window size.
        if (self.viewport) |vp| {
            vp.setDestination(pw + 2 * m, ph + 2 * m);
        }
    }

    // --- listeners --------------------------------------------------------------------

    const registry_listener = wl.Registry.Listener{
        .global = onGlobal,
        .global_remove = onGlobalRemove,
    };

    fn onGlobal(data: ?*anyopaque, registry: *wl.Registry, name: u32, interface: [*:0]const u8, ver: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        const iface = std.mem.span(interface);
        if (std.mem.eql(u8, iface, "wl_compositor")) {
            self.compositor = @ptrCast(registry.bind(name, &wl.wl_compositor_interface, @min(ver, 4)).?);
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(registry.bind(name, &wl.wl_shm_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wl_subcompositor")) {
            self.subcompositor = @ptrCast(registry.bind(name, &wl.wl_subcompositor_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "zwp_linux_dmabuf_v1")) {
            // v2 is enough (create_immed); cap at 4 (v5 changes nothing we use).
            if (ver >= 2)
                self.dmabuf = @ptrCast(registry.bind(name, &wl.zwp_linux_dmabuf_v1_interface, @min(ver, 4)).?);
        } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
            self.wm_base = @ptrCast(registry.bind(name, &wl.xdg_wm_base_interface, @min(ver, 6)).?);
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            const seat: *wl.Seat = @ptrCast(registry.bind(name, &wl.wl_seat_interface, @min(ver, 5)).?);
            seat.setListener(&seat_listener, self);
            self.seat = seat;
            if (self.text_input_manager != null and self.text_input == null) {
                self.setupTextInput(seat);
            }
        } else if (std.mem.eql(u8, iface, "zwp_text_input_manager_v3")) {
            self.text_input_manager = @ptrCast(registry.bind(name, &wl.zwp_text_input_manager_v3_interface, 1).?);
            if (self.seat) |seat| {
                self.setupTextInput(seat);
            }
        } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
            // v3 is current; v1 still covers the selection path we use.
            self.data_device_manager = @ptrCast(registry.bind(name, &wl.wl_data_device_manager_interface, @min(ver, 3)).?);
        } else if (std.mem.eql(u8, iface, "ext_background_effect_manager_v1")) {
            self.blur_manager = @ptrCast(registry.bind(name, &wl.ext_background_effect_manager_v1_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wp_cursor_shape_manager_v1")) {
            self.cursor_shapes = @ptrCast(registry.bind(name, &wl.wp_cursor_shape_manager_v1_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wp_viewporter")) {
            self.viewporter = @ptrCast(registry.bind(name, &wl.wp_viewporter_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wp_fractional_scale_manager_v1")) {
            self.fractional_manager = @ptrCast(registry.bind(name, &wl.wp_fractional_scale_manager_v1_interface, 1).?);
        } else if (std.mem.eql(u8, iface, appmenu_global)) {
            self.appmenu_manager = @ptrCast(registry.bind(name, appmenu_interface, 1).?);
        }
    }

    fn onGlobalRemove(_: ?*anyopaque, _: *wl.Registry, _: u32) callconv(.c) void {}

    const wm_base_listener = wl.XdgWmBase.Listener{ .ping = onPing };

    fn onPing(data: ?*anyopaque, wm_base: *wl.XdgWmBase, serial: u32) callconv(.c) void {
        _ = data;
        wm_base.pong(serial);
    }

    const xdg_surface_listener = wl.XdgSurface.Listener{ .configure = onXdgConfigure };

    fn onXdgConfigure(data: ?*anyopaque, xdg_surface: *wl.XdgSurface, serial: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        xdg_surface.ackConfigure(serial);
        self.configured = true;
        self.redrawAll();
        // Before the loop is pumping (init roundtrips) draw right here so the window maps.
        // Once running, only flag it: the loop paints once per iteration, so a burst of
        // resize configures collapses into a single redraw instead of one apiece.
        if (!self.running) self.redraw() catch {};
    }

    const toplevel_listener = wl.XdgToplevel.Listener{
        .configure = onToplevelConfigure,
        .close = onToplevelClose,
        .configure_bounds = onConfigureBounds,
        .wm_capabilities = onWmCapabilities,
    };

    // wl_array: Wayland dynamic buffer. `states` of xdg_toplevel.configure is a
    // u32 array (state enum); `size` is in bytes.
    const WlArray = extern struct { size: usize, alloc: usize, data: ?[*]u32 };

    fn onToplevelConfigure(data: ?*anyopaque, _: *wl.XdgToplevel, width: i32, height: i32, states: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));

        // Detect fullscreen and maximized from the compositor's states array.
        var is_fs = false;
        var is_max = false;
        if (states) |sp| {
            const arr: *const WlArray = @ptrCast(@alignCast(sp));
            if (arr.data) |d| {
                const n = arr.size / @sizeOf(u32);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    if (d[i] == wl.STATE_FULLSCREEN) is_fs = true;
                    if (d[i] == wl.STATE_MAXIMIZED) is_max = true;
                }
            }
        }
        self.maximized = is_max;

        // Entering/leaving fullscreen: zero or restore gutter/shadow/corners.
        // The size is carried by the `width`/`height` of this same configure;
        // the decor repaint and geometry are updated by the redraw on resize.
        if (is_fs != self.fullscreen) {
            self.fullscreen = is_fs;
            if (is_fs) {
                self.saved_panel_w = self.panel_w;
                self.saved_panel_h = self.panel_h;
                self.saved_margin = self.opts.style.margin;
                self.saved_radius = self.opts.style.corner_radius;
                self.saved_content_radius = self.opts.style.content_radius;
                self.opts.style.margin = 0;
                self.opts.style.corner_radius = 0;
                // Content without rounded corners too: fullscreen has no
                // frame/border, the content fills edge to edge.
                self.opts.style.content_radius = 0;
            } else {
                self.opts.style.margin = self.saved_margin;
                self.opts.style.corner_radius = self.saved_radius;
                self.opts.style.content_radius = self.saved_content_radius;
                // If the compositor suggests no size (0), fall back to
                // the pre-fullscreen one.
                if (width <= 0) self.panel_w = self.saved_panel_w;
                if (height <= 0) self.panel_h = self.saved_panel_h;
            }
        }

        // The suggested size is window geometry — the panel. 0 means "you pick".
        if (width > 0) self.panel_w = @max(@as(u32, @intCast(width)), self.minPanel());
        if (height > 0) self.panel_h = @max(@as(u32, @intCast(height)), self.minPanel());
    }

    fn onToplevelClose(data: ?*anyopaque, _: *wl.XdgToplevel) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // the app may veto (unsaved changes): it will call close() itself later
        if (self.opts.on_close_request) |cb| {
            if (!cb(self, self.opts.user)) {
                self.invalidate(); // repaint so the app can show its own dialog
                return;
            }
        }
        self.closed = true;
    }

    fn onConfigureBounds(data: ?*anyopaque, _: *wl.XdgToplevel, width: i32, height: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // Maximum usable area for the window geometry (0 = "no constraint").
        if (width > 0) self.bounds_w = @intCast(width);
        if (height > 0) self.bounds_h = @intCast(height);
        // If the current content exceeds the usable area, bring it back in: before
        // mapping (init roundtrip) instantly, and with the window alive using
        // an animation. This way a document taller than the screen doesn't overflow below.
        const fitted = self.fitBounds(self.panel_w, self.panel_h);
        if (fitted.w != self.panel_w or fitted.h != self.panel_h) {
            if (self.running) {
                self.animateResize(fitted.w, fitted.h);
            } else {
                self.panel_w = fitted.w;
                self.panel_h = fitted.h;
            }
        }
    }
    fn onWmCapabilities(_: ?*anyopaque, _: *wl.XdgToplevel, _: ?*anyopaque) callconv(.c) void {}

    const buffer_listener = wl.Buffer.Listener{ .release = onBufferRelease };

    fn onBufferRelease(data: ?*anyopaque, _: *wl.Buffer) callconv(.c) void {
        const slot: *BufferSlot = @ptrCast(@alignCast(data.?));
        slot.busy = false;
    }

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
        // Keys keep flowing to `on_key` as raw evdev codes regardless; the keymap only
        // feeds the layout-correct `on_text` translation. Any failure below just leaves
        // `xkb_state` null → on_text never fires (apps fall back to their own mapping).
        if (format != wl.KEYBOARD_KEYMAP_FORMAT_XKB_V1 or size == 0) return;
        const map = posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch return;
        defer posix.munmap(map);
        if (self.xkb_context == null) self.xkb_context = xkb.xkb_context_new(xkb.CONTEXT_NO_FLAGS);
        const ctx = self.xkb_context orelse return;
        // The blob is NUL-terminated per protocol (`size` includes the terminator).
        const keymap = xkb.xkb_keymap_new_from_string(ctx, @ptrCast(map.ptr), xkb.KEYMAP_FORMAT_TEXT_V1, xkb.KEYMAP_COMPILE_NO_FLAGS) orelse return;
        const state = xkb.xkb_state_new(keymap) orelse {
            xkb.xkb_keymap_unref(keymap);
            return;
        };
        // A new keymap (layout switch, keyboard hotplug) replaces the old one wholesale.
        if (self.xkb_state) |st| xkb.xkb_state_unref(st);
        if (self.xkb_keymap) |km| xkb.xkb_keymap_unref(km);
        self.xkb_keymap = keymap;
        self.xkb_state = state;
    }

    fn onKeyEnter(_: ?*anyopaque, _: *wl.Keyboard, _: u32, _: ?*wl.Surface, _: ?*anyopaque) callconv(.c) void {}
    fn onKeyLeave(data: ?*anyopaque, _: *wl.Keyboard, _: u32, _: ?*wl.Surface) callconv(.c) void {
        // Focus gone: the release for a held key will never arrive — stop repeating, and
        // deliver the releases ourselves so the app's modifier state is not left stuck.
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.cancelRepeat();
        var it = self.held_keys.iterator(.{});
        while (it.next()) |k| {
            const key: u32 = @intCast(k);
            if (!self.routeInput(.{ .key = .{ .key = key, .pressed = false } })) {
                if (self.opts.on_key) |cb| cb(self, key, 0, self.opts.user);
            }
        }
        self.held_keys = .empty;
    }

    fn onKey(data: ?*anyopaque, _: *wl.Keyboard, serial: u32, _: u32, key: u32, state: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.input_serial = serial;
        const pressed = state == wl.KEYBOARD_KEY_STATE_PRESSED;
        if (key < 256) self.held_keys.setValue(key, pressed);
        if (!pressed and key == self.repeat_key) self.cancelRepeat();
        if (self.routeInput(.{ .key = .{ .key = key, .pressed = pressed } })) return;
        // Repeat is armed only once a panel has had first refusal: a panel-owned
        // key (menu navigation, popup dismissal) must not resurface at the app
        // via synthetic repeat ticks after the panel already claimed the press.
        if (pressed) self.armRepeat(key);
        if (key == wl.KEY_ESC and pressed) {
            // Layered dismissal: the topmost registered layer eats this ESC.
            if (self.n_dismissables > 0) {
                self.n_dismissables -= 1;
                const d = self.dismissables[self.n_dismissables];
                d.dismiss(d.ctx);
            } else if (self.opts.close_on_esc) self.closed = true;
        }
        if (self.opts.on_key) |cb| cb(self, key, state, self.opts.user);
        if (pressed) self.emitText(key);
    }

    /// Start (or retarget — a newer key steals the repeat, like every toolkit) the
    /// repeat timer for `key`, if the keymap marks it as repeating. No keymap →
    /// no repeat, matching `on_text` degrading in the same situation.
    fn armRepeat(self: *Window, key: u32) void {
        if (self.repeat_rate <= 0) return;
        const km = self.xkb_keymap orelse return;
        if (xkb.xkb_keymap_key_repeats(km, key + 8) == 0) return;
        self.repeat_key = key;
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
        const spec = std.mem.zeroes(linux.itimerspec);
        _ = linux.timerfd_settime(self.repeat_fd, .{}, &spec, null);
    }

    /// A repeat tick: re-deliver the held key as synthetic presses, exactly like
    /// `onKey` minus the layer/ESC bookkeeping (a repeat never dismisses a popup).
    /// Multiple expirations (loop stalled by a redraw) are honored, capped so a
    /// long stall can't flood the app.
    fn onRepeatTick(self: *Window) void {
        var expirations: u64 = 0;
        _ = posix.read(self.repeat_fd, std.mem.asBytes(&expirations)) catch return;
        if (self.repeat_key == 0) return;
        const n: u64 = @min(expirations, 8);
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            if (self.opts.on_key) |cb| cb(self, self.repeat_key, wl.KEYBOARD_KEY_STATE_PRESSED, self.opts.user);
            self.emitText(self.repeat_key);
        }
    }

    /// Layout-correct text for a pressed evdev key, additive to `on_key`: 1..4 UTF-8
    /// bytes via xkbcommon (keycode = evdev + 8), control chars and DEL skipped.
    fn emitText(self: *Window, key: u32) void {
        const cb = self.opts.on_text orelse return;
        const st = self.xkb_state orelse return;
        var buf: [8]u8 = undefined;
        const n = xkb.xkb_state_key_get_utf8(st, key + 8, &buf, buf.len);
        if (n < 1 or n > 4) return; // no text, or beyond one codepoint
        const len: u8 = @intCast(n);
        if (len == 1 and (buf[0] < 0x20 or buf[0] == 0x7f)) return;
        var bytes: [4]u8 = .{ 0, 0, 0, 0 };
        @memcpy(bytes[0..len], buf[0..len]);
        cb(self, bytes, len, self.opts.user);
    }

    fn onKeyModifiers(data: ?*anyopaque, _: *wl.Keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // Feed the compositor-authoritative masks straight into xkb, so shifted/altgr
        // text comes out right. `group` is the effective layout index.
        if (self.xkb_state) |st| _ = xkb.xkb_state_update_mask(st, depressed, latched, locked, 0, 0, group);
    }
    fn onKeyRepeatInfo(data: ?*anyopaque, _: *wl.Keyboard, rate: i32, delay: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.repeat_rate = rate;
        self.repeat_delay = delay;
        if (rate <= 0) self.cancelRepeat(); // compositor says: no repeat
    }

    // --- touch: the primary finger is synthesized as a pointer (down→press, motion, up→release),
    //     so every zrame app is usable with touch without changes. Multi-touch (pinch) may
    //     expose a dedicated callback later.
    const touch_listener = wl.Touch.Listener{
        .down = onTouchDown,
        .up = onTouchUp,
        .motion = onTouchMotion,
        .frame = onTouchFrame,
        .cancel = onTouchCancel,
        .shape = onTouchShape,
        .orientation = onTouchOrientation,
    };

    pub const Dismissable = struct {
        ctx: ?*anyopaque,
        dismiss: *const fn (ctx: ?*anyopaque) void,
    };

    /// Register a dismissable layer (popup, panel, overlay): the next ESC
    /// closes it instead of the window. LIFO — the last pushed goes first.
    /// Window-thread only; push from callbacks or before `run`.
    pub fn pushDismissable(self: *Window, ctx: ?*anyopaque, dismiss: *const fn (ctx: ?*anyopaque) void) void {
        if (self.n_dismissables == self.dismissables.len) return;
        self.dismissables[self.n_dismissables] = .{ .ctx = ctx, .dismiss = dismiss };
        self.n_dismissables += 1;
    }

    /// Remove a layer that dismissed itself by other means (click-away, key).
    pub fn removeDismissable(self: *Window, ctx: ?*anyopaque) void {
        var i: usize = 0;
        while (i < self.n_dismissables) {
            if (self.dismissables[i].ctx == ctx) {
                std.mem.copyForwards(
                    Dismissable,
                    self.dismissables[i .. self.n_dismissables - 1],
                    self.dismissables[i + 1 .. self.n_dismissables],
                );
                self.n_dismissables -= 1;
            } else i += 1;
        }
    }

    /// App origin for pointer coordinates: the live dmabuf frame's rect when
    /// the video plane is up, else the staged-frame math of `chrome.appOrigin`.
    fn appOriginPx(self: *Window) struct { x: f32, y: f32 } {
        if (self.video_rect) |r|
            return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y) };
        const o = chrome.appOrigin(self.frameArea(), &self.mailbox.front);
        return .{ .x = o.x, .y = o.y };
    }

    fn touchEmitMotion(self: *Window, fx: f32, fy: f32) void {
        self.pointer_x = fx;
        self.pointer_y = fy;
        if (self.routeInput(.{ .motion = .{ .x = fx, .y = fy } })) return;
        // Mouse in APP coordinates, like the pointer path (see `MouseEvent`).
        if (self.opts.on_mouse) |cb| {
            const o = self.appOriginPx();
            _ = cb(self, .{ .motion = .{ .x = fx - o.x, .y = fy - o.y } }, self.opts.user);
        }
    }

    fn touchEmitButton(self: *Window, pressed: bool) void {
        const state: u32 = if (pressed) wl.POINTER_BUTTON_STATE_PRESSED else 0;
        if (self.routeInput(.{ .button = .{ .x = self.pointer_x, .y = self.pointer_y, .button = wl.BTN_LEFT, .pressed = pressed } })) return;
        if (self.opts.on_mouse) |cb| _ = cb(self, .{ .button = .{ .button = wl.BTN_LEFT, .state = state } }, self.opts.user);
    }

    fn onTouchDown(data: ?*anyopaque, _: *wl.Touch, _: u32, _: u32, _: ?*wl.Surface, id: i32, x: wl.Fixed, y: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.touch_id != -1) return; // a single primary finger at a time
        self.touch_id = id;
        const s = self.scaleFactor();
        self.touchEmitMotion(wl.fixedToF32(x) * s, wl.fixedToF32(y) * s);
        self.touchEmitButton(true);
    }

    fn onTouchMotion(data: ?*anyopaque, _: *wl.Touch, _: u32, id: i32, x: wl.Fixed, y: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (id != self.touch_id) return;
        const s = self.scaleFactor();
        self.touchEmitMotion(wl.fixedToF32(x) * s, wl.fixedToF32(y) * s);
    }

    fn onTouchUp(data: ?*anyopaque, _: *wl.Touch, _: u32, _: u32, id: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (id != self.touch_id) return;
        self.touchEmitButton(false);
        self.touch_id = -1;
    }

    fn onTouchCancel(data: ?*anyopaque, _: *wl.Touch) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.touch_id == -1) return;
        self.touchEmitButton(false);
        self.touch_id = -1;
    }

    fn onTouchFrame(_: ?*anyopaque, _: *wl.Touch) callconv(.c) void {}
    fn onTouchShape(_: ?*anyopaque, _: *wl.Touch, _: i32, _: wl.Fixed, _: wl.Fixed) callconv(.c) void {}
    fn onTouchOrientation(_: ?*anyopaque, _: *wl.Touch, _: i32, _: wl.Fixed) callconv(.c) void {}

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
        .axis_relative_direction = onPointerAxisRelDir,
    };

    fn onPointerEnter(data: ?*anyopaque, _: *wl.Pointer, serial: u32, _: ?*wl.Surface, _: wl.Fixed, _: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.pointer_serial = serial;
        self.cursor_shape = wl.CursorShapeDevice.SHAPE_DEFAULT;
        if (self.cursor_device) |device| device.setShape(serial, wl.CursorShapeDevice.SHAPE_DEFAULT);
    }

    fn onPointerLeave(data: ?*anyopaque, _: *wl.Pointer, _: u32, _: ?*wl.Surface) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // Broadcast to every panel (none consumes `leave`) so hover states fade out,
        // then hand it to the app. `routeInput` arms the animation timer, so the fade
        // actually plays out.
        _ = self.routeInput(.leave);
        if (self.opts.on_mouse) |cb| _ = cb(self, .leave, self.opts.user);
    }
    fn onPointerMotion(data: ?*anyopaque, _: *wl.Pointer, _: u32, x: wl.Fixed, y: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // Pointer events arrive in logical surface coords; everything client-side
        // (canvas, panels, app) lives in physical buffer pixels.
        const s = self.scaleFactor();
        const fx = wl.fixedToF32(x) * s;
        const fy = wl.fixedToF32(y) * s;
        self.pointer_x = fx;
        self.pointer_y = fy;
        if (self.routeInput(.{ .motion = .{ .x = fx, .y = fy } })) return;
        if (self.opts.on_mouse) |cb| {
            // Mouse in APP coordinates (see `MouseEvent`): canvas minus the origin of the
            // staged/video frame (or of the content rect), so the app hit-tests in the same
            // space it drew in — panels and the resize band stay in canvas space.
            const o = self.appOriginPx();
            const consumed = cb(self, .{ .motion = .{ .x = fx - o.x, .y = fy - o.y } }, self.opts.user);
            if (consumed) {
                // The app owns this motion (e.g. hovering/dragging its own scrollbar):
                // keep the normal cursor, don't flash the resize arrows over its widget.
                self.setCursorShape(wl.CursorShapeDevice.SHAPE_DEFAULT);
                return;
            }
        }
        // Not over a panel/app widget: reflect the resize band in the cursor, else default.
        if (!self.fullscreen and !self.maximized) {
            self.setCursorShape(edgeCursor(self.resizeEdgeAt(fx, fy)));
        } else {
            self.setCursorShape(wl.CursorShapeDevice.SHAPE_DEFAULT);
        }
    }

    fn onPointerButton(data: ?*anyopaque, _: *wl.Pointer, serial: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.pointer_serial = serial;
        self.input_serial = serial;
        const pressed = state == wl.POINTER_BUTTON_STATE_PRESSED;
        if (self.routeInput(.{ .button = .{ .x = self.pointer_x, .y = self.pointer_y, .button = button, .pressed = pressed } })) return;
        // The resize band is window chrome: it wins over the app even when the app
        // content reaches the panel edge (a browser consuming every click would
        // otherwise make a frameless window impossible to resize). It matches the
        // cursor, which already shows the resize arrows over the band unconditionally.
        if (button == wl.BTN_LEFT and pressed and !self.fullscreen and !self.maximized) {
            const edge = self.resizeEdgeAt(self.pointer_x, self.pointer_y);
            if (edge != wl.RESIZE_EDGE_NONE) {
                if (self.seat) |seat| {
                    self.toplevel.?.resize(seat, serial, edge);
                    return;
                }
            }
        }
        if (self.opts.on_mouse) |cb| {
            // App consumed it (e.g. grabbed its own scrollbar) → skip the default
            // window move so the two don't fight over the same click.
            if (cb(self, .{ .button = .{ .button = button, .state = state } }, self.opts.user)) return;
        }
        if (button == wl.BTN_LEFT and state == wl.POINTER_BUTTON_STATE_PRESSED) {
            if (!self.opts.titlebar) {
                // No title bar to grab: keep the panel draggable from near its edge, as
                // before. With a title bar, dragging is the bar's job (see controls.zig).
                const p = self.panelLocal(self.pointer_x, self.pointer_y);
                const grab = self.physPxF(30.0);
                if (p.px < grab or p.py < grab or p.px > p.w - grab or p.py > p.h - grab) {
                    if (self.seat) |seat| self.toplevel.?.move(seat, serial);
                }
            }
        }
    }

    fn onPointerAxis(data: ?*anyopaque, _: *wl.Pointer, _: u32, axis: u32, value: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.routeInput(.{ .axis = .{ .x = self.pointer_x, .y = self.pointer_y, .axis = axis, .value = wl.fixedToF32(value), .line = true } })) return;
        if (self.opts.on_scroll) |cb| cb(self, axis, value, self.opts.user);
    }
    const fractional_listener = wl.FractionalScale.Listener{ .preferred_scale = onPreferredScale };

    fn onPreferredScale(data: ?*anyopaque, _: *wl.FractionalScale, scale: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (scale == 0 or scale == self.scale120) return;
        self.scale120 = scale;
        // Buffer dimensions derive from the scale: the next redraw resizes, repaints
        // the decor and re-applies the viewport destination.
        self.redrawAll();
    }

    fn onPointerFrame(_: ?*anyopaque, _: *wl.Pointer) callconv(.c) void {}
    fn onPointerAxisSource(_: ?*anyopaque, _: *wl.Pointer, _: u32) callconv(.c) void {}
    fn onPointerAxisStop(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: u32) callconv(.c) void {}
    fn onPointerAxisDiscrete(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: i32) callconv(.c) void {}
    fn onPointerAxisValue120(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: i32) callconv(.c) void {}
    fn onPointerAxisRelDir(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: u32) callconv(.c) void {}
};

/// Build the blur region as the rounded panel itself: one span per row through the
/// corner arcs, one big rect for the body. wl_region only speaks rectangles, so the
/// arc becomes ~radius scanline spans — pixel-accurate, so no blur leaks past a corner.
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
        region.add(m + inset, m + y, span, 1); // top arc row
        region.add(m + inset, m + h - 1 - y, span, 1); // bottom arc row
    }
    if (h > 2 * rows) region.add(m, m + rows, w, h - 2 * rows);
}
