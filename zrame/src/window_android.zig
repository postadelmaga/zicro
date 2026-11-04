//! # zrame.window (Android backend) — a thin adapter over `zicro.window.Window` (NDK)
//!
//! Like the macOS backend: zicro's window does the OS transport (here the NDK
//! NativeActivity — ANativeWindow present + AInputQueue events + the looper), and zrame
//! adds its panels/compositing on top. Android is fullscreen with no desktop title bar, so
//! (as on macOS) the client-side glass chrome is NOT painted — the content fills the whole
//! surface; only the floating scrollbars mount by default. Input is already normalized by
//! the time it reaches this adapter: zicro's own Android backend translates AKEYCODE_* to
//! the same evdev codes the Wayland/Win32 backends emit, so `on_key` handlers stay
//! cross-platform, and printable keys additionally fire `on_text` via the shared US keymap.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zicro = @import("zicro");
const paint = zicro.paint;
const text = zicro.text;

const facade = @import("window.zig");
const plugin = @import("plugin.zig");
const scroll = @import("scroll.zig");
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

    panel_w: u32,
    panel_h: u32,
    closed: bool = false,
    fullscreen: bool = true, // Android apps are fullscreen
    maximized: bool = true,

    font: ?text.Font = null,
    shift_down: bool = false,

    panels: plugin.Registry,
    scrollbars: scroll.Scroll = .{ .follow_content = true },

    mailbox: chrome.FrameMailbox = .{},

    pub fn init(gpa: Allocator, opts: Options) !*Window {
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .opts = opts,
            .panel_w = @max(opts.width, 1),
            .panel_h = @max(opts.height, 1),
            .panels = plugin.Registry.init(gpa),
        };
        try self.panels.add(Panel.of(scroll.Scroll, &self.scrollbars), false);
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
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Wire the glue `android_app` into the underlying NDK window (call from android_main
    /// before `run`, same as a bare zicro app).
    pub fn attach(self: *Window, app: *zicro.android.android_app) void {
        self.inner.attach(app);
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
    pub fn reserveGutter(_: *Window, _: u32) void {}
    pub fn waitFrame(_: *Window, _: u32) bool {
        return false;
    }
    pub fn hasBlur(_: *Window) bool {
        return false;
    }
    pub fn scaleFactor(_: *const Window) f32 {
        return 1;
    }
    pub fn physPx(self: *Window, logical_dp: u32) u32 {
        return facade.physPxScale(self.scaleFactor(), logical_dp);
    }
    /// Responsive metrics — Android is always touch-primary. (Display density feeds in
    /// through `scaleFactor`; until it's wired it stays 1, so `w_dp` == physical px.)
    pub fn metrics(self: *Window) facade.Metrics {
        const c = self.contentPx();
        return facade.computeMetrics(self.scaleFactor(), c.w, c.h, true);
    }
    pub fn videoBusy(_: *const Window) bool {
        return false;
    }
    /// No video plane on this backend (`presentDmabuf` is a no-op): nothing to hide.
    pub fn hideVideo(_: *Window) void {}

    pub fn presentDmabuf(_: *Window, _: u8, _: i32, _: u32, _: u32, _: u32, _: u32, _: u64) bool {
        return false;
    }
    pub fn presentDmabufPlanes(_: *Window, _: u8, _: []const facade.DmabufPlane, _: u32, _: u32, _: u32) bool {
        return false;
    }
    pub fn toggleFullscreen(_: *Window) void {}
    pub fn setStyle(self: *Window, style: Style) !void {
        self.opts.style = style;
    }
    pub fn presentRgba(self: *Window, width: u32, height: u32, rgba: []const u8) void {
        if (self.mailbox.stage(self.gpa, width, height, rgba)) {
            self.inner.requestRedraw();
        }
    }
    pub fn textFont(self: *Window) !*text.Font {
        if (self.font == null) self.font = try text.Font.initDefault(self.gpa);
        return &self.font.?;
    }
    pub fn addPanel(self: *Window, panel: Panel, owned: bool) !void {
        try self.panels.add(panel, owned);
    }

    // --- geometry (content fills the whole surface; no chrome gutter) -------------------

    pub fn contentRect(self: *Window) Rect {
        return .{ .x = 0, .y = 0, .w = self.panel_w, .h = self.panel_h };
    }
    pub fn contentPx(self: *Window) struct { w: u32, h: u32 } {
        return .{ .w = self.panel_w, .h = self.panel_h };
    }

    /// Content-fill style: every mask/fade zeroed so `blitRgba` takes its fast path and no
    /// rounded/faded clipping trims a fullscreen frame (same preset the web backend uses).
    fn presentStyle(self: *const Window) Style {
        return self.opts.style.contentFill();
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
            else => {},
        }
    }
    fn hostInfo(ptr: *anyopaque) plugin.Info {
        const self: *Window = @ptrCast(@alignCast(ptr));
        return .{ .content = self.contentRect(), .panel_w = self.panel_w, .panel_h = self.panel_h, .margin = 0, .maximized = true, .fullscreen = true };
    }
    fn hostFont(ptr: *anyopaque) ?*text.Font {
        const self: *Window = @ptrCast(@alignCast(ptr));
        return self.textFont() catch null;
    }

    // --- composition / input (zicro callbacks) -----------------------------------------

    fn innerDraw(canvas: *paint.Canvas, content: zicro.window.Rect, user: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(user.?));
        self.panel_w = @intCast(@max(content.w, 1));
        self.panel_h = @intCast(@max(content.h, 1));
        _ = self.panels.tick(0.016, self.host());
        self.mailbox.swap();
        chrome.composeContent(canvas, self.contentRect(), self.contentRect(), &self.mailbox.front, self.presentStyle(), &self.panels, self.host(), self.opts.on_draw, self.opts.user);
    }

    fn innerKey(_: *zicro.window.Window, key: u32, state: u32, user: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(user.?));
        chrome.forwardKey(self, key, state); // key is already evdev (zicro's Android backend translates it)
    }

    fn innerMouse(_: *zicro.window.Window, event: zicro.window.MouseEvent, user: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(user.?));
        if (event.kind == .scroll) {
            if (self.panels.route(.{ .axis = .{ .x = event.x, .y = event.y, .axis = 0, .value = event.scroll_dy, .line = true } }, self.host())) return;
            if (self.opts.on_scroll) |cb| cb(self, 0, @intFromFloat(event.scroll_dy * 256.0), self.opts.user);
            return;
        }
        chrome.forwardMouse(self, event);
    }

    // Multi-touch gesture from the substrate: reports the center in app coordinates (like innerMouse).
    fn innerGesture(_: *zicro.window.Window, g: zicro.gesture.Gesture, user: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(user.?));
        chrome.forwardGesture(self, g);
    }
};
