//! zicro on ANDROID — a NativeActivity app.
//!
//! native_app_glue calls `android_main` on its own thread; we create the zicro `Window`
//! (the NDK backend), `attach` the glue's `android_app` so its command/input callbacks
//! route into the window, and `run` the loop. `on_draw` renders the design-system
//! primitives (the same CPU rasterizer as every other platform) into the ANativeWindow
//! surface. A tap flips the toggle.
//!
//! Built into libzicro.so + packaged as an APK by scripts/build-apk.sh (see issue #10).

const std = @import("std");
const zicro = @import("zicro");
const window = zicro.window;
const paint = zicro.paint;
const text = zicro.text;
const Color = paint.Color;

const gpa = std.heap.c_allocator; // bionic libc is linked

var g_win: *window.Window = undefined;
var toggle_on = true;
var touch_x: f32 = -1;
var touch_y: f32 = -1;

export fn android_main(app: *zicro.android.android_app) callconv(.c) void {
    g_win = window.Window.init(gpa, undefined, .{
        .title = "zicro-android",
        .on_draw = onDraw,
        .on_mouse = onMouse,
    }) catch return;
    g_win.attach(app);
    g_win.run() catch {};
}

fn onMouse(_: *window.Window, event: window.MouseEvent, _: ?*anyopaque) void {
    switch (event.kind) {
        .motion => {
            touch_x = event.x;
            touch_y = event.y;
        },
        .press => if (hitToggle(event.x, event.y)) {
            toggle_on = !toggle_on;
        },
        else => {},
    }
}

fn hitToggle(x: f32, y: f32) bool {
    return x >= 60 and x <= 60 + 220 and y >= 300 and y <= 300 + 90;
}

fn onDraw(canvas: *paint.Canvas, content: window.Rect, _: ?*anyopaque) void {
    const w: f32 = @floatFromInt(content.w);
    const h: f32 = @floatFromInt(content.h);
    canvas.fillRoundedRectVGradient(0, 0, w, h, 0, Color.rgba(20, 22, 30, 1.0), Color.rgba(11, 12, 18, 1.0));

    const f = g_win.textFont() catch null;
    if (f) |font| {
        canvas.drawText(font, 60, 120, "zicro · android", .{ .size = 44, .style = .bold, .color = Color.rgba(235, 238, 250, 1.0) });
        canvas.drawText(font, 60, 180, "CPU-rasterized design system, NDK NativeActivity", .{ .size = 24, .style = .regular, .color = Color.rgba(200, 208, 224, 0.85) });
    }

    // A raised, gradient primary button with elevation.
    canvas.dropShadowRoundedRect(60, 240, 360, 88, 20, 26, 8, Color.rgba(4, 6, 18, 0.4));
    canvas.fillRoundedRectVGradient(60, 240, 360, 88, 20, Color.rgba(120, 170, 255, 0.98), Color.rgba(158, 122, 255, 0.98));

    // A tappable toggle pill.
    const on: f32 = if (toggle_on) 1 else 0;
    const pill = Color.rgba(120 + @as(u8, @intFromFloat(on * 0)), 170, 255, 0.2 + 0.7 * on);
    canvas.fillRoundedRect(60, 300 + 120, 96, 54, 27, pill);
    const kd: f32 = 44;
    const kx = 60 + 5 + on * (96 - kd - 10);
    canvas.dropShadowRoundedRect(kx, 300 + 125, kd, kd, kd / 2, 8, 3, Color.rgba(4, 6, 18, 0.4));
    canvas.fillRoundedRect(kx, 300 + 125, kd, kd, kd / 2, Color.rgba(255, 255, 255, 0.96));

    // Touch halo so input wiring is visible.
    if (touch_x >= 0) canvas.fillRoundedRect(touch_x - 8, touch_y - 8, 16, 16, 8, Color.rgba(120, 200, 255, 0.9));
}
