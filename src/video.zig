//! # zicro.video — the video sink adapter
//!
//! A video sink *pulls* frames from the [media data plane](media) — the zero-copy,
//! reference-counted side — and puts them on screen. It deliberately ignores the JSON
//! bus: a 1080p RGBA frame is ~8 MB, and serializing 60 of those a second is a
//! non-starter. The bus only ever carries the tiny "frame ready" control message; the
//! bytes travel here, by ownership.
//!
//! The actual GPU/window backend is the *app's* job — that is the platform weight zicro
//! stays out of. This file is just the framework-side contract: the [`FrameSink`]
//! interface an app implements to present a frame, the [`VideoSink`] module that drives
//! it off the data plane, and a headless [`BufferSink`] so the whole path is testable
//! without a GPU.

const std = @import("std");
const Io = std.Io;

const sync = @import("sync.zig");
const core = @import("core.zig");
const media = @import("media.zig");

pub const Frame = media.Frame;

/// Implemented by an app to put a frame on screen. The real impl uploads `frame.pixels`
/// to a GPU texture and presents; the framework only needs this one call. The instance
/// pointer is mutable so a backend can hold state (a swapchain, a staging buffer) across
/// presents.
pub const FrameSink = struct {
    ptr: *anyopaque,
    presentFn: *const fn (*anyopaque, *const Frame) void,

    /// Wrap any type with `pub fn present(self: *T, frame: *const Frame) void`.
    pub fn of(comptime T: type, instance: *T) FrameSink {
        const Impl = struct {
            fn present(ptr: *anyopaque, frame: *const Frame) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                self.present(frame);
            }
        };
        return .{ .ptr = instance, .presentFn = Impl.present };
    }

    pub fn present(sink: FrameSink, frame: *const Frame) void {
        sink.presentFn(sink.ptr, frame);
    }
};

/// A module that pumps the freshest [`Frame`] from a [`latest`](media.latest) mailbox
/// into a [`FrameSink`]. It reads only the data plane — no bus subscriptions.
pub const VideoSink = struct {
    id_: []const u8,
    frames: media.LatestReceiver(Frame),
    sink: FrameSink,

    pub fn init(id_: []const u8, frames: media.LatestReceiver(Frame), sink: FrameSink) VideoSink {
        return .{ .id_ = id_, .frames = frames, .sink = sink };
    }

    pub fn id(self: *VideoSink) []const u8 {
        return self.id_;
    }

    // No bus subscriptions: a video sink lives entirely on the data plane.

    pub fn run(self: *VideoSink, ctx: *core.ModuleCtx) anyerror!void {
        defer self.frames.deinit();
        while (!ctx.shouldStop()) {
            const taken = self.frames.tryRecv() catch break; // producer gone for good
            if (taken) |frame| {
                // Newest frame wins — present it. Stale frames were already coalesced away.
                var owned = frame;
                defer owned.deinit();
                self.sink.present(&owned);
            } else {
                // Nothing ready: poll at ~250 Hz so we stay responsive to shouldStop
                // without busy-spinning a core. (No blocking recv — it would ignore stop.)
                sync.sleepNs(ctx.io, 4 * std.time.ns_per_ms);
            }
        }
    }
};

// --- headless reference sink (tests, debug overlays) ---------------------------------------

/// A [`FrameSink`] that presents nowhere — it just remembers the last frame and a count.
/// Lets the whole video path be exercised without a GPU. Read it (from any thread) with
/// [`presented`](BufferSink.presented) and [`takeLast`](BufferSink.takeLast).
pub const BufferSink = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    last: ?Frame = null,
    count: u64 = 0,

    pub fn init(io: Io) BufferSink {
        return .{ .io = io };
    }

    pub fn deinit(self: *BufferSink) void {
        sync.lock(&self.mutex, self.io);
        if (self.last) |*frame| frame.deinit();
        self.last = null;
        sync.unlock(&self.mutex, self.io);
    }

    pub fn present(self: *BufferSink, frame: *const Frame) void {
        // Retaining is a pointer bump (pixels are shared), so recording is cheap.
        sync.lock(&self.mutex, self.io);
        if (self.last) |*old| old.deinit();
        self.last = frame.retain();
        self.count += 1;
        sync.unlock(&self.mutex, self.io);
    }

    /// How many frames have been presented so far.
    pub fn presented(self: *BufferSink) u64 {
        sync.lock(&self.mutex, self.io);
        defer sync.unlock(&self.mutex, self.io);
        return self.count;
    }

    /// Take (and own) the most recent frame, if any.
    pub fn takeLast(self: *BufferSink) ?Frame {
        sync.lock(&self.mutex, self.io);
        defer sync.unlock(&self.mutex, self.io);
        const frame = self.last;
        self.last = null;
        return frame;
    }
};

// --- tests ---------------------------------------------------------------------------------

test "video sink presents the freshest frame" {
    const testing = std.testing;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bus = core.LocalBus.init(testing.allocator, io);
    defer bus.deinit();
    var rt = try core.Runtime.init(testing.allocator, io, &bus);

    const tx, const rx = try media.latest(Frame, testing.allocator, io);

    var buffer = BufferSink.init(io);
    defer buffer.deinit();
    var video = VideoSink.init("video", rx, FrameSink.of(BufferSink, &buffer));
    try rt.spawn(core.Module.of(VideoSink, &video));

    // Send a few frames; the sink must present at least the last one.
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        const frame = try Frame.init(testing.allocator, 2, 1, .rgba8, &.{ i, i, i, i, i, i, i, i });
        tx.send(frame) catch |e| {
            var owned = frame;
            owned.deinit();
            return e;
        };
        sync.sleepNs(io, 10 * std.time.ns_per_ms);
    }
    tx.deinit();

    // Wait for the sink to notice the producer is gone and stop.
    rt.shutdown();
    var report = rt.join();
    defer report.deinit();
    try testing.expect(report.isClean());

    try testing.expect(buffer.presented() >= 1);
    var last = buffer.takeLast().?;
    defer last.deinit();
    try testing.expectEqual(@as(u32, 2), last.width);
    try testing.expectEqual(@as(u8, 2), last.pixels.slice()[0]);
}
