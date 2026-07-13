//! # zicro.audio_device — real hardware audio output
//!
//! The missing piece of [`audio`]: a concrete [`AudioOut`](audio.AudioOut) that drives the
//! sound card, so an [`AudioSink`](audio.AudioSink) actually makes noise. Platform backend
//! behind a comptime switch, like the window backends:
//!   - **Windows** → `winmm` **waveOut** (a plain C API — no COM to hand-declare; Wine
//!     implements it too), double-buffered with a small pool of `WAVEHDR`s.
//!   - **Linux**   → **ALSA** `snd_pcm` (`default` device), blocking interleaved writes.
//!   - other       → a no-op device (compiles everywhere; silent).
//!
//! The device opens at a FIXED format — 32-bit float, interleaved, `channels`×`rate` — and
//! does NOT resample: the producer (e.g. a libav player, or a MIDI synth) renders straight
//! to `openedRate()`/`openedChannels()`. That keeps the device dumb and the policy (A/V
//! sync, resampling) where the data comes from. `play()` blocks until the block is queued,
//! so backpressure flows back through the lossless [`AudioSink`] channel — no dropped audio.

const std = @import("std");
const builtin = @import("builtin");
const media = @import("media.zig");

pub const AudioBlock = media.AudioBlock;

const is_win = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;

pub const Error = error{ OpenFailed, Unsupported };

/// Hardware audio output. Wrap with `audio.AudioOut.of(DeviceOut, &dev)` to feed an
/// `AudioSink`, or call `play()` directly. Not thread-safe: one producer thread.
pub const DeviceOut = struct {
    backend: Backend,
    rate: u32,
    channels: u16,

    /// Open the default output device at `rate` Hz / `channels`, 32-bit float.
    pub fn open(rate: u32, channels: u16) Error!DeviceOut {
        return .{ .backend = try Backend.open(rate, channels), .rate = rate, .channels = channels };
    }

    pub fn openedRate(self: *const DeviceOut) u32 {
        return self.rate;
    }
    pub fn openedChannels(self: *const DeviceOut) u16 {
        return self.channels;
    }

    /// Queue one block of interleaved f32 samples (device format assumed). Blocks until
    /// the hardware accepts it (backpressure). Matches the `audio.AudioOut` contract.
    pub fn play(self: *DeviceOut, block: *const AudioBlock) void {
        const s = block.samples.slice();
        if (s.len == 0) return;
        self.backend.write(s);
    }

    pub fn close(self: *DeviceOut) void {
        self.backend.close();
    }
};

// ── Backend selection ───────────────────────────────────────────────────────
const Backend = if (is_win) WaveOut else if (is_linux) Alsa else NullDev;

/// Fallback for platforms without a backend: silent, always "succeeds".
const NullDev = struct {
    fn open(_: u32, _: u16) Error!NullDev {
        return .{};
    }
    fn write(_: *NullDev, _: []const f32) void {}
    fn close(_: *NullDev) void {}
};

// ── Windows: winmm waveOut ──────────────────────────────────────────────────
const WaveOut = struct {
    const HWAVEOUT = *anyopaque;
    const WAVE_MAPPER: u32 = 0xFFFF_FFFF;
    const WAVE_FORMAT_IEEE_FLOAT: u16 = 0x0003;
    const CALLBACK_NULL: u32 = 0;
    const WHDR_DONE: u32 = 0x0000_0001;
    const WHDR_PREPARED: u32 = 0x0000_0002;
    const MMSYSERR_NOERROR: u32 = 0;

    const WAVEFORMATEX = extern struct {
        wFormatTag: u16,
        nChannels: u16,
        nSamplesPerSec: u32,
        nAvgBytesPerSec: u32,
        nBlockAlign: u16,
        wBitsPerSample: u16,
        cbSize: u16,
    };
    const WAVEHDR = extern struct {
        lpData: [*]u8,
        dwBufferLength: u32,
        dwBytesRecorded: u32 = 0,
        dwUser: usize = 0,
        dwFlags: u32 = 0,
        dwLoops: u32 = 0,
        lpNext: ?*WAVEHDR = null,
        reserved: usize = 0,
    };

    extern "winmm" fn waveOutOpen(phwo: *HWAVEOUT, uDeviceID: u32, pwfx: *const WAVEFORMATEX, cb: usize, inst: usize, flags: u32) callconv(.winapi) u32;
    extern "winmm" fn waveOutPrepareHeader(hwo: HWAVEOUT, pwh: *WAVEHDR, cb: u32) callconv(.winapi) u32;
    extern "winmm" fn waveOutUnprepareHeader(hwo: HWAVEOUT, pwh: *WAVEHDR, cb: u32) callconv(.winapi) u32;
    extern "winmm" fn waveOutWrite(hwo: HWAVEOUT, pwh: *WAVEHDR, cb: u32) callconv(.winapi) u32;
    extern "winmm" fn waveOutReset(hwo: HWAVEOUT) callconv(.winapi) u32;
    extern "winmm" fn waveOutClose(hwo: HWAVEOUT) callconv(.winapi) u32;
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

    const NBUF = 8; // WAVEHDR pool: queue depth ~ NBUF × block size

    hwo: HWAVEOUT,
    channels: u16,
    hdrs: [NBUF]WAVEHDR,
    bufs: [NBUF][]u8, // buffer per header (grows to the largest block seen)
    next: usize,
    gpa: std.mem.Allocator,

    fn open(rate: u32, channels: u16) Error!WaveOut {
        const block_align: u16 = channels * 4; // f32
        const fmt = WAVEFORMATEX{
            .wFormatTag = WAVE_FORMAT_IEEE_FLOAT,
            .nChannels = channels,
            .nSamplesPerSec = rate,
            .nAvgBytesPerSec = rate * block_align,
            .nBlockAlign = block_align,
            .wBitsPerSample = 32,
            .cbSize = 0,
        };
        var hwo: HWAVEOUT = undefined;
        if (waveOutOpen(&hwo, WAVE_MAPPER, &fmt, 0, 0, CALLBACK_NULL) != MMSYSERR_NOERROR)
            return Error.OpenFailed;
        var self = WaveOut{
            .hwo = hwo,
            .channels = channels,
            .hdrs = undefined,
            .bufs = undefined,
            .next = 0,
            .gpa = std.heap.c_allocator,
        };
        for (0..NBUF) |i| {
            self.hdrs[i] = .{ .lpData = undefined, .dwBufferLength = 0, .dwFlags = WHDR_DONE };
            self.bufs[i] = &.{};
        }
        return self;
    }

    /// Copies the samples into the next free header (waiting for one if all are queued),
    /// (re)preparing and submitting it. Blocking write = backpressure.
    fn write(self: *WaveOut, samples: []const f32) void {
        const bytes = std.mem.sliceAsBytes(samples);
        const h = &self.hdrs[self.next];
        // Wait until this header has been consumed by the hardware, but with a
        // cap (~2s): if the device doesn't drain (e.g. Wine without audio) do NOT block
        // forever — drop the block, so the thread stays responsive (stop/join).
        var spins: u32 = 0;
        while ((h.dwFlags & WHDR_DONE) == 0) : (spins += 1) {
            if (spins > 2000) return;
            Sleep(1);
        }
        if ((h.dwFlags & WHDR_PREPARED) != 0) _ = waveOutUnprepareHeader(self.hwo, h, @sizeOf(WAVEHDR));
        // Ensure the buffer is large enough and copy the samples into it.
        if (self.bufs[self.next].len < bytes.len) {
            if (self.bufs[self.next].len > 0) self.gpa.free(self.bufs[self.next]);
            self.bufs[self.next] = &.{}; // never leave the slot pointing at freed memory
            self.bufs[self.next] = self.gpa.alloc(u8, bytes.len) catch return;
        }
        @memcpy(self.bufs[self.next][0..bytes.len], bytes);
        h.* = .{ .lpData = self.bufs[self.next].ptr, .dwBufferLength = @intCast(bytes.len) };
        if (waveOutPrepareHeader(self.hwo, h, @sizeOf(WAVEHDR)) != MMSYSERR_NOERROR) {
            h.dwFlags = WHDR_DONE; // slot still free: the next write must not wait on the timeout
            return;
        }
        _ = waveOutWrite(self.hwo, h, @sizeOf(WAVEHDR));
        self.next = (self.next + 1) % NBUF;
    }

    fn close(self: *WaveOut) void {
        _ = waveOutReset(self.hwo); // marks all headers as DONE
        for (0..NBUF) |i| {
            if ((self.hdrs[i].dwFlags & WHDR_PREPARED) != 0)
                _ = waveOutUnprepareHeader(self.hwo, &self.hdrs[i], @sizeOf(WAVEHDR));
            if (self.bufs[i].len > 0) self.gpa.free(self.bufs[i]);
        }
        _ = waveOutClose(self.hwo);
    }
};

// ── Linux: ALSA snd_pcm ─────────────────────────────────────────────────────
const Alsa = struct {
    const snd_pcm_t = opaque {};
    const SND_PCM_STREAM_PLAYBACK: c_int = 0;
    const SND_PCM_FORMAT_FLOAT_LE: c_int = 14;
    const SND_PCM_ACCESS_RW_INTERLEAVED: c_int = 3;

    extern "c" fn snd_pcm_open(pcm: **snd_pcm_t, name: [*:0]const u8, stream: c_int, mode: c_int) c_int;
    extern "c" fn snd_pcm_set_params(pcm: *snd_pcm_t, format: c_int, access: c_int, channels: c_uint, rate: c_uint, soft_resample: c_int, latency_us: c_uint) c_int;
    extern "c" fn snd_pcm_writei(pcm: *snd_pcm_t, buffer: *const anyopaque, size: c_ulong) c_long;
    extern "c" fn snd_pcm_recover(pcm: *snd_pcm_t, err: c_int, silent: c_int) c_int;
    extern "c" fn snd_pcm_prepare(pcm: *snd_pcm_t) c_int;
    extern "c" fn snd_pcm_drain(pcm: *snd_pcm_t) c_int;
    extern "c" fn snd_pcm_close(pcm: *snd_pcm_t) c_int;

    pcm: *snd_pcm_t,
    channels: u16,

    fn open(rate: u32, channels: u16) Error!Alsa {
        var pcm: *snd_pcm_t = undefined;
        if (snd_pcm_open(&pcm, "default", SND_PCM_STREAM_PLAYBACK, 0) < 0) return Error.OpenFailed;
        // soft_resample=1 (ALSA resamples if the device can't handle the rate); ~100ms of latency.
        if (snd_pcm_set_params(pcm, SND_PCM_FORMAT_FLOAT_LE, SND_PCM_ACCESS_RW_INTERLEAVED, channels, rate, 1, 100_000) < 0) {
            _ = snd_pcm_close(pcm);
            return Error.OpenFailed;
        }
        return .{ .pcm = pcm, .channels = channels };
    }

    fn write(self: *Alsa, samples: []const f32) void {
        const ch: usize = @max(self.channels, 1);
        var off: usize = 0;
        const total_frames = samples.len / ch;
        while (off < total_frames) {
            const n = snd_pcm_writei(self.pcm, samples.ptr + off * ch, @intCast(total_frames - off));
            if (n < 0) {
                // Underrun/error: try to recover and retry the same chunk.
                if (snd_pcm_recover(self.pcm, @intCast(n), 1) < 0) return;
                continue;
            }
            off += @intCast(n);
        }
    }

    fn close(self: *Alsa) void {
        _ = snd_pcm_drain(self.pcm);
        _ = snd_pcm_close(self.pcm);
    }
};

test "device out compiles and plays into the null/real backend without error" {
    // On headless CI the real device may fail to open: we tolerate OpenFailed, what matters
    // is that the API compiles and that play() on an open device doesn't crash.
    var dev = DeviceOut.open(48_000, 2) catch return;
    defer dev.close();
    var block = try AudioBlock.init(std.testing.allocator, 48_000, 2, &(.{0.0} ** 512));
    defer block.deinit();
    dev.play(&block);
}
