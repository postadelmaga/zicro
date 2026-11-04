//! # zrame.sink — the zicro seam
//!
//! zicro's `video.zig` ends at a contract: *"The actual GPU/window backend is the
//! app's job — the framework only needs `FrameSink.present`."* This file is that
//! backend. [`WindowSink`] adapts a zrame [`Window`] to zicro's `FrameSink`, so a
//! standard zicro pipeline — producer → `media.latest` → `VideoSink` module — lands
//! its frames inside the glass panel.
//!
//! `present` is called on the VideoSink module's thread; `Window.presentRgba` is the
//! window's thread-safe door (stage + eventfd), so no Wayland object is ever touched
//! off the window thread.

const std = @import("std");
const zicro = @import("zicro");

const window = @import("window.zig");

pub const WindowSink = struct {
    win: *window.Window,
    swizzle_buf: std.ArrayList(u8) = .empty,

    pub fn init(win: *window.Window) WindowSink {
        return .{ .win = win, .swizzle_buf = .empty };
    }

    pub fn deinit(self: *WindowSink) void {
        self.swizzle_buf.deinit(self.win.gpa);
    }

    /// zicro `FrameSink` entry point. `bgra8` frames are swizzled to RGBA on the way in.
    pub fn present(self: *WindowSink, frame: *const zicro.media.Frame) void {
        const pixels = frame.pixels.slice();
        switch (frame.format) {
            .rgba8 => self.win.presentRgba(frame.width, frame.height, pixels),
            .bgra8 => {
                self.swizzle_buf.clearRetainingCapacity();
                self.swizzle_buf.resize(self.win.gpa, pixels.len) catch return;
                const swizzled = self.swizzle_buf.items;
                var i: usize = 0;
                while (i < pixels.len) : (i += 4) {
                    swizzled[i] = pixels[i + 2];
                    swizzled[i + 1] = pixels[i + 1];
                    swizzled[i + 2] = pixels[i];
                    swizzled[i + 3] = pixels[i + 3];
                }
                self.win.presentRgba(frame.width, frame.height, swizzled);
            },
        }
    }

    /// The vtable zicro's `VideoSink` module wants.
    pub fn frameSink(self: *WindowSink) zicro.video.FrameSink {
        return zicro.video.FrameSink.of(WindowSink, self);
    }

    /// zicro `GpuFrameSink` entry point — present a dmabuf frame with **no CPU
    /// copy**: plane fds go straight to the desynced video subsurface. Supports
    /// single-plane RGBA as well as multi-planar NV12/YUV formats.
    /// Returns `false` when the window has no dmabuf/subcompositor support.
    pub fn presentGpu(self: *WindowSink, frame: *const zicro.video.GpuFrame) bool {
        if (frame.planes.len == 0) return false;
        var planes: [4]window.DmabufPlane = undefined;
        const count = @min(frame.planes.len, 4);
        for (frame.planes[0..count], 0..) |p, i| {
            planes[i] = .{
                .fd = p.fd,
                .offset = p.offset,
                .stride = p.stride,
                .modifier = frame.modifier,
            };
        }
        return self.win.presentDmabufPlanes(
            frame.slot,
            planes[0..count],
            frame.width,
            frame.height,
            frame.fourcc,
        );
    }

    /// The vtable zicro wants for the zero-copy GPU path.
    pub fn gpuFrameSink(self: *WindowSink) zicro.video.GpuFrameSink {
        return zicro.video.GpuFrameSink.of(WindowSink, self);
    }
};
