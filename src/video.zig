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

// --- GPU frames (zero-copy dmabuf) ---------------------------------------------------------
//
// The twin of [`Frame`]/[`FrameSink`] for the frames that never touch the CPU: a
// render target exported as a dmabuf and handed to a backend that can import it
// (a Wayland linux-dmabuf subsurface, a KMS plane). This is what keeps the fast
// present path — a marcher/upscaler writes a GPU image, the backend commits it
// with no copy and no per-frame allocation. Purely additive: CPU-only sinks just
// don't implement [`GpuFrameSink`], and nothing here touches the [`Frame`] path.

/// One dmabuf plane. RGBA is single-plane; the array leaves room for YUV/multiplanar.
pub const DmabufPlane = struct {
    fd: std.posix.fd_t,
    offset: u32 = 0,
    stride: u32,
};

/// A frame that lives on the GPU as a dmabuf. The producer keeps ownership of the
/// plane fds — a sink imports them and must NOT close them.
pub const GpuFrame = struct {
    width: u32,
    height: u32,
    /// DRM fourcc of the buffer (e.g. `0x34324241` = 'AB24' = ABGR8888).
    fourcc: u32,
    /// DRM format modifier (`0` = LINEAR).
    modifier: u64 = 0,
    planes: []const DmabufPlane,
    /// Double-buffer hint. A backend that caches one imported buffer per slot keys
    /// on this, so re-presenting the same slot is a bare re-commit — no re-import.
    slot: u8 = 0,
};

/// Implemented by a backend that can present a [`GpuFrame`] with no CPU copy.
/// `present` returns `false` when the backend can't take this frame (unsupported
/// modifier, no dmabuf support) so the caller can fall back to a CPU [`Frame`].
pub const GpuFrameSink = struct {
    ptr: *anyopaque,
    presentFn: *const fn (*anyopaque, *const GpuFrame) bool,

    /// Wrap any type with `pub fn presentGpu(self: *T, frame: *const GpuFrame) bool`.
    pub fn of(comptime T: type, instance: *T) GpuFrameSink {
        const Impl = struct {
            fn present(ptr: *anyopaque, frame: *const GpuFrame) bool {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.presentGpu(frame);
            }
        };
        return .{ .ptr = instance, .presentFn = Impl.present };
    }

    pub fn present(sink: GpuFrameSink, frame: *const GpuFrame) bool {
        return sink.presentFn(sink.ptr, frame);
    }
};

/// What a surface backend knows about its output geometry — filled from the real
/// window/compositor size (or the configured offscreen size for a headless
/// backend). The context-adaptive knob: a consumer sizes its render to this.
pub const SurfaceInfo = struct {
    width: u32,
    height: u32,
    /// Fractional / HiDPI scale (`1.0` = one buffer px per logical px).
    scale: f32 = 1.0,
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

test "GpuFrameSink wraps presentGpu, forwards the frame, and reports fallback" {
    const testing = std.testing;
    const Backend = struct {
        got: ?GpuFrame = null,
        ok: bool = true,
        fn presentGpu(self: *@This(), f: *const GpuFrame) bool {
            self.got = f.*;
            return self.ok;
        }
    };
    var be = Backend{};
    const sink = GpuFrameSink.of(Backend, &be);

    // `fd_t` è c_int su Linux ma un HANDLE (*anyopaque) su Windows: fd fittizio
    // per-OS così il test compila ovunque (i dmabuf sono comunque Linux-only e
    // l'fd viene solo inoltrato al backend, mai dereferenziato).
    const fake_fd: std.posix.fd_t = if (@import("builtin").os.tag == .windows) @ptrFromInt(7) else 7;
    const planes = [_]DmabufPlane{.{ .fd = fake_fd, .offset = 0, .stride = 4096 }};
    const frame = GpuFrame{
        .width = 1024,
        .height = 512,
        .fourcc = 0x34324241, // ABGR8888
        .modifier = 0,
        .planes = &planes,
        .slot = 1,
    };

    // Success path: the frame reaches the backend intact.
    try testing.expect(sink.present(&frame));
    try testing.expect(be.got != null);
    try testing.expectEqual(@as(u32, 1024), be.got.?.width);
    try testing.expectEqual(@as(u32, 512), be.got.?.height);
    try testing.expectEqual(@as(u8, 1), be.got.?.slot);
    try testing.expectEqual(fake_fd, be.got.?.planes[0].fd);
    try testing.expectEqual(@as(u32, 4096), be.got.?.planes[0].stride);

    // Fallback path: a backend that can't take the frame returns false.
    be.ok = false;
    try testing.expect(!sink.present(&frame));
}
