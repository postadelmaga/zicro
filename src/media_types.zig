//! The two canonical media payloads. Both wrap their buffer in an [`Rc`](rc.Rc) so
//! moving one across a channel (or retaining a handle for a second sink) is a pointer
//! bump, not a copy — the whole point of the data plane.

const std = @import("std");
const Allocator = std.mem.Allocator;

const rc = @import("rc.zig");

/// How the bytes of a [`Frame`] are laid out. Kept minimal on purpose; an app adds
/// variants in its own renderer if it needs more.
pub const PixelFormat = enum {
    /// 8 bits per channel, red-green-blue-alpha, 4 bytes per pixel.
    rgba8,
    /// 8 bits per channel, blue-green-red-alpha (common GPU swapchain order).
    bgra8,

    /// Bytes per pixel for this format.
    pub fn bytesPerPixel(format: PixelFormat) usize {
        return switch (format) {
            .rgba8, .bgra8 => 4,
        };
    }
};

/// A single decoded video frame: a shared pixel buffer plus its geometry. Cheap to move
/// and to retain (the buffer is shared, the pixels are not copied).
pub const Frame = struct {
    width: u32,
    height: u32,
    format: PixelFormat,
    /// Tightly packed `width * height * bytesPerPixel` bytes.
    pixels: rc.Rc(u8),

    /// Build a frame over a shared copy of `pixels`, checking the buffer length matches
    /// the geometry.
    pub fn init(
        gpa: Allocator,
        width: u32,
        height: u32,
        format: PixelFormat,
        pixels: []const u8,
    ) error{ OutOfMemory, WrongBufferSize }!Frame {
        const expected = @as(usize, width) * @as(usize, height) * format.bytesPerPixel();
        if (pixels.len != expected) return error.WrongBufferSize;
        return .{
            .width = width,
            .height = height,
            .format = format,
            .pixels = try rc.Rc(u8).init(gpa, pixels),
        };
    }

    /// A second handle onto the same pixels — a pointer bump, not a copy.
    pub fn retain(frame: Frame) Frame {
        return .{
            .width = frame.width,
            .height = frame.height,
            .format = frame.format,
            .pixels = frame.pixels.retain(),
        };
    }

    pub fn deinit(frame: *Frame) void {
        frame.pixels.release();
    }
};

/// A block of rendered audio: interleaved `f32` samples plus the format needed to play
/// them. Shared so a block can fan out to, say, a player and a meter without a copy.
pub const AudioBlock = struct {
    sample_rate: u32,
    channels: u16,
    /// Interleaved samples: `frames * channels` values, each in `-1.0..=1.0`.
    samples: rc.Rc(f32),

    pub fn init(gpa: Allocator, sample_rate: u32, channels: u16, samples: []const f32) Allocator.Error!AudioBlock {
        return .{
            .sample_rate = sample_rate,
            .channels = channels,
            .samples = try rc.Rc(f32).init(gpa, samples),
        };
    }

    pub fn retain(block: AudioBlock) AudioBlock {
        return .{
            .sample_rate = block.sample_rate,
            .channels = block.channels,
            .samples = block.samples.retain(),
        };
    }

    pub fn deinit(block: *AudioBlock) void {
        block.samples.release();
    }

    /// Number of sample frames (samples per channel) in this block.
    pub fn frames(block: *const AudioBlock) usize {
        const ch: usize = @max(block.channels, 1);
        return block.samples.slice().len / ch;
    }
};

test "frame rejects a mismatched buffer" {
    const gpa = std.testing.allocator;
    var ok = try Frame.init(gpa, 2, 2, .rgba8, &(.{0} ** 16));
    ok.deinit();
    try std.testing.expectError(error.WrongBufferSize, Frame.init(gpa, 2, 2, .rgba8, &(.{0} ** 15)));
}

test "audio block counts frames" {
    const gpa = std.testing.allocator;
    var b = try AudioBlock.init(gpa, 48_000, 2, &(.{0.0} ** 256));
    defer b.deinit();
    try std.testing.expectEqual(@as(usize, 128), b.frames());
}
