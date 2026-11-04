//! zrame on the WEB — a glass window in a browser tab.
//!
//! The whole zrame chrome (rounded translucent panel, drop shadow, title-bar controls,
//! floating scrollbars) is CPU + platform-independent, so this is an ordinary zrame app:
//! open a `Window` with a title bar and an `on_draw`, and it renders its glass window
//! inside a `<canvas>` via the web backend (`window_web.zig`), which paints the chrome and
//! hands the content rect to `on_draw`. The only web-specific line is `zicroBoot` (wasm
//! has no auto-main; JS calls it once).
//!
//!   zig build web   → zig-out/web/{zrame.wasm,index.html}

const std = @import("std");
const zrame = @import("zrame");
const paint = zrame.paint;
const Color = paint.Color;

const gpa = std.heap.wasm_allocator;

var g_win: *zrame.Window = undefined;
var booted = false;

export fn zicroBoot() void {
    if (booted) return;
    g_win = zrame.Window.init(gpa, .{
        .title = "zrame · web",
        .width = 760,
        .height = 480,
        .titlebar = true,
        .titlebar_style = .macos,
        .style = paint.Style.carbon(), // dark metallized glass — reads well over any page
        .on_draw = onDraw,
    }) catch return;
    booted = true;
}

fn onDraw(canvas: *paint.Canvas, content: zrame.Rect, _: ?*anyopaque) void {
    const f = g_win.textFont() catch return;
    const x0: i32 = @as(i32, @intCast(content.x)) + 30;
    const cy0: i32 = @as(i32, @intCast(content.y));
    var y: i32 = cy0 + 26;

    canvas.drawText(f, x0, y + 26, "zrame · web", .{ .size = 30, .style = .bold, .color = Color.rgba(235, 238, 250, 1.0) });
    y += 54;
    canvas.drawText(f, x0, y + 16, "Glass chrome, rendered on the CPU, in a browser.", .{ .size = 15, .style = .regular, .color = Color.rgba(200, 208, 224, 0.85) });
    y += 44;

    // A row of glass "cards" to show the panel surface + rounded rects on top of the chrome.
    const accent = [_]Color{ Color.rgba(120, 170, 255, 0.9), Color.rgba(158, 122, 255, 0.9), Color.rgba(120, 230, 180, 0.9) };
    const labels = [_][]const u8{ "Frost", "Aurora", "Mint" };
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const cxi: i32 = x0 + @as(i32, @intCast(i)) * 180;
        const cx: f32 = @floatFromInt(cxi);
        const cy: f32 = @floatFromInt(y);
        canvas.fillRoundedRect(cx, cy, 160, 96, 14, Color.rgba(255, 255, 255, 0.06));
        canvas.strokeRoundedRect(cx, cy, 160, 96, 14, 1, Color.rgba(255, 255, 255, 0.14));
        canvas.fillRoundedRect(cx + 16, cy + 16, 40, 40, 12, accent[i]);
        canvas.drawText(f, cxi + 16, y + 80, labels[i], .{ .size = 15, .style = .bold, .color = Color.rgba(230, 234, 244, 0.95) });
    }

    const foot_y: i32 = cy0 + @as(i32, @intCast(content.h)) - 24;
    canvas.drawText(f, x0, foot_y, "Drag the title bar · the traffic-light controls are live", .{ .size = 13, .style = .regular, .color = Color.rgba(170, 178, 196, 0.7) });
}
