//! `zig build run-plugin`
//!
//! Opens a glass window and `dlopen`s the `libzrame_clock.so` plugin (built alongside),
//! which registers a live "uptime" panel. Pass a path as the first argument to load a
//! different plugin. Demonstrates the POSIX dynamic-loading path end-to-end.

const std = @import("std");
const zrame = @import("zrame");

fn drawContent(canvas: *zrame.Canvas, content: zrame.Rect, user: ?*anyopaque) void {
    const font: *zrame.Font = @ptrCast(@alignCast(user.?));
    const cx: f32 = @floatFromInt(content.x);
    const cy: f32 = @floatFromInt(content.y);
    canvas.drawText(font, @as(i32, @intFromFloat(cx)) + 24, @as(i32, @intFromFloat(cy)) + 60, "dlopen'd plugin →", .{
        .size = 20,
        .style = .bold,
        .color = zrame.Color.rgba(235, 238, 250, 0.85),
    });
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // `user` must be set before init: the first configure paints during `Window.init`.
    var font = try zrame.Font.initDefault(gpa);
    defer font.deinit();

    const win = try zrame.Window.init(gpa, .{
        .title = "zrame — Plugin Host",
        .app_id = "dev.zrame.pluginhost",
        .width = 560,
        .height = 360,
        .on_draw = drawContent,
        .user = @ptrCast(&font),
        .titlebar = true,
        .titlebar_style = .material,
        .style = zrame.Style.material(),
    });
    defer win.deinit();

    // The plugin `.so` is installed next to the host by `zig build`.
    const path = "zig-out/lib/libzrame_clock.so";
    win.loadPlugin(path) catch |e| std.log.warn("zrame: could not load plugin {s}: {}", .{ path, e });

    try win.run();
}
