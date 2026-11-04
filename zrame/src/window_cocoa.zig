//! # zrame.window (macOS backend) — a thin adapter over `zicro.window.Window`
//!
//! Unlike the Wayland and Win32 backends, which speak their windowing protocol directly,
//! the macOS backend delegates every AppKit interaction to zicro's Cocoa window
//! (`zicro/src/window_cocoa.zig`) — by design: the ObjC-runtime plumbing lives in ONE
//! place of the stack, so anything downstream (zrame, Zengine apps, Z's integration)
//! inherits the same window. zicro already delivers the cross-platform contract this
//! facade promises — evdev key/button codes, content coordinates, 60 Hz on_draw — so the
//! adapter only adds what zrame owns: the panel stack (scrollbars, plugins), the staged
//! `presentRgba` mailbox, and the `Host` seam.
//!
//! The glass chrome is intentionally NOT painted here: macOS windows keep their native
//! title bar and shadow (the platform's own decorations, same reasoning as Win32's
//! `titlebar` being "ignored on platforms that use native decorations"). The content
//! therefore fills the whole panel — margin 0, no rounded mask — the exact geometry the
//! Win32 opaque escape-hatch uses.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zicro = @import("zicro");
const paint = zicro.paint;
const text = zicro.text;

const facade = @import("window.zig");
const plugin = @import("plugin.zig");
const scroll = @import("scroll.zig");

pub const Style = facade.Style;
pub const Panel = facade.Panel;
pub const Host = facade.Host;
pub const Options = facade.Options;
pub const MouseEvent = facade.MouseEvent;
pub const Rect = facade.Rect;

const chrome = @import("chrome.zig");
const SpinLock = chrome.SpinLock;
const Staged = chrome.Staged;

pub const Window = struct {
    gpa: Allocator,
    opts: Options,
    /// The zicro Cocoa window doing all the AppKit work.
    inner: *zicro.window.Window = undefined,
    /// zicro's blocking primitives live behind `std.Io`; the adapter owns one.
    threaded: std.Io.Threaded,

    /// Content-area size in pixels — the public geometry the app reads and presents into.
    panel_w: u32,
    panel_h: u32,
    closed: bool = false,
    fullscreen: bool = false,
    maximized: bool = false,

    font: ?text.Font = null,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,

    panels: plugin.Registry,
    scrollbars: scroll.Scroll = .{ .follow_content = true },

    mailbox: chrome.FrameMailbox = .{},

    pub fn init(gpa: Allocator, opts: Options) !*Window {
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .opts = opts,
            .threaded = .init(gpa, .{}),
            .panel_w = @max(opts.width, 160),
            .panel_h = @max(opts.height, 120),
            .panels = plugin.Registry.init(gpa),
        };

        // Floating scrollbars are the bottom-most panel (borrowed: the Window owns the
        // field instance, so the registry must not free it). Mirrors the other backends.
        try self.panels.add(Panel.of(scroll.Scroll, &self.scrollbars), false);
        // opts.titlebar / opts.context_menu are native-decoration concerns here: the OS
        // draws the title bar and the window menu, so the CSD panels are never mounted.

        self.inner = try zicro.window.Window.init(gpa, self.threaded.io(), .{
            .title = opts.title,
            .width = self.panel_w,
            .height = self.panel_h,
            .on_draw = innerDraw,
            .on_key = innerKey,
            .on_mouse = innerMouse,
            .on_close_request = if (opts.on_close_request != null) innerCloseRequest else null,
            .user = self,
        });
        return self;
    }

    pub fn deinit(self: *Window) void {
        self.inner.deinit();
        self.panels.deinit();
        if (self.font) |*f| f.deinit();
        self.mailbox.deinit(self.gpa);
        self.threaded.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn innerCloseRequest(_: *zicro.window.Window, user: ?*anyopaque) bool {
        const self: *Window = @ptrCast(@alignCast(user.?));
        const cb = self.opts.on_close_request orelse return true;
        return cb(self, self.opts.user);
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

    /// Native glass: true when the zicro window mounted its NSVisualEffectView
    /// (real AppKit). Under Darling/Cocotron the class is missing → false, as before.
    pub fn hasBlur(self: *Window) bool {
        return self.inner.hasBlur();
    }

    /// Retina scaling is not wired yet — the buffer is 1:1, as on Win32.
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
    /// frame wins. No wake needed: the zicro run loop repaints at 60 Hz.
    pub fn presentRgba(self: *Window, width: u32, height: u32, rgba: []const u8) void {
        _ = self.mailbox.stage(self.gpa, width, height, rgba);
    }

    /// dmabuf zero-copy present is a Linux/Wayland path; callers fall back to `presentRgba`.
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

    /// API parity with the Wayland backend: no vsync hook is wired, so return `false` at
    /// once — the caller degrades to its own software pacer (same contract as Win32).
    pub fn waitFrame(_: *Window, _: u32) bool {
        return false;
    }

    /// The event loop: zicro pumps AppKit until the window is closed.
    pub fn run(self: *Window) !void {
        try self.inner.run();
        self.closed = true;
    }

    pub fn close(self: *Window) void {
        self.closed = true;
        self.inner.close();
    }

    pub fn setStyle(self: *Window, style: Style) !void {
        self.opts.style = style;
    }

    pub fn toggleFullscreen(self: *Window) void {
        self.fullscreen = !self.fullscreen;
        self.inner.toggleFullscreen();
    }

    /// Resize the content area to `target_w`×`target_h` (the native frame grows around
    /// it). No animation: AppKit animates frame changes on its own terms.
    pub fn animateResize(self: *Window, target_w: u32, target_h: u32) void {
        if (self.fullscreen) return;
        self.inner.setContentSize(@max(target_w, 160), @max(target_h, 120));
    }

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
    }

    pub fn removePanel(self: *Window, ptr: *anyopaque) void {
        self.panels.remove(ptr);
    }

    pub fn loadPlugin(self: *Window, path: []const u8) !void {
        _ = try plugin.loadPlugin(&self.panels, path);
    }

    pub fn loadPluginDir(self: *Window, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |ent| {
            if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".dylib")) continue;
            const full = std.fs.path.join(self.gpa, &.{ dir_path, ent.name }) catch continue;
            defer self.gpa.free(full);
            self.loadPlugin(full) catch |e| std.log.warn("zrame: plugin {s} failed to load: {}", .{ ent.name, e });
        }
    }

    /// System clipboard is not wired on Cocoa yet: API-parity no-op (see the Wayland /
    /// Win32 backends for the real implementations).
    pub fn clipboardSet(_: *Window, _: []const u8) void {}

    /// System clipboard is not wired on Cocoa yet: always null (no selection).
    pub fn clipboardGet(_: *Window, _: Allocator) ?[]u8 {
        return null;
    }

    // --- host seam (panels reach back into the window) --------------------------------

    pub fn host(self: *Window) Host {
        return .{ .ptr = self, .vtable = &host_vtable };
    }

    const host_vtable = Host.VTable{ .do = hostDo, .info = hostInfo, .font = hostFont };

    fn hostDo(ptr: *anyopaque, action: plugin.Action) void {
        const self: *Window = @ptrCast(@alignCast(ptr));
        switch (action) {
            .minimize => self.inner.setMinimized(),
            .toggle_maximize => {}, // native zoom button owns this
            .toggle_fullscreen => self.toggleFullscreen(),
            .close => self.close(),
            .begin_move => self.inner.beginMove(),
            .begin_resize => |edge| self.inner.beginResize(edge),
            .set_cursor => {},
            // The zicro loop repaints every frame; nothing to poke.
            .request_redraw => {},
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
            .margin = 0,
            .maximized = self.maximized,
            .fullscreen = self.fullscreen,
        };
    }

    fn hostFont(ptr: *anyopaque) ?*text.Font {
        const self: *Window = @ptrCast(@alignCast(ptr));
        return self.textFont() catch null;
    }

    // --- composition / input (zicro callbacks) -----------------------------------------

    /// Content fills the whole panel: native decorations, no shadow gutter, no client
    /// title bar (same geometry as the Win32 opaque escape-hatch).
    pub fn contentRect(self: *Window) Rect {
        return .{ .x = 0, .y = 0, .w = self.panel_w, .h = self.panel_h };
    }

    /// Physical size of the content rect — mirrors the other backends' `contentPx`.
    pub fn contentPx(self: *Window) struct { w: u32, h: u32 } {
        const r = self.contentRect();
        return .{ .w = r.w, .h = r.h };
    }

    /// The style used for content compositing: every mask/fade field zeroed so
    /// `blitRgba` takes its trivial fast path — a square opaque window doesn't want
    /// rounded/faded content clipping.
    fn presentStyle(self: *const Window) Style {
        return self.opts.style.contentFill();
    }

    fn innerDraw(canvas: *paint.Canvas, content: zicro.window.Rect, user: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(user.?));
        self.panel_w = @intCast(@max(content.w, 1));
        self.panel_h = @intCast(@max(content.h, 1));
        // Panels animate on the frame clock (the zicro loop is a steady ~60 Hz).
        _ = self.panels.tick(0.016, self.host());
        self.mailbox.swap();
        chrome.composeContent(canvas, self.contentRect(), self.contentRect(), &self.mailbox.front, self.presentStyle(), &self.panels, self.host(), self.opts.on_draw, self.opts.user);
    }

    fn innerKey(_: *zicro.window.Window, key: u32, state: u32, user: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(user.?));
        if (self.panels.route(.{ .key = .{ .key = key, .pressed = state == 1 } }, self.host())) return;
        if (self.opts.on_key) |cb| cb(self, key, state, self.opts.user);
    }

    fn innerMouse(_: *zicro.window.Window, event: zicro.window.MouseEvent, user: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(user.?));
        // App-space mouse (see `MouseEvent`): canvas minus the staged-frame/content
        // origin — panels and the resize band stay in canvas coordinates.
        chrome.forwardMouse(self, event);
    }
};
