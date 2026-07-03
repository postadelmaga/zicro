//! # zicro.audio — the audio sink adapter
//!
//! The audio sink pulls [`AudioBlock`]s from the **data plane** ([`media`]), not the
//! serializing JSON bus: audio is high-bandwidth and must never be encoded. It rides a
//! [`bounded`](media.bounded), **lossless** channel, so a slow consumer applies
//! backpressure to the producer instead of dropping samples — for audio, pacing is
//! correct and dropping is an audible glitch.
//!
//! The sink is generic over an [`AudioOut`] device contract. zicro ships only the
//! headless [`Recorder`] (used in tests), so it compiles and runs without any audio
//! hardware; a real device backend (the Rust original gates a `cpal` one behind a
//! feature) is an app-side `AudioOut` implementation.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const sync = @import("sync.zig");
const core = @import("core.zig");
const media = @import("media.zig");

pub const AudioBlock = media.AudioBlock;

/// A device that can play an [`AudioBlock`]. Implement this to drive real hardware; the
/// sink hands it blocks one at a time, in order, off the data plane. The block is
/// borrowed — copy out anything you need to keep.
pub const AudioOut = struct {
    ptr: *anyopaque,
    playFn: *const fn (*anyopaque, *const AudioBlock) void,

    /// Wrap any type with `pub fn play(self: *T, block: *const AudioBlock) void`.
    pub fn of(comptime T: type, instance: *T) AudioOut {
        const Impl = struct {
            fn play(ptr: *anyopaque, block: *const AudioBlock) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                self.play(block);
            }
        };
        return .{ .ptr = instance, .playFn = Impl.play };
    }

    pub fn play(out: AudioOut, block: *const AudioBlock) void {
        out.playFn(out.ptr, block);
    }
};

/// A module that drains [`AudioBlock`]s from a bounded data-plane channel into an
/// [`AudioOut`] device. It owns the receiver, so backpressure reaches the producer
/// directly. Nothing on the control bus: blocks arrive on the data plane.
pub const AudioSink = struct {
    id_: []const u8,
    blocks: media.BoundedReceiver(AudioBlock),
    out: AudioOut,

    /// Build a sink reading from `blocks` and playing into `out`.
    pub fn init(id_: []const u8, blocks: media.BoundedReceiver(AudioBlock), out: AudioOut) AudioSink {
        return .{ .id_ = id_, .blocks = blocks, .out = out };
    }

    pub fn id(self: *AudioSink) []const u8 {
        return self.id_;
    }

    pub fn run(self: *AudioSink, ctx: *core.ModuleCtx) anyerror!void {
        defer self.blocks.deinit();
        while (!ctx.shouldStop()) {
            // Time out periodically so a quiet stream still observes the shutdown signal.
            const taken = self.blocks.recvTimeout(50 * std.time.ns_per_ms) catch break; // producer gone
            if (taken) |block| {
                var owned = block;
                defer owned.deinit();
                self.out.play(&owned);
            }
        }
    }
};

/// A headless [`AudioOut`] that captures every sample played into a shared buffer. The
/// reference output for tests and debugging — no device, fully deterministic.
pub const Recorder = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    samples: std.ArrayListUnmanaged(f32) = .empty,

    pub fn init(gpa: Allocator, io: Io) Recorder {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Recorder) void {
        self.samples.deinit(self.gpa);
    }

    pub fn play(self: *Recorder, block: *const AudioBlock) void {
        sync.lock(&self.mutex, self.io);
        defer sync.unlock(&self.mutex, self.io);
        self.samples.appendSlice(self.gpa, block.samples.slice()) catch {};
    }

    /// A copy of everything recorded so far (caller frees).
    pub fn recorded(self: *Recorder, gpa: Allocator) Allocator.Error![]f32 {
        sync.lock(&self.mutex, self.io);
        defer sync.unlock(&self.mutex, self.io);
        return gpa.dupe(f32, self.samples.items);
    }
};

// --- tests ---------------------------------------------------------------------------------

test "audio sink plays every block in order into the device" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bus = core.LocalBus.init(testing.allocator, io);
    defer bus.deinit();
    var rt = try core.Runtime.init(testing.allocator, io, &bus);

    const tx, const rx = try media.bounded(AudioBlock, testing.allocator, io, 2);

    var recorder = Recorder.init(testing.allocator, io);
    defer recorder.deinit();
    var sink = AudioSink.init("audio", rx, AudioOut.of(Recorder, &recorder));
    try rt.spawn(core.Module.of(AudioSink, &sink));

    // Three blocks whose samples spell out their order.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const value: f32 = @floatFromInt(i);
        const block = try AudioBlock.init(testing.allocator, 48_000, 1, &.{ value, value });
        tx.send(block) catch |e| {
            var owned = block;
            owned.deinit();
            return e;
        };
    }
    tx.deinit();

    // Give the sink time to drain, then stop it.
    sync.sleepNs(io, 50 * std.time.ns_per_ms);
    rt.shutdown();
    var report = rt.join();
    defer report.deinit();
    try testing.expect(report.isClean());

    const got = try recorder.recorded(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 1, 1, 2, 2 }, got);
}
