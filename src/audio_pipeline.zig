//! # zicro.audio_pipeline — inline (bus-free) audio processing
//!
//! The [`core`] runtime spawns every [`Module`](core.Module) on its own thread and wires
//! them through the bus / data-plane channels. That is the right shape for loosely-coupled
//! modules — but *wrong* for a hot audio chain (mic → denoise → EQ → speaker): thread hops
//! and per-stage channels add latency and cache churn to a loop that wants to stay on one
//! core. This is the escape hatch: a **single-thread** pipeline that pulls from an
//! [`AudioIn`](audio.AudioIn), runs an ordered chain of in-place [`AudioProcessor`]s, and
//! pushes to an [`AudioOut`](audio.AudioOut) — no bus, no thread-per-stage.
//!
//! It is still a well-behaved [`Module`], so the runtime supervises it and it observes
//! shutdown via [`ModuleCtx.shouldStop`]; the point is only that *inside* the module the
//! processing is inline. Processors work on the raw interleaved `f32` buffer (not on an
//! [`AudioBlock`], whose samples are a shared, immutable [`rc.Rc`]), so a chain is just DSP
//! over a slice — no allocation, no ref-counting, no serialization per stage.

const std = @import("std");
const core = @import("core.zig");
const audio = @import("audio.zig");
const media = @import("media.zig");
const sync = @import("sync.zig");

pub const AudioBlock = media.AudioBlock;
pub const AudioIn = audio.AudioIn;
pub const AudioOut = audio.AudioOut;

/// One in-place stage of an [`AudioPipeline`]. It mutates `samples` (interleaved f32,
/// `frames × channels`) in place — a gain, a filter, a denoiser. Implement this to add a
/// stage; the pipeline hands stages the same buffer in order, on the pipeline's own thread.
pub const AudioProcessor = struct {
    ptr: *anyopaque,
    processFn: *const fn (*anyopaque, samples: []f32, channels: u16) void,

    /// Wrap any type with `pub fn process(self: *T, samples: []f32, channels: u16) void`.
    pub fn of(comptime T: type, instance: *T) AudioProcessor {
        const Impl = struct {
            fn process(ptr: *anyopaque, samples: []f32, channels: u16) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                self.process(samples, channels);
            }
        };
        return .{ .ptr = instance, .processFn = Impl.process };
    }

    pub fn process(self: AudioProcessor, samples: []f32, channels: u16) void {
        self.processFn(self.ptr, samples, channels);
    }
};

/// A single-thread capture → process → play loop. Owns nothing but the borrowed device
/// contracts and the (borrowed) processor chain — keep them alive for the module's life.
/// This is the "inline pipeline": the whole chain runs on this one module's thread, so a
/// monitoring path (mic straight to headphones through a few filters) pays no bus or
/// per-stage-channel cost.
pub const AudioPipeline = struct {
    id_: []const u8,
    in: AudioIn,
    /// Applied in order, in place, once per captured block. Borrowed.
    processors: []const AudioProcessor,
    out: AudioOut,
    rate: u32,
    channels: u16,
    /// Frames processed per iteration — the loop granularity / latency knob.
    block_frames: usize,

    pub fn init(
        id_: []const u8,
        in: AudioIn,
        processors: []const AudioProcessor,
        out: AudioOut,
        rate: u32,
        channels: u16,
        block_frames: usize,
    ) AudioPipeline {
        return .{ .id_ = id_, .in = in, .processors = processors, .out = out, .rate = rate, .channels = channels, .block_frames = block_frames };
    }

    pub fn id(self: *AudioPipeline) []const u8 {
        return self.id_;
    }

    pub fn run(self: *AudioPipeline, ctx: *core.ModuleCtx) anyerror!void {
        const ch: usize = @max(self.channels, 1);
        const scratch = try ctx.gpa.alloc(f32, @max(self.block_frames, 1) * ch);
        defer ctx.gpa.free(scratch);
        while (!ctx.shouldStop()) {
            // capture() blocks ≈one block, so shutdown is observed promptly. 0 ⇒ done.
            const frames = self.in.capture(scratch);
            if (frames == 0) break;
            const used = scratch[0 .. frames * ch];
            // The whole chain runs inline, on this thread — no bus, no per-stage channel.
            for (self.processors) |p| p.process(used, self.channels);
            // Wrap once for the device contract (AudioOut borrows the block).
            var block = try AudioBlock.init(ctx.gpa, self.rate, self.channels, used);
            defer block.deinit();
            self.out.play(&block);
        }
    }
};

// --- a worked-example processor -------------------------------------------------------------

/// The simplest [`AudioProcessor`]: scale every sample by `factor`. Handy as a monitoring
/// trim and as the reference stage for tests — real stages (EQ, denoise) look the same.
pub const Gain = struct {
    factor: f32,

    pub fn process(self: *Gain, samples: []f32, channels: u16) void {
        _ = channels; // gain is channel-agnostic
        for (samples) |*s| s.* *= self.factor;
    }
};

// --- tests ----------------------------------------------------------------------------------

const FakeMic = struct {
    data: []const f32,
    channels: u16,
    chunk_frames: usize,
    pos: usize = 0,

    pub fn capture(self: *FakeMic, buf: []f32) usize {
        const ch: usize = @max(self.channels, 1);
        if (self.pos >= self.data.len) return 0;
        const want = @min(buf.len, self.chunk_frames * ch);
        const n = @min(want, self.data.len - self.pos);
        @memcpy(buf[0..n], self.data[self.pos .. self.pos + n]);
        self.pos += n;
        return n / ch;
    }
};

test "inline pipeline applies every stage in order, capture to playback" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bus = core.LocalBus.init(testing.allocator, io);
    defer bus.deinit();
    var rt = try core.Runtime.init(testing.allocator, io, &bus);

    var mic = FakeMic{ .data = &.{ 1, 1, 2, 2, 3, 3 }, .channels = 1, .chunk_frames = 2 };
    var recorder = audio.Recorder.init(testing.allocator, io);
    defer recorder.deinit();

    // Two stages compose: ×0.5 then ×4 ⇒ net ×2. Proves order/chaining, not just one stage.
    var half = Gain{ .factor = 0.5 };
    var quad = Gain{ .factor = 4.0 };
    const stages = [_]AudioProcessor{ AudioProcessor.of(Gain, &half), AudioProcessor.of(Gain, &quad) };

    var pipe = AudioPipeline.init(
        "monitor",
        AudioIn.of(FakeMic, &mic),
        &stages,
        AudioOut.of(audio.Recorder, &recorder),
        48_000,
        1,
        2,
    );
    try rt.spawn(core.Module.of(AudioPipeline, &pipe));

    // The pipeline drains the finite mic and stops itself; give it time, then join.
    sync.sleepNs(io, 50 * std.time.ns_per_ms);
    rt.shutdown();
    var report = rt.join();
    defer report.deinit();
    try testing.expect(report.isClean());

    const got = try recorder.recorded(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(f32, &.{ 2, 2, 4, 4, 6, 6 }, got);
}
