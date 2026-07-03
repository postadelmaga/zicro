//! # zicro.shmem — the seqlock'd "latest value" shared-memory slot
//!
//! A durable **latest-wins state** channel (the generic retained-channel idea, see
//! [`bus.LocalBus.retain`]) only ever needs the *newest* value, never a history of them.
//! That makes a FIFO ring the wrong shape — it would grow unboundedly if the reader fell
//! behind, and deliver stale values the reader must then skip. The right shape is a
//! single **slot**: one fixed buffer the writer overwrites in place and the reader reads.
//!
//! The slot is protected by a **seqlock** (the classic single-writer / many-reader
//! pattern):
//!
//!   * the **writer never blocks** — it stamps an odd sequence, overwrites the bytes,
//!     stamps the next even sequence;
//!   * the **reader always observes a complete, latest value** — it snapshots the
//!     sequence, copies the bytes, and re-checks the sequence; a value that changed (or
//!     was odd, i.e. a write in flight) is retried, so a torn read is never returned;
//!   * a **reader restart re-syncs for free** — the slot is writer-owned shared memory,
//!     so a freshly respawned reader re-opens the same mapping and immediately reads the
//!     last value: the shared-memory equivalent of a retained-channel replay.
//!
//! The payload is **opaque bytes** — the writer encodes whatever it likes; this file
//! stays free of any domain dependency.
//!
//! ## Backing store & portability
//! POSIX shared memory. Zig's std has no `shm_open` wrapper, so on Linux the slot is a
//! file under `/dev/shm` — byte- and name-compatible with what glibc's `shm_open` does,
//! so a zicro writer and a Micro (Rust) reader can share one slot. Linux-only for now
//! (`create`/`open` return `error.Unsupported` elsewhere); the Rust original also covers
//! macOS and Windows.
//!
//! Port note: Zig removed the `@fence` builtin, so the Rust version's
//! `fence(Release)/fence(Acquire)` pairs become per-word release **stores** / acquire
//! **loads** on the payload itself: a reader that observes any in-flight word
//! synchronizes with the writer and is then guaranteed to see the odd sequence on its
//! re-check, which is exactly the torn-read rejection the fences bought.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Env var carrying the slot's identifier from writer to reader. The writer sets it
/// before spawning the reader; the child inherits and opens it.
pub const shmem_id_env = "MICRO_STATE_SHMEM_ID";

/// Env var that toggles the shared-memory state path. Default **on**; set to `0`/`false`/
/// `off`/`no` to force the caller's fallback transport (the safe escape hatch if shmem
/// setup fails or misbehaves on a host).
///
/// Zig 0.16 has no ambient `getenv` (the environment flows through
/// `std.process.Environ`), so fetch the variable yourself and parse it with
/// [`shmemEnabledFromEnv`]; same for `MICRO_BUS_CAP_BYTES` and [`capFromEnv`].
pub const shmem_toggle_env = "MICRO_STATE_SHMEM";

/// Parse the value of [`shmem_toggle_env`] (pass `null` when unset). Absent or anything
/// but a falsey value ⇒ enabled.
pub fn shmemEnabledFromEnv(value: ?[]const u8) bool {
    const v = value orelse return true;
    const trimmed = std.mem.trim(u8, v, " \t");
    inline for (.{ "0", "false", "off", "no" }) |falsey| {
        if (std.ascii.eqlIgnoreCase(trimmed, falsey)) return false;
    }
    return true;
}

// --- slot layout ---------------------------------------------------------------
//
// [0 ..  8)  seq : u64 atomic — seqlock counter (even = stable, odd = write in progress)
// [8 .. 16)  len : u64 atomic — current payload length in bytes
// [16 ..  )  data             — the opaque payload, up to `cap`

const off_seq: usize = 0;
const off_len: usize = 8;
const header: usize = 16;

/// Default payload ceiling (bytes) when none is configured: 128 MiB. The backing file is
/// sparse — only touched pages are ever resident — so a large ceiling is free (a tiny
/// payload uses a few hundred bytes).
pub const default_cap: usize = 128 * 1024 * 1024;

/// Parse a `MICRO_BUS_CAP_BYTES` value into a payload ceiling (pass `null` when unset).
/// Writer and reader must agree on it: the reader is typically spawned as a child of the
/// writer and inherits its environment, so both observe the same value — and the default
/// covers the case where neither sets it.
pub fn capFromEnv(value: ?[]const u8) usize {
    const v = value orelse return default_cap;
    const parsed = std.fmt.parseInt(usize, v, 10) catch return default_cap;
    return if (parsed >= 4096) parsed else default_cap;
}

/// Options for [`StateWriter.create`] / [`StateReader.open`].
pub const Options = struct {
    /// Payload ceiling in bytes — both ends must agree (see [`capFromEnv`]).
    cap: usize = default_cap,
};

/// Bounded reader retry budget: a single infrequent writer means a collision is rare and
/// clears in nanoseconds, but we never spin unboundedly — past this we report "no fresh
/// value this tick" and the caller simply polls again.
const read_retries: u32 = 1024;

fn atomicAt(base: [*]align(std.heap.page_size_min) u8, off: usize) *std.atomic.Value(u64) {
    // The mapping is page-aligned and `off` is a multiple of 8, so the cast is
    // well-aligned; the seqlock protocol is the only accessor of these words.
    return @ptrCast(@alignCast(base + off));
}

fn shmPath(buf: *[96:0]u8, id: []const u8) ![:0]const u8 {
    // A POSIX shm name "/foo" lives at /dev/shm/foo on Linux — same layout glibc uses,
    // which is what keeps a zicro slot openable by a Rust `shm_open` peer.
    if (id.len == 0 or id[0] != '/') return error.InvalidSlotId;
    return std.fmt.bufPrintZ(buf, "/dev/shm{s}", .{id});
}

// --- orphan sweeping -------------------------------------------------------------
//
// A slot is unlinked by [`StateWriter.deinit`] — which never runs if the writer process
// is SIGKILLed, panics (Zig panics abort), or exits without teardown. The backing shm
// object then outlives the process. [`sweepOrphans`] is the garbage collector for that
// case: it scans for slots whose creator pid (baked into the slot name) is no longer
// alive and unlinks them. [`StateWriter.create`] calls it best-effort, so any
// long-running host cleans up after its predecessors automatically.

/// Whether `pid` names a live process, via `/proc/<pid>`.
fn pidAlive(pid: i32) bool {
    var buf: [32:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "/proc/{d}", .{pid}) catch return true;
    return std.os.linux.errno(std.os.linux.access(path, 0)) == .SUCCESS;
}

/// Unlink every `micro-state-<pid>-*` slot whose creator process is dead, returning how
/// many were removed. Never touches a slot whose pid is still alive, so a concurrent
/// writer is safe. Linux-only (POSIX gives no portable way to enumerate shm objects, but
/// on Linux they are the files of `/dev/shm`). Sweeps the slots of Rust Micro peers too —
/// same name scheme, same backing store. Raw syscalls so it needs no `Io` and
/// [`StateWriter.create`] can run it unconditionally.
pub fn sweepOrphans() error{Unsupported}!usize {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;

    const dir_rc = linux.open("/dev/shm", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(dir_rc) != .SUCCESS) return 0; // no /dev/shm: nothing to sweep
    const dir_fd: i32 = @intCast(dir_rc);
    defer _ = linux.close(dir_fd);

    var removed: usize = 0;
    var buf: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
    while (true) {
        const n = linux.getdents64(dir_fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const entry: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            defer off += entry.reclen;
            const name_ptr: [*:0]const u8 = @ptrCast(@as([*]const u8, @ptrCast(entry)) + @offsetOf(linux.dirent64, "name"));
            const name = std.mem.sliceTo(name_ptr, 0);
            if (!std.mem.startsWith(u8, name, "micro-state-")) continue;
            const rest = name["micro-state-".len..];
            const dash = std.mem.indexOfScalar(u8, rest, '-') orelse continue;
            const pid = std.fmt.parseInt(i32, rest[0..dash], 10) catch continue;
            if (pidAlive(pid)) continue;
            // Dead creator: remove the leaked slot.
            if (linux.errno(linux.unlinkat(dir_fd, name_ptr, 0)) == .SUCCESS) removed += 1;
        }
    }
    return removed;
}

/// The single writer of a slot. Create it, export [`StateWriter.id`] to the child via
/// [`shmem_id_env`], then [`write`](StateWriter.write) at will — it never blocks.
pub const StateWriter = struct {
    id_buf: [64]u8,
    id_len: usize,
    map: []align(std.heap.page_size_min) u8,
    fd: std.posix.fd_t,
    cap: usize,

    /// Create a fresh slot: allocate the backing shared memory object and map it. Also
    /// sweeps slots leaked by dead predecessors (see [`sweepOrphans`]), best-effort.
    pub fn create(options: Options) !StateWriter {
        if (builtin.os.tag != .linux) return error.Unsupported;
        const linux = std.os.linux;

        _ = sweepOrphans() catch 0;

        var w: StateWriter = undefined;
        // Unique name: pid + nanotime, like the Rust original. `O_EXCL` below turns any
        // residual collision into a hard error instead of silent sharing.
        var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        const nanos: u64 = @intCast(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec);
        const written = std.fmt.bufPrint(&w.id_buf, "/micro-state-{d}-{d}", .{
            linux.getpid(),
            nanos,
        }) catch unreachable;
        w.id_len = written.len;

        var path_buf: [96:0]u8 = undefined;
        const path = try shmPath(&path_buf, written);
        const open_rc = linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, 0o600);
        if (linux.errno(open_rc) != .SUCCESS) return error.ShmOpenFailed;
        const fd: std.posix.fd_t = @intCast(open_rc);
        errdefer _ = linux.close(fd);

        w.cap = options.cap;
        const total = header + w.cap;
        if (linux.errno(linux.ftruncate(fd, @intCast(total))) != .SUCCESS) {
            _ = linux.unlink(path);
            return error.ShmResizeFailed;
        }
        w.map = try std.posix.mmap(null, total, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        w.fd = fd;
        return w;
    }

    /// The slot identifier to pass to the sidecar via [`shmem_id_env`].
    pub fn id(w: *const StateWriter) []const u8 {
        return w.id_buf[0..w.id_len];
    }

    /// Publish `bytes` as the new latest payload. Never blocks; an oversized blob is
    /// rejected whole (the previous value stays readable).
    pub fn write(w: *StateWriter, bytes: []const u8) error{BlobExceedsCap}!void {
        if (bytes.len > w.cap) return error.BlobExceedsCap;
        const seq = atomicAt(w.map.ptr, off_seq);
        const len = atomicAt(w.map.ptr, off_len);

        const start = seq.load(.monotonic);
        seq.store(start +% 1, .monotonic); // odd: write in progress
        len.store(bytes.len, .monotonic);

        // Release stores: a reader that acquires any of these words also sees the odd
        // sequence above, so its seq re-check rejects the torn read (the fence stand-in).
        const data = w.map.ptr + header;
        copyRelease(data, bytes);

        seq.store(start +% 2, .release); // even: stable
    }

    pub fn deinit(w: *StateWriter) void {
        std.posix.munmap(w.map);
        _ = std.os.linux.close(w.fd);
        var path_buf: [96:0]u8 = undefined;
        if (shmPath(&path_buf, w.id())) |path| {
            _ = std.os.linux.unlink(path);
        } else |_| {}
    }
};

/// A reader of a slot created by a (possibly foreign) [`StateWriter`].
pub const StateReader = struct {
    map: []align(std.heap.page_size_min) u8,
    fd: std.posix.fd_t,
    cap: usize,

    /// Open the slot the host created, by its shm name (from [`shmem_id_env`]).
    pub fn open(slot_id: []const u8, options: Options) !StateReader {
        if (builtin.os.tag != .linux) return error.Unsupported;
        const linux = std.os.linux;

        var path_buf: [96:0]u8 = undefined;
        const path = try shmPath(&path_buf, slot_id);
        const open_rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(open_rc) != .SUCCESS) return error.ShmOpenFailed;
        const fd: std.posix.fd_t = @intCast(open_rc);
        errdefer _ = linux.close(fd);

        const map = try std.posix.mmap(null, header + options.cap, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
        return .{ .map = map, .fd = fd, .cap = options.cap };
    }

    /// Copy out the latest payload **iff it changed** since `last_seq` (caller frees).
    /// `null` means: nothing written yet, nothing new, or a writer collision that
    /// outlasted the retry budget — in every case, just poll again next tick.
    pub fn readLatest(r: *const StateReader, gpa: Allocator, last_seq: *u64) Allocator.Error!?[]u8 {
        const seq = atomicAt(r.map.ptr, off_seq);
        const len = atomicAt(r.map.ptr, off_len);
        const data = r.map.ptr + header;

        var retry: u32 = 0;
        while (retry < read_retries) : (retry += 1) {
            const s1 = seq.load(.acquire);
            if (s1 & 1 != 0) {
                std.atomic.spinLoopHint();
                continue; // write in flight
            }
            if (s1 == 0) return null; // nothing ever written
            if (s1 == last_seq.*) return null; // unchanged: the caller won't rebuild

            const n = len.load(.monotonic);
            if (n > r.cap) {
                std.atomic.spinLoopHint();
                continue; // torn header: len from a write in flight
            }
            const out = try gpa.alloc(u8, @intCast(n));
            copyAcquire(out, data);
            const s2 = seq.load(.monotonic);
            if (s1 == s2) {
                last_seq.* = s1;
                return out;
            }
            gpa.free(out); // the slot moved under us: retry
        }
        return null;
    }

    pub fn deinit(r: *StateReader) void {
        std.posix.munmap(r.map);
        _ = std.os.linux.close(r.fd);
    }
};

// --- the fence-free seqlock copies ----------------------------------------------------

/// Copy `bytes` into the slot with `.release` word stores (u64 body + byte tail).
fn copyRelease(dest: [*]u8, bytes: []const u8) void {
    const words = bytes.len / 8;
    const dest_words: [*]std.atomic.Value(u64) = @ptrCast(@alignCast(dest));
    for (0..words) |i| {
        dest_words[i].store(std.mem.readInt(u64, bytes[i * 8 ..][0..8], .little), .release);
    }
    for (words * 8..bytes.len) |i| {
        @atomicStore(u8, &dest[i], bytes[i], .release);
    }
}

/// Copy the slot into `out` with `.acquire` word loads (mirror of [`copyRelease`]).
fn copyAcquire(out: []u8, src: [*]u8) void {
    const words = out.len / 8;
    const src_words: [*]std.atomic.Value(u64) = @ptrCast(@alignCast(src));
    for (0..words) |i| {
        std.mem.writeInt(u64, out[i * 8 ..][0..8], src_words[i].load(.acquire), .little);
    }
    for (words * 8..out.len) |i| {
        out[i] = @atomicLoad(u8, &src[i], .acquire);
    }
}

// --- tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "write then read latest is change-tracked" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    var w = try StateWriter.create(.{ .cap = 4096 });
    defer w.deinit();
    var r = try StateReader.open(w.id(), .{ .cap = 4096 });
    defer r.deinit();

    var seen: u64 = 0;
    // Empty slot → nothing yet.
    try testing.expectEqual(null, try r.readLatest(gpa, &seen));

    try w.write("alpha");
    const first = (try r.readLatest(gpa, &seen)).?;
    defer gpa.free(first);
    try testing.expectEqualStrings("alpha", first);
    // Unchanged → null (the render loop won't rebuild).
    try testing.expectEqual(null, try r.readLatest(gpa, &seen));

    // Latest-wins: only the newest survives, history is overwritten.
    try w.write("beta");
    try w.write("gamma");
    const latest = (try r.readLatest(gpa, &seen)).?;
    defer gpa.free(latest);
    try testing.expectEqualStrings("gamma", latest);
    try testing.expectEqual(null, try r.readLatest(gpa, &seen));
}

test "oversized blob is rejected, value preserved" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    var w = try StateWriter.create(.{ .cap = 4096 });
    defer w.deinit();
    var r = try StateReader.open(w.id(), .{ .cap = 4096 });
    defer r.deinit();

    try w.write("keep");
    const too_big = try gpa.alloc(u8, w.cap + 1);
    defer gpa.free(too_big);
    try testing.expectError(error.BlobExceedsCap, w.write(too_big));

    // The prior value must still be readable (write was rejected, not half-applied).
    var seen: u64 = 0;
    const got = (try r.readLatest(gpa, &seen)).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("keep", got);
}

test "sweepOrphans removes dead-pid slots and keeps live ones" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;

    // A pid that is certainly dead right now: scan downward from past pid_max.
    var dead_pid: i32 = 4_194_304;
    while (pidAlive(dead_pid)) dead_pid -= 1;

    // Fabricate two "leaked" slots: one from the dead pid, one from us (alive).
    var dead_buf: [96:0]u8 = undefined;
    const dead_path = try std.fmt.bufPrintZ(&dead_buf, "/dev/shm/micro-state-{d}-42", .{dead_pid});
    var live_buf: [96:0]u8 = undefined;
    const live_path = try std.fmt.bufPrintZ(&live_buf, "/dev/shm/micro-state-{d}-42", .{linux.getpid()});
    for ([_][*:0]const u8{ dead_path, live_path }) |path| {
        const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600);
        try testing.expect(linux.errno(rc) == .SUCCESS);
        _ = linux.close(@intCast(rc));
    }
    defer _ = linux.unlink(live_path);

    const removed = try sweepOrphans();
    try testing.expect(removed >= 1);
    // The dead creator's slot is gone; the live one survived.
    try testing.expect(linux.errno(linux.access(dead_path, 0)) != .SUCCESS);
    try testing.expect(linux.errno(linux.access(live_path, 0)) == .SUCCESS);
}

test "reader never sees a torn frame under concurrent writes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = testing.allocator;

    var w = try StateWriter.create(.{ .cap = 4096 });
    defer w.deinit();
    var r = try StateReader.open(w.id(), .{ .cap = 4096 });
    defer r.deinit();

    var stop: std.atomic.Value(bool) = .init(false);
    const Writer = struct {
        fn run(writer: *StateWriter, stop_flag: *std.atomic.Value(bool)) void {
            var frame: [4096]u8 = undefined;
            var k: u8 = 1;
            while (!stop_flag.load(.monotonic)) {
                @memset(&frame, k);
                writer.write(&frame) catch unreachable;
                k = @max(k +% 1, 1);
            }
        }
    };
    const writer_thread = try std.Thread.spawn(.{}, Writer.run, .{ &w, &stop });

    var seen: u64 = 0;
    var reads: usize = 0;
    var i: usize = 0;
    while (i < 50_000) : (i += 1) {
        if (try r.readLatest(gpa, &seen)) |frame| {
            defer gpa.free(frame);
            try testing.expectEqual(@as(usize, 4096), frame.len);
            const first = frame[0];
            for (frame) |byte| {
                if (byte != first) {
                    stop.store(true, .monotonic);
                    writer_thread.join();
                    return error.TornFrame;
                }
            }
            reads += 1;
        }
    }
    stop.store(true, .monotonic);
    writer_thread.join();
    try testing.expect(reads > 0); // the reader should have observed at least one frame
}
