//! # zrame.scroll — thin, fluid scrollbars, as a panel
//!
//! The scrollbar *look and feel* now lives in `zicro.scroll`, a UI-agnostic primitive: a
//! faithful port of egui 0.29's floating `ScrollArea` (2px dormant thumb swelling to 10px on
//! aim, `cubic_out` fades, low-pass wheel smoothing, linear kinetic friction, no overscroll).
//! This module is the thin **panel adapter**: it wraps a `zicro.scroll.Scroll`, maps zrame's
//! `plugin.Event` / `plugin.Rect` onto the primitive's plain method calls, and forwards the
//! drawing. The app-facing API is unchanged.
//!
//! Usage (see `examples/scroll.zig`): the app owns a `Scroll`, registers it as a panel for
//! input + bar drawing, and each frame sets `viewport` (the scrollable region, canvas coords)
//! and `content` (total content size), then draws its content translated by `-offset`.

const std = @import("std");

const zicro = @import("zicro");
const paint = zicro.paint;
const plugin = @import("plugin.zig");
const wl = zicro.wl;

const Rect = plugin.Rect;

pub const Scroll = struct {
    inner: zicro.scroll.Scroll = .{},
    /// When true (auto-mounted by `Window`), the panel derives its `viewport` from the
    /// host's content rect each draw/input/tick, so the app only has to report the
    /// content size via `setContent`. When false (the app owns the panel, e.g.
    /// `examples/scroll.zig`), `viewport` is whatever the app set.
    follow_content: bool = false,

    // --- app-facing API (adapts zrame's integer Rect to the primitive) -----------------

    pub fn setViewport(self: *Scroll, r: Rect) void {
        self.inner.setViewport(.{
            .x = @floatFromInt(r.x),
            .y = @floatFromInt(r.y),
            .w = @floatFromInt(r.w),
            .h = @floatFromInt(r.h),
        });
    }
    pub fn setContent(self: *Scroll, w: f32, h: f32) void {
        self.inner.setContent(w, h);
    }
    /// Current scroll offset (top-left of the visible window into the content).
    pub fn scrollX(self: *const Scroll) f32 {
        return self.inner.scrollX();
    }
    pub fn scrollY(self: *const Scroll) f32 {
        return self.inner.scrollY();
    }

    // --- panel interface (maps plugin.Event onto the primitive) ------------------------

    /// When auto-mounted, pin the viewport to the host's content rect (the panel
    /// interior). No-op for app-owned panels.
    fn syncViewport(self: *Scroll, host: plugin.Host) void {
        if (!self.follow_content) return;
        const c = host.info().content;
        self.setViewport(.{ .x = c.x, .y = c.y, .w = c.w, .h = c.h });
    }

    pub fn draw(self: *Scroll, canvas: *paint.Canvas, host: plugin.Host) void {
        self.syncViewport(host);
        self.inner.draw(canvas);
    }

    pub fn onInput(self: *Scroll, event: plugin.Event, host: plugin.Host) bool {
        self.syncViewport(host);
        return switch (event) {
            // wl_pointer axis: 0 = vertical scroll, 1 = horizontal.
            .axis => |a| self.inner.onWheel(
                if (a.axis == wl.AXIS_VERTICAL_SCROLL) .vertical else .horizontal,
                a.value,
                a.line,
                a.x,
                a.y,
            ),
            .button => |b| if (b.button != wl.BTN_LEFT)
                false
            else if (b.pressed)
                self.inner.onButtonDown(b.x, b.y)
            else
                self.inner.onButtonUp(),
            .motion => |m| self.inner.onMotion(m.x, m.y),
            // Pointer left the surface: drop hover, but don't consume — every panel
            // needs to see it to clear its own hover.
            .leave => blk: {
                self.inner.onLeave();
                break :blk false;
            },
            else => false,
        };
    }

    pub fn tick(self: *Scroll, dt: f32, host: plugin.Host) bool {
        self.syncViewport(host);
        return self.inner.tick(dt);
    }

    /// Damage hint: only the bands of the bars whose axes are visible or fading —
    /// typically a thin strip along the right (or bottom) edge, so the
    /// scrollbar fade does not recompose the entire content.
    pub fn dirtyBounds(self: *Scroll, host: plugin.Host) ?plugin.Rect {
        self.syncViewport(host);
        const vp = self.inner.viewport;
        // expanded_width (10) + lead-in di grab (8) + margine di sicurezza.
        const band: f32 = 20.0;
        var acc: ?plugin.Rect = null;
        if (self.inner.show[1] > 0.001 or self.inner.bar_hover[1] > 0.001) {
            acc = bandRect(vp.x + vp.w - band, vp.y, band, vp.h);
        }
        if (self.inner.show[0] > 0.001 or self.inner.bar_hover[0] > 0.001) {
            const r = bandRect(vp.x, vp.y + vp.h - band, vp.w, band);
            acc = if (acc) |a| plugin.unionOf(a, r) else r;
        }
        return acc;
    }
};

fn bandRect(x: f32, y: f32, w: f32, h: f32) plugin.Rect {
    return .{
        .x = @intFromFloat(@max(0.0, x)),
        .y = @intFromFloat(@max(0.0, y)),
        .w = @intFromFloat(@ceil(@max(0.0, w))),
        .h = @intFromFloat(@ceil(@max(0.0, h))),
    };
}

// --- tests ---------------------------------------------------------------------------
// The scroll behavior itself is covered in `zicro.scroll`; here we just check the panel
// adapter wires the integer Rect and offset through correctly.

test "adapter maps integer viewport and exposes the primitive's offset" {
    var s = Scroll{};
    s.setViewport(.{ .x = 10, .y = 20, .w = 200, .h = 100 });
    s.setContent(200, 1000);
    s.inner.offset[1] = 300;
    try std.testing.expectEqual(@as(f32, 300), s.scrollY());
    try std.testing.expectEqual(@as(f32, 0), s.scrollX());
}
