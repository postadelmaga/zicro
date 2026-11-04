//! # zrame.window (web backend) — a thin adapter over `zicro.window.Window` (wasm)
//!
//! Same idea as the macOS backend: delegate the OS transport to zicro's window (here the
//! WebAssembly one — buffer + normalized events + the run loop JS drives) and keep zrame's
//! own value on top. Unlike macOS, which uses native decorations, the web backend PAINTS
//! the client-side glass chrome, exactly like Wayland — the whole compositing pipeline
//! (rounded translucent panel, drop shadow, title-bar controls, floating scrollbars) is
//! pure CPU and platform-independent (`chrome.composeContent` + `paint.drawChrome`), so a
//! zrame app renders its glass window inside a browser `<canvas>` with no app changes.
//!
//! One wrinkle: zicro's web canvas is straight-RGBA (a browser `ImageData`), while
//! `drawChrome`/`blitRgba` work in premultiplied ARGB. So we compose into our own premul
//! buffer and convert premul→straight into zicro's canvas each frame.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zicro = @import("zicro");
const paint = zicro.paint;
const text = zicro.text;

const facade = @import("window.zig");
const plugin = @import("plugin.zig");
const scroll = @import("scroll.zig");
const controls = @import("controls.zig");
const menu = @import("menu.zig");
const chrome = @import("chrome.zig");

pub const Style = facade.Style;
pub const Panel = facade.Panel;
pub const Host = facade.Host;
pub const Options = facade.Options;
pub const MouseEvent = facade.MouseEvent;
pub const Rect = facade.Rect;

const SpinLock = chrome.SpinLock;
const Staged = chrome.Staged;

pub const Window = struct {
    gpa: Allocator,
    opts: Options,
    inner: *zicro.window.Window = undefined,

    /// Physical (buffer) window size, learned from every zicro `on_draw`. Named
    /// `panel_w`/`panel_h` (not `win_w`/`win_h`) to satisfy the shared backend
    /// contract every other backend already exposes these fields under.
    panel_w: u32,
    panel_h: u32,
    closed: bool = false,
    fullscreen: bool = false,
    /// Pixels reserved on the right of the content for the app's own overlay
    /// (see `reserveGutter`).
    gutter_right: u32 = 0,
    maximized: bool = false,

    font: ?text.Font = null,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    shift_down: bool = false,

    panels: plugin.Registry,
    scrollbars: scroll.Scroll = .{ .follow_content = true },

    mailbox: chrome.FrameMailbox = .{},

    /// Premultiplied-ARGB scratch the chrome + content compose into, before the
    /// premul→straight conversion into zicro's straight-RGBA canvas.
    decor: []u32 = &.{},
    /// The painted chrome (shadow + glass panel + border), cached in premul and memcpy'd
    /// into `decor` each frame instead of re-running the SDF — the Wayland backend's trick.
    /// Rebuilt only when the size changes. -1 forces the first build.
    chrome_cache: []u32 = &.{},
    cache_w: u32 = 0,
    cache_h: u32 = 0,

    /// 2D-GL engine (Slice 2): when `gl_mode` is enabled, `innerDraw` composes `on_draw`+
    /// panels into a GPU-backed `Canvas` (recording vertices in `gl_rec`) instead of the CPU
    /// rasterizer; JS reads `glBytes()` and renders them via the WebGL2 ubershader. Default OFF.
    gl_mode: bool = false,
    gl_rec: zicro.paint_gl.GlRecorder = undefined,
    gl_iface: paint.GlBackend = undefined,

    pub fn init(gpa: Allocator, opts_in: Options) !*Window {
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);

        // Web default: NO glass frame — on the web the browser tab IS the window, so the
        // content fills the <canvas> edge-to-edge (like the Android backend). Unless the
        // app explicitly asks for a titlebar (the decorated glass-window showcase), the
        // style collapses via `Style.contentFill` — see its doc for the opaque-unless-
        // alpha-0 rule (E8's GPU build relies on the alpha-0 hole to stack a software HUD
        // over a WebGPU canvas).
        var opts = opts_in;
        if (!opts.titlebar) opts.style = opts.style.contentFill();

        self.* = .{
            .gpa = gpa,
            .opts = opts,
            .panel_w = opts.width + 2 * opts.style.margin,
            .panel_h = opts.height + 2 * opts.style.margin,
            .panels = plugin.Registry.init(gpa),
        };

        // 2D-GL recorder (Slice 2): Window lives on heap (gpa.create) → `&self.gl_rec` is
        // stable, so `gl_iface` can point to it for the lifetime of the page.
        self.gl_rec = zicro.paint_gl.GlRecorder.init(gpa);
        self.gl_iface = self.gl_rec.iface();

        // Bottom-most panel: floating scrollbars (borrowed — the Window owns the field).
        try self.panels.add(Panel.of(scroll.Scroll, &self.scrollbars), false);
        if (opts.titlebar) {
            const c = try controls.Controls.create(gpa, opts.titlebar_style, opts.titlebar_height, opts.title);
            try self.panels.add(Panel.of(controls.Controls, c), true);
        }
        if (opts.context_menu) {
            const mnu = try menu.Menu.create(gpa);
            try self.panels.add(Panel.of(menu.Menu, mnu), true);
        }

        // The zicro web window: the transport. It ignores the `std.Io` argument (there is
        // no blocking on a wasm page), so `undefined` is safe.
        self.inner = try zicro.window.Window.init(gpa, undefined, .{
            .title = opts.title,
            .width = self.panel_w,
            .height = self.panel_h,
            .on_draw = innerDraw,
            .on_key = innerKey,
            .on_mouse = innerMouse,
            .on_gesture = innerGesture,
            .user = self,
        });
        return self;
    }

    pub fn deinit(self: *Window) void {
        self.inner.deinit();
        self.panels.deinit();
        if (self.font) |*f| f.deinit();
        self.mailbox.deinit(self.gpa);
        if (self.decor.len > 0) self.gpa.free(self.decor);
        if (self.chrome_cache.len > 0) self.gpa.free(self.chrome_cache);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn run(self: *Window) !void {
        return self.inner.run();
    }
    pub fn requestClose(self: *Window) void {
        self.close();
    }
    pub fn close(self: *Window) void {
        self.closed = true;
        self.inner.requestClose();
    }
    pub fn isVisible(self: *Window) bool {
        return !self.closed;
    }
    pub fn setVisible(self: *Window, visible: bool) void {
        if (!visible) self.close();
    }
    pub fn hasBlur(_: *Window) bool {
        return false; // the compositor blur seam is Wayland's; the browser has none
    }
    pub fn scaleFactor(self: *const Window) f32 {
        return self.inner.scaleFactor();
    }
    pub fn physPx(self: *Window, logical_dp: u32) u32 {
        return facade.physPxScale(self.scaleFactor(), logical_dp);
    }
    /// Responsive metrics (dp size, form factor, touch, density) — the browser reports
    /// devicePixelRatio and touch; the content size is the current canvas.
    pub fn metrics(self: *Window) facade.Metrics {
        const c = self.contentPx();
        return facade.computeMetrics(self.inner.scaleFactor(), c.w, c.h, self.inner.isTouch());
    }
    pub fn videoBusy(_: *const Window) bool {
        return false;
    }
    pub fn waitFrame(_: *Window, _: u32) bool {
        return true;
    }
    /// No video plane on this backend (`presentDmabuf` is a no-op): nothing to hide.
    pub fn hideVideo(_: *Window) void {}

    /// The browser repaints the whole canvas every animation frame, so an overlay
    /// that changed is already on its way: there is no partial-damage path here to
    /// tell, and nothing to wake — the rAF loop never sleeps. (On Wayland this is
    /// what keeps a HUD from freezing over a moving video plane.)
    pub fn invalidate(_: *Window) void {}

    /// Keep `px` pixels of the content for the app's own overlay (a side panel), so
    /// a staged frame centers in the rest. Same contract as Wayland's; here the app
    /// composes into the canvas itself, so recording the reservation is all there is
    /// to do — the app reads it back through `contentPx` and lays out around it.
    pub fn reserveGutter(self: *Window, px: u32) void {
        self.gutter_right = px;
    }

    pub fn presentDmabuf(_: *Window, _: u8, _: i32, _: u32, _: u32, _: u32, _: u32, _: u64) bool {
        return false; // GPU zero-copy is a Linux/Wayland path
    }
    pub fn presentDmabufPlanes(_: *Window, _: u8, _: []const facade.DmabufPlane, _: u32, _: u32, _: u32) bool {
        return false;
    }
    pub fn toggleFullscreen(self: *Window) void {
        self.fullscreen = !self.fullscreen;
    }
    pub fn setStyle(self: *Window, style: Style) !void {
        self.opts.style = style;
    }

    /// Stage an externally-rendered straight-RGBA frame (composed centered in the content).
    pub fn presentRgba(self: *Window, width: u32, height: u32, rgba: []const u8) void {
        if (self.mailbox.stage(self.gpa, width, height, rgba)) {
            self.inner.requestRedraw();
        }
    }

    // --- 2D-GL engine: seam for wasm exports (called by the app in web.zig) ----------------
    pub fn setGl(self: *Window, on: bool) void {
        self.gl_mode = on;
    }
    /// Vertices of the last frame as raw bytes (layout `paint_gl.Vertex`), to upload
    /// into JS-side VBO. Valid after `innerDraw`.
    pub fn glBytes(self: *Window) []const u8 {
        return self.gl_rec.vertexBytes();
    }
    pub fn glCount(self: *Window) usize {
        return self.gl_rec.vertexCount();
    }
    // Glyph/icon atlas (RGBA 2048²): the JS side re-uploads it when it changes (dirty band)
    // and draws the whole frame in ONE draw call.
    pub fn glAtlasPtr(self: *Window) usize {
        return @intFromPtr(self.gl_rec.atlasPtr());
    }
    pub fn glAtlasReady(self: *Window) bool {
        return self.gl_rec.atlasReady();
    }
    pub fn glDirtyLo(self: *Window) u32 {
        return self.gl_rec.dirtyLo();
    }
    pub fn glDirtyHi(self: *Window) u32 {
        return self.gl_rec.dirtyHi();
    }
    pub fn glClearDirty(self: *Window) void {
        self.gl_rec.clearDirty();
    }

    pub fn textFont(self: *Window) !*text.Font {
        if (self.font == null) self.font = try text.Font.initDefault(self.gpa);
        return &self.font.?;
    }
    pub fn setFont(self: *Window, ttf: []const u8) !void {
        const f = try self.textFont();
        try f.setFace(.regular, ttf);
    }
    pub fn addPanel(self: *Window, panel: Panel, owned: bool) !void {
        try self.panels.add(panel, owned);
    }

    // --- geometry -----------------------------------------------------------------------

    fn marginPx(self: *const Window) u32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(self.opts.style.margin)) * self.scaleFactor()));
    }
    fn titlebarPx(self: *const Window) u32 {
        if (!self.opts.titlebar or self.fullscreen) return 0;
        return self.opts.titlebar_height;
    }
    fn panelW(self: *const Window) u32 {
        return self.panel_w -| 2 * self.marginPx();
    }
    fn panelH(self: *const Window) u32 {
        return self.panel_h -| 2 * self.marginPx();
    }
    pub fn contentRect(self: *Window) Rect {
        const m = self.marginPx();
        const tb = self.titlebarPx();
        return .{ .x = @intCast(m), .y = @intCast(m + tb), .w = self.panelW(), .h = self.panelH() -| tb };
    }
    pub fn contentPx(self: *Window) struct { w: u32, h: u32 } {
        const r = self.contentRect();
        return .{ .w = r.w, .h = r.h };
    }

    /// The rect a staged frame centers in: the content minus the app's gutter.
    /// Same contract as Wayland's `frameArea` (see `reserveGutter`).
    fn frameArea(self: *Window) Rect {
        const c = self.contentRect();
        const g = @min(self.gutter_right, c.w);
        return .{ .x = c.x, .y = c.y, .w = c.w - g, .h = c.h };
    }

    fn paintStyle(self: *const Window) Style {
        const f = self.scaleFactor();
        var s = self.opts.style;
        s.margin = @intFromFloat(@round(@as(f32, @floatFromInt(s.margin)) * f));
        s.corner_radius *= f;
        s.shadow_blur *= f;
        s.shadow_offset_y *= f;
        s.glass_fade_width *= f;
        s.content_radius *= f;
        s.content_fade_width *= f;
        s.corner_fade_width *= f;
        s.border_anim_width *= f;
        return s;
    }

    // --- host seam ----------------------------------------------------------------------

    pub fn host(self: *Window) Host {
        return .{ .ptr = self, .vtable = &host_vtable };
    }
    const host_vtable = Host.VTable{ .do = hostDo, .info = hostInfo, .font = hostFont };

    fn hostDo(ptr: *anyopaque, action: plugin.Action) void {
        const self: *Window = @ptrCast(@alignCast(ptr));
        switch (action) {
            .close => self.close(),
            .toggle_fullscreen => self.toggleFullscreen(),
            .minimize, .toggle_maximize, .begin_move, .begin_resize, .set_cursor, .request_redraw, .create_popup, .dismiss_popup, .enable_text_input, .disable_text_input => {},
        }
    }
    fn hostInfo(ptr: *anyopaque) plugin.Info {
        const self: *Window = @ptrCast(@alignCast(ptr));
        return .{
            .content = self.contentRect(),
            .panel_w = self.panelW(),
            .panel_h = self.panelH(),
            .margin = self.marginPx(),
            .maximized = self.maximized,
            .fullscreen = self.fullscreen,
        };
    }
    fn hostFont(ptr: *anyopaque) ?*text.Font {
        const self: *Window = @ptrCast(@alignCast(ptr));
        return self.textFont() catch null;
    }

    // --- composition / input (zicro callbacks) -----------------------------------------

    fn ensure(self: *Window, buf: *[]u32, n: usize) void {
        if (buf.len >= n) return;
        if (buf.len > 0) self.gpa.free(buf.*);
        buf.* = self.gpa.alloc(u32, n) catch &.{};
    }

    /// (Re)paint the chrome into the cache only when the window size changed — the SDF is
    /// the costliest per-pixel work and the panel/shadow are static between resizes.
    fn refreshChrome(self: *Window, n: usize) void {
        if (self.cache_w == self.panel_w and self.cache_h == self.panel_h and self.chrome_cache.len >= n) return;
        self.ensure(&self.chrome_cache, n);
        if (self.chrome_cache.len < n) return;
        @memset(self.chrome_cache[0..n], 0);
        var cc = paint.Canvas.init(self.chrome_cache[0..n], self.panel_w, self.panel_h);
        cc.drawChrome(self.paintStyle());
        self.cache_w = self.panel_w;
        self.cache_h = self.panel_h;
    }

    fn innerDraw(canvas: *paint.Canvas, content: zicro.window.Rect, user: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(user.?));
        self.panel_w = @intCast(@max(content.w, 1));
        self.panel_h = @intCast(@max(content.h, 1));

        _ = self.panels.tick(0.016, self.host());
        self.mailbox.swap();
        const cr = self.contentRect();
        const fa = self.frameArea();

        // 2D-GL engine: composes `on_draw`+panels into a GPU-backed Canvas (records
        // vertices in `gl_rec`); no CPU raster, no premul→straight. Presented JS-side
        // (a WebGL2 ubershader reading `glBytes()`). The glass chrome is disabled on
        // the web backend (titlebar=false).
        if (self.gl_mode) {
            self.gl_rec.reset();
            var gc = paint.Canvas{ .pixels = &.{}, .width = self.panel_w, .height = self.panel_h, .gl = &self.gl_iface };
            chrome.composeContent(&gc, cr, fa, &self.mailbox.front, self.paintStyle(), &self.panels, self.host(), self.opts.on_draw, self.opts.user);
            return;
        }

        const n = @as(usize, self.panel_w) * self.panel_h;
        self.ensure(&self.decor, n);
        if (self.decor.len < n or canvas.pixels.len < n) return;

        // Cached chrome → decor (a memcpy, not a per-pixel SDF), then compose content +
        // panels on top, all in PREMULTIPLIED ARGB…
        self.refreshChrome(n);
        if (self.chrome_cache.len < n) return;
        @memcpy(self.decor[0..n], self.chrome_cache[0..n]);
        var pc = paint.Canvas.init(self.decor[0..n], self.panel_w, self.panel_h);
        chrome.composeContent(&pc, cr, fa, &self.mailbox.front, self.paintStyle(), &self.panels, self.host(), self.opts.on_draw, self.opts.user);

        // …then convert premul→straight into zicro's browser canvas (shared LUT converter).
        paint.premulToStraightRgba(self.decor[0..n], canvas.pixels[0..n]);
    }

    fn innerKey(_: *zicro.window.Window, key: u32, state: u32, user: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(user.?));
        chrome.forwardKey(self, key, state); // key is already evdev (the JS glue translates it)
    }

    fn innerMouse(_: *zicro.window.Window, event: zicro.window.MouseEvent, user: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(user.?));
        if (event.kind == .scroll) {
            const value_px = -event.scroll_dy;
            if (self.panels.route(.{ .axis = .{ .x = event.x, .y = event.y, .axis = 0, .value = value_px, .line = true } }, self.host())) return;
            if (self.opts.on_scroll) |cb| cb(self, 0, @intFromFloat(value_px * 256.0), self.opts.user);
            return;
        }
        chrome.forwardMouse(self, event);
    }

    // Multi-touch gesture from the substrate: like `innerMouse`, reports the center in
    // app coordinates (subtracts the content origin); dx/dy are deltas and pass through.
    fn innerGesture(_: *zicro.window.Window, g: zicro.gesture.Gesture, user: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(user.?));
        chrome.forwardGesture(self, g);
    }
};
