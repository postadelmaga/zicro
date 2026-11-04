//! A loadable zrame plugin, built as a shared library (`libzrame_clock.so`).
//!
//! It exports `zrame_plugin_register`, which the host `dlopen`s and calls (see
//! `plugin_host.zig` / `Window.loadPlugin`). The plugin registers one panel — a small
//! glass "uptime" pill in the top-right corner that ticks every frame — proving the whole
//! panel contract works identically across the `.so` boundary as it does in-tree.

const std = @import("std");
const zrame = @import("zrame");

const Color = zrame.Color;

const ClockPanel = struct {
    t: f32 = 0,

    pub fn draw(self: *ClockPanel, canvas: *zrame.Canvas, host: zrame.Host) void {
        const info = host.info();
        const w: f32 = 104;
        const h: f32 = 30;
        const x = @as(f32, @floatFromInt(info.content.x + info.content.w)) - w - 14;
        const y = @as(f32, @floatFromInt(info.content.y)) + 12;
        canvas.fillRoundedRect(x, y, w, h, 15, Color.rgba(0, 0, 0, 0.35));
        canvas.strokeRoundedRect(x, y, w, h, 15, 1.0, Color.rgba(255, 255, 255, 0.16));
        const font = host.font() orelse return;
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "plugin {d:.1}s", .{self.t}) catch return;
        const v = font.vmetrics(14, .bold);
        const th = v.ascent - v.descent;
        const baseline = @as(i32, @intFromFloat(y)) + @divFloor(@as(i32, @intFromFloat(h)) - th, 2) + v.ascent;
        const tw = font.measure(14, .bold, s);
        canvas.drawText(font, @as(i32, @intFromFloat(x + w / 2)) - @divFloor(tw, 2), baseline, s, .{
            .size = 14,
            .style = .bold,
            .color = Color.rgba(150, 210, 255, 0.95),
        });
    }

    pub fn onInput(self: *ClockPanel, event: zrame.Event, host: zrame.Host) bool {
        _ = self;
        _ = event;
        _ = host;
        return false;
    }

    pub fn tick(self: *ClockPanel, dt: f32, host: zrame.Host) bool {
        _ = host;
        self.t += dt;
        return true; // self-animating: keep requesting frames
    }

    pub fn deinit(self: *ClockPanel, gpa: std.mem.Allocator) void {
        gpa.destroy(self);
    }
};

/// C-ABI entry point the host resolves via `dlsym`. Allocate through `reg.gpa`.
export fn zrame_plugin_register(reg: *zrame.plugin.Registry) callconv(.c) c_int {
    const gpa = reg.gpa;
    const p = gpa.create(ClockPanel) catch return 1;
    p.* = .{};
    reg.add(zrame.Panel.of(ClockPanel, p), true) catch {
        gpa.destroy(p);
        return 2;
    };
    return 0;
}
