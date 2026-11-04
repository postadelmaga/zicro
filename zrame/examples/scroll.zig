//! `zig build run-scroll`
//!
//! A long, scrollable list inside the glass panel, showing the ported egui floating
//! scrollbars: invisible at rest, a 2px thumb that fades in when the pointer enters the
//! content and swells to 10px when you aim at it, smooth mouse-wheel scrolling, and
//! thumb-drag. Content is wider and taller than the viewport, so both bars appear.

const std = @import("std");
const zrame = @import("zrame");

const row_h: f32 = 44.0;
const rows = 60;
const content_w: f32 = 980.0;

const Ctx = struct {
    scroll: *zrame.scroll.Scroll,
    font: *zrame.Font,
};

fn drawContent(canvas: *zrame.Canvas, content: zrame.Rect, user: ?*anyopaque) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));
    const s = ctx.scroll;

    // Tell the scrollbar what region it governs and how big the content is.
    s.setViewport(content);
    s.setContent(content_w, rows * row_h);
    const ox = s.scrollX();
    const oy = s.scrollY();

    // Clip everything to the viewport so scrolled rows never bleed onto the chrome.
    const saved = canvas.setClip(content.x, content.y, content.w, content.h);
    defer canvas.clip = saved;

    const cx: f32 = @floatFromInt(content.x);
    const cy: f32 = @floatFromInt(content.y);
    const vh: f32 = @floatFromInt(content.h);

    var i: usize = 0;
    while (i < rows) : (i += 1) {
        const top = cy + @as(f32, @floatFromInt(i)) * row_h - oy;
        if (top + row_h < cy or top > cy + vh) continue; // cull off-screen rows

        const shade: f32 = if (i % 2 == 0) 0.06 else 0.03;
        canvas.fillRoundedRect(cx + 10 - ox, top + 5, content_w - 20, row_h - 10, 10, zrame.Color.rgba(255, 255, 255, shade));

        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "Row {d:0>2}  —  fluid scrolling, thin bars, macOS/Material chrome", .{i + 1}) catch "row";
        const v = ctx.font.vmetrics(16, .regular);
        const baseline = @as(i32, @intFromFloat(top + (row_h - @as(f32, @floatFromInt(v.ascent - v.descent))) / 2)) + v.ascent;
        canvas.drawText(ctx.font, @as(i32, @intFromFloat(cx + 26 - ox)), baseline, label, .{
            .size = 16,
            .color = zrame.Color.rgba(230, 233, 245, 0.92),
        });
    }
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // `user` must be set before init: the first configure paints during `Window.init`.
    var font = try zrame.Font.initDefault(gpa);
    defer font.deinit();
    var scroll = zrame.scroll.Scroll{};
    var ctx = Ctx{ .scroll = &scroll, .font = &font };

    const win = try zrame.Window.init(gpa, .{
        .title = "zrame — Scroll",
        .app_id = "dev.zrame.scroll",
        .width = 560,
        .height = 460,
        .on_draw = drawContent,
        .user = @ptrCast(&ctx),
        .titlebar = true,
        .titlebar_style = .macos,
        .style = zrame.Style.macos(),
    });
    defer win.deinit();

    try win.addPanel(zrame.Panel.of(zrame.scroll.Scroll, &scroll), false);
    try win.run();
}
