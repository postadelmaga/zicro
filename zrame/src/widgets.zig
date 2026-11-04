//! # zrame.widgets — the no-thread path
//!
//! Run `zicro.widget` (the immediate-mode toolkit) in a glass window with **no app
//! thread and no app framebuffer**. The app writes a single `build(ui, user)`
//! function; this module wires everything else: the five window callbacks, the
//! input queue, the presentation→canvas coordinate shift, the OS clipboard bridge,
//! and repaint-on-animation.
//!
//! ```zig
//! var app = MyState{ ... };
//! var w = zrame.Widgets.init(gpa, zrame.widget.Theme.light(), build, &app);
//! defer w.deinit();
//! const win = try zrame.Window.init(gpa, w.options(.{ .title = "demo", .titlebar = true }));
//! defer win.deinit();
//! w.attach(win);
//! try win.run();
//!
//! fn build(ui: *zrame.widget.Ui, user: ?*anyopaque) void {
//!     const app: *MyState = @ptrCast(@alignCast(user.?));
//!     if (ui.button("Click")) app.clicks += 1;
//! }
//! ```
//!
//! The whole UI is rebuilt from state each frame; `zicro.widget.Store` retains
//! hot/active/focus, scroll offsets and animation values across frames. Only
//! animating frames repaint (the build's `EndReport.needs_repaint` drives
//! `request_redraw`), so an idle UI costs nothing.

const std = @import("std");

const zicro = @import("zicro");
const widget = zicro.widget;
const paint = zicro.paint;

const window = @import("window.zig");
const Window = window.Window;
const Options = window.Options;
const Rect = window.Rect;
const MouseEvent = window.MouseEvent;

/// Retained widget state bound to one window. Construct with [`init`], pass
/// [`options`] to `Window.init`, then [`attach`] the window before `win.run()`.
pub const Widgets = struct {
    store: widget.Store,
    theme: widget.Theme,
    build: *const fn (*widget.Ui, ?*anyopaque) void,
    user: ?*anyopaque,
    queue: widget.InputQueue = .{},
    win: ?*Window = null,
    text_input_active: bool = false,

    /// `build` is called every redraw with a live `Ui` and your `user` pointer.
    pub fn init(
        gpa: std.mem.Allocator,
        theme: widget.Theme,
        build: *const fn (*widget.Ui, ?*anyopaque) void,
        user: ?*anyopaque,
    ) Widgets {
        return .{ .store = widget.Store.init(gpa), .theme = theme, .build = build, .user = user };
    }

    pub fn deinit(self: *Widgets) void {
        self.store.deinit();
    }

    /// `base` window options (title/size/style/titlebar…) with the five callbacks
    /// and `user` overwritten to route through this host. Any callbacks already set
    /// on `base` are replaced.
    pub fn options(self: *Widgets, base: Options) Options {
        var o = base;
        o.user = self;
        o.on_draw = onDraw;
        o.on_mouse = onMouse;
        o.on_key = onKey;
        o.on_text = onText;
        o.on_scroll = onScroll;
        return o;
    }

    /// Bind the constructed window: needed for the font, the OS clipboard, and
    /// `request_redraw`. Call once, after `Window.init`, before `win.run()`.
    pub fn attach(self: *Widgets, win: *Window) void {
        self.win = win;
        self.store.os_clipboard = .{ .ctx = win, .set = clipSet, .get = clipGet };
    }
};

// --- callback trampolines (read `Widgets` from the window's `user`) -----------------

fn onDraw(canvas: *paint.Canvas, content: Rect, user: ?*anyopaque) void {
    const self: *Widgets = @ptrCast(@alignCast(user.?));
    const win = self.win orelse return;
    const font = win.textFont() catch return;
    var ui = widget.Ui.begin(
        &self.store,
        canvas,
        font,
        self.theme.scaled(win.scaleFactor()),
        .{
            .x = @floatFromInt(content.x),
            .y = @floatFromInt(content.y),
            .w = @floatFromInt(content.w),
            .h = @floatFromInt(content.h),
        },
        widget.nowMs(),
        self.queue.take(),
    );
    self.build(&ui, self.user);
    const report = ui.end();
    const is_text_focused = self.store.focus != 0 and self.store.focus_is_text;
    if (is_text_focused != self.text_input_active) {
        self.text_input_active = is_text_focused;
        if (is_text_focused) {
            win.host().do(.{ .enable_text_input = .{} });
        } else {
            win.host().do(.disable_text_input);
        }
    }
    if (report.needs_repaint) win.host().do(.request_redraw);
}

fn onMouse(win: *Window, event: MouseEvent, user: ?*anyopaque) bool {
    const self: *Widgets = @ptrCast(@alignCast(user.?));
    // `on_mouse` delivers presentation-space coords; a no-frame app's presentation
    // origin is the content rect, and the Ui draws in canvas coords → add content.x/y.
    const c = win.host().info().content;
    switch (event) {
        .motion => |m| self.queue.push(.{ .motion = .{
            .x = m.x + @as(f32, @floatFromInt(c.x)),
            .y = m.y + @as(f32, @floatFromInt(c.y)),
        } }),
        .button => |b| self.queue.push(.{ .button = .{ .button = b.button, .pressed = b.state == 1 } }),
        // Pointer left: park it far away so hover clears (matches the widget contract).
        .leave => self.queue.push(.{ .motion = .{ .x = -1e9, .y = -1e9 } }),
    }
    win.host().do(.request_redraw);
    return false; // never consume: chrome (resize bands, title bar) still works
}

fn onKey(win: *Window, key: u32, state: u32, user: ?*anyopaque) void {
    const self: *Widgets = @ptrCast(@alignCast(user.?));
    self.queue.push(.{ .key = .{ .code = key, .pressed = state == 1 } });
    win.host().do(.request_redraw);
}

fn onText(win: *Window, bytes: [4]u8, len: u8, user: ?*anyopaque) void {
    const self: *Widgets = @ptrCast(@alignCast(user.?));
    self.queue.push(.{ .text = .{ .bytes = bytes, .len = len } });
    win.host().do(.request_redraw);
}

fn onScroll(win: *Window, axis: u32, value: i32, user: ?*anyopaque) void {
    const self: *Widgets = @ptrCast(@alignCast(user.?));
    self.queue.push(.{ .scroll = .{ .axis = axis, .px = @as(f32, @floatFromInt(value)) / 256.0 } });
    win.host().do(.request_redraw);
}

// --- OS clipboard bridge (Store ↔ window) -------------------------------------------

fn clipSet(ctx: ?*anyopaque, s: []const u8) void {
    const win: *Window = @ptrCast(@alignCast(ctx.?));
    win.clipboardSet(s);
}

fn clipGet(ctx: ?*anyopaque, gpa: std.mem.Allocator) ?[]u8 {
    const win: *Window = @ptrCast(@alignCast(ctx.?));
    return win.clipboardGet(gpa);
}
