//! # zicro.scroll — thin, fluid scrollbars, as a UI-agnostic primitive
//!
//! A faithful port of egui 0.29's *floating* `ScrollArea` look: bars invisible at rest, a
//! hair-thin 2px thumb that fades in when the pointer enters the content and swells to 10px
//! when you aim at it, `cubic_out` fades over ~83ms, low-pass–smoothed mouse-wheel
//! scrolling, and linear kinetic friction. No overscroll/bounce; the offset is hard-clamped.
//!
//! This is the reusable core, decoupled from any widget/panel framework: it holds the
//! geometry + animation state, draws with a [`paint.Canvas`], eases with [`anim`], and takes
//! input as plain method calls (`onWheel`/`onButtonDown`/`onButtonUp`/`onMotion`). A UI layer
//! (e.g. `zrame.scroll`) wraps it into whatever event/panel shape it uses.
//!
//! Each frame the owner sets `viewport` (the scrollable region, canvas coords) and `content`
//! (total content size), then draws its content translated by `-offset`. Internal axis index
//! is 0 = horizontal (x), 1 = vertical (y); [`Axis`] names the two for `onWheel`.

const std = @import("std");
const paint = @import("paint.zig");
const anim = @import("anim.zig");

const Color = paint.Color;

/// Scrollable region in canvas (buffer) pixels — the space `viewport`/pointer live in.
pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

/// Which bar a wheel/scroll event drives. Values match the internal axis index
/// (0 = horizontal/x, 1 = vertical/y).
pub const Axis = enum(u1) { horizontal = 0, vertical = 1 };

// egui floating-ScrollStyle constants (see the port notes).
const dormant_width: f32 = 2.0;
const expanded_width: f32 = 10.0;
const min_thumb: f32 = 12.0;
const inner_margin: f32 = 3.0;
const grab_cross: f32 = 14.0; // hover/grab cross-width, independent of the visual width
// Opacity ramps: dormant → area-hover → bar-interact.
const bg_active: f32 = 0.4;
const bg_interact: f32 = 0.7;
const handle_active: f32 = 0.6;
const handle_interact: f32 = 1.0;
// Kinetic friction (px/s²) and the speed below which motion snaps to rest (px/s).
const friction: f32 = 1000.0;
const stop_speed: f32 = 20.0;
// Mouse-wheel gain: wl axis values are ~15/notch; a little gain gives a natural step.
const wheel_gain: f32 = 2.4;

pub const Scroll = struct {
    /// Scrollable region in canvas coords (app sets each frame). Bars sit at its edges.
    viewport: Rect = .{},
    /// Total content size (app sets each frame).
    content: [2]f32 = .{ 0, 0 },
    offset: [2]f32 = .{ 0, 0 },
    vel: [2]f32 = .{ 0, 0 },
    /// Pending wheel delta being low-pass filtered into `offset`.
    unprocessed: [2]f32 = .{ 0, 0 },

    // Animation factors (linear 0..1; eased with cubicOut on use).
    show: [2]f32 = .{ 0, 0 },
    area_hover: f32 = 0,
    bar_hover: [2]f32 = .{ 0, 0 },

    // Interaction state.
    dragging: ?u8 = null, // axis being dragged via its thumb
    grab: f32 = 0, // pointer-to-thumb-top offset captured at grab
    pointer: [2]f32 = .{ 0, 0 },
    in_area: bool = false,
    over_bar: [2]bool = .{ false, false },

    // --- app-facing API ----------------------------------------------------------------

    pub fn setViewport(self: *Scroll, r: Rect) void {
        self.viewport = r;
    }
    pub fn setContent(self: *Scroll, w: f32, h: f32) void {
        self.content = .{ w, h };
    }
    /// Current scroll offset (top-left of the visible window into the content).
    pub fn scrollX(self: *const Scroll) f32 {
        return self.offset[0];
    }
    pub fn scrollY(self: *const Scroll) f32 {
        return self.offset[1];
    }

    // --- geometry ----------------------------------------------------------------------

    fn viewLen(self: *const Scroll, d: u8) f32 {
        return if (d == 0) self.viewport.w else self.viewport.h;
    }
    fn maxOff(self: *const Scroll, d: u8) f32 {
        return @max(0.0, self.content[d] - self.viewLen(d));
    }
    fn barStart(self: *const Scroll, d: u8) f32 {
        const base: f32 = if (d == 0) self.viewport.x else self.viewport.y;
        return base + 2.0;
    }
    fn barLen(self: *const Scroll, d: u8) f32 {
        return self.viewLen(d) - 4.0;
    }
    fn fromContent(self: *const Scroll, d: u8, c: f32) f32 {
        return anim.remapClamp(c, 0.0, self.content[d], self.barStart(d), self.barStart(d) + self.barLen(d));
    }

    const Seg = struct { lo: f32, hi: f32 };
    /// Thumb extent along the scroll axis, honoring the 12px minimum length.
    fn thumbSeg(self: *const Scroll, d: u8) Seg {
        var lo = self.fromContent(d, self.offset[d]);
        var hi = self.fromContent(d, self.offset[d] + self.viewLen(d));
        if (hi - lo < min_thumb) {
            const mid = (lo + hi) / 2.0;
            lo = mid - min_thumb / 2.0;
            hi = mid + min_thumb / 2.0;
            const s = self.barStart(d);
            const e = s + self.barLen(d);
            if (lo < s) {
                hi += s - lo;
                lo = s;
            }
            if (hi > e) {
                lo -= hi - e;
                hi = e;
            }
        }
        return .{ .lo = lo, .hi = hi };
    }

    /// Cross-axis position of the bar's near edge (right edge for vertical, bottom for
    /// horizontal), given the current visual `w`.
    fn barCross(self: *const Scroll, d: u8, w: f32) f32 {
        if (d == 1) { // vertical bar at the right
            return self.viewport.x + self.viewport.w - w - inner_margin;
        } else { // horizontal bar at the bottom
            return self.viewport.y + self.viewport.h - w - inner_margin;
        }
    }

    fn visualWidth(self: *const Scroll, d: u8) f32 {
        return dormant_width + (expanded_width - dormant_width) * anim.cubicOut(self.bar_hover[d]);
    }

    /// Is `(x,y)` within the grab strip of axis `d`'s bar?
    fn overBarStrip(self: *const Scroll, d: u8, x: f32, y: f32) bool {
        if (self.maxOff(d) <= 0) return false;
        const along = if (d == 1) y else x;
        const cross = if (d == 1) x else y;
        const s = self.barStart(d);
        if (along < s or along > s + self.barLen(d)) return false;
        const cx = self.barCross(d, grab_cross);
        return cross >= cx and cross <= cx + grab_cross + 2.0;
    }

    fn inViewport(self: *const Scroll, x: f32, y: f32) bool {
        return x >= self.viewport.x and x < self.viewport.x + self.viewLen(0) and
            y >= self.viewport.y and y < self.viewport.y + self.viewLen(1);
    }

    fn clampOffsets(self: *Scroll) void {
        for (0..2) |i| {
            const d: u8 = @intCast(i);
            const m = self.maxOff(d);
            const clamped = std.math.clamp(self.offset[d], 0.0, m);
            if (clamped != self.offset[d]) {
                self.offset[d] = clamped;
                self.vel[d] = 0; // no bounce; kill momentum at the ends
                self.unprocessed[d] = 0;
            }
        }
    }

    // --- drawing -----------------------------------------------------------------------

    pub fn draw(self: *Scroll, canvas: *paint.Canvas) void {
        for (0..2) |i| {
            const d: u8 = @intCast(i);
            const show = anim.cubicOut(self.show[d]);
            if (show <= 0.01 or self.maxOff(d) <= 0) continue;

            const bh = anim.cubicOut(self.bar_hover[d]);
            const ah = anim.cubicOut(self.area_hover);
            const interacting = (self.dragging != null and self.dragging.? == d);
            const inter_f = if (interacting) 1.0 else bh;

            const bg_op = @max(anim.lerp(0.0, bg_active, ah), anim.lerp(0.0, bg_interact, inter_f)) * show;
            const handle_op = @max(anim.lerp(0.0, handle_active, ah), anim.lerp(0.0, handle_interact, inter_f)) * show;

            const w = self.visualWidth(d);
            const cross = self.barCross(d, w);
            const seg = self.thumbSeg(d);
            const rad = w / 2.0;

            // Track.
            if (bg_op > 0.001) {
                if (d == 1)
                    canvas.fillRoundedRect(cross, self.barStart(d), w, self.barLen(d), rad, Color.rgba(16, 17, 21, bg_op))
                else
                    canvas.fillRoundedRect(self.barStart(d), cross, self.barLen(d), w, rad, Color.rgba(16, 17, 21, bg_op));
            }
            // Thumb: gray at rest, brighter on hover, white while dragging.
            const g: u8 = if (interacting) 255 else if (bh > 0.5) 240 else 180;
            const thumb = Color.rgba(g, g, g, handle_op);
            if (d == 1)
                canvas.fillRoundedRect(cross, seg.lo, w, seg.hi - seg.lo, rad, thumb)
            else
                canvas.fillRoundedRect(seg.lo, cross, seg.hi - seg.lo, w, rad, thumb);
        }
    }

    // --- input (plain method calls; a UI layer maps its events to these) ---------------

    /// A wheel/scroll notch (or trackpad pixel delta) on `axis`. `line` is true for
    /// discrete wheel notches (smoothed in `tick`), false for trackpad pixels (applied
    /// verbatim). Returns true if the event fell inside the scrollable content.
    pub fn onWheel(self: *Scroll, axis: Axis, value: f32, line: bool, x: f32, y: f32) bool {
        const d: u8 = @intFromEnum(axis);
        if (!self.inViewport(x, y) or self.maxOff(d) <= 0) return false;
        if (line) {
            self.unprocessed[d] += value * wheel_gain; // smoothed in tick
        } else {
            self.offset[d] += value; // trackpad pixels: apply immediately
            self.clampOffsets();
        }
        return true;
    }

    /// Primary-button press at `(x,y)`. Grabs a thumb (or jumps it under the cursor) if the
    /// press lands on a bar. Returns true if it started a drag.
    pub fn onButtonDown(self: *Scroll, x: f32, y: f32) bool {
        var d: u8 = 1;
        while (true) : (d -%= 1) {
            if (self.overBarStrip(d, x, y)) {
                const seg = self.thumbSeg(d);
                const p = if (d == 1) y else x;
                self.grab = if (p >= seg.lo and p <= seg.hi) p - seg.lo else (seg.hi - seg.lo) / 2.0;
                self.dragging = d;
                self.dragTo(d, p);
                return true;
            }
            if (d == 0) break;
        }
        return false;
    }

    /// Primary-button release. Returns true if it ended an in-progress drag.
    pub fn onButtonUp(self: *Scroll) bool {
        const was = self.dragging != null;
        self.dragging = null;
        return was;
    }

    /// Pointer moved to `(x,y)`. Updates hover state and, while dragging, the offset.
    /// Returns true if the motion should be consumed (over a bar or dragging).
    pub fn onMotion(self: *Scroll, x: f32, y: f32) bool {
        self.pointer = .{ x, y };
        self.in_area = self.inViewport(x, y);
        self.over_bar[0] = self.overBarStrip(0, x, y);
        self.over_bar[1] = self.overBarStrip(1, x, y);
        if (self.dragging) |d| {
            self.dragTo(d, if (d == 1) y else x);
            return true;
        }
        // Consume hovers over a bar so the thumb feedback is ours; let plain content
        // motion through to the app.
        return self.over_bar[0] or self.over_bar[1];
    }

    fn dragTo(self: *Scroll, d: u8, pointer_along: f32) void {
        const new_top = pointer_along - self.grab;
        self.offset[d] = anim.remapClamp(new_top, self.barStart(d), self.barStart(d) + self.barLen(d), 0.0, self.content[d]);
        self.clampOffsets();
    }

    // --- per-frame advance -------------------------------------------------------------

    /// Advance smoothing, kinetics and fades by `dt` seconds. Returns true while anything is
    /// still animating (so the owner keeps requesting frames).
    pub fn tick(self: *Scroll, dt: f32) bool {
        var active = false;

        // Wheel low-pass: reach 90% of the pending delta in 0.1s.
        const t = 1.0 - std.math.pow(f32, 0.1, dt / 0.1);
        for (0..2) |i| {
            const d: u8 = @intCast(i);
            if (@abs(self.unprocessed[d]) >= 1.0) {
                const applied = t * self.unprocessed[d];
                self.offset[d] += applied;
                self.unprocessed[d] -= applied;
                active = true;
            } else if (self.unprocessed[d] != 0) {
                self.offset[d] += self.unprocessed[d];
                self.unprocessed[d] = 0;
                active = true;
            }
            // Kinetic decay (linear friction).
            if (self.vel[d] != 0) {
                const f = friction * dt;
                if (f > @abs(self.vel[d]) or @abs(self.vel[d]) < stop_speed) {
                    self.vel[d] = 0;
                } else {
                    self.vel[d] -= f * std.math.sign(self.vel[d]);
                    self.offset[d] -= self.vel[d] * dt;
                }
                active = true;
            }
        }
        self.clampOffsets();

        // Fades: bar visibility, area hover, per-bar hover.
        for (0..2) |i| {
            const d: u8 = @intCast(i);
            const ns = anim.approach(self.show[d], self.maxOff(d) > 0, dt);
            if (ns != self.show[d]) active = true;
            self.show[d] = ns;
            const nb = anim.approach(self.bar_hover[d], self.over_bar[d] or (self.dragging != null and self.dragging.? == d), dt);
            if (nb != self.bar_hover[d]) active = true;
            self.bar_hover[d] = nb;
        }
        const na = anim.approach(self.area_hover, self.in_area or self.dragging != null, dt);
        if (na != self.area_hover) active = true;
        self.area_hover = na;

        return active or self.dragging != null;
    }
};

// --- tests ---------------------------------------------------------------------------

fn testScroll() Scroll {
    var s = Scroll{};
    s.setViewport(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    s.setContent(200, 1000); // vertical overflow only
    return s;
}

test "offset clamps to content minus viewport, no overscroll" {
    var s = testScroll();
    s.offset[1] = 5000;
    s.clampOffsets();
    try std.testing.expectEqual(@as(f32, 900), s.offset[1]); // 1000 - 100
    s.offset[1] = -50;
    s.clampOffsets();
    try std.testing.expectEqual(@as(f32, 0), s.offset[1]);
    try std.testing.expectEqual(@as(f32, 0), s.maxOff(0)); // no horizontal overflow
}

test "thumb length reflects viewport/content ratio and honors the minimum" {
    var s = testScroll();
    const seg = s.thumbSeg(1);
    // viewport/content = 100/1000 → ~10% of the ~96px track ≈ 9.6px, bumped to min 12.
    try std.testing.expect(seg.hi - seg.lo >= min_thumb - 0.01);
    // A gentler ratio gives a proportional, larger-than-min thumb.
    s.setContent(200, 200);
    const seg2 = s.thumbSeg(1);
    try std.testing.expect(seg2.hi - seg2.lo > seg.hi - seg.lo);
}

test "kinetic velocity decays to zero" {
    var s = testScroll();
    s.offset[1] = 400;
    s.vel[1] = 800;
    var iters: usize = 0;
    while (s.vel[1] != 0 and iters < 1000) : (iters += 1) {
        _ = s.tick(0.016);
    }
    try std.testing.expectEqual(@as(f32, 0), s.vel[1]);
    try std.testing.expect(iters < 1000);
}

test "wheel notches smooth in over several ticks" {
    var s = testScroll();
    _ = s.onWheel(.vertical, 10, true, 100, 50); // a notch inside the content
    try std.testing.expect(s.unprocessed[1] > 0);
    var iters: usize = 0;
    while (s.unprocessed[1] != 0 and iters < 1000) : (iters += 1) {
        _ = s.tick(0.016);
    }
    try std.testing.expect(s.offset[1] > 0); // it moved
    try std.testing.expectEqual(@as(f32, 0), s.unprocessed[1]);
}
