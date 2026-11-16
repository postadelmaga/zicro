//! # zrame.window (macOS, web, Android) — the adapter over zicro's per-frame canvas
//!
//! On these three targets zicro's window drives the frame itself: it pumps the platform
//! loop (AppKit, the browser's rAF, the NDK looper) and hands `on_draw` a canvas every
//! frame. So this ONE adapter only adds what zrame owns on top — the panel stack
//! (floating scrollbars, plugins, and on the web the title bar and context menu), the
//! staged `presentRgba` mailbox, app-space input and the `Host` seam — and the targets
//! differ by a handful of comptime switches:
//!
//! | target  | chrome painted by zrame                    | margin / title bar | text input              |
//! |---------|---------------------------------------------|--------------------|-------------------------|
//! | macOS   | glass + rounded corners, no shadow gutter (macOS draws the shadow); square in full screen | 0 / native | AppKit `on_text`  |
//! | web     | the full glass window, only when the app asks for a `titlebar` (else the tab IS the window) | yes / panels | US keymap |
//! | Android | none: full-screen content                   | 0 / none           | US keymap               |
//!
//! Wayland and Win32 use `window_native.zig` instead: there zicro composes on damage
//! (`on_compose`), with a dmabuf video plane, IME, popups and the desktop integrations.
//!
//! The web canvas is straight RGBA (a browser `ImageData`) while the chrome and the blit
//! work in premultiplied ARGB, so the web composes into its own premul buffer and
//! converts each frame; it can also record the frame for WebGL instead (`setGl`).

const std = @import("std");
const builtin = @import("builtin");
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

const Inner = zicro.window.Window;

const is_cocoa = builtin.os.tag == .macos;
const is_web = builtin.cpu.arch.isWasm();
const is_android = builtin.abi == .android or builtin.abi == .androideabi;
comptime {
    if (@as(u2, @intFromBool(is_cocoa)) + @intFromBool(is_web) + @intFromBool(is_android) != 1)
        @compileError("window_canvas.zig serves macOS, wasm and Android only");
}

/// macOS keeps its native title bar, shadow and window menu: the client-side title bar
/// and context menu are never mounted there, nor on a full-screen Android activity.
const csd_panels = is_web;
/// macOS and Android deliver real layout-aware text (`on_text`) or none; the web and
/// Android hand over raw keys only, so text is synthesized from the US keymap.
const synth_text = !is_cocoa;
/// Smallest content size the window accepts (macOS: a usable window; else a pixel).
const min_w: u32 = if (is_cocoa) 160 else 1;
const min_h: u32 = if (is_cocoa) 120 else 1;
const plugin_ext = if (is_cocoa) ".dylib" else ".so";
/// `std.DynLib` has no wasm form: the web loads no plugin libraries.
const PluginLib = if (is_web) void else std.DynLib;

pub const Window = struct {
    gpa: Allocator,
    opts: Options,
    inner: *Inner = undefined,
    /// zicro's Cocoa window blocks through `std.Io`; the web and NDK ones ignore it.
    threaded: if (is_cocoa) std.Io.Threaded else void,

    /// The canvas size zicro reports every frame, in pixels: the whole surface (on the
    /// web it includes the shadow gutter, see `panelW`).
    panel_w: u32,
    panel_h: u32,
    closed: bool = false,
    /// Android activities are full screen and maximized for good.
    fullscreen: bool = is_android,
    maximized: bool = is_android,

    font: ?text.Font = null,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    /// The last key press went to a panel: its AppKit text must not reach the app.
    key_consumed: bool = false,
    /// Shift state for the synthesized text (`synth_text`).
    shift_down: bool = false,
    /// Pixels on the right of the content kept for the app's own overlay: a staged
    /// frame centers in the rest (see `reserveGutter`).
    gutter_right: u32 = 0,

    panels: plugin.Registry,
    scrollbars: scroll.Scroll = .{ .follow_content = true },
    mailbox: chrome.FrameMailbox = .{},
    /// dlopen'd plugin libraries, closed after the panels (their code lives inside).
    plugin_libs: std.ArrayList(PluginLib) = .empty,

    /// `requestResize` from any thread: (w << 32) | h, 0 = none. AppKit may be touched
    /// only from the main thread (`setFrame` from a worker kills the process: "transaction
    /// must be valid"), so `innerTick` applies it.
    pending_resize: std.atomic.Value(u64) = .init(0),

    // Web only: the premultiplied scratch the frame composes into, the chrome painted
    // once per size/style and memcpy'd under each frame, and the WebGL recorder.
    decor: []u32 = &.{},
    chrome_cache: []u32 = &.{},
    cache_w: u32 = 0,
    cache_h: u32 = 0,
    gl_mode: bool = false,
    gl_rec: if (is_web) zicro.paint_gl.GlRecorder else void = undefined,
    gl_iface: if (is_web) paint.GlBackend else void = undefined,

    pub fn init(gpa: Allocator, opts_in: Options) !*Window {
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);

        // Web default: NO glass frame — the browser tab IS the window, so the content
        // fills the <canvas> edge to edge. Only an app that asks for a title bar (the
        // decorated glass-window showcase) gets the chrome; see `Style.contentFill` for the
        // opaque-unless-alpha-0 rule a WebGPU canvas under a software HUD relies on.
        var opts = opts_in;
        if (is_web and !opts.titlebar) opts.style = opts.style.contentFill();
        const gutter = if (is_web) 2 * opts.style.margin else 0;

        self.* = .{
            .gpa = gpa,
            .opts = opts,
            .threaded = if (is_cocoa) .init(gpa, .{}) else {},
            .panel_w = @max(opts.width, min_w) + gutter,
            .panel_h = @max(opts.height, min_h) + gutter,
            .panels = plugin.Registry.init(gpa),
        };
        errdefer {
            self.panels.deinit();
            if (is_cocoa) self.threaded.deinit();
        }
        if (is_web) {
            // `self` lives on the heap: `&self.gl_rec` is stable for the page's lifetime.
            self.gl_rec = zicro.paint_gl.GlRecorder.init(gpa);
            self.gl_iface = self.gl_rec.iface();
        }

        // Scrollbars at the bottom (borrowed: the Window owns the field), then the title
        // bar, then the context menu on top (it draws over the bar and grabs first).
        try self.panels.add(Panel.of(scroll.Scroll, &self.scrollbars), false);
        if (csd_panels and opts.titlebar) {
            const c = try controls.Controls.create(gpa, opts.titlebar_style, opts.titlebar_height, opts.title);
            try self.panels.add(Panel.of(controls.Controls, c), true);
        }
        if (csd_panels and opts.context_menu) {
            const mnu = try menu.Menu.create(gpa);
            try self.panels.add(Panel.of(menu.Menu, mnu), true);
        }

        // Callbacks a backend has no source for are simply never called (the web and
        // Android have no close veto, no Finder and no IME text).
        self.inner = try Inner.init(gpa, if (is_cocoa) self.threaded.io() else undefined, .{
            .title = opts.title,
            .width = self.panel_w,
            .height = self.panel_h,
            .on_draw = innerDraw,
            .on_key = innerKey,
            .on_text = if (is_cocoa) innerText else null,
            .on_mouse = innerMouse,
            .on_gesture = innerGesture,
            .on_close_request = if (opts.on_close_request != null) innerCloseRequest else null,
            .on_open_file = if (opts.on_open_file != null) innerOpenFile else null,
            .on_tick = if (is_cocoa) innerTick else null,
            .tick_ms = if (is_cocoa) 1 else 0,
            .user = self,
        });
        return self;
    }

    pub fn deinit(self: *Window) void {
        self.inner.deinit();
        // Panels first (runs plugin `deinit`s), then the libraries that hold them.
        self.panels.deinit();
        if (!is_web) for (self.plugin_libs.items) |*lib| lib.close();
        self.plugin_libs.deinit(self.gpa);
        if (self.font) |*f| f.deinit();
        self.mailbox.deinit(self.gpa);
        if (self.decor.len > 0) self.gpa.free(self.decor);
        if (self.chrome_cache.len > 0) self.gpa.free(self.chrome_cache);
        if (is_cocoa) self.threaded.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Android: wire the glue `android_app` into the NDK window (from `android_main`,
    /// before `run`, as a bare zicro app does).
    pub fn attach(self: *Window, app: *zicro.android.android_app) void {
        self.inner.attach(app);
    }

    // --- lifecycle ----------------------------------------------------------------------

    /// The event loop. macOS: blocks until the window closes. Web: returns at once, the
    /// page's rAF drives the frames. Android: runs the activity's looper.
    pub fn run(self: *Window) !void {
        try self.inner.run();
        if (is_cocoa) self.closed = true;
    }

    pub fn close(self: *Window) void {
        self.closed = true;
        if (is_cocoa) self.inner.close() else self.inner.requestClose();
    }

    pub fn requestClose(self: *Window) void {
        self.close();
    }

    pub fn isVisible(self: *Window) bool {
        return !self.closed;
    }

    /// No hidden state on these platforms: hiding closes.
    pub fn setVisible(self: *Window, visible: bool) void {
        if (!visible) self.close();
    }

    pub fn toggleFullscreen(self: *Window) void {
        if (is_android) return; // always full screen
        self.fullscreen = !self.fullscreen;
        if (is_cocoa) self.inner.toggleFullscreen();
    }

    /// Start an interactive window move from the press `on_mouse` is handling, with any
    /// button. macOS only: the page and the activity own their window elsewhere.
    pub fn beginMove(self: *Window) void {
        if (!is_cocoa or self.fullscreen) return;
        self.inner.beginMove();
    }

    /// macOS: resize the content area (the native frame grows around it). AppKit
    /// animates frame changes on its own terms. Main thread.
    pub fn animateResize(self: *Window, target_w: u32, target_h: u32) void {
        if (!is_cocoa or self.fullscreen) return;
        self.inner.setContentSize(@max(target_w, min_w), @max(target_h, min_h));
    }

    /// `animateResize` from any thread: the main thread applies it on its next loop turn
    /// (the last request wins).
    pub fn requestResize(self: *Window, width: u32, height: u32) void {
        const w: u64 = @max(width, 1);
        const h: u64 = @max(height, 1);
        self.pending_resize.store((w << 32) | h, .release);
    }

    pub fn setStyle(self: *Window, style: Style) !void {
        self.opts.style = style;
        self.cache_w = 0; // the web's chrome cache is painted from the style
    }

    // --- geometry -----------------------------------------------------------------------

    /// Buffer px per logical px. macOS renders 1:1 for now; Android's density is not
    /// wired into zrame's geometry yet (it stays 1, so `w_dp` == physical px).
    pub fn scaleFactor(self: *const Window) f32 {
        return if (is_web) self.inner.scaleFactor() else 1.0;
    }

    pub fn physPx(self: *const Window, logical_dp: u32) u32 {
        return zicro.window.physPxScale(self.scaleFactor(), logical_dp);
    }

    pub fn metrics(self: *Window) facade.Metrics {
        const c = self.contentPx();
        const touch = if (@hasDecl(Inner, "isTouch")) self.inner.isTouch() else false;
        return zicro.window.computeMetrics(self.scaleFactor(), c.w, c.h, touch);
    }

    /// No compositor blur seam here; macOS reports its NSVisualEffectView (absent under
    /// Darling/Cocotron).
    pub fn hasBlur(self: *Window) bool {
        return if (is_cocoa) self.inner.hasBlur() else false;
    }

    /// The shadow gutter, buffer px: the web's glass window only.
    fn marginPx(self: *const Window) u32 {
        if (!is_web) return 0;
        return @intFromFloat(@round(@as(f32, @floatFromInt(self.opts.style.margin)) * self.scaleFactor()));
    }

    fn titlebarPx(self: *const Window) u32 {
        if (!csd_panels or !self.opts.titlebar or self.fullscreen) return 0;
        return self.opts.titlebar_height;
    }

    /// The glass panel (the window geometry), buffer px: the canvas minus the gutter.
    fn panelW(self: *const Window) u32 {
        return self.panel_w -| 2 * self.marginPx();
    }

    fn panelH(self: *const Window) u32 {
        return self.panel_h -| 2 * self.marginPx();
    }

    /// The content rect, buffer px (canvas space): the panel minus the title bar.
    pub fn contentRect(self: *Window) Rect {
        const m = self.marginPx();
        const tb = self.titlebarPx();
        return .{ .x = m, .y = m + tb, .w = self.panelW(), .h = self.panelH() -| tb };
    }

    /// Buffer-pixel size of the content rect: present frames at THIS size to fill it.
    pub fn contentPx(self: *Window) struct { w: u32, h: u32 } {
        const r = self.contentRect();
        return .{ .w = r.w, .h = r.h };
    }

    /// The rect a staged frame centers in: the content minus the app's gutter.
    fn frameArea(self: *Window) Rect {
        const c = self.contentRect();
        const g = @min(self.gutter_right, c.w);
        return .{ .x = c.x, .y = c.y, .w = c.w - g, .h = c.h };
    }

    /// The chrome style in buffer px. macOS: the glass and the rounded corners on a
    /// borderless window, no shadow gutter, square in full screen. Android: content fill.
    fn paintStyle(self: *const Window) Style {
        if (is_android) return self.opts.style.contentFill();
        if (is_cocoa) {
            if (self.fullscreen) return self.opts.style.contentFill();
            var s = self.opts.style;
            s.margin = 0;
            return s;
        }
        const f = self.scaleFactor();
        var s = self.opts.style;
        s.margin = self.marginPx();
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

    // --- presentation -------------------------------------------------------------------

    /// Stage a straight-alpha RGBA frame. Any thread; the newest frame wins. macOS needs
    /// no wake (its loop repaints at 60 Hz, and AppKit must not be poked off the main
    /// thread); the web and Android ask for the next frame.
    pub fn presentRgba(self: *Window, width: u32, height: u32, rgba: []const u8) void {
        if (self.mailbox.stage(self.gpa, width, height, rgba) and !is_cocoa) self.inner.requestRedraw();
    }

    /// The whole frame is recomposed here anyway: the changed area is only a hint.
    pub fn presentRgbaRegion(self: *Window, width: u32, height: u32, rgba: []const u8, _: ?Rect) void {
        self.presentRgba(width, height, rgba);
    }

    /// Keep `px` on the right of the content for the app's own overlay. Window thread.
    pub fn reserveGutter(self: *Window, px: u32) void {
        self.gutter_right = px;
    }

    /// The loop repaints every frame: a changed overlay is already on its way.
    pub fn invalidate(_: *Window) void {}

    /// No vsync hook is wired: the caller paces itself. The web answers true, its rAF
    /// being the pacer.
    pub fn waitFrame(_: *Window, _: u32) bool {
        return is_web;
    }

    // The dmabuf video plane is a Wayland path: callers fall back to `presentRgba`.
    pub fn hideVideo(_: *Window) void {}
    pub fn dmabufSupported(_: *Window, _: u32, _: u64) bool {
        return false;
    }
    pub fn contentCornerPx(_: *Window) f32 {
        return 0;
    }
    pub fn presentDmabuf(_: *Window, _: u8, _: i32, _: u32, _: u32, _: u32, _: u32, _: u64) bool {
        return false;
    }
    pub fn presentDmabufPlanes(_: *Window, _: u8, _: []const facade.DmabufPlane, _: u32, _: u32, _: u32) bool {
        return false;
    }
    pub fn presentDmabufPlanesIn(_: *Window, _: u8, _: []const facade.DmabufPlane, _: u32, _: u32, _: u32, _: Rect) bool {
        return false;
    }
    pub fn dmabufAvailable(_: *Window) bool {
        return false;
    }
    pub fn videoBusy(_: *const Window) bool {
        return false;
    }
    pub fn videoSlotFree(_: *Window, _: u8) bool {
        return false;
    }

    // The system clipboard is not wired on these platforms yet.
    pub fn clipboardSet(_: *Window, _: []const u8) void {}
    pub fn clipboardGet(_: *Window, _: Allocator) ?[]u8 {
        return null;
    }

    // --- web: the WebGL path (exports the page's JS reads) ------------------------------

    /// Record the frame for WebGL (`glBytes`) instead of rasterizing it on the CPU.
    pub fn setGl(self: *Window, on: bool) void {
        self.gl_mode = on;
    }
    /// The last frame's vertices (layout `paint_gl.Vertex`), for the JS-side VBO.
    pub fn glBytes(self: *Window) []const u8 {
        return self.gl_rec.vertexBytes();
    }
    pub fn glCount(self: *Window) usize {
        return self.gl_rec.vertexCount();
    }
    /// Glyph/icon atlas (RGBA 2048²): JS re-uploads its dirty band and draws the whole
    /// frame in one call.
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

    // --- text, panels, plugins ----------------------------------------------------------

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
    }

    pub fn removePanel(self: *Window, ptr: *anyopaque) void {
        self.panels.remove(ptr);
    }

    /// Load a plugin library and let it register its panels. macOS (`.dylib`).
    pub fn loadPlugin(self: *Window, path: []const u8) !void {
        const lib = try plugin.loadPlugin(&self.panels, path);
        try self.plugin_libs.append(self.gpa, lib);
    }

    /// Load every plugin library in `dir_path`; a missing directory is a no-op, a
    /// failing plugin is logged and skipped.
    pub fn loadPluginDir(self: *Window, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |ent| {
            if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, plugin_ext)) continue;
            const full = std.fs.path.join(self.gpa, &.{ dir_path, ent.name }) catch continue;
            defer self.gpa.free(full);
            self.loadPlugin(full) catch |e| std.log.warn("zrame: plugin {s} failed to load: {}", .{ ent.name, e });
        }
    }

    // --- host seam (panels reach back into the window) ----------------------------------

    pub fn host(self: *Window) Host {
        return .{ .ptr = self, .vtable = &host_vtable };
    }

    const host_vtable = Host.VTable{ .do = hostDo, .info = hostInfo, .font = hostFont };

    fn hostDo(ptr: *anyopaque, action: plugin.Action) void {
        const self: *Window = @ptrCast(@alignCast(ptr));
        switch (action) {
            .close => self.close(),
            .toggle_fullscreen => self.toggleFullscreen(),
            .minimize => if (is_cocoa) self.inner.setMinimized(),
            .begin_move => if (is_cocoa) self.inner.beginMove(),
            .begin_resize => |edge| if (is_cocoa) self.inner.beginResize(edge),
            // The native zoom button owns maximize; the loop repaints every frame; no
            // popups, cursor shapes or IME on these backends yet.
            .toggle_maximize, .set_cursor, .request_redraw, .create_popup, .dismiss_popup, .enable_text_input, .disable_text_input => {},
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

    // --- zicro callbacks: the frame -----------------------------------------------------

    fn from(user: ?*anyopaque) *Window {
        return @ptrCast(@alignCast(user.?));
    }

    /// macOS, every loop turn on the main thread: apply a pending `requestResize`.
    fn innerTick(_: *Inner, user: ?*anyopaque) void {
        const self = from(user);
        const v = self.pending_resize.swap(0, .acq_rel);
        if (v != 0) self.animateResize(@intCast(v >> 32), @truncate(v));
    }

    fn innerDraw(canvas: *paint.Canvas, content: zicro.window.Rect, user: ?*anyopaque) void {
        const self = from(user);
        self.panel_w = @intCast(@max(content.w, 1));
        self.panel_h = @intCast(@max(content.h, 1));
        // Panels animate on the frame clock (the loop is a steady ~60 Hz).
        _ = self.panels.tick(0.016, self.host());
        self.mailbox.swap();
        const style = self.paintStyle();
        const cr = self.contentRect();
        const fa = self.frameArea();

        if (is_web) {
            self.drawWeb(canvas, style, cr, fa);
            return;
        }
        if (is_cocoa) canvas.drawChrome(style);
        chrome.composeContent(canvas, cr, fa, &self.mailbox.front, style, &self.panels, self.host(), self.opts.on_draw, self.opts.user);
    }

    /// The web frame: recorded for WebGL, or composed in premultiplied ARGB over the
    /// cached chrome and converted into the browser's straight-RGBA canvas.
    fn drawWeb(self: *Window, canvas: *paint.Canvas, style: Style, cr: Rect, fa: Rect) void {
        if (self.gl_mode) {
            self.gl_rec.reset();
            var gc = paint.Canvas{ .pixels = &.{}, .width = self.panel_w, .height = self.panel_h, .gl = &self.gl_iface };
            chrome.composeContent(&gc, cr, fa, &self.mailbox.front, style, &self.panels, self.host(), self.opts.on_draw, self.opts.user);
            return;
        }
        const n = @as(usize, self.panel_w) * self.panel_h;
        self.ensure(&self.decor, n);
        if (self.decor.len < n or canvas.pixels.len < n) return;
        self.refreshChrome(n, style);
        if (self.chrome_cache.len < n) return;
        @memcpy(self.decor[0..n], self.chrome_cache[0..n]);
        var pc = paint.Canvas.init(self.decor[0..n], self.panel_w, self.panel_h);
        chrome.composeContent(&pc, cr, fa, &self.mailbox.front, style, &self.panels, self.host(), self.opts.on_draw, self.opts.user);
        paint.premulToStraightRgba(self.decor[0..n], canvas.pixels[0..n]);
    }

    fn ensure(self: *Window, buf: *[]u32, n: usize) void {
        if (buf.len >= n) return;
        if (buf.len > 0) self.gpa.free(buf.*);
        buf.* = self.gpa.alloc(u32, n) catch &.{};
    }

    /// (Re)paint the chrome into the cache only when the size or the style changed: the
    /// SDF is the costliest per-pixel work, and the glass is static in between.
    fn refreshChrome(self: *Window, n: usize, style: Style) void {
        if (self.cache_w == self.panel_w and self.cache_h == self.panel_h and self.chrome_cache.len >= n) return;
        self.ensure(&self.chrome_cache, n);
        if (self.chrome_cache.len < n) return;
        @memset(self.chrome_cache[0..n], 0);
        var cc = paint.Canvas.init(self.chrome_cache[0..n], self.panel_w, self.panel_h);
        cc.drawChrome(style);
        self.cache_w = self.panel_w;
        self.cache_h = self.panel_h;
    }

    // --- zicro callbacks: input ---------------------------------------------------------

    /// A key, already an evdev code on every backend: the panels first, then the app.
    /// Where the platform gives no text (`synth_text`), a press also types through the
    /// US keymap into `on_text`.
    fn innerKey(_: *Inner, key: u32, state: u32, user: ?*anyopaque) void {
        const self = from(user);
        const pressed = state == 1;
        if (synth_text and (key == 42 or key == 54)) self.shift_down = pressed; // Left/Right Shift
        self.key_consumed = self.panels.route(.{ .key = .{ .key = key, .pressed = pressed } }, self.host());
        if (self.key_consumed) return;
        if (self.opts.on_key) |cb| cb(self, key, state, self.opts.user);
        if (synth_text and pressed) {
            if (self.opts.on_text) |cb| {
                if (zicro.keymap.toChar(key, self.shift_down)) |ch| cb(self, .{ ch, 0, 0, 0 }, 1, self.opts.user);
            }
        }
    }

    /// macOS: the layout-aware text of the key just sent to `innerKey`, unless a panel
    /// took that key.
    fn innerText(win: *Inner, bytes: [4]u8, len: u8, user: ?*anyopaque) void {
        const self = from(user);
        if (win.text_from_key and self.key_consumed) return;
        if (self.opts.on_text) |cb| cb(self, bytes, len, self.opts.user);
    }

    fn innerMouse(_: *Inner, event: zicro.window.MouseEvent, user: ?*anyopaque) void {
        const self = from(user);
        if (chrome.forwardMouse(self, event)) return;
        // macOS, no title bar to grab: the window drags from near its edge, as on Wayland.
        if (!is_cocoa) return;
        if (event.kind == .press and event.button == zicro.wl.BTN_LEFT and !self.fullscreen) {
            const w: f32 = @floatFromInt(self.panel_w);
            const h: f32 = @floatFromInt(self.panel_h);
            const grab: f32 = 30.0;
            if (event.x < grab or event.y < grab or event.x > w - grab or event.y > h - grab) self.inner.beginMove();
        }
    }

    /// Multi-touch (web, Android): the center in app coordinates, like `innerMouse`.
    fn innerGesture(_: *Inner, g: zicro.gesture.Gesture, user: ?*anyopaque) void {
        chrome.forwardGesture(from(user), g);
    }

    fn innerCloseRequest(_: *Inner, user: ?*anyopaque) bool {
        const self = from(user);
        const cb = self.opts.on_close_request orelse return true;
        return cb(self, self.opts.user);
    }

    fn innerOpenFile(_: *Inner, path: []const u8, user: ?*anyopaque) void {
        const self = from(user);
        if (self.opts.on_open_file) |cb| cb(self, path, self.opts.user);
    }
};
