//! `zig build run-hello`
//!
//! Four static glass windows, one per style preset. Everything that differs between
//! them is data: a `Demo` entry with the preset, an accent tint for the info tile,
//! and the letter glyph as a list of rounded-rect segments.

const std = @import("std");
const zrame = @import("zrame");

/// One rounded-rect segment of a letter glyph: `{ x, y, w, h }` from the glyph origin.
const Seg = [4]f32;

const Demo = struct {
    title: [:0]const u8,
    app_id: [:0]const u8,
    style: zrame.Style,
    /// Accent color of the second info tile.
    tint: zrame.Color,
    glyph: []const Seg,
    /// Title-bar control layout for this window.
    tb: zrame.TitlebarStyle = .macos,
};

const glyph_a = [_]Seg{ .{ 0, 0, 10, 60 }, .{ 25, 0, 10, 60 }, .{ 0, 0, 35, 10 }, .{ 0, 25, 35, 10 } };
const glyph_b = [_]Seg{ .{ 0, 0, 10, 60 }, .{ 0, 0, 30, 10 }, .{ 0, 25, 30, 10 }, .{ 0, 50, 30, 10 }, .{ 20, 0, 10, 35 }, .{ 20, 25, 10, 35 } };
const glyph_c = [_]Seg{ .{ 0, 0, 10, 60 }, .{ 0, 0, 35, 10 }, .{ 0, 50, 35, 10 } };
const glyph_d = [_]Seg{ .{ 0, 0, 10, 60 }, .{ 0, 0, 25, 10 }, .{ 0, 50, 25, 10 }, .{ 18, 5, 10, 50 } };

const demos = [_]Demo{
    .{
        .title = "zrame — Window A (Fluent Design)",
        .app_id = "dev.zrame.hello.a",
        .style = zrame.Style.fluent(),
        .tint = zrame.Color.rgba(255, 255, 255, 0.15),
        .glyph = &glyph_a,
        .tb = .material,
    },
    .{
        .title = "zrame — Window B (Vision Pro Glass)",
        .app_id = "dev.zrame.hello.b",
        .style = zrame.Style.macos(),
        .tint = zrame.Color.rgba(137, 180, 250, 0.45),
        .glyph = &glyph_b,
    },
    .{
        .title = "zrame — Window C (Aurora Glass)",
        .app_id = "dev.zrame.hello.c",
        .style = zrame.Style.aurora(),
        .tint = zrame.Color.rgba(243, 139, 168, 0.45),
        .glyph = &glyph_c,
    },
    .{
        .title = "zrame — Window D (Material Design)",
        .app_id = "dev.zrame.hello.d",
        .style = zrame.Style.material(),
        .tint = zrame.Color.rgba(166, 227, 161, 0.45),
        .glyph = &glyph_d,
    },
};

fn drawContent(canvas: *zrame.Canvas, content: zrame.Rect, user: ?*anyopaque) void {
    const demo: *const Demo = @ptrCast(@alignCast(user.?));
    const cx: f32 = @floatFromInt(content.x);
    const cy: f32 = @floatFromInt(content.y);

    const white = zrame.Color.rgba(255, 255, 255, 0.65);
    for (demo.glyph) |seg| {
        canvas.fillRoundedRect(cx + 32 + seg[0], cy + 32 + seg[1], seg[2], seg[3], 4, white);
    }

    canvas.fillRoundedRect(cx + 88, cy + 32, 280, 26, 13, zrame.Color.rgba(255, 255, 255, 0.20));
    canvas.fillRoundedRect(cx + 88, cy + 70, 300, 22, 11, demo.tint);
}

fn runWindow(win: *zrame.Window) void {
    win.run() catch {};
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var wins: [demos.len]*zrame.Window = undefined;
    var opened: usize = 0;
    defer for (wins[0..opened]) |win| win.deinit();
    for (&demos, &wins) |*demo, *win| {
        win.* = try zrame.Window.init(gpa, .{
            .title = demo.title,
            .app_id = demo.app_id,
            .width = 640,
            .height = 400,
            .on_draw = drawContent,
            .user = @ptrCast(@constCast(demo)),
            .style = demo.style,
            .titlebar = true,
            .titlebar_style = demo.tb,
        });
        opened += 1;
    }

    // Each window owns its thread (each has its own Wayland connection); the last
    // one runs on main. Closing a window ends its loop.
    var threads: [demos.len - 1]std.Thread = undefined;
    var spawned: usize = 0;
    defer for (threads[0..spawned]) |t| t.join();
    for (&threads, wins[0 .. demos.len - 1]) |*t, win| {
        t.* = try std.Thread.spawn(.{}, runWindow, .{win});
        spawned += 1;
    }
    try wins[demos.len - 1].run();
}
