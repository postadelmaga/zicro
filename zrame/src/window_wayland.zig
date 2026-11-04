//! # zrame.window (Linux backend) — the glass window over zicro's Wayland window
//!
//! The Wayland transport is zicro's (`zicro/src/window_wayland.zig`): connection, xdg
//! toplevel, shm buffers, HiDPI, input, IME, popups, clipboard, the dmabuf video plane
//! and frame pacing all live there, once for the whole stack. This file adds what zrame
//! owns, exactly as the macOS / web / Android adapters do:
//!
//! - the frameless glass chrome (rounded panel, drop shadow in a transparent margin,
//!   compositor blur), painted into the buffer zicro hands to `on_compose`, cached and
//!   recomposed only where something changed;
//! - the panel stack (title bar, context menu, floating scrollbars, dlopen plugins),
//!   which gets every input before the app and animates off its own timerfd;
//! - the staged-frame mailbox behind `presentRgba`, app-space mouse coordinates, ESC
//!   dismissal, the resize band and drag-to-move;
//! - the Linux desktop integrations: StatusNotifierItem tray and the KDE global menu,
//!   whose sd-bus fds zicro's loop polls.
//!
//! Threading: as zicro — everything runs on the thread that calls `run`; `presentRgba`
//! and the `request*` doors are safe from any thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const linux = std.os.linux;

const zicro = @import("zicro");
const wl = zicro.wl;
const paint = zicro.paint;
const text = zicro.text;
const plugin = @import("plugin.zig");
const controls = @import("controls.zig");
const menu = @import("menu.zig");
const scroll = @import("scroll.zig");
const tray_mod = @import("tray.zig");
const dbusmenu = @import("dbusmenu.zig");

const facade = @import("window.zig");
pub const Style = facade.Style;
pub const Panel = facade.Panel;
pub const Host = facade.Host;
pub const TitlebarStyle = facade.TitlebarStyle;
pub const Options = facade.Options;
pub const TrayConfig = facade.TrayConfig;
pub const MouseEvent = facade.MouseEvent;
pub const Rect = facade.Rect;
pub const DmabufPlane = facade.DmabufPlane;

const chrome = @import("chrome.zig");

/// zicro's Wayland window: the transport underneath.
const Inner = zicro.window.Window;

pub const Window = struct {
    gpa: Allocator,
    opts: Options,
    inner: *Inner = undefined,
    /// zicro's window takes a `std.Io`; the adapter owns one.
    threaded: std.Io.Threaded,

    /// Window geometry (the glass panel), logical px — mirrors zicro's after every
    /// configure. Apps read these.
    panel_w: u32,
    panel_h: u32,
    closed: bool = false,
    fullscreen: bool = false,
    maximized: bool = false,
    /// Last pointer position, buffer px (canvas space).
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,

    // Fullscreen drops the shadow gutter and the corners; restored on the way out.
    saved_margin: u32 = 0,
    saved_radius: f32 = 0,
    saved_content_radius: f32 = 0,

    font: ?text.Font = null,
    panels: plugin.Registry,
    /// Floating egui-style scrollbars, the bottom-most panel on every window; dormant
    /// until the app calls `win.scrollbars.setContent(w, h)`.
    scrollbars: scroll.Scroll = .{ .follow_content = true },
    /// Beats the panel animation clock (~60 Hz) while a panel animates; disarmed when
    /// everything settled, so an idle window blocks.
    timer_fd: posix.fd_t = -1,
    timer_armed: bool = false,
    last_tick_ns: i64 = 0,
    tray: ?*tray_mod.Tray = null,
    menu: ?*dbusmenu.Server = null,
    /// dlopen'd plugin libraries, closed after the panels (their code lives inside).
    plugin_libs: std.ArrayList(std.DynLib) = .empty,

    /// The chrome, painted once per size/style and memcpy'd under every frame.
    decor: []u32 = &.{},
    decor_dirty: bool = true,
    decor_scale: f32 = 0,

    /// Cross-thread app frames: `presentRgba` stages, the compose swaps.
    mailbox: chrome.FrameMailbox = .{},

    // Damage for the next compose: a new app frame damages its rect (and the old one's),
    // panels their `dirtyBounds`, anything else everything.
    dirty_full: bool = true,
    dirty_staged: bool = false,
    dirty_rect: ?Rect = null,
    last_front_rect: ?Rect = null,
    /// `invalidate` from another thread: the `on_draw` overlay changed.
    overlay_dirty: std.atomic.Value(bool) = .init(false),
    /// Gutter on the right of the content kept for the app's own overlay.
    gutter_right: std.atomic.Value(u32) = .init(0),
    /// Last overlay repaint over a live dmabuf video, ms (capped at ~15 Hz).
    last_overlay_ms: i64 = 0,

    /// A panel took the key being delivered: its text and its repeats stay with the
    /// panels too.
    key_consumed: bool = false,
    consumed_key: u32 = 0,

    /// LIFO of dismissable layers: ESC pops the topmost before `close_on_esc` decides.
    dismissables: [8]Dismissable = undefined,
    n_dismissables: usize = 0,

    pub const Dismissable = struct {
        ctx: ?*anyopaque,
        dismiss: *const fn (ctx: ?*anyopaque) void,
    };

    pub fn init(gpa: Allocator, opts: Options) !*Window {
        const tfd = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
        if (linux.errno(tfd) != .SUCCESS) return error.TimerFdFailed;
        const timer_fd: posix.fd_t = @intCast(tfd);
        errdefer _ = linux.close(timer_fd);

        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        const min = 4 * opts.style.margin;
        self.* = .{
            .gpa = gpa,
            .opts = opts,
            .threaded = .init(gpa, .{}),
            .panel_w = @max(opts.width, min),
            .panel_h = @max(opts.height, min),
            .timer_fd = timer_fd,
            .panels = plugin.Registry.init(gpa),
        };
        errdefer {
            self.panels.deinit();
            self.threaded.deinit();
        }

        // Panels before the window: zicro's init roundtrip already composes a frame.
        // Scrollbars at the bottom (borrowed: the Window owns the field), then the title
        // bar, then the context menu on top (it draws over the bar and grabs first).
        try self.panels.add(Panel.of(scroll.Scroll, &self.scrollbars), false);
        if (opts.titlebar) {
            const c = try controls.Controls.create(gpa, opts.titlebar_style, opts.titlebar_height, opts.title);
            try self.panels.add(Panel.of(controls.Controls, c), true);
        }
        if (opts.context_menu) {
            const mnu = try menu.Menu.create(gpa);
            try self.panels.add(Panel.of(menu.Menu, mnu), true);
        }

        self.inner = try Inner.init(gpa, self.threaded.io(), .{
            .title = opts.title,
            .app_id = opts.app_id,
            .width = self.panel_w,
            .height = self.panel_h,
            .margin = opts.style.margin,
            .blur = blurOf(opts.style),
            .min_size = min,
            .hidpi = true,
            .resize_band = false,
            .video_native = opts.video_fit == .native,
            .on_key = innerKey,
            .on_text = innerText,
            .on_preedit = innerPreedit,
            .on_mouse = innerMouse,
            .on_close_request = innerCloseRequest,
            .on_before_compose = innerBeforeCompose,
            .on_compose = innerCompose,
            .on_wake = innerWake,
            .on_configure = innerConfigure,
            .user = self,
        });
        try self.inner.addPoller(.{ .fd = timer_fd, .ctx = self, .process = onTimerTick });
        return self;
    }

    pub fn deinit(self: *Window) void {
        if (self.menu) |mnu| mnu.deinit();
        if (self.tray) |t| t.deinit();
        // Panels first (runs plugin `deinit`s), then the libraries that hold them.
        self.panels.deinit();
        for (self.plugin_libs.items) |*lib| lib.close();
        self.plugin_libs.deinit(self.gpa);
        self.inner.deinit();
        if (self.font) |*f| f.deinit();
        if (self.decor.len > 0) self.gpa.free(self.decor);
        self.mailbox.deinit(self.gpa);
        _ = linux.close(self.timer_fd);
        self.threaded.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// zicro's callbacks carry zicro's window; `inner` is set on the first one (the
    /// init roundtrip composes before `Inner.init` has returned).
    fn from(win: *Inner, user: ?*anyopaque) *Window {
        const self: *Window = @ptrCast(@alignCast(user.?));
        self.inner = win;
        return self;
    }

    fn blurOf(style: Style) zicro.window.Blur {
        return .{ .radius = style.corner_radius, .inset = style.blur_inset };
    }

    // --- public API: geometry --------------------------------------------------------------

    pub fn hasBlur(self: *Window) bool {
        return self.inner.hasBlur();
    }

    /// Buffer px per logical px (1.0 without fractional scaling).
    pub fn scaleFactor(self: *const Window) f32 {
        return self.inner.bufferScale();
    }

    pub fn metrics(self: *Window) facade.Metrics {
        const c = self.contentPx();
        return facade.computeMetrics(self.scaleFactor(), c.w, c.h, self.inner.isTouch());
    }

    /// Logical → physical pixels, rounded.
    pub fn physPx(self: *const Window, v: u32) u32 {
        return self.inner.physPx(v);
    }

    fn physPxF(self: *const Window, v: f32) f32 {
        return self.inner.physPxF(v);
    }

    fn titlebarHeight(self: *const Window) u32 {
        if (!self.opts.titlebar or self.fullscreen) return 0;
        return @min(self.opts.titlebar_height, self.panel_h);
    }

    /// The content rect, buffer px (canvas space): the panel minus the title bar.
    pub fn contentRect(self: *Window) Rect {
        const g = self.inner.geometryPx();
        // The title bar stays unscaled: the controls panel draws it with its own metrics.
        const tb = @min(self.titlebarHeight(), g.h);
        return .{ .x = g.x, .y = g.y + tb, .w = g.w, .h = g.h - tb };
    }

    /// Buffer-pixel size of the content rect: present frames at THIS size to fill the
    /// panel edge to edge, 1:1 with `on_mouse` coordinates.
    pub fn contentPx(self: *Window) struct { w: u32, h: u32 } {
        const r = self.contentRect();
        return .{ .w = r.w, .h = r.h };
    }

    /// The rect a staged frame centers in: the content minus the app's gutter.
    fn frameArea(self: *Window) Rect {
        const c = self.contentRect();
        const g = @min(self.gutter_right.load(.acquire), c.w);
        return .{ .x = c.x, .y = c.y, .w = c.w - g, .h = c.h };
    }

    /// The chrome style in buffer px (geometry fields only).
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

    // --- public API: presentation ----------------------------------------------------------

    /// Stage a straight-alpha RGBA frame. Any thread; the newest frame wins.
    pub fn presentRgba(self: *Window, width: u32, height: u32, rgba: []const u8) void {
        if (self.mailbox.stage(self.gpa, width, height, rgba)) self.inner.wake();
    }

    /// Keep `px` on the right of the content for the app's overlay. Any thread.
    pub fn reserveGutter(self: *Window, px: u32) void {
        self.gutter_right.store(px, .release);
        self.invalidate();
    }

    /// The `on_draw` overlay changed outside the frame rect: recompose all of it on
    /// the next redraw. Any thread.
    pub fn invalidate(self: *Window) void {
        self.overlay_dirty.store(true, .release);
        self.inner.wake();
    }

    pub fn requestResize(self: *Window, width: u32, height: u32) void {
        self.inner.requestResize(width, height);
    }

    pub fn requestClipboardSet(self: *Window, bytes: []const u8) void {
        self.inner.requestClipboardSet(bytes);
    }

    pub fn hideVideo(self: *Window) void {
        self.inner.hideVideo();
    }

    pub fn presentDmabuf(self: *Window, slot: u8, fd: posix.fd_t, width: u32, height: u32, stride: u32, fourcc: u32, modifier: u64) bool {
        return self.inner.presentDmabuf(slot, fd, width, height, stride, fourcc, modifier);
    }

    pub fn presentDmabufPlanes(self: *Window, slot: u8, planes: []const DmabufPlane, width: u32, height: u32, fourcc: u32) bool {
        return self.inner.presentDmabufPlanes(slot, planes, width, height, fourcc);
    }

    pub fn videoBusy(self: *const Window) bool {
        return self.inner.videoBusy();
    }

    /// Block any thread until the compositor's next frame, or `timeout_ms` (false).
    pub fn waitFrame(self: *Window, timeout_ms: u32) bool {
        return self.inner.waitFrame(timeout_ms);
    }

    // --- public API: lifecycle -------------------------------------------------------------

    /// The event loop: blocks until the window is closed or the connection drops.
    pub fn run(self: *Window) !void {
        if (self.tray == null) {
            if (self.opts.tray) |tc| self.setupTray(tc);
        }
        if (self.menu == null) {
            if (self.opts.menu) |items| self.setupMenu(items);
        }
        defer self.closed = true;
        try self.inner.run();
    }

    pub fn close(self: *Window) void {
        self.closed = true;
        self.inner.close();
    }

    /// Thread-safe `close`.
    pub fn requestClose(self: *Window) void {
        self.closed = true;
        self.inner.requestClose();
    }

    pub fn setVisible(self: *Window, show: bool) void {
        self.inner.setVisible(show);
        if (show) self.redrawAll();
    }

    pub fn isVisible(self: *Window) bool {
        return self.inner.isVisible();
    }

    pub fn requestToggleVisible(self: *Window) void {
        self.inner.requestToggleVisible();
    }

    pub fn toggleFullscreen(self: *Window) void {
        self.inner.toggleFullscreen();
    }

    /// Resize the panel to `w`×`h` (kept on screen, re-centered). Window thread.
    pub fn animateResize(self: *Window, target_w: u32, target_h: u32) void {
        self.inner.setContentSize(target_w, target_h);
        self.syncGeometry();
        self.redrawAll();
    }

    /// Swap the decoration style. Window thread.
    pub fn setStyle(self: *Window, style: Style) !void {
        self.opts.style = style;
        self.inner.setSurfaceShape(style.margin, blurOf(style));
        self.inner.setMinSize(4 * style.margin);
        self.decor_dirty = true;
        self.redrawAll();
    }

    fn syncGeometry(self: *Window) void {
        self.panel_w = self.inner.width;
        self.panel_h = self.inner.height;
    }

    /// Any trigger other than a new app frame repaints everything.
    fn redrawAll(self: *Window) void {
        self.dirty_full = true;
        self.inner.needs_redraw = true;
    }

    // --- public API: text, panels, plugins -------------------------------------------------

    /// The window's text engine, created lazily with the default font.
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
        self.redrawAll();
    }

    pub fn removePanel(self: *Window, ptr: *anyopaque) void {
        self.panels.remove(ptr);
        self.redrawAll();
    }

    /// Load a plugin `.so` and let it register its panels. Window thread.
    pub fn loadPlugin(self: *Window, path: []const u8) !void {
        const lib = try plugin.loadPlugin(&self.panels, path);
        try self.plugin_libs.append(self.gpa, lib);
        self.redrawAll();
    }

    /// Load every `*.so` in `dir_path`; a missing directory is a no-op, a failing
    /// plugin is logged and skipped.
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

    pub fn createPopup(self: *Window, spec: plugin.PopupSpec) !u32 {
        return self.inner.createPopup(spec);
    }

    pub fn dismissPopup(self: *Window, id: u32) void {
        self.inner.dismissPopup(id);
    }

    pub fn enableTextInput(self: *Window, spec: plugin.TextInputSpec) void {
        self.inner.enableTextInput(spec);
    }

    pub fn disableTextInput(self: *Window) void {
        self.inner.disableTextInput();
    }

    pub fn clipboardSet(self: *Window, bytes: []const u8) void {
        self.inner.clipboardSet(bytes);
    }

    pub fn clipboardOwn(self: *Window) ?[]const u8 {
        return self.inner.clipboardOwn();
    }

    pub fn clipboardGet(self: *Window, gpa: Allocator) ?[]u8 {
        return self.inner.clipboardGet(gpa);
    }

    /// Register a dismissable layer: the next ESC closes it instead of the window.
    pub fn pushDismissable(self: *Window, ctx: ?*anyopaque, dismiss: *const fn (ctx: ?*anyopaque) void) void {
        if (self.n_dismissables == self.dismissables.len) return;
        self.dismissables[self.n_dismissables] = .{ .ctx = ctx, .dismiss = dismiss };
        self.n_dismissables += 1;
    }

    /// Remove a layer that dismissed itself by other means.
    pub fn removeDismissable(self: *Window, ctx: ?*anyopaque) void {
        var i: usize = 0;
        while (i < self.n_dismissables) {
            if (self.dismissables[i].ctx == ctx) {
                std.mem.copyForwards(Dismissable, self.dismissables[i .. self.n_dismissables - 1], self.dismissables[i + 1 .. self.n_dismissables]);
                self.n_dismissables -= 1;
            } else i += 1;
        }
    }

    // --- host seam ------------------------------------------------------------------------

    pub fn host(self: *Window) Host {
        return .{ .ptr = self, .vtable = &host_vtable };
    }

    const host_vtable = Host.VTable{ .do = hostDo, .info = hostInfo, .font = hostFont };

    fn hostDo(ptr: *anyopaque, action: plugin.Action) void {
        const self: *Window = @ptrCast(@alignCast(ptr));
        switch (action) {
            .minimize => self.inner.setMinimized(),
            .toggle_maximize => self.inner.toggleMaximized(),
            .toggle_fullscreen => self.toggleFullscreen(),
            .close => self.close(),
            .begin_move => self.inner.beginMove(),
            .begin_resize => |edge| self.inner.beginResize(edge),
            .set_cursor => |shape| self.inner.setCursorShape(shape),
            .request_redraw => self.redrawAll(),
            .create_popup => |spec| _ = self.inner.createPopup(spec) catch {},
            .dismiss_popup => |id| self.inner.dismissPopup(id),
            .enable_text_input => |spec| self.inner.enableTextInput(spec),
            .disable_text_input => self.inner.disableTextInput(),
        }
    }

    fn hostInfo(ptr: *anyopaque) plugin.Info {
        const self: *Window = @ptrCast(@alignCast(ptr));
        const g = self.inner.geometryPx();
        return .{
            .content = self.contentRect(),
            .panel_w = g.w,
            .panel_h = g.h,
            .margin = g.x,
            .maximized = self.maximized,
            .fullscreen = self.fullscreen,
        };
    }

    fn hostFont(ptr: *anyopaque) ?*text.Font {
        const self: *Window = @ptrCast(@alignCast(ptr));
        return self.textFont() catch null;
    }

    // --- desktop integrations ---------------------------------------------------------------

    fn setupTray(self: *Window, tc: TrayConfig) void {
        const t = tray_mod.Tray.init(self.gpa, .{
            .id = tc.id,
            .title = tc.title,
            .icon_name = tc.icon_name,
            .tooltip = tc.tooltip,
            .on_activate = onTrayActivate,
            .ctx = self,
        }) catch |err| {
            std.log.warn("zrame: tray icon unavailable ({s})", .{@errorName(err)});
            return;
        };
        self.tray = t;
        self.inner.addPoller(.{ .fd = t.fd(), .ctx = t, .process = trayProcess, .flush = trayFlush }) catch {};
    }

    fn trayProcess(ctx: ?*anyopaque) void {
        const t: *tray_mod.Tray = @ptrCast(@alignCast(ctx.?));
        t.process();
    }

    fn trayFlush(ctx: ?*anyopaque) void {
        const t: *tray_mod.Tray = @ptrCast(@alignCast(ctx.?));
        t.flush();
    }

    fn onTrayActivate(ctx: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(ctx.?));
        if (self.opts.tray) |tc| {
            if (tc.on_activate) |cb| cb(self, self.opts.user);
        }
    }

    const menu_object_path = "/MenuBar";

    /// Export the global menu on the bus and tell KWin its address (appmenu protocol).
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
        self.inner.addPoller(.{ .fd = server.fd(), .ctx = server, .process = menuProcess, .flush = menuFlush }) catch {};
        if (!self.inner.hasAppMenu()) {
            std.log.warn("zrame: compositor has no org_kde_kwin_appmenu — menu is on the bus but not shown", .{});
            return;
        }
        const name = server.uniqueName() orelse return;
        self.inner.setAppMenuAddress(name, menu_object_path);
    }

    fn menuProcess(ctx: ?*anyopaque) void {
        const s: *dbusmenu.Server = @ptrCast(@alignCast(ctx.?));
        s.process();
    }

    fn menuFlush(ctx: ?*anyopaque) void {
        const s: *dbusmenu.Server = @ptrCast(@alignCast(ctx.?));
        s.flush();
    }

    // --- the panel animation clock ----------------------------------------------------------

    fn monotonicNs() i64 {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1_000_000_000 + ts.nsec;
    }

    /// Drain the timerfd, tick every panel with the real `dt`, repaint; disarm when
    /// nothing animates any more.
    fn onTimerTick(ctx: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(ctx.?));
        var expirations: u64 = 0;
        _ = posix.read(self.timer_fd, std.mem.asBytes(&expirations)) catch {};
        const now = monotonicNs();
        const dt: f32 = if (self.last_tick_ns != 0)
            @min(@as(f32, @floatFromInt(now - self.last_tick_ns)) / 1_000_000_000.0, 0.1)
        else
            0.016;
        self.last_tick_ns = now;
        const active = self.panels.tick(dt, self.host());
        // Partial damage only if EVERY panel can declare its own area.
        switch (self.panels.dirtyBounds(self.host())) {
            .rect => |r| {
                self.dirty_rect = if (self.dirty_rect) |cur| plugin.unionOf(cur, r) else r;
                self.inner.needs_redraw = true;
            },
            .unknown => self.redrawAll(),
            .none => if (active) self.redrawAll(),
        }
        if (!active) self.disarmTimer();
    }

    fn armTimer(self: *Window) void {
        if (self.timer_armed) return;
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

    /// Route an input event through the panels (true = a panel consumed it). Any input
    /// may start an animation: the timer is re-armed (it disarms itself when idle).
    fn routeInput(self: *Window, event: plugin.Event) bool {
        const consumed = self.panels.route(event, self.host());
        if (consumed) self.redrawAll();
        self.armTimer();
        return consumed;
    }

    // --- zicro callbacks: composition ----------------------------------------------------

    fn toPx(r: Rect) zicro.window.PxRect {
        return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    }

    fn innerBeforeCompose(win: *Inner, user: ?*anyopaque) void {
        const self = from(win, user);
        self.syncGeometry();
        // The frame's rect is known only after the swap: a new frame damages the union
        // of its old and new rect (a shrinking frame uncovers a border to clean).
        self.mailbox.swap();
        var full = self.dirty_full;
        var partial: ?Rect = null;
        const area = self.frameArea();
        if (self.mailbox.front.width > 0) {
            const r = chrome.frameRect(area, self.mailbox.front.width, self.mailbox.front.height);
            if (self.dirty_staged) {
                if (self.last_front_rect) |prev| partial = plugin.unionOf(prev, r) else full = true;
            }
            self.last_front_rect = r;
        } else if (self.dirty_staged) {
            full = true;
        }
        if (self.dirty_rect) |dr| partial = if (partial) |p| plugin.unionOf(p, dr) else dr;
        self.dirty_full = false;
        self.dirty_staged = false;
        self.dirty_rect = null;
        if (full or partial == null) win.damageAll() else win.damage(toPx(partial.?));
        win.setVideoArea(toPx(area));
    }

    /// Paint one window frame into zicro's buffer: chrome from the cache, the app's
    /// `on_draw` overlay, the staged frame, the panels. With a region only that rect is
    /// repainted (the rest of the buffer holds its last frame, by construction).
    fn innerCompose(win: *Inner, pixels: []u32, bw: u32, bh: u32, region: ?zicro.window.PxRect, user: ?*anyopaque) void {
        const self = from(win, user);
        var canvas = paint.Canvas.init(pixels, bw, bh);
        const stale = self.decor_dirty or self.decor.len != pixels.len or self.decor_scale != self.scaleFactor();
        if (region != null and !stale) {
            const r0 = region.?;
            const x1 = @min(bw, r0.x +| r0.w);
            const y1 = @min(bh, r0.y +| r0.h);
            if (r0.x >= x1 or r0.y >= y1) return;
            const r = Rect{ .x = r0.x, .y = r0.y, .w = x1 - r0.x, .h = y1 - r0.y };
            var y: u32 = r.y;
            while (y < r.y + r.h) : (y += 1) {
                const off = @as(usize, y) * bw + r.x;
                @memcpy(pixels[off .. off + r.w], self.decor[off .. off + r.w]);
            }
            _ = canvas.setClip(r.x, r.y, r.w, r.h);
        } else {
            if (stale) self.repaintDecor(bw, bh) catch return;
            @memcpy(pixels, self.decor);
        }
        chrome.composeContent(&canvas, self.contentRect(), self.frameArea(), &self.mailbox.front, self.paintStyle(), &self.panels, self.host(), self.opts.on_draw, self.opts.user);
    }

    /// (Re)raster the chrome cache at `bw`×`bh`, reusing the allocation at equal size.
    fn repaintDecor(self: *Window, bw: u32, bh: u32) !void {
        const len = @as(usize, bw) * bh;
        if (self.decor.len != len) {
            if (self.decor.len > 0) self.gpa.free(self.decor);
            self.decor = &.{};
            self.decor = try self.gpa.alloc(u32, len);
        }
        var canvas = paint.Canvas.init(self.decor, bw, bh);
        canvas.drawChrome(self.paintStyle());
        self.decor_dirty = false;
        self.decor_scale = self.scaleFactor();
    }

    fn innerWake(win: *Inner, video: bool, user: ?*anyopaque) void {
        const self = from(win, user);
        if (self.mailbox.isFresh()) {
            // A new app frame: damage = its rect, derived after the swap.
            self.dirty_staged = true;
            win.needs_redraw = true;
        } else if (video and self.opts.on_draw != null) {
            // A HUD over a live dmabuf video repaints at ~15 Hz, not at video rate: the
            // parent repaint shares this thread with input dispatch.
            const now_ms = @divTrunc(monotonicNs(), 1_000_000);
            if (now_ms - self.last_overlay_ms >= 66) {
                self.last_overlay_ms = now_ms;
                self.redrawAll();
            }
        }
        if (self.overlay_dirty.swap(false, .acquire)) self.redrawAll();
    }

    fn innerConfigure(win: *Inner, user: ?*anyopaque) void {
        const self = from(win, user);
        self.syncGeometry();
        self.maximized = win.maximized;
        // Fullscreen: no gutter, no shadow, no corners — the content fills the screen.
        if (win.fullscreen != self.fullscreen) {
            self.fullscreen = win.fullscreen;
            if (self.fullscreen) {
                self.saved_margin = self.opts.style.margin;
                self.saved_radius = self.opts.style.corner_radius;
                self.saved_content_radius = self.opts.style.content_radius;
                self.opts.style.margin = 0;
                self.opts.style.corner_radius = 0;
                self.opts.style.content_radius = 0;
            } else {
                self.opts.style.margin = self.saved_margin;
                self.opts.style.corner_radius = self.saved_radius;
                self.opts.style.content_radius = self.saved_content_radius;
            }
            win.setSurfaceShape(self.opts.style.margin, blurOf(self.opts.style));
            win.setMinSize(4 * self.opts.style.margin);
            self.decor_dirty = true;
        }
        self.redrawAll();
    }

    fn innerCloseRequest(win: *Inner, user: ?*anyopaque) bool {
        const self = from(win, user);
        const cb = self.opts.on_close_request orelse return true;
        if (cb(self, self.opts.user)) return true;
        self.invalidate(); // repaint so the app can show its own dialog
        return false;
    }

    // --- zicro callbacks: input -----------------------------------------------------------

    fn innerKey(win: *Inner, key: u32, state: u32, user: ?*anyopaque) void {
        const self = from(win, user);
        const pressed = state != 0;
        const repeat = win.key_repeating;
        self.key_consumed = false;
        // The repeats of a key a panel took stay with the panels.
        if (self.consumed_key != 0 and key == self.consumed_key) {
            if (!pressed) self.consumed_key = 0;
            self.key_consumed = true;
            _ = self.routeInput(.{ .key = .{ .key = key, .pressed = pressed } });
            return;
        }
        if (self.routeInput(.{ .key = .{ .key = key, .pressed = pressed } })) {
            if (pressed) self.consumed_key = key;
            self.key_consumed = true;
            return;
        }
        if (key == wl.KEY_ESC and pressed and !repeat) {
            // Layered dismissal: the topmost registered layer eats this ESC.
            if (self.n_dismissables > 0) {
                self.n_dismissables -= 1;
                const d = self.dismissables[self.n_dismissables];
                d.dismiss(d.ctx);
            } else if (self.opts.close_on_esc) self.close();
        }
        if (self.opts.on_key) |cb| cb(self, key, state, self.opts.user);
    }

    fn innerText(win: *Inner, bytes: [4]u8, len: u8, user: ?*anyopaque) void {
        const self = from(win, user);
        if (win.text_from_key and self.key_consumed) return;
        if (self.opts.on_text) |cb| cb(self, bytes, len, self.opts.user);
    }

    fn innerPreedit(win: *Inner, txt: []const u8, cursor_begin: i32, cursor_end: i32, user: ?*anyopaque) void {
        const self = from(win, user);
        if (self.opts.on_preedit) |cb| cb(self, txt, cursor_begin, cursor_end, self.opts.user);
        self.redrawAll();
    }

    /// App origin for pointer coordinates: the live dmabuf frame's rect while the video
    /// plane is up, else the staged frame's (or the content rect's).
    fn appOriginPx(self: *Window) struct { x: f32, y: f32 } {
        if (self.inner.video_rect) |r| return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y) };
        const o = chrome.appOrigin(self.frameArea(), &self.mailbox.front);
        return .{ .x = o.x, .y = o.y };
    }

    fn innerMouse(win: *Inner, ev: zicro.window.MouseEvent, user: ?*anyopaque) void {
        const self = from(win, user);
        switch (ev.kind) {
            .motion => {
                self.pointer_x = ev.x;
                self.pointer_y = ev.y;
                if (self.routeInput(.{ .motion = .{ .x = ev.x, .y = ev.y } })) return;
                if (self.opts.on_mouse) |cb| {
                    // APP coordinates (see `MouseEvent`): canvas minus the frame origin.
                    const o = self.appOriginPx();
                    if (cb(self, .{ .motion = .{ .x = ev.x - o.x, .y = ev.y - o.y } }, self.opts.user)) {
                        // The app owns this motion: no resize arrows over its widget.
                        win.setCursorShape(wl.CursorShapeDevice.SHAPE_DEFAULT);
                        return;
                    }
                }
                const edge = if (self.fullscreen or self.maximized) wl.RESIZE_EDGE_NONE else win.resizeEdgeAt(ev.x, ev.y);
                win.setCursorShape(Inner.edgeCursor(edge));
            },
            .press, .release => {
                const pressed = ev.kind == .press;
                const state: u32 = @intFromBool(pressed);
                if (self.routeInput(.{ .button = .{ .x = self.pointer_x, .y = self.pointer_y, .button = ev.button, .pressed = pressed } })) return;
                // The resize band is chrome: it wins over the app even when the content
                // reaches the panel edge (else a frameless window could not be resized).
                if (ev.button == wl.BTN_LEFT and pressed and !self.fullscreen and !self.maximized) {
                    const edge = win.resizeEdgeAt(self.pointer_x, self.pointer_y);
                    if (edge != wl.RESIZE_EDGE_NONE) {
                        win.beginResize(edge);
                        return;
                    }
                }
                if (self.opts.on_mouse) |cb| {
                    // Consumed (e.g. the app grabbed its scrollbar): no window move.
                    if (cb(self, .{ .button = .{ .button = ev.button, .state = state } }, self.opts.user)) return;
                }
                if (ev.button == wl.BTN_LEFT and pressed and !self.opts.titlebar) {
                    // No title bar to grab: the panel drags from near its edge.
                    const g = win.geometryPx();
                    const px = self.pointer_x - @as(f32, @floatFromInt(g.x));
                    const py = self.pointer_y - @as(f32, @floatFromInt(g.y));
                    const w: f32 = @floatFromInt(g.w);
                    const h: f32 = @floatFromInt(g.h);
                    const grab = self.physPxF(30.0);
                    if (px < grab or py < grab or px > w - grab or py > h - grab) win.beginMove();
                }
            },
            .scroll => {
                const axis: u32 = if (ev.scroll_dx != 0) 1 else 0;
                const v = if (axis == 1) ev.scroll_dx else ev.scroll_dy;
                if (self.routeInput(.{ .axis = .{ .x = self.pointer_x, .y = self.pointer_y, .axis = axis, .value = v, .line = true } })) return;
                if (self.opts.on_scroll) |cb| cb(self, axis, @intFromFloat(v * 256.0), self.opts.user);
            },
            .leave => {
                // Every panel hears it (hover states fade out), then the app.
                _ = self.routeInput(.leave);
                if (self.opts.on_mouse) |cb| _ = cb(self, .leave, self.opts.user);
            },
        }
    }
};
