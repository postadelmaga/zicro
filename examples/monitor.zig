//! `zig build run-monitor` — live low-latency monitoring: mic → gain → speaker.
//!
//! The capstone that ties the audio work together on one thread: [`DeviceIn`] captures from
//! the sound card, an [`AudioPipeline`] runs an in-place [`Gain`] stage, and [`DeviceOut`]
//! plays it straight back — no bus, no thread-per-stage. On Linux this rides the PipeWire
//! backend when a graph is up (else ALSA), so the whole loop is the low-latency path from
//! issues #16/#17/#18.
//!
//! ⚠️ It's a real monitor: mic straight to speakers *will* feed back. Use headphones. The
//! gain is set low (0.3) to keep any feedback tame.

const std = @import("std");
const zicro = @import("zicro");

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const rate: u32 = 48_000;
    const channels: u16 = 2;

    var mic = zicro.audio_device.DeviceIn.open(rate, channels) catch |err| {
        std.debug.print("no capture device ({s}) — is PipeWire/ALSA up?\n", .{@errorName(err)});
        return;
    };
    defer mic.close();
    var speaker = zicro.audio_device.DeviceOut.open(rate, channels) catch |err| {
        std.debug.print("no output device ({s})\n", .{@errorName(err)});
        return;
    };
    defer speaker.close();

    var bus = zicro.LocalBus.init(gpa, io);
    defer bus.deinit();
    var rt = try zicro.Runtime.init(gpa, io, &bus);

    // One in-place stage; a real monitor would chain denoise/EQ here the same way.
    var gain = zicro.audio_pipeline.Gain{ .factor = 0.3 };
    const stages = [_]zicro.audio_pipeline.AudioProcessor{
        zicro.audio_pipeline.AudioProcessor.of(zicro.audio_pipeline.Gain, &gain),
    };

    var pipe = zicro.audio_pipeline.AudioPipeline.init(
        "monitor",
        zicro.audio.AudioIn.of(zicro.audio_device.DeviceIn, &mic),
        &stages,
        zicro.audio.AudioOut.of(zicro.audio_device.DeviceOut, &speaker),
        rate,
        channels,
        256, // block frames — the latency knob
    );
    try rt.spawn(zicro.Module.of(zicro.audio_pipeline.AudioPipeline, &pipe));

    std.debug.print("monitoring mic → gain(0.3) → speaker for 3s (use headphones!)…\n", .{});
    io.sleep(.fromNanoseconds(3 * std.time.ns_per_s), .awake) catch {};

    rt.shutdown();
    var report = rt.join();
    defer report.deinit();
    std.debug.print("done ({s}).\n", .{if (report.isClean()) "clean" else "with errors"});
}
