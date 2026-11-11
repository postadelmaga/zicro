//! # zicro.audio_device — real hardware audio I/O
//!
//! The missing pieces of [`audio`]: concrete [`AudioOut`](audio.AudioOut) / [`AudioIn`](audio.AudioIn)
//! devices that drive the sound card, so an [`AudioSink`](audio.AudioSink) actually makes
//! noise and an [`AudioSource`](audio.AudioSource) actually hears. Platform backend behind a
//! comptime switch, like the window backends:
//!   - **Windows** → **WASAPI** shared-mode output (src/audio_wasapi.c: follows the default
//!     endpoint, reopens after a device loss, reports real latency), `winmm` **waveOut** as
//!     the fallback when WASAPI can't open; capture stays on **waveIn**.
//!   - **Linux**   → **ALSA** `snd_pcm` (`default` device), blocking interleaved reads/writes.
//!   - **macOS**   → **AudioQueue** output (AudioToolbox, opened at runtime: nothing to
//!     link, so cross-compiles need no SDK). Capture stays the no-op device.
//!   - other       → a no-op device (compiles everywhere; silent output / silent capture).
//!
//! The device opens at a FIXED format — 32-bit float, interleaved, `channels`×`rate` — and
//! does NOT resample: the producer (e.g. a libav player, or a MIDI synth) renders straight
//! to `openedRate()`/`openedChannels()`, and a consumer of [`DeviceIn`] reads that same
//! format. That keeps the device dumb and the policy (A/V sync, resampling) where the data
//! comes from. `play()` blocks until the block is queued, so backpressure flows back through
//! the lossless [`AudioSink`] channel — no dropped audio. `capture()` blocks until the next
//! block is read; capture hardware won't wait, so the *overflow* policy (drop vs. block a
//! slow consumer) lives in [`AudioSource`], not here.

const std = @import("std");
const builtin = @import("builtin");
const media = @import("media.zig");
const time = @import("time.zig");

pub const AudioBlock = media.AudioBlock;

const is_win = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;
const is_mac = builtin.os.tag == .macos;

pub const Error = error{ OpenFailed, Unsupported };

/// Name the app's audio streams (PipeWire `application.id`/`application.name`) before
/// opening a device. The session manager remembers a volume per stream identity: an app
/// that also plays through another engine naming itself the same way (mpv's
/// `audio-client-name`) keeps one volume for both. No-op elsewhere. `id` is copied.
pub fn setAppId(id: [:0]const u8) void {
    if (comptime is_linux) zicro_pw_set_app_id(id.ptr);
}

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

    /// Same as [`play`] but straight from a caller-owned slice: no `AudioBlock` wrapping,
    /// so no per-block allocation + copy. For real-time producers (a media player thread)
    /// that already own a scratch buffer and just need the blocking submit.
    pub fn playRaw(self: *DeviceOut, samples: []const f32) void {
        if (samples.len == 0) return;
        self.backend.write(samples);
    }

    /// Current estimated output latency in frames — how far the newest submitted sample is
    /// from the speaker — or `null` when the backend can't tell (ALSA/waveOut/null device).
    /// PipeWire reports ring occupancy + one graph quantum, live: a player can derive an
    /// exact-ish playback clock (`submitted - latencyFrames()`) instead of guessing.
    pub fn latencyFrames(self: *const DeviceOut) ?u32 {
        return self.backend.latencyFrames();
    }

    /// How many times the backend reopened its stream after losing the device (or after
    /// the default device changed), or `null` when the backend doesn't reopen by itself
    /// (everything but WASAPI). Diagnostics and tests: a removal that never shows up here
    /// was never noticed.
    pub fn reopens(self: *const DeviceOut) ?u32 {
        if (comptime Backend != WinOut) return null;
        return self.backend.reopens();
    }

    pub fn close(self: *DeviceOut) void {
        self.backend.close();
    }
};

/// Hardware audio input — the dual of [`DeviceOut`]. Wrap with `audio.AudioIn.of(DeviceIn, &dev)`
/// to feed an `AudioSource`, or call `capture()` directly. Not thread-safe: one consumer thread.
pub const DeviceIn = struct {
    backend: InBackend,
    rate: u32,
    channels: u16,

    /// Open the default capture device at `rate` Hz / `channels`, 32-bit float.
    pub fn open(rate: u32, channels: u16) Error!DeviceIn {
        return .{ .backend = try InBackend.open(rate, channels), .rate = rate, .channels = channels };
    }

    pub fn openedRate(self: *const DeviceIn) u32 {
        return self.rate;
    }
    pub fn openedChannels(self: *const DeviceIn) u16 {
        return self.channels;
    }

    /// Read one block of interleaved f32 samples into `buf` (device format). Blocks until
    /// the hardware delivers samples, then returns the number of *frames* read (samples =
    /// frames × channels). Returns `null` on end-of-stream or an unrecoverable device error
    /// (the caller stops) and `0` when nothing arrived this round (retry). `buf` should hold
    /// whole frames.
    pub fn capture(self: *DeviceIn, buf: []f32) ?usize {
        if (buf.len == 0) return 0;
        return self.backend.read(buf, self.channels);
    }

    pub fn close(self: *DeviceIn) void {
        self.backend.close();
    }
};

// ── Backend selection ───────────────────────────────────────────────────────
// On Linux both audio backends are tried at runtime: PipeWire first (low latency), ALSA as
// the fallback when no PipeWire graph is reachable (see LinuxOut/LinuxIn).
const Backend = if (is_win) WinOut else if (is_linux) LinuxOut else if (is_mac) MacOut else NullDev;
const InBackend = if (is_win) WaveIn else if (is_linux) LinuxIn else NullIn;

/// Fallback for platforms without a backend: silent, always "succeeds".
const NullDev = struct {
    fn open(_: u32, _: u16) Error!NullDev {
        return .{};
    }
    fn write(_: *NullDev, _: []const f32) void {}
    fn latencyFrames(_: *const NullDev) ?u32 {
        return null;
    }
    fn close(_: *NullDev) void {}
};

/// Capture fallback: fills the buffer with silence and "succeeds". Reports a full block so a
/// polling `AudioSource` still makes progress (and observes shutdown) on a device-less build.
const NullIn = struct {
    fn open(_: u32, _: u16) Error!NullIn {
        return .{};
    }
    fn read(_: *NullIn, buf: []f32, channels: u16) ?usize {
        @memset(buf, 0);
        return buf.len / @max(channels, 1);
    }
    fn close(_: *NullIn) void {}
};

// ── macOS: AudioToolbox AudioQueue ─────────────────────────────────────────
// Same shape as WaveOut: a small pool of queue buffers, `write` copies a block into the
// next free one (waiting, with a cap, for the hardware to hand it back) and enqueues it.
// The queue runs its callbacks on its own internal thread (run loop NULL): the callback
// only flips the buffer's "busy" flag. That shared state lives on the heap, because the
// backend value is moved after `open` and the callback keeps the pointer.
const MacOut = struct {
    const OSStatus = i32;
    const AudioQueueRef = *anyopaque;
    const AudioStreamBasicDescription = extern struct {
        mSampleRate: f64,
        mFormatID: u32,
        mFormatFlags: u32,
        mBytesPerPacket: u32,
        mFramesPerPacket: u32,
        mBytesPerFrame: u32,
        mChannelsPerFrame: u32,
        mBitsPerChannel: u32,
        mReserved: u32 = 0,
    };
    const AudioQueueBuffer = extern struct {
        mAudioDataBytesCapacity: u32,
        mAudioData: [*]u8,
        mAudioDataByteSize: u32,
        mUserData: ?*anyopaque,
        mPacketDescriptionCapacity: u32,
        mPacketDescriptions: ?*anyopaque,
        mPacketDescriptionCount: u32,
    };
    const Callback = *const fn (?*anyopaque, AudioQueueRef, *AudioQueueBuffer) callconv(.c) void;
    const kAudioFormatLinearPCM: u32 = 0x6C70636D; // 'lpcm'
    const kAudioFormatFlagIsFloat: u32 = 1 << 0;
    const kAudioFormatFlagIsPacked: u32 = 1 << 3;

    const Api = struct {
        AudioQueueNewOutput: *const fn (*const AudioStreamBasicDescription, Callback, ?*anyopaque, ?*anyopaque, ?*anyopaque, u32, *AudioQueueRef) callconv(.c) OSStatus,
        AudioQueueAllocateBuffer: *const fn (AudioQueueRef, u32, **AudioQueueBuffer) callconv(.c) OSStatus,
        AudioQueueFreeBuffer: *const fn (AudioQueueRef, *AudioQueueBuffer) callconv(.c) OSStatus,
        AudioQueueEnqueueBuffer: *const fn (AudioQueueRef, *AudioQueueBuffer, u32, ?*const anyopaque) callconv(.c) OSStatus,
        AudioQueueStart: *const fn (AudioQueueRef, ?*const anyopaque) callconv(.c) OSStatus,
        AudioQueueStop: *const fn (AudioQueueRef, bool) callconv(.c) OSStatus,
        AudioQueueDispose: *const fn (AudioQueueRef, bool) callconv(.c) OSStatus,
        AudioQueueGetCurrentTime: *const fn (AudioQueueRef, ?*anyopaque, *AudioTimeStamp, ?*u8) callconv(.c) OSStatus,
    };
    /// CoreAudio's AudioTimeStamp (64 bytes): only `mSampleTime` is read — the queue's
    /// playback position, in frames of the queue's own format, since `AudioQueueStart`.
    const AudioTimeStamp = extern struct {
        mSampleTime: f64,
        mHostTime: u64,
        mRateScalar: f64,
        mWordClockTime: u64,
        mSMPTETime: [24]u8,
        mFlags: u32,
        mReserved: u32,
    };
    comptime {
        std.debug.assert(@sizeOf(AudioTimeStamp) == 64);
    }
    const toolbox_path = "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox";
    var api_lock: std.atomic.Value(bool) = .init(false);
    var api: ?Api = null;

    /// The framework stays loaded for the process lifetime (it lives in the dyld shared
    /// cache anyway): a queue's callbacks must never outlive the code that serves them.
    fn getApi() ?*const Api {
        while (api_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        defer api_lock.store(false, .release);
        if (api) |*a| return a;
        var lib = std.DynLib.open(toolbox_path) catch return null;
        var a: Api = undefined;
        inline for (@typeInfo(Api).@"struct".field_names, @typeInfo(Api).@"struct".field_types) |name, T| {
            @field(a, name) = lib.lookup(T, name) orelse return null;
        }
        api = a;
        return &api.?;
    }

    extern "c" fn usleep(usec: c_uint) c_int;

    const NBUF = 8;
    const Shared = struct { busy: [NBUF]std.atomic.Value(bool) };

    a: *const Api,
    q: AudioQueueRef,
    shared: *Shared,
    bufs: [NBUF]?*AudioQueueBuffer,
    next: usize,
    started: bool,
    channels: u16,
    rate: u32,
    /// Frames handed to the queue since start (the producer thread only).
    submitted: u64,
    /// `time.monotonicMs` at `AudioQueueStart`: bounds the reported position (below).
    start_ms: i64,

    fn onDone(user: ?*anyopaque, _: AudioQueueRef, buf: *AudioQueueBuffer) callconv(.c) void {
        const sh: *Shared = @ptrCast(@alignCast(user.?));
        const idx = @intFromPtr(buf.mUserData) - 1;
        sh.busy[idx].store(false, .release);
    }

    fn open(rate: u32, channels: u16) Error!MacOut {
        const a = getApi() orelse return Error.OpenFailed;
        const shared = std.heap.c_allocator.create(Shared) catch return Error.OpenFailed;
        for (&shared.busy) |*b| b.* = .init(false);
        const frame_bytes: u32 = @as(u32, channels) * 4;
        const fmt = AudioStreamBasicDescription{
            .mSampleRate = @floatFromInt(rate),
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            .mBytesPerPacket = frame_bytes,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = frame_bytes,
            .mChannelsPerFrame = channels,
            .mBitsPerChannel = 32,
        };
        var q: AudioQueueRef = undefined;
        if (a.AudioQueueNewOutput(&fmt, onDone, shared, null, null, 0, &q) != 0) {
            std.heap.c_allocator.destroy(shared);
            return Error.OpenFailed;
        }
        return .{ .a = a, .q = q, .shared = shared, .bufs = @splat(null), .next = 0, .started = false, .channels = channels, .rate = rate, .submitted = 0, .start_ms = 0 };
    }

    /// Largest buffer handed to the queue, in frames (~85 ms at 48 kHz). A decoder
    /// frame can be far longer (TTA: ~1 s, Monkey's Audio: ~1.5 s): one buffer per
    /// write would queue NBUF of them, seconds of audio, while the other codecs queue
    /// well under a second. Seen on the GitHub macOS VMs: with TTA the queue reported
    /// ~7 s queued and its position did not move for 6 s.
    const max_buf_frames = 4096;

    /// Blocking write = backpressure, capped at ~2 s per buffer like WaveOut: a queue
    /// that never drains (no output device) drops the block instead of hanging the
    /// producer. Blocks longer than `max_buf_frames` go out as several buffers.
    fn write(self: *MacOut, samples: []const f32) void {
        const step = max_buf_frames * @as(usize, @max(self.channels, 1));
        var rest = samples;
        while (rest.len > 0) {
            const n = @min(rest.len, step);
            self.writeBuffer(rest[0..n]);
            rest = rest[n..];
        }
    }

    fn writeBuffer(self: *MacOut, samples: []const f32) void {
        const bytes = std.mem.sliceAsBytes(samples);
        const i = self.next;
        var spins: u32 = 0;
        while (self.shared.busy[i].load(.acquire)) : (spins += 1) {
            if (spins > 2000) return;
            _ = usleep(1000);
        }
        if (self.bufs[i]) |b| {
            if (b.mAudioDataBytesCapacity < bytes.len) {
                _ = self.a.AudioQueueFreeBuffer(self.q, b);
                self.bufs[i] = null;
            }
        }
        if (self.bufs[i] == null) {
            var nb: *AudioQueueBuffer = undefined;
            if (self.a.AudioQueueAllocateBuffer(self.q, @intCast(bytes.len), &nb) != 0) return;
            nb.mUserData = @ptrFromInt(i + 1);
            self.bufs[i] = nb;
        }
        const b = self.bufs[i].?;
        @memcpy(b.mAudioData[0..bytes.len], bytes);
        b.mAudioDataByteSize = @intCast(bytes.len);
        self.shared.busy[i].store(true, .release);
        if (self.a.AudioQueueEnqueueBuffer(self.q, b, 0, null) != 0) {
            self.shared.busy[i].store(false, .release);
            return;
        }
        if (!self.started) {
            self.started = self.a.AudioQueueStart(self.q, null) == 0;
            if (self.started) self.start_ms = time.monotonicMs();
        }
        self.submitted += samples.len / @max(self.channels, 1);
        self.next = (i + 1) % NBUF;
    }

    /// Frames queued and not yet played: submitted minus the queue's playback position
    /// (`AudioQueueGetCurrentTime`). The output device's own hardware latency (a few ms)
    /// is not included. `null` only before the queue starts.
    fn latencyFrames(self: *const MacOut) ?u32 {
        if (!self.started) return null;
        // Right after AudioQueueStart the queue may have no position yet (the call
        // fails or mSampleTime < 0): nothing has played, so everything submitted is
        // queued. Returning null there made the player fall back to its fixed 30 ms
        // estimate with ~0.6 s already queued (seen on the GitHub macOS VMs with
        // fast-decoding WAV): the audio clock ran ~0.5 s ahead of real time.
        var ts: AudioTimeStamp = undefined;
        const pos: u64 = if (self.a.AudioQueueGetCurrentTime(self.q, null, &ts, null) == 0 and ts.mSampleTime >= 0)
            @intFromFloat(ts.mSampleTime)
        else
            0;
        // A device never plays faster than real time: the position is bounded by the
        // time elapsed since the start, whatever the queue reports.
        const elapsed_ms: u64 = @intCast(@max(0, time.monotonicMs() - self.start_ms));
        const wall: u64 = elapsed_ms * self.rate / 1000;
        const played: u64 = @min(pos, wall);
        return @intCast(@min(self.submitted -| played, std.math.maxInt(u32)));
    }

    fn close(self: *MacOut) void {
        _ = self.a.AudioQueueStop(self.q, true); // immediate: no callback after this returns
        _ = self.a.AudioQueueDispose(self.q, true); // frees the buffers too
        std.heap.c_allocator.destroy(self.shared);
    }
};

// ── Windows: winmm shared constants/types/decls (WaveOut and WaveIn are otherwise
// identical mirror images of each other over waveOut*/waveIn* — one home for the
// bytes-on-the-wire shape they share). ─────────────────────────────────────────
const winmm = struct {
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

    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
};

// ── Windows: winmm waveOut ──────────────────────────────────────────────────
const WaveOut = struct {
    const HWAVEOUT = *anyopaque;
    const WAVE_MAPPER = winmm.WAVE_MAPPER;
    const WAVE_FORMAT_IEEE_FLOAT = winmm.WAVE_FORMAT_IEEE_FLOAT;
    const CALLBACK_NULL = winmm.CALLBACK_NULL;
    const WHDR_DONE = winmm.WHDR_DONE;
    const WHDR_PREPARED = winmm.WHDR_PREPARED;
    const MMSYSERR_NOERROR = winmm.MMSYSERR_NOERROR;
    const WAVEFORMATEX = winmm.WAVEFORMATEX;
    const WAVEHDR = winmm.WAVEHDR;
    const Sleep = winmm.Sleep;

    extern "winmm" fn waveOutOpen(phwo: *HWAVEOUT, uDeviceID: u32, pwfx: *const WAVEFORMATEX, cb: usize, inst: usize, flags: u32) callconv(.winapi) u32;
    extern "winmm" fn waveOutPrepareHeader(hwo: HWAVEOUT, pwh: *WAVEHDR, cb: u32) callconv(.winapi) u32;
    extern "winmm" fn waveOutUnprepareHeader(hwo: HWAVEOUT, pwh: *WAVEHDR, cb: u32) callconv(.winapi) u32;
    extern "winmm" fn waveOutWrite(hwo: HWAVEOUT, pwh: *WAVEHDR, cb: u32) callconv(.winapi) u32;
    extern "winmm" fn waveOutReset(hwo: HWAVEOUT) callconv(.winapi) u32;
    extern "winmm" fn waveOutClose(hwo: HWAVEOUT) callconv(.winapi) u32;

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

    fn latencyFrames(_: *const WaveOut) ?u32 {
        return null; // queue depth is known only in bytes queued, not device position
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

// ── Windows: winmm waveIn (dual of WaveOut) ─────────────────────────────────
const WaveIn = struct {
    const HWAVEIN = *anyopaque;
    const WAVE_MAPPER = winmm.WAVE_MAPPER;
    const WAVE_FORMAT_IEEE_FLOAT = winmm.WAVE_FORMAT_IEEE_FLOAT;
    const CALLBACK_NULL = winmm.CALLBACK_NULL;
    const WHDR_DONE = winmm.WHDR_DONE;
    const WHDR_PREPARED = winmm.WHDR_PREPARED;
    const MMSYSERR_NOERROR = winmm.MMSYSERR_NOERROR;
    const WAVEFORMATEX = winmm.WAVEFORMATEX;
    const WAVEHDR = winmm.WAVEHDR;
    const Sleep = winmm.Sleep;

    extern "winmm" fn waveInOpen(phwi: *HWAVEIN, uDeviceID: u32, pwfx: *const WAVEFORMATEX, cb: usize, inst: usize, flags: u32) callconv(.winapi) u32;
    extern "winmm" fn waveInPrepareHeader(hwi: HWAVEIN, pwh: *WAVEHDR, cb: u32) callconv(.winapi) u32;
    extern "winmm" fn waveInUnprepareHeader(hwi: HWAVEIN, pwh: *WAVEHDR, cb: u32) callconv(.winapi) u32;
    extern "winmm" fn waveInAddBuffer(hwi: HWAVEIN, pwh: *WAVEHDR, cb: u32) callconv(.winapi) u32;
    extern "winmm" fn waveInStart(hwi: HWAVEIN) callconv(.winapi) u32;
    extern "winmm" fn waveInStop(hwi: HWAVEIN) callconv(.winapi) u32;
    extern "winmm" fn waveInReset(hwi: HWAVEIN) callconv(.winapi) u32;
    extern "winmm" fn waveInClose(hwi: HWAVEIN) callconv(.winapi) u32;

    const NBUF = 8; // WAVEHDR pool: queue depth ~ NBUF × block size

    hwi: HWAVEIN,
    channels: u16,
    hdrs: [NBUF]WAVEHDR,
    bufs: [NBUF][]u8, // capture buffer per header (sized on first read)
    next: usize,
    started: bool,
    gpa: std.mem.Allocator,

    fn open(rate: u32, channels: u16) Error!WaveIn {
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
        var hwi: HWAVEIN = undefined;
        if (waveInOpen(&hwi, WAVE_MAPPER, &fmt, 0, 0, CALLBACK_NULL) != MMSYSERR_NOERROR)
            return Error.OpenFailed;
        var self = WaveIn{
            .hwi = hwi,
            .channels = channels,
            .hdrs = undefined,
            .bufs = undefined,
            .next = 0,
            .started = false,
            .gpa = std.heap.c_allocator,
        };
        for (0..NBUF) |i| {
            self.hdrs[i] = .{ .lpData = undefined, .dwBufferLength = 0 };
            self.bufs[i] = &.{};
        }
        return self;
    }

    /// The capture queue is sized to the first `read`'s block: allocate and enqueue every
    /// header at that size, then start recording. Idempotent — later reads with a bigger
    /// buffer keep the original block size (the producer picks one size and sticks to it).
    fn ensureStarted(self: *WaveIn, bytes: usize) bool {
        if (self.started) return true;
        for (0..NBUF) |i| {
            self.bufs[i] = self.gpa.alloc(u8, bytes) catch return false;
            self.hdrs[i] = .{ .lpData = self.bufs[i].ptr, .dwBufferLength = @intCast(bytes) };
            if (waveInPrepareHeader(self.hwi, &self.hdrs[i], @sizeOf(WAVEHDR)) != MMSYSERR_NOERROR) return false;
            if (waveInAddBuffer(self.hwi, &self.hdrs[i], @sizeOf(WAVEHDR)) != MMSYSERR_NOERROR) return false;
        }
        if (waveInStart(self.hwi) != MMSYSERR_NOERROR) return false;
        self.started = true;
        return true;
    }

    /// Waits for the next header the driver has filled, copies its recorded samples into
    /// `buf`, re-queues that header, and advances. Returns frames read, or `null` if the
    /// device can't start or stalls (unrecoverable).
    fn read(self: *WaveIn, buf: []f32, channels: u16) ?usize {
        const want = std.mem.sliceAsBytes(buf);
        if (!self.ensureStarted(want.len)) return null;
        const h = &self.hdrs[self.next];
        // Wait until the driver has finished filling this header, but cap the wait (~2s) so
        // the capture thread stays responsive (stop/join) if the device stalls.
        var spins: u32 = 0;
        while ((h.dwFlags & WHDR_DONE) == 0) : (spins += 1) {
            if (spins > 2000) return null;
            Sleep(1);
        }
        const recorded = @min(h.dwBytesRecorded, self.bufs[self.next].len);
        const n = @min(recorded, want.len);
        @memcpy(want[0..n], self.bufs[self.next][0..n]);
        // Re-queue the header for reuse (dwFlags keeps WHDR_PREPARED; clear DONE via re-add).
        h.dwFlags &= ~WHDR_DONE;
        h.dwBytesRecorded = 0;
        _ = waveInAddBuffer(self.hwi, h, @sizeOf(WAVEHDR));
        self.next = (self.next + 1) % NBUF;
        return n / (4 * @as(usize, @max(channels, 1)));
    }

    fn close(self: *WaveIn) void {
        if (self.started) {
            _ = waveInStop(self.hwi);
            _ = waveInReset(self.hwi); // marks queued headers as DONE
        }
        for (0..NBUF) |i| {
            if ((self.hdrs[i].dwFlags & WHDR_PREPARED) != 0)
                _ = waveInUnprepareHeader(self.hwi, &self.hdrs[i], @sizeOf(WAVEHDR));
            if (self.bufs[i].len > 0) self.gpa.free(self.bufs[i]);
        }
        _ = waveInClose(self.hwi);
    }
};

// ── Windows: WASAPI first, waveOut as the fallback ─────────────────────────
// Same shape as LinuxOut (PipeWire → ALSA). `ZICRO_AUDIO=waveout` forces the fallback,
// for comparisons and for the tests of the fallback path itself.
const WinOut = union(enum) {
    wasapi: WasapiOut,
    waveout: WaveOut,

    fn open(rate: u32, channels: u16) Error!WinOut {
        const force_waveout = if (std.c.getenv("ZICRO_AUDIO")) |v| std.mem.eql(u8, std.mem.span(v), "waveout") else false;
        if (!force_waveout) {
            if (WasapiOut.open(rate, channels)) |w| return .{ .wasapi = w } else |_| {}
        }
        return .{ .waveout = try WaveOut.open(rate, channels) };
    }
    fn write(self: *WinOut, samples: []const f32) void {
        switch (self.*) {
            inline else => |*b| b.write(samples),
        }
    }
    fn latencyFrames(self: *const WinOut) ?u32 {
        return switch (self.*) {
            inline else => |*b| b.latencyFrames(),
        };
    }
    fn reopens(self: *const WinOut) ?u32 {
        return switch (self.*) {
            .wasapi => |*b| b.reopens(),
            else => null,
        };
    }
    fn close(self: *WinOut) void {
        switch (self.*) {
            inline else => |*b| b.close(),
        }
    }
};

const WasapiOut = struct {
    extern fn zicro_wasapi_open(rate: c_uint, channels: c_uint) ?*anyopaque;
    extern fn zicro_wasapi_write(h: *anyopaque, samples: [*]const f32, frames: c_uint) c_int;
    extern fn zicro_wasapi_latency(h: *anyopaque) c_int;
    extern fn zicro_wasapi_close(h: *anyopaque) void;
    extern fn zicro_wasapi_reopens(h: *anyopaque) c_uint;

    h: *anyopaque,
    channels: u16,

    fn open(rate: u32, channels: u16) Error!WasapiOut {
        const h = zicro_wasapi_open(rate, channels) orelse return Error.OpenFailed;
        return .{ .h = h, .channels = channels };
    }
    fn write(self: *WasapiOut, samples: []const f32) void {
        const frames = samples.len / @max(self.channels, 1);
        if (frames > 0) _ = zicro_wasapi_write(self.h, samples.ptr, @intCast(frames));
    }
    fn latencyFrames(self: *const WasapiOut) ?u32 {
        const l = zicro_wasapi_latency(self.h);
        return if (l < 0) null else @intCast(l);
    }
    fn reopens(self: *const WasapiOut) u32 {
        return zicro_wasapi_reopens(self.h);
    }
    fn close(self: *WasapiOut) void {
        zicro_wasapi_close(self.h);
    }
};

/// Loopback capture of the default output's MIX (Windows/WASAPI only), for tests that
/// must prove samples actually reached the device — see `audio_wasapi.c`. Mono f32.
pub const Loopback = if (is_win) struct {
    extern fn zicro_wasapi_loop_open(rate: *c_uint, channels: *c_uint) ?*anyopaque;
    extern fn zicro_wasapi_loop_read(h: *anyopaque, out: [*]f32, cap: c_int) c_int;
    extern fn zicro_wasapi_loop_close(h: *anyopaque) void;

    h: *anyopaque,
    rate: u32,

    pub fn open() Error!@This() {
        var rate: c_uint = 0;
        var ch: c_uint = 0;
        const h = zicro_wasapi_loop_open(&rate, &ch) orelse return Error.OpenFailed;
        return .{ .h = h, .rate = rate };
    }
    /// Drains what was captured since the last call into `out`; returns samples read.
    pub fn read(self: *@This(), out: []f32) ?usize {
        const n = zicro_wasapi_loop_read(self.h, out.ptr, @intCast(@min(out.len, std.math.maxInt(c_int))));
        return if (n < 0) null else @intCast(n);
    }
    pub fn close(self: *@This()) void {
        zicro_wasapi_loop_close(self.h);
    }
} else struct {
    rate: u32 = 0,
    pub fn open() Error!@This() {
        return Error.Unsupported;
    }
    pub fn read(_: *@This(), _: []f32) ?usize {
        return null;
    }
    pub fn close(_: *@This()) void {}
};

/// Active output endpoints as "name\n" lines (the default one prefixed "* "), for
/// diagnostics; returns how many. Only Windows enumerates for now (elsewhere: 0 and
/// an empty string — the backends there always play on the system default).
pub fn listOutputs(buf: []u8) usize {
    if (comptime is_win) {
        const f = struct {
            extern fn zicro_wasapi_list(out: [*]u8, cap: c_int) c_int;
        };
        const n = f.zicro_wasapi_list(buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_int))));
        return if (n < 0) 0 else @intCast(n);
    }
    if (buf.len > 0) buf[0] = 0;
    return 0;
}

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

    fn latencyFrames(_: *const Alsa) ?u32 {
        return null; // snd_pcm_delay would need error/xrun handling; callers keep their estimate
    }

    fn close(self: *Alsa) void {
        _ = snd_pcm_drain(self.pcm);
        _ = snd_pcm_close(self.pcm);
    }
};

// ── Linux: ALSA snd_pcm capture (dual of Alsa) ──────────────────────────────
const AlsaIn = struct {
    const snd_pcm_t = Alsa.snd_pcm_t;
    const SND_PCM_STREAM_CAPTURE: c_int = 1;
    const SND_PCM_FORMAT_FLOAT_LE = Alsa.SND_PCM_FORMAT_FLOAT_LE;
    const SND_PCM_ACCESS_RW_INTERLEAVED = Alsa.SND_PCM_ACCESS_RW_INTERLEAVED;

    // snd_pcm_readi is the capture dual of snd_pcm_writei (not declared on the output side).
    extern "c" fn snd_pcm_readi(pcm: *snd_pcm_t, buffer: *anyopaque, size: c_ulong) c_long;

    pcm: *snd_pcm_t,
    channels: u16,

    fn open(rate: u32, channels: u16) Error!AlsaIn {
        var pcm: *snd_pcm_t = undefined;
        if (Alsa.snd_pcm_open(&pcm, "default", SND_PCM_STREAM_CAPTURE, 0) < 0) return Error.OpenFailed;
        // soft_resample=1; ~100ms of buffering. A low-latency capture path is issue #16.
        if (Alsa.snd_pcm_set_params(pcm, SND_PCM_FORMAT_FLOAT_LE, SND_PCM_ACCESS_RW_INTERLEAVED, channels, rate, 1, 100_000) < 0) {
            _ = Alsa.snd_pcm_close(pcm);
            return Error.OpenFailed;
        }
        return .{ .pcm = pcm, .channels = channels };
    }

    /// Read up to `buf.len / channels` frames; blocks until at least one arrives. Recovers
    /// from over/underruns internally, so it returns `null` only on an unrecoverable error
    /// (and `0` only for a zero-length buffer).
    fn read(self: *AlsaIn, buf: []f32, channels: u16) ?usize {
        const ch: usize = @max(channels, 1);
        const want_frames = buf.len / ch;
        if (want_frames == 0) return 0;
        while (true) {
            const n = snd_pcm_readi(self.pcm, buf.ptr, @intCast(want_frames));
            if (n < 0) {
                // Overrun/error: recover and retry (silent=1). Give up if unrecoverable.
                if (Alsa.snd_pcm_recover(self.pcm, @intCast(n), 1) < 0) return null;
                continue;
            }
            return @intCast(n);
        }
    }

    fn close(self: *AlsaIn) void {
        _ = Alsa.snd_pcm_close(self.pcm);
    }
};

// ── Linux: PipeWire (via the audio_pw.c shim) ───────────────────────────────
// The shim exposes a blocking push/pull API over pw_stream's realtime callback, so these
// backends look exactly like the ALSA ones to DeviceOut/DeviceIn.
extern fn zicro_pw_open_playback(rate: u32, channels: u16) ?*anyopaque;
extern fn zicro_pw_open_capture(rate: u32, channels: u16) ?*anyopaque;
extern fn zicro_pw_write(pw: *anyopaque, src: [*]const f32, frames: usize) c_int;
extern fn zicro_pw_read(pw: *anyopaque, dst: [*]f32, frames: usize) usize;
extern fn zicro_pw_delay_frames(pw: *anyopaque) u32;
extern fn zicro_pw_close(pw: *anyopaque) void;
extern fn zicro_pw_set_app_id(id: [*:0]const u8) void;

const PipeWireOut = struct {
    handle: *anyopaque,
    channels: u16,

    fn open(rate: u32, channels: u16) Error!PipeWireOut {
        const h = zicro_pw_open_playback(rate, channels) orelse return Error.OpenFailed;
        return .{ .handle = h, .channels = channels };
    }
    fn write(self: *PipeWireOut, samples: []const f32) void {
        const ch: usize = @max(self.channels, 1);
        _ = zicro_pw_write(self.handle, samples.ptr, samples.len / ch);
    }
    fn latencyFrames(self: *const PipeWireOut) ?u32 {
        return zicro_pw_delay_frames(self.handle);
    }
    fn close(self: *PipeWireOut) void {
        zicro_pw_close(self.handle);
    }
};

const PipeWireIn = struct {
    handle: *anyopaque,
    channels: u16,

    fn open(rate: u32, channels: u16) Error!PipeWireIn {
        const h = zicro_pw_open_capture(rate, channels) orelse return Error.OpenFailed;
        return .{ .handle = h, .channels = channels };
    }
    fn read(self: *PipeWireIn, buf: []f32, channels: u16) ?usize {
        const ch: usize = @max(channels, 1);
        const n = zicro_pw_read(self.handle, buf.ptr, buf.len / ch);
        return if (n == 0) null else n; // shim returns 0 only when the stream is closing
    }
    fn close(self: *PipeWireIn) void {
        zicro_pw_close(self.handle);
    }
};

// ── Linux output/input: PipeWire first, ALSA fallback ───────────────────────
const LinuxOut = union(enum) {
    pw: PipeWireOut,
    alsa: Alsa,

    fn open(rate: u32, channels: u16) Error!LinuxOut {
        if (PipeWireOut.open(rate, channels)) |p| return .{ .pw = p } else |_| {}
        return .{ .alsa = try Alsa.open(rate, channels) };
    }
    fn write(self: *LinuxOut, samples: []const f32) void {
        switch (self.*) {
            .pw => |*p| p.write(samples),
            .alsa => |*a| a.write(samples),
        }
    }
    fn latencyFrames(self: *const LinuxOut) ?u32 {
        return switch (self.*) {
            .pw => |*p| p.latencyFrames(),
            .alsa => |*a| a.latencyFrames(),
        };
    }
    fn close(self: *LinuxOut) void {
        switch (self.*) {
            .pw => |*p| p.close(),
            .alsa => |*a| a.close(),
        }
    }
};

const LinuxIn = union(enum) {
    pw: PipeWireIn,
    alsa: AlsaIn,

    fn open(rate: u32, channels: u16) Error!LinuxIn {
        if (PipeWireIn.open(rate, channels)) |p| return .{ .pw = p } else |_| {}
        return .{ .alsa = try AlsaIn.open(rate, channels) };
    }
    fn read(self: *LinuxIn, buf: []f32, channels: u16) ?usize {
        return switch (self.*) {
            .pw => |*p| p.read(buf, channels),
            .alsa => |*a| a.read(buf, channels),
        };
    }
    fn close(self: *LinuxIn) void {
        switch (self.*) {
            .pw => |*p| p.close(),
            .alsa => |*a| a.close(),
        }
    }
};

test "device out compiles and plays into the null/real backend without error" {
    // On headless CI the real device may fail to open: we tolerate OpenFailed, what matters
    // is that the API compiles and that play() on an open device doesn't crash.
    var dev = DeviceOut.open(48_000, 2) catch return;
    defer dev.close();
    var block = try AudioBlock.init(std.testing.allocator, 48_000, 2, &@as([512]f32, @splat(0.0)));
    defer block.deinit();
    dev.play(&block);
}

test "device in compiles and captures from the null/real backend without error" {
    // Same tolerance as the output test: on headless CI the real device may fail to open.
    // What matters is that the capture API compiles on every backend and doesn't crash.
    var dev = DeviceIn.open(48_000, 2) catch return;
    defer dev.close();
    var buf: [1024]f32 = undefined; // 512 frames × 2ch
    if (dev.capture(&buf)) |frames| try std.testing.expect(frames <= 512);
}
