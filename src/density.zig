//! Density presets — how big the interactive things are, independent of how they look.
//!
//! The look presets (`widget.Theme.macos()`, `.material()`, `.signature()`) pick colors,
//! radii and surfaces. Density is the other axis: the same look must work under a mouse
//! (a 1-px-accurate pointer, dense layouts are fine) and under a finger (a ~9 mm blob that
//! occludes what it touches). Mixing the two up is the classic touch-port bug: everything
//! draws, but buttons are 28 px tall and the user hits the neighbour.
//!
//! Three presets, in logical px (multiply by the UI scale as usual):
//!
//! | token        | compact | regular | touch | why                                          |
//! |--------------|--------:|--------:|------:|----------------------------------------------|
//! | `ctl_h`      | 28      | 36      | 44    | buttons, fields, steppers, segmented          |
//! | `ctl_h_sm`   | 24      | 30      | 40    | chips, controls inside table rows             |
//! | `ctl_h_lg`   | 36      | 42      | 48    | the primary actions at the foot of a dialog   |
//! | `row_h`      | 28      | 34      | 44    | list/menu rows (the whole row is the target)  |
//! | `hit_min`    | 20      | 24      | 44    | smallest tappable square (icons, handles)     |
//! | `gap`        | 6       | 8       | 10    | spacing between adjacent targets              |
//!
//! `touch` follows Apple's HIG (44 pt minimum target); Material asks 48 dp, which `ctl_h_lg`
//! meets for the actions that matter most. `hit_min` is for the hit area: a 16 px icon can
//! stay 16 px on screen while its tappable square is `hit_min`.
//!
//! Usage:
//! ```zig
//! const d = zicro.density.Density.forPointer(metrics.touch); // .touch or .regular
//! ui.theme = ui.theme.withDensity(d);                         // widget geometry
//! const m = d.metrics();                                      // app-drawn controls
//! const bh = m.ctl_h * scale;
//! ```

pub const Density = enum {
    compact,
    regular,
    touch,

    /// The natural density for the active pointer: `touch` for a finger, `regular` for a
    /// mouse. Apps that offer a choice ("automatic / desktop / touch") call this only for
    /// "automatic".
    pub fn forPointer(touch_input: bool) Density {
        return if (touch_input) .touch else .regular;
    }

    pub fn metrics(d: Density) Metrics {
        return switch (d) {
            .compact => .{ .ctl_h = 28, .ctl_h_sm = 24, .ctl_h_lg = 36, .row_h = 28, .hit_min = 20, .gap = 6, .check = 16, .knob_d = 14, .toggle_w = 36, .toggle_h = 20, .scrollbar_w = 6, .icon = 14 },
            .regular => .{},
            .touch => .{ .ctl_h = 44, .ctl_h_sm = 40, .ctl_h_lg = 48, .row_h = 44, .hit_min = 44, .gap = 10, .check = 24, .knob_d = 24, .toggle_w = 52, .toggle_h = 32, .scrollbar_w = 10, .icon = 20 },
        };
    }
};

/// Geometry tokens for one density (logical px @ scale 1). Defaults = `regular`.
pub const Metrics = struct {
    ctl_h: f32 = 36,
    ctl_h_sm: f32 = 30,
    ctl_h_lg: f32 = 42,
    row_h: f32 = 34,
    hit_min: f32 = 24,
    gap: f32 = 8,
    check: f32 = 18,
    knob_d: f32 = 16,
    toggle_w: f32 = 42,
    toggle_h: f32 = 24,
    scrollbar_w: f32 = 6,
    icon: f32 = 16,

    /// Grow a hit rectangle around its center to at least `hit_min` × `hit_min` (logical
    /// px × `scale`). Drawing stays where it is; only the tappable area gets bigger.
    pub fn hitRect(m: Metrics, x: f32, y: f32, w: f32, h: f32, scale: f32) [4]f32 {
        const min = m.hit_min * scale;
        const nw = @max(w, min);
        const nh = @max(h, min);
        return .{ x - (nw - w) / 2, y - (nh - h) / 2, nw, nh };
    }
};

const std = @import("std");

test "touch targets meet the 44 px minimum, regular keeps the old desktop sizes" {
    const t = Density.touch.metrics();
    try std.testing.expect(t.ctl_h >= 44 and t.row_h >= 44 and t.hit_min >= 44 and t.ctl_h_lg >= 48);
    const r = Density.regular.metrics();
    try std.testing.expectEqual(@as(f32, 36), r.ctl_h);
    try std.testing.expectEqual(Density.touch, Density.forPointer(true));
    try std.testing.expectEqual(Density.regular, Density.forPointer(false));
    // compact < regular < touch on every size token
    const c = Density.compact.metrics();
    inline for (.{ "ctl_h", "ctl_h_sm", "ctl_h_lg", "row_h", "hit_min" }) |f| {
        try std.testing.expect(@field(c, f) < @field(r, f) and @field(r, f) < @field(t, f));
    }
}

test "hitRect grows small targets around their center and leaves big ones alone" {
    const t = Density.touch.metrics();
    const r = t.hitRect(100, 100, 16, 16, 1);
    try std.testing.expectEqual([4]f32{ 86, 86, 44, 44 }, r);
    const big = t.hitRect(0, 0, 200, 60, 1);
    try std.testing.expectEqual([4]f32{ 0, 0, 200, 60 }, big);
}
