//! `zig build run-frames`
//!
//! The full Frame spine, on screen: a zicro **source** (`Painter`) renders an animated
//! plasma into `media.Frame`s at 60 Hz and pushes them down the zero-copy data plane
//! (`media.latest`); zicro's stock **`VideoSink` module** pumps the freshest frame into
//! zrame's `WindowSink`; the frame lands inside a frameless, blurred, rounded,
//! shadowed glass window. Three threads, no shared state outside the channel.
//!
//! The plasma glows through the animated border band (`Style.withBorderAnim`), which
//! is orthogonal to the chrome presets: press **Space** to cycle psy → fluent →
//! macos → aurora → material, all wearing the same animated border. Esc closes.

const std = @import("std");
const zicro = @import("zicro");
const zrame = @import("zrame");

const content_w: u32 = 640;
const content_h: u32 = 400;

/// Width of the animated border band applied to every preset.
const border_anim_width: f32 = 80;

const presets = [_]struct { name: []const u8, style: zrame.Style }{
    .{ .name = "psy", .style = zrame.Style.psy() },
    .{ .name = "fluent", .style = zrame.Style.fluent() },
    .{ .name = "macos", .style = zrame.Style.macos() },
    .{ .name = "aurora", .style = zrame.Style.aurora() },
    .{ .name = "material", .style = zrame.Style.material() },
};

/// Index of the preset currently shown. Only ever touched from the window thread
/// (key callbacks run inside the window's event loop).
var preset_idx: usize = 0;

fn onKey(win: *zrame.Window, key: u32, state: u32, _: ?*anyopaque) void {
    if (key != zrame.wl.KEY_SPACE or state != zrame.wl.KEYBOARD_KEY_STATE_PRESSED) return;
    preset_idx = (preset_idx + 1) % presets.len;
    const preset = presets[preset_idx];
    win.setStyle(preset.style.withBorderAnim(border_anim_width)) catch return;
    std.debug.print("style: {s}\n", .{preset.name});
}

/// A source module: paints plasma frames and sends them latest-wins.
const Painter = struct {
    sender: zicro.media.LatestSender(zicro.media.Frame),

    pub fn id(_: *Painter) []const u8 {
        return "painter";
    }

    pub fn run(self: *Painter, ctx: *zicro.ModuleCtx) anyerror!void {
        defer self.sender.deinit();
        const rgba = try ctx.gpa.alloc(u8, content_w * content_h * 4);
        defer ctx.gpa.free(rgba);

        var pacer = zicro.time.Pacer.hz(ctx.io, 60);
        var t: f32 = 0;
        while (!ctx.shouldStop()) {
            plasma(rgba, t);
            const frame = zicro.media.Frame.init(ctx.gpa, content_w, content_h, .rgba8, rgba) catch break;
            self.sender.send(frame) catch {
                var owned = frame;
                owned.deinit();
                break; // window gone: nothing left to paint for
            };
            // Advance by the pacer's real delta time, not a fixed step: a late frame
            // doesn't slow the motion down, it just skips ahead smoothly.
            t += @floatCast(pacer.tick());
        }
    }

    fn plasma(rgba: []u8, t: f32) void {
        // The wave directions slowly counter-rotate, so the pattern swirls in place
        // instead of scrolling by — liquid rather than conveyor-belt motion.
        const ca = @cos(t * 0.21);
        const sa = @sin(t * 0.21);
        var y: u32 = 0;
        while (y < content_h) : (y += 1) {
            const fy = @as(f32, @floatFromInt(y)) / content_h;
            var x: u32 = 0;
            while (x < content_w) : (x += 1) {
                const fx = @as(f32, @floatFromInt(x)) / content_w;
                const u = fx * ca + fy * sa;
                const w = fy * ca - fx * sa;
                const v = @sin(u * 7.0 + t * 1.1) + @sin((w * 5.0 - t) * 1.3) +
                    @sin((u + w) * 6.0 - t * 0.7);
                const p = rgba[(@as(usize, y) * content_w + x) * 4 ..][0..4];
                p[0] = @intFromFloat(90.0 + 60.0 * @sin(v * std.math.pi * 0.5));
                p[1] = @intFromFloat(120.0 + 80.0 * @sin(v * std.math.pi * 0.5 + 2.1));
                p[2] = @intFromFloat(160.0 + 90.0 * @sin(v * std.math.pi * 0.5 + 4.2));
                p[3] = 170; // punchy enough to glow through the border band
            }
        }
    }
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const win = try zrame.Window.init(gpa, .{
        .title = "zrame — zicro frames",
        .app_id = "dev.zrame.frames",
        .width = content_w,
        .height = content_h,
        .style = presets[0].style.withBorderAnim(border_anim_width),
        .on_key = onKey,
    });
    defer win.deinit();

    // sources → world → sinks, minus the world: pixels don't need a reducer.
    var app = try zicro.App.init(gpa, io);
    const sender, const receiver = try zicro.media.latest(zicro.media.Frame, gpa, io);

    var window_sink = zrame.WindowSink.init(win);
    defer window_sink.deinit();
    var video_sink = zicro.video.VideoSink.init("video", receiver, window_sink.frameSink());
    try app.sink(zicro.Module.of(zicro.video.VideoSink, &video_sink));
    var painter: Painter = .{ .sender = sender };
    try app.source(zicro.Module.of(Painter, &painter));

    // The window owns the main thread until the user closes it; then the app winds down.
    try win.run();
    var report = app.shutdownAndJoin();
    defer report.deinit();
    app.deinit();
    if (!report.isClean()) std.debug.print("modules failed: {d}\n", .{report.failed.len});
}
