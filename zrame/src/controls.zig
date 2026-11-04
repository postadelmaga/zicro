//! # zrame.controls — the title-bar window controls, as a panel
//!
//! A [`plugin.Panel`] that paints the title bar and drives minimize/maximize/close
//! through the [`plugin.Host`]. Two modern layouts are supported:
//!
//!   * `.macos` — the traffic-light cluster (red/yellow/green discs) on the left, title
//!     centered; the ✕ / – / + glyphs fade in when the pointer is over the cluster.
//!   * `.material` — title left, square min/max/close buttons right, with a soft hover
//!     wash (red on close), à la Material / Fluent.
//!
//! Everything is procedural — discs are `fillRoundedRect` with a full radius, glyphs are
//! capsule strokes (`paint.strokeSegment`) and a hollow rounded rect — so there are no
//! image assets and it stays crisp at any scale. Hover fades ride the shared clock.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zicro = @import("zicro");
const paint = zicro.paint;
const plugin = @import("plugin.zig");
const ui = @import("ui.zig");
const wl = zicro.wl;

const Color = paint.Color;

/// Which button. `Button` is the *action*; visual order depends on the layout.
const Button = enum(u8) { minimize = 0, maximize = 1, close = 2 };
const button_count = 3;

pub const Layout = enum { macos, material };

// macOS traffic-light colors (matching the system swatches).
const mac_close = Color.rgba(255, 95, 87, 1.0); // #FF5F57
const mac_min = Color.rgba(254, 188, 46, 1.0); // #FEBC2E
const mac_max = Color.rgba(40, 200, 64, 1.0); // #28C840
const mac_glyph = Color.rgba(0, 0, 0, 0.55);

pub const Controls = struct {
    layout: Layout,
    /// Bar height in canvas pixels (matches `Options.titlebar_height`).
    height: u32,
    /// Borrowed window title (owned by `Window.opts`).
    title: []const u8,
    /// Per-button hover factor 0..1 (linear; eased with `ui.cubicOut` on use).
    hover: [button_count]f32 = .{ 0, 0, 0 },
    /// Cluster reveal factor for the macOS glyphs (0 hidden … 1 shown).
    reveal: f32 = 0,
    hovered: ?Button = null,
    /// True while the pointer is anywhere over the control cluster (drives `reveal`).
    over_cluster: bool = false,

    /// Heap-allocate a controls panel. The registry owns it (`Window.addPanel(.., true)`),
    /// so its `deinit` frees this allocation.
    pub fn create(gpa: Allocator, layout: Layout, height: u32, title: []const u8) !*Controls {
        const self = try gpa.create(Controls);
        self.* = .{ .layout = layout, .height = height, .title = title };
        return self;
    }

    pub fn deinit(self: *Controls, gpa: Allocator) void {
        gpa.destroy(self);
    }

    // --- layout ------------------------------------------------------------------------

    const Bar = struct { x: f32, y: f32, w: f32, h: f32 };

    fn bar(self: *const Controls, info: plugin.Info) Bar {
        return .{
            .x = @floatFromInt(info.margin),
            .y = @floatFromInt(info.margin),
            .w = @floatFromInt(info.panel_w),
            .h = @floatFromInt(self.height),
        };
    }

    /// Disc diameter for the macOS layout.
    fn discDiameter(b: Bar) f32 {
        return std.math.clamp(b.h * 0.30, 11.0, 14.0);
    }

    /// Center of a macOS traffic-light disc. Visual order left→right: close, min, max.
    fn discCenter(btn: Button, b: Bar) struct { x: f32, y: f32 } {
        const d = discDiameter(b);
        const gap = d + 8.0;
        const first_x = b.x + 20.0 + d / 2.0;
        const pos: f32 = switch (btn) {
            .close => 0,
            .minimize => 1,
            .maximize => 2,
        };
        return .{ .x = first_x + pos * gap, .y = b.y + b.h / 2.0 };
    }

    /// Square cell for the Material layout, right-aligned: close is rightmost.
    fn cell(btn: Button, b: Bar) Bar {
        const c = b.h;
        const right = b.x + b.w;
        const close_x = right - c;
        const x = switch (btn) {
            .close => close_x,
            .maximize => close_x - c,
            .minimize => close_x - 2 * c,
        };
        return .{ .x = x, .y = b.y, .w = c, .h = c };
    }

    const macos_order = [3]Button{ .close, .minimize, .maximize };
    const material_order = [3]Button{ .minimize, .maximize, .close };

    fn buttonAt(self: *const Controls, info: plugin.Info, x: f32, y: f32) ?Button {
        const b = self.bar(info);
        if (y < b.y or y >= b.y + b.h) return null;
        switch (self.layout) {
            .macos => {
                const d = discDiameter(b);
                const hit = d / 2.0 + 3.0; // a little slop
                inline for (macos_order) |btn| {
                    const c = discCenter(btn, b);
                    if ((x - c.x) * (x - c.x) + (y - c.y) * (y - c.y) <= hit * hit) return btn;
                }
            },
            .material => {
                inline for (material_order) |btn| {
                    const r = cell(btn, b);
                    if (x >= r.x and x < r.x + r.w) return btn;
                }
            },
        }
        return null;
    }

    /// Bounding box of the macOS cluster (for the glyph-reveal hover region).
    fn clusterBox(b: Bar) Bar {
        const d = discDiameter(b);
        const left = discCenter(.close, b).x - d / 2.0 - 6.0;
        const right = discCenter(.maximize, b).x + d / 2.0 + 6.0;
        return .{ .x = left, .y = b.y, .w = right - left, .h = b.h };
    }

    fn inBar(self: *const Controls, info: plugin.Info, x: f32, y: f32) bool {
        const b = self.bar(info);
        return x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h;
    }

    // --- panel interface ---------------------------------------------------------------

    pub fn draw(self: *Controls, canvas: *paint.Canvas, host: plugin.Host) void {
        const info = host.info();
        if (info.fullscreen) return; // no chrome in fullscreen
        const b = self.bar(info);

        // Faint separator under the bar; the glass itself is the background.
        canvas.strokeSegment(b.x, b.y + b.h - 0.5, b.x + b.w, b.y + b.h - 0.5, 1.0, Color.rgba(255, 255, 255, 0.06));

        self.drawTitle(canvas, host, b);

        switch (self.layout) {
            .macos => inline for (macos_order) |btn| {
                self.drawDisc(canvas, btn, b, info);
            },
            .material => inline for (material_order) |btn| {
                self.drawCell(canvas, btn, cell(btn, b), info);
            },
        }
    }

    fn drawTitle(self: *Controls, canvas: *paint.Canvas, host: plugin.Host, b: Bar) void {
        if (self.title.len == 0) return;
        const font = host.font() orelse return;
        const size: u16 = @intFromFloat(@max(11.0, @min(15.0, b.h * 0.38)));
        const v = font.vmetrics(size, .bold);
        const th = v.ascent - v.descent;
        const baseline = @as(i32, @intFromFloat(b.y)) + @divFloor(@as(i32, @intFromFloat(b.h)) - th, 2) + v.ascent;
        const color = Color.rgba(236, 238, 248, 0.92);
        switch (self.layout) {
            // macOS centers the title over the whole bar.
            .macos => {
                const tw = font.measure(size, .bold, self.title);
                const x = @as(i32, @intFromFloat(b.x + b.w / 2.0)) - @divFloor(tw, 2);
                canvas.drawText(font, x, baseline, self.title, .{ .size = size, .style = .bold, .color = color });
            },
            // Material left-aligns it.
            .material => canvas.drawText(font, @as(i32, @intFromFloat(b.x)) + 16, baseline, self.title, .{ .size = size, .style = .bold, .color = color }),
        }
    }

    fn drawDisc(self: *Controls, canvas: *paint.Canvas, btn: Button, b: Bar, info: plugin.Info) void {
        const d = discDiameter(b);
        const c = discCenter(btn, b);
        const hf = ui.cubicOut(self.hover[@backingInt(btn)]);
        var col = switch (btn) {
            .close => mac_close,
            .minimize => mac_min,
            .maximize => mac_max,
        };
        // Lighten the disc slightly on direct hover (macOS style).
        const lift = 0.18 * hf;
        col.r += (1.0 - col.r) * lift;
        col.g += (1.0 - col.g) * lift;
        col.b += (1.0 - col.b) * lift;
        col.a = 1.0;
        canvas.fillRoundedRect(c.x - d / 2.0, c.y - d / 2.0, d, d, d / 2.0, col);

        // Glyphs fade in with the cluster reveal.
        const rv = ui.cubicOut(self.reveal);
        if (rv <= 0.01) return;
        const g = d * 0.22;
        const stroke = @max(1.0, d * 0.10);
        var ink = mac_glyph;
        ink.a *= rv;
        switch (btn) {
            .close => {
                canvas.strokeSegment(c.x - g, c.y - g, c.x + g, c.y + g, stroke, ink);
                canvas.strokeSegment(c.x - g, c.y + g, c.x + g, c.y - g, stroke, ink);
            },
            .minimize => canvas.strokeSegment(c.x - g, c.y, c.x + g, c.y, stroke, ink),
            .maximize => if (info.maximized) {
                // Restore hint: a small diagonal double-chevron pointing inward.
                canvas.strokeSegment(c.x - g, c.y - g, c.x, c.y, stroke, ink);
                canvas.strokeSegment(c.x + g, c.y + g, c.x, c.y, stroke, ink);
            } else {
                // Zoom hint: a plus.
                canvas.strokeSegment(c.x - g, c.y, c.x + g, c.y, stroke, ink);
                canvas.strokeSegment(c.x, c.y - g, c.x, c.y + g, stroke, ink);
            },
        }
    }

    fn drawCell(self: *Controls, canvas: *paint.Canvas, btn: Button, r: Bar, info: plugin.Info) void {
        const hf = ui.cubicOut(self.hover[@backingInt(btn)]);
        if (hf > 0.001) {
            const hl = if (btn == .close)
                Color.rgba(232, 76, 76, 0.90 * hf)
            else
                Color.rgba(255, 255, 255, 0.12 * hf);
            const pad = r.w * 0.16;
            canvas.fillRoundedRect(r.x + pad, r.y + pad, r.w - 2 * pad, r.h - 2 * pad, 6, hl);
        }

        const cx = r.x + r.w / 2.0;
        const cy = r.y + r.h / 2.0;
        const g = r.h * 0.16;
        const stroke = @max(1.2, r.h * 0.055);
        const base: f32 = 0.72 + 0.28 * hf;
        const ink = if (btn == .close and hf > 0.4)
            Color.rgba(255, 255, 255, 0.95)
        else
            Color.rgba(232, 235, 245, base);

        switch (btn) {
            .minimize => canvas.strokeSegment(cx - g, cy + g * 0.65, cx + g, cy + g * 0.65, stroke, ink),
            .maximize => if (info.maximized) {
                const s = g * 1.4;
                const o = g * 0.5;
                canvas.strokeRoundedRect(cx - s / 2 + o, cy - s / 2 - o, s, s, 2, stroke, ink);
                canvas.strokeRoundedRect(cx - s / 2 - o, cy - s / 2 + o, s, s, 2, stroke, ink);
            } else {
                canvas.strokeRoundedRect(cx - g, cy - g, 2 * g, 2 * g, 2.5, stroke, ink);
            },
            .close => {
                canvas.strokeSegment(cx - g, cy - g, cx + g, cy + g, stroke, ink);
                canvas.strokeSegment(cx - g, cy + g, cx + g, cy - g, stroke, ink);
            },
        }
    }

    pub fn onInput(self: *Controls, event: plugin.Event, host: plugin.Host) bool {
        const info = host.info();
        if (info.fullscreen) return false;
        switch (event) {
            .motion => |m| {
                self.hovered = self.buttonAt(info, m.x, m.y);
                const b = self.bar(info);
                self.over_cluster = switch (self.layout) {
                    .macos => blk: {
                        const box = clusterBox(b);
                        break :blk m.x >= box.x and m.x < box.x + box.w and m.y >= box.y and m.y < box.y + box.h;
                    },
                    .material => self.hovered != null,
                };
                const on_bar = self.inBar(info, m.x, m.y);
                if (on_bar) {
                    host.do(.{ .set_cursor = if (self.hovered != null)
                        wl.CursorShapeDevice.SHAPE_POINTER
                    else
                        wl.CursorShapeDevice.SHAPE_DEFAULT });
                }
                return on_bar;
            },
            .button => |btn| {
                if (btn.button != wl.BTN_LEFT or !btn.pressed) return false;
                if (self.buttonAt(info, btn.x, btn.y)) |bb| {
                    switch (bb) {
                        .minimize => host.do(.minimize),
                        .maximize => host.do(.toggle_maximize),
                        .close => host.do(.close),
                    }
                    return true;
                }
                if (self.inBar(info, btn.x, btn.y)) {
                    host.do(.begin_move); // drag the window from the bar
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn tick(self: *Controls, dt: f32, host: plugin.Host) bool {
        _ = host;
        var active = false;
        inline for (0..button_count) |i| {
            const target = if (self.hovered) |h| @backingInt(h) == i else false;
            const nf = ui.approach(self.hover[i], target, dt);
            if (nf != self.hover[i]) active = true;
            self.hover[i] = nf;
        }
        const nr = ui.approach(self.reveal, self.over_cluster, dt);
        if (nr != self.reveal) active = true;
        self.reveal = nr;
        return active;
    }

    /// Damage hint: the bar's animations (hover/reveal) all live in the title
    /// band — the partial present recomposes only that.
    pub fn dirtyBounds(self: *Controls, host: plugin.Host) ?plugin.Rect {
        const info = host.info();
        if (info.fullscreen) return null;
        const b = self.bar(info);
        return .{
            .x = @intFromFloat(@max(0.0, b.x)),
            .y = @intFromFloat(@max(0.0, b.y)),
            .w = @intFromFloat(@ceil(@max(0.0, b.w))),
            .h = @intFromFloat(@ceil(@max(0.0, b.h + 1.0))), // +1: separator under the bar
        };
    }
};
