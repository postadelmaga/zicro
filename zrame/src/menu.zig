//! # zrame.menu — the window context menu, as a panel
//!
//! A [`plugin.Panel`] that draws an in-surface glass popup with the window commands
//! (Minimize, Maximize/Restore, Full Screen, Close) and dismisses on selection, an
//! outside click, or Escape. It is client-drawn on the same canvas as the chrome — same
//! rounded glass, same SDF anti-aliasing — so it matches the window instead of borrowing
//! the compositor's look. Confined to the window bounds (its position is clamped).
//!
//! Trigger: right-click the title bar (or anywhere in a title-bar-less window). The
//! open/close is a `cubicOut` fade + a small downward slide off the shared clock.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zicro = @import("zicro");
const paint = zicro.paint;
const plugin = @import("plugin.zig");
const ui = @import("ui.zig");
const wl = zicro.wl;

const Color = paint.Color;

const Command = enum { minimize, maximize, fullscreen, close };
const Row = union(enum) { command: Command, separator };

const rows = [_]Row{
    .{ .command = .minimize },
    .{ .command = .maximize },
    .{ .command = .fullscreen },
    .separator,
    .{ .command = .close },
};

const row_h: f32 = 30.0;
const sep_h: f32 = 9.0;
const pad_x: f32 = 12.0;
const pad_y: f32 = 6.0;
const min_w: f32 = 180.0;
const radius: f32 = 10.0;

pub const Menu = struct {
    open: bool = false,
    /// Open factor 0..1 (linear; eased on use). Drawn while > 0 even after `open=false`.
    anim: f32 = 0,
    /// Requested top-left in canvas coords (clamped into the panel at draw time).
    ax: f32 = 0,
    ay: f32 = 0,
    hovered: ?usize = null,

    pub fn create(gpa: Allocator) !*Menu {
        const self = try gpa.create(Menu);
        self.* = .{};
        return self;
    }

    pub fn deinit(self: *Menu, gpa: Allocator) void {
        gpa.destroy(self);
    }

    // --- geometry ----------------------------------------------------------------------

    const Box = struct { x: f32, y: f32, w: f32, h: f32 };

    fn contentHeight() f32 {
        var h: f32 = 2 * pad_y;
        for (rows) |r| h += switch (r) {
            .command => row_h,
            .separator => sep_h,
        };
        return h;
    }

    fn width(host: plugin.Host, info: plugin.Info) f32 {
        var w: f32 = min_w;
        if (host.font()) |font| {
            for (rows) |r| switch (r) {
                .command => |c| {
                    const tw: f32 = @floatFromInt(font.measure(14, .regular, label(c, info)));
                    w = @max(w, tw + 2 * pad_x + 28);
                },
                .separator => {},
            };
        }
        return w;
    }

    /// The popup box, clamped so it stays inside the panel.
    fn box(self: *const Menu, host: plugin.Host, info: plugin.Info) Box {
        const w = width(host, info);
        const h = contentHeight();
        const m: f32 = @floatFromInt(info.margin);
        const pw: f32 = @floatFromInt(info.panel_w);
        const ph: f32 = @floatFromInt(info.panel_h);
        const x = std.math.clamp(self.ax, m, m + @max(0.0, pw - w));
        const y = std.math.clamp(self.ay, m, m + @max(0.0, ph - h));
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    /// Index into `rows` under local point `(x,y)`, or null. Separators never match.
    fn rowAt(b: Box, x: f32, y: f32) ?usize {
        if (x < b.x or x >= b.x + b.w or y < b.y + pad_y or y >= b.y + b.h - pad_y) return null;
        var yy = b.y + pad_y;
        for (rows, 0..) |r, i| {
            const rh: f32 = switch (r) {
                .command => row_h,
                .separator => sep_h,
            };
            if (y >= yy and y < yy + rh) return switch (r) {
                .command => i,
                .separator => null,
            };
            yy += rh;
        }
        return null;
    }

    fn label(c: Command, info: plugin.Info) []const u8 {
        return switch (c) {
            .minimize => "Minimize",
            .maximize => if (info.maximized) "Restore" else "Maximize",
            .fullscreen => if (info.fullscreen) "Exit Full Screen" else "Enter Full Screen",
            .close => "Close",
        };
    }

    // --- panel interface ---------------------------------------------------------------

    pub fn draw(self: *Menu, canvas: *paint.Canvas, host: plugin.Host) void {
        if (self.anim <= 0.001) return;
        const info = host.info();
        const b = self.box(host, info);
        const t = ui.cubicOut(self.anim);
        const slide = (1.0 - t) * 6.0; // small downward slide on open
        const bx = b.x;
        const by = b.y - slide;

        // Glass background + subtle ring, both faded by the open factor.
        canvas.fillRoundedRect(bx, by, b.w, b.h, radius, Color.rgba(30, 30, 40, 0.94 * t));
        canvas.strokeRoundedRect(bx, by, b.w, b.h, radius, 1.0, Color.rgba(255, 255, 255, 0.10 * t));

        const font = host.font();
        var yy = by + pad_y;
        for (rows, 0..) |r, i| switch (r) {
            .separator => {
                canvas.strokeSegment(bx + pad_x, yy + sep_h / 2, bx + b.w - pad_x, yy + sep_h / 2, 1.0, Color.rgba(255, 255, 255, 0.10 * t));
                yy += sep_h;
            },
            .command => |c| {
                const hovered = self.hovered != null and self.hovered.? == i;
                if (hovered) {
                    // macOS-style accent highlight, full width.
                    canvas.fillRoundedRect(bx + 4, yy + 2, b.w - 8, row_h - 4, 6, Color.rgba(64, 120, 255, 0.92 * t));
                }
                if (font) |f| {
                    const v = f.vmetrics(14, .regular);
                    const th = v.ascent - v.descent;
                    const baseline = @as(i32, @intFromFloat(yy)) + @divFloor(@as(i32, @intFromFloat(row_h)) - th, 2) + v.ascent;
                    const col = if (hovered) Color.rgba(255, 255, 255, 0.98 * t) else Color.rgba(232, 235, 245, 0.92 * t);
                    const danger = c == .close and !hovered;
                    const final = if (danger) Color.rgba(255, 138, 128, 0.92 * t) else col;
                    canvas.drawText(f, @as(i32, @intFromFloat(bx + pad_x)), baseline, label(c, info), .{ .size = 14, .color = final });
                }
                yy += row_h;
            },
        };
    }

    pub fn onInput(self: *Menu, event: plugin.Event, host: plugin.Host) bool {
        const info = host.info();
        switch (event) {
            .button => |btn| {
                if (!btn.pressed) return self.open; // swallow the release while open
                if (btn.button == wl.BTN_RIGHT) {
                    if (self.shouldOpenAt(info, btn.x, btn.y)) {
                        self.openAt(btn.x, btn.y);
                        return true;
                    }
                    // Right-click elsewhere while open just dismisses.
                    if (self.open) {
                        self.close();
                        return true;
                    }
                    return false;
                }
                if (btn.button == wl.BTN_LEFT and self.open) {
                    const b = self.box(host, info);
                    if (rowAt(b, btn.x, btn.y)) |i| {
                        self.activate(i, host);
                    }
                    self.close();
                    return true; // consume the click that dismisses the menu
                }
                return false;
            },
            .motion => |m| {
                if (self.anim <= 0.001) return false;
                const b = self.box(host, info);
                self.hovered = rowAt(b, m.x, m.y);
                // Consume motion only while actually over the popup.
                return m.x >= b.x and m.x < b.x + b.w and m.y >= b.y and m.y < b.y + b.h;
            },
            .key => |k| {
                if (self.open and k.pressed and k.key == wl.KEY_ESC) {
                    self.close();
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn tick(self: *Menu, dt: f32, host: plugin.Host) bool {
        _ = host;
        const nf = ui.approach(self.anim, self.open, dt);
        const moved = nf != self.anim;
        self.anim = nf;
        return moved;
    }

    /// Damage hint: the popup (with the vertical open slide and the 1px ring),
    /// or nothing when it is closed and the fade has finished.
    pub fn dirtyBounds(self: *Menu, host: plugin.Host) ?plugin.Rect {
        if (!self.open and self.anim <= 0.001) return null;
        const b = self.box(host, host.info());
        return .{
            .x = @intFromFloat(@max(0.0, b.x - 2.0)),
            .y = @intFromFloat(@max(0.0, b.y - 8.0)), // 6px slide upward + ring
            .w = @intFromFloat(@ceil(b.w + 4.0)),
            .h = @intFromFloat(@ceil(b.h + 10.0)),
        };
    }

    // --- helpers -----------------------------------------------------------------------

    fn shouldOpenAt(self: *Menu, info: plugin.Info, x: f32, y: f32) bool {
        _ = self;
        const m: f32 = @floatFromInt(info.margin);
        const pw: f32 = @floatFromInt(info.panel_w);
        const ph: f32 = @floatFromInt(info.panel_h);
        // Inside the panel at all?
        if (x < m or y < m or x >= m + pw or y >= m + ph) return false;
        // With a title bar, only the bar strip opens the window menu (content is the
        // app's); a bar-less window opens anywhere.
        const tb_h: f32 = @floatFromInt(info.content.y - info.margin);
        if (tb_h <= 0) return true;
        return y < m + tb_h;
    }

    pub fn openAt(self: *Menu, x: f32, y: f32) void {
        self.ax = x;
        self.ay = y;
        self.open = true;
        self.hovered = null;
    }

    pub fn close(self: *Menu) void {
        self.open = false;
        self.hovered = null;
    }

    fn activate(self: *Menu, i: usize, host: plugin.Host) void {
        _ = self;
        switch (rows[i]) {
            .command => |c| switch (c) {
                .minimize => host.do(.minimize),
                .maximize => host.do(.toggle_maximize),
                .fullscreen => host.do(.toggle_fullscreen),
                .close => host.do(.close),
            },
            .separator => {},
        }
    }
};

test "menu row hit-testing skips separators" {
    var menu = Menu{};
    menu.openAt(100, 100);
    // A tall-enough synthetic box; rows are min/max/full/sep/close.
    const b = Menu.Box{ .x = 100, .y = 100, .w = 200, .h = Menu.contentHeight() };
    // First row (minimize) center.
    const first_y = b.y + pad_y + row_h / 2;
    try std.testing.expectEqual(@as(?usize, 0), Menu.rowAt(b, 150, first_y));
    // The separator band (index 3) yields null.
    var yy = b.y + pad_y + 3 * row_h; // after 3 command rows
    const sep_center = yy + sep_h / 2;
    try std.testing.expectEqual(@as(?usize, null), Menu.rowAt(b, 150, sep_center));
    yy += sep_h;
    // Close row (index 4).
    try std.testing.expectEqual(@as(?usize, 4), Menu.rowAt(b, 150, yy + row_h / 2));
    // Outside the box → null.
    try std.testing.expectEqual(@as(?usize, null), Menu.rowAt(b, 400, first_y));
}
