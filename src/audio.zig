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

/// A device that can capture audio — the dual of [`AudioOut`]. Implement this to read from
/// real hardware; the [`AudioSource`] calls it in a loop for one block at a time. Fill `buf`
/// with interleaved f32 samples (device format) and return the number of *frames* read
/// (samples = frames × channels); return 0 to signal end-of-stream so the source stops.
pub const AudioIn = struct {
    ptr: *anyopaque,
    captureFn: *const fn (*anyopaque, []f32) usize,

    /// Wrap any type with `pub fn capture(self: *T, buf: []f32) usize`.
    pub fn of(comptime T: type, instance: *T) AudioIn {
        const Impl = struct {
            fn capture(ptr: *anyopaque, buf: []f32) usize {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.capture(buf);
            }
        };
        return .{ .ptr = instance, .captureFn = Impl.capture };
    }

    pub fn capture(in: AudioIn, buf: []f32) usize {
        return in.captureFn(in.ptr, buf);
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

/// What an [`AudioSource`] does when the data-plane channel is full. A *sink* gets
/// backpressure for free (its device write blocks); a *source* cannot — capture hardware
/// keeps producing whether or not the consumer keeps up, so the policy is explicit here.
pub const Overflow = enum {
    /// Block the next capture until the consumer drains one block. Lossless, but a slow
    /// consumer stalls the read and risks a hardware **overrun** — use only when the
    /// consumer is real-time.
    block,
    /// Drop the just-captured block when the channel is full (counted in `dropped`). Keeps
    /// the capture loop real-time at the cost of a gap — the right default for live input.
    drop,
};

/// A module that captures [`AudioBlock`]s from an [`AudioIn`] device into a bounded
/// data-plane channel — the dual of [`AudioSink`]. It owns the sender, so a downstream
/// consumer's backpressure reaches it (under [`Overflow.block`]) or is shed as counted
/// drops (under [`Overflow.drop`]). Nothing on the control bus: blocks ride the data plane.
pub const AudioSource = struct {
    id_: []const u8,
    in: AudioIn,
    blocks: media.BoundedSender(AudioBlock),
    rate: u32,
    channels: u16,
    /// Frames requested per capture — the block granularity (e.g. 512 @ 48kHz ≈ 10.7ms).
    block_frames: usize,
    policy: Overflow,
    /// Blocks shed under [`Overflow.drop`] because the channel was full. Read after `run`.
    dropped: usize = 0,

    /// Build a source reading from `in` at `rate`/`channels`, `block_frames` per block,
    /// sending into `blocks` with the given overflow `policy`.
    pub fn init(
        id_: []const u8,
        in: AudioIn,
        blocks: media.BoundedSender(AudioBlock),
        rate: u32,
        channels: u16,
        block_frames: usize,
        policy: Overflow,
    ) AudioSource {
        return .{ .id_ = id_, .in = in, .blocks = blocks, .rate = rate, .channels = channels, .block_frames = block_frames, .policy = policy };
    }

    pub fn id(self: *AudioSource) []const u8 {
        return self.id_;
    }

    pub fn run(self: *AudioSource, ctx: *core.ModuleCtx) anyerror!void {
        defer self.blocks.deinit();
        const ch: usize = @max(self.channels, 1);
        const scratch = try ctx.gpa.alloc(f32, @max(self.block_frames, 1) * ch);
        defer ctx.gpa.free(scratch);
        while (!ctx.shouldStop()) {
            // capture() blocks ~one block (≈10ms), so shutdown is observed promptly. 0 =
            // end-of-stream or an unrecoverable device error → the source is done.
            const frames = self.in.capture(scratch);
            if (frames == 0) break;
            var block = try AudioBlock.init(ctx.gpa, self.rate, self.channels, scratch[0 .. frames * ch]);
            switch (self.policy) {
                .block => self.blocks.send(block) catch {
                    block.deinit();
                    break; // consumer gone
                },
                .drop => {
                    const pushed = self.blocks.trySend(block) catch {
                        block.deinit();
                        break; // consumer gone
                    };
                    if (!pushed) {
                        block.deinit();
                        self.dropped += 1;
                    }
                },
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

/// A deterministic [`AudioIn`]: hands out a fixed interleaved buffer `chunk_frames` at a
/// time, then reports end-of-stream (0). The capture dual of [`Recorder`] — no hardware.
const FakeMic = struct {
    data: []const f32,
    channels: u16,
    chunk_frames: usize,
    pos: usize = 0,

    fn capture(self: *FakeMic, buf: []f32) usize {
        const ch: usize = @max(self.channels, 1);
        if (self.pos >= self.data.len) return 0; // exhausted → end-of-stream
        const want = @min(buf.len, self.chunk_frames * ch);
        const n = @min(want, self.data.len - self.pos);
        @memcpy(buf[0..n], self.data[self.pos .. self.pos + n]);
        self.pos += n;
        return n / ch;
    }
};

test "audio source captures every block in order onto the data plane" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bus = core.LocalBus.init(testing.allocator, io);
    defer bus.deinit();
    var rt = try core.Runtime.init(testing.allocator, io, &bus);

    const tx, const rx = try media.bounded(AudioBlock, testing.allocator, io, 8);
    defer rx.deinit();

    // Six mono samples, captured two frames at a time → blocks [0,0] [1,1] [2,2].
    var mic = FakeMic{ .data = &.{ 0, 0, 1, 1, 2, 2 }, .channels = 1, .chunk_frames = 2 };
    var source = AudioSource.init("mic", AudioIn.of(FakeMic, &mic), tx, 48_000, 1, 2, .block);
    try rt.spawn(core.Module.of(AudioSource, &source));

    // Drain the data plane until the source finishes and closes the channel.
    var out: std.ArrayListUnmanaged(f32) = .empty;
    defer out.deinit(testing.allocator);
    while (true) {
        var block = rx.recv() catch break; // Disconnected once the source is done + drained
        defer block.deinit();
        try out.appendSlice(testing.allocator, block.samples.slice());
    }

    rt.shutdown();
    var report = rt.join();
    defer report.deinit();
    try testing.expect(report.isClean());

    try testing.expectEqualSlices(f32, &.{ 0, 0, 1, 1, 2, 2 }, out.items);
}
