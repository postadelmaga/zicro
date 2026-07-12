//! zicro on the WEB — the software canvas in a browser tab.
//!
//! zicro's whole render path is a CPU rasterizer into an RGBA byte buffer, so the
//! web "backend" is tiny: this wasm module owns the buffer, draws the design-system
//! primitives into it each frame, and the JS glue (`web/index.html`) blits it into a
//! `<canvas>` with one `putImageData` and feeds pointer events back. No WebGL, no
//! emscripten, no libc — `wasm32-freestanding` + `zicro.paint` (pure Zig).
//!
//! Build:  zig build web         (emits zig-out/web/zicro.wasm + copies web/)
//! Run:    serve zig-out/web and open index.html (the build prints the command).

const std = @import("std");
const zicro = @import("zicro");
const paint = zicro.paint;
const text = zicro.text;
const Color = paint.Color;
const Corners = paint.Corners;

// The text engine (stb_truetype in wasm). Lazily created on the first frame; the wasm
// page lives forever, so it is never deinit'd.
var font: ?text.Font = null;

fn ensureFont() ?*text.Font {
    if (font == null) font = text.Font.initDefault(std.heap.wasm_allocator) catch return null;
    return &font.?;
}

/// Draw `s` left-aligned with its TOP at `y` (converts to a baseline via vmetrics).
fn label(c: *paint.Canvas, f: *text.Font, x: f32, y: f32, s: []const u8, size: u16, style: text.Style, color: Color) void {
    const v = f.vmetrics(size, style);
    const baseline = @as(i32, @intFromFloat(y)) + v.ascent;
    c.drawText(f, @intFromFloat(x), baseline, s, .{ .size = size, .style = style, .color = color });
}

/// Centered label within [x, x+w] at vertical center `cy`.
fn labelCentered(c: *paint.Canvas, f: *text.Font, x: f32, w: f32, cy: f32, s: []const u8, size: u16, style: text.Style, color: Color) void {
    const tw: f32 = @floatFromInt(f.measure(size, style, s));
    const v = f.vmetrics(size, style);
    const th: f32 = @floatFromInt(v.ascent - v.descent);
    const baseline = @as(i32, @intFromFloat(cy - th / 2)) + v.ascent;
    c.drawText(f, @intFromFloat(x + (w - tw) / 2), baseline, s, .{ .size = size, .style = style, .color = color });
}

// A fixed backing buffer — no allocator needed on a single-page wasm module. Straight
// RGBA8888 (bytes R,G,B,A), which is exactly the layout a browser `ImageData` wants, so
// JS wraps this memory with zero copy.
const MAX_W: u32 = 1920;
const MAX_H: u32 = 1200;
var pixels: [MAX_W * MAX_H]u32 = undefined;

var width: u32 = 1000;
var height: u32 = 640;
var mouse_x: f32 = -1;
var mouse_y: f32 = -1;
var mouse_down: bool = false;
var toggle_on: bool = true;

// --- the exported wasm ABI the JS glue drives --------------------------------------

/// Pointer to the RGBA buffer (JS reads it straight out of the wasm memory).
export fn zicroPixels() [*]u8 {
    return @ptrCast(&pixels);
}
export fn zicroWidth() u32 {
    return width;
}
export fn zicroHeight() u32 {
    return height;
}

/// The compositor handed us a (new) drawable size. Clamp to the static buffer.
export fn zicroResize(w: u32, h: u32) void {
    width = std.math.clamp(w, 1, MAX_W);
    height = std.math.clamp(h, 1, MAX_H);
}

export fn zicroPointer(x: f32, y: f32, down: i32) void {
    mouse_x = x;
    mouse_y = y;
    // Rising edge over the toggle pill flips it (see its rect in `draw`).
    const was_down = mouse_down;
    mouse_down = down != 0;
    if (mouse_down and !was_down and hitToggle(x, y)) toggle_on = !toggle_on;
}

/// Draw one frame at time `t` (seconds). Called from requestAnimationFrame.
export fn zicroFrame(t: f64) void {
    var canvas = paint.Canvas.initRgba8(pixels[0 .. width * height], width, height);
    draw(&canvas, @floatCast(t));
}

// --- the picture: the design system, rendered on the CPU, in a browser --------------

const sig = struct {
    const bg_top = Color.rgba(20, 22, 30, 1.0);
    const bg_bot = Color.rgba(11, 12, 18, 1.0);
    const text = Color.rgba(235, 238, 245, 0.95);
    const card = Color.rgba(255, 255, 255, 0.05);
    const widget = Color.rgba(255, 255, 255, 0.085);
    const border = Color.rgba(255, 255, 255, 0.13);
    const accent = Color.rgba(120, 170, 255, 0.98);
    const accent2 = Color.rgba(158, 122, 255, 0.98);
    const knob = Color.rgba(255, 255, 255, 0.96);
    const shadow = Color.rgba(4, 6, 18, 0.36);
};

const toggle_rect = struct {
    const x: f32 = 260;
    const y: f32 = 250;
    const w: f32 = 48;
    const h: f32 = 27;
};

fn hitToggle(x: f32, y: f32) bool {
    return x >= toggle_rect.x and x <= toggle_rect.x + toggle_rect.w and
        y >= toggle_rect.y and y <= toggle_rect.y + toggle_rect.h;
}

fn lerp(a: f32, b: f32, s: f32) f32 {
    return a + (b - a) * s;
}

fn draw(c: *paint.Canvas, t: f32) void {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);

    // Backdrop: vertical gradient (the new paint primitive).
    c.fillRoundedRectVGradient(0, 0, w, h, 0, sig.bg_top, sig.bg_bot);

    // A raised card with a soft elevation shadow + glassy sheen.
    const card = .{ .x = @as(f32, 40), .y = @as(f32, 40), .w = @min(w - 80, 640), .h = @as(f32, 360) };
    c.dropShadowRoundedRect(card.x, card.y, card.w, card.h, 16, 22, 8, sig.shadow);
    c.fillRoundedRectVGradient(card.x, card.y, card.w, card.h, 16, brighten(sig.card, 0.05), brighten(sig.card, -0.03));
    c.strokeRoundedRect(card.x, card.y, card.w, card.h, 16, 1, sig.border);

    // Primary button: accent gradient (blue→violet), elevated. Lightens on hover.
    const btn = .{ .x = card.x + 40, .y = card.y + 60, .w = @as(f32, 200), .h = @as(f32, 44) };
    const over_btn = inside(btn, mouse_x, mouse_y);
    c.dropShadowRoundedRect(btn.x, btn.y, btn.w, btn.h, 10, 16, 5, sig.shadow);
    const a1 = if (over_btn) brighten(sig.accent, 0.10) else sig.accent;
    const a2 = if (over_btn) brighten(sig.accent2, 0.10) else sig.accent2;
    c.fillRoundedRectVGradient(btn.x, btn.y, btn.w, btn.h, 10, a1, a2);

    // Secondary (ghost) button.
    const btn2 = .{ .x = btn.x + btn.w + 20, .y = btn.y, .w = @as(f32, 150), .h = @as(f32, 44) };
    const over2 = inside(btn2, mouse_x, mouse_y);
    c.fillRoundedRect(btn2.x, btn2.y, btn2.w, btn2.h, 10, if (over2) brighten(sig.widget, 0.06) else sig.widget);
    c.strokeRoundedRect(btn2.x, btn2.y, btn2.w, btn2.h, 10, 1, sig.border);

    // Toggle pill (click it): animated knob.
    const tr = toggle_rect;
    const on: f32 = if (toggle_on) 1 else 0;
    const pill = mix(sig.widget, sig.accent, on);
    c.fillRoundedRect(tr.x, tr.y, tr.w, tr.h, tr.h / 2, pill);
    c.strokeRoundedRect(tr.x, tr.y, tr.w, tr.h, tr.h / 2, 1, sig.border);
    const knob_d: f32 = 21;
    const m = (tr.h - knob_d) / 2;
    const kx = tr.x + m + on * (tr.w - knob_d - 2 * m);
    c.dropShadowRoundedRect(kx, tr.y + m, knob_d, knob_d, knob_d / 2, 6, 2, sig.shadow);
    c.fillRoundedRect(kx, tr.y + m, knob_d, knob_d, knob_d / 2, sig.knob);

    // A determinate progress/slider bar with a breathing accent fill.
    const bar = .{ .x = btn.x, .y = card.y + 200, .w = @as(f32, 370), .h = @as(f32, 8) };
    const p = 0.5 + 0.35 * @sin(t * 1.2);
    c.fillRoundedRect(bar.x, bar.y, bar.w, bar.h, 4, sig.widget);
    c.fillRoundedRectVGradient(bar.x, bar.y, bar.w * p, bar.h, 4, sig.accent, sig.accent2);
    const kx2 = bar.x + bar.w * p - 8;
    c.dropShadowRoundedRect(kx2, bar.y - 6, 16, 16, 8, 6, 2, sig.shadow);
    c.fillRoundedRect(kx2, bar.y - 6, 16, 16, 8, sig.knob);

    // An indeterminate spinner — proof the arc/AA path runs in wasm.
    c.drawSpinner(card.x + card.w - 40, card.y + card.h - 40, 14, 3.5, t, sig.accent);

    // Text — the whole point of #4: stb_truetype rasterized in wasm.
    if (ensureFont()) |f| {
        label(c, f, card.x + 4, 8, "zicro · web", 15, .bold, brighten(sig.text, -0.1));
        labelCentered(c, f, btn.x, btn.w, btn.y + btn.h / 2, "Primary action", 15, .regular, Color.rgba(10, 14, 28, 0.98));
        labelCentered(c, f, btn2.x, btn2.w, btn2.y + btn2.h / 2, "Secondary", 15, .regular, sig.text);
        label(c, f, tr.x + tr.w + 12, tr.y + 4, if (toggle_on) "Notifications  on" else "Notifications  off", 15, .regular, sig.text);
        label(c, f, bar.x, bar.y - 26, "Volume", 13, .regular, brighten(sig.text, -0.25));
        label(c, f, card.x + 4, card.y + card.h + 10, "CPU-rasterized in WebAssembly — stb_truetype, no libc", 13, .regular, brighten(sig.text, -0.4));
    }

    // A soft "cursor" halo so you can see the pointer wiring is live.
    if (mouse_x >= 0) c.fillRoundedRect(mouse_x - 3, mouse_y - 3, 6, 6, 3, sig.accent);
}

fn inside(r: anytype, x: f32, y: f32) bool {
    return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h;
}

/// Toward white (amt>0) or black (amt<0), alpha preserved.
fn brighten(col: Color, amt: f32) Color {
    if (amt >= 0) return .{ .r = col.r + (1 - col.r) * amt, .g = col.g + (1 - col.g) * amt, .b = col.b + (1 - col.b) * amt, .a = col.a };
    const k = -amt;
    return .{ .r = col.r * (1 - k), .g = col.g * (1 - k), .b = col.b * (1 - k), .a = col.a };
}

fn mix(a: Color, b: Color, s: f32) Color {
    return .{ .r = lerp(a.r, b.r, s), .g = lerp(a.g, b.g, s), .b = lerp(a.b, b.b, s), .a = lerp(a.a, b.a, s) };
}
