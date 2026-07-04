//! # zicro.shmem — Linux backend (POSIX shared memory via `/dev/shm`)
//!
//! Named shared regions as files under `/dev/shm` — byte- and name-compatible with what
//! glibc's `shm_open` produces, so a zicro slot and a Rust Micro peer can share one object.
//! Raw syscalls throughout, so the backend needs no `Io`. This file owns *only* the
//! platform mapping; the seqlock and slot layout live in [`shmem`](shmem.zig).

const std = @import("std");
const linux = std.os.linux;
const page = std.heap.page_size_min;

pub const supported = true;

/// One mapped named region: the bytes plus the fd that backs them.
pub const Mapping = struct {
    bytes: []align(page) u8,
    fd: std.posix.fd_t,
};

pub const CreateResult = struct {
    mapping: Mapping,
    id_len: usize,
};

fn shmPath(buf: *[96:0]u8, id: []const u8) ![:0]const u8 {
    // A POSIX shm name "/foo" lives at /dev/shm/foo on Linux — same layout glibc uses,
    // which is what keeps a zicro slot openable by a Rust `shm_open` peer.
    if (id.len == 0 or id[0] != '/') return error.InvalidSlotId;
    return std.fmt.bufPrintZ(buf, "/dev/shm{s}", .{id});
}

/// Create a fresh, uniquely-named region of `total` bytes and map it read-write. The slot
/// name (pid + monotonic nanos, like the Rust original) is written into `id_buf`.
pub fn createSlot(id_buf: *[64]u8, total: usize) !CreateResult {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    const nanos: u64 = @intCast(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec);
    const written = std.fmt.bufPrint(id_buf, "/micro-state-{d}-{d}", .{ linux.getpid(), nanos }) catch unreachable;

    var path_buf: [96:0]u8 = undefined;
    const path = try shmPath(&path_buf, written);
    // O_EXCL turns any residual name collision into a hard error instead of silent sharing.
    const open_rc = linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, 0o600);
    if (linux.errno(open_rc) != .SUCCESS) return error.ShmOpenFailed;
    const fd: std.posix.fd_t = @intCast(open_rc);
    errdefer _ = linux.close(fd);
    // We just created (O_CREAT|O_EXCL) this object; unlink it on any failure below, or the
    // live creating process orphans it (sweepOrphans only reaps names whose creator exited).
    errdefer _ = linux.unlink(path);

    if (linux.errno(linux.ftruncate(fd, @intCast(total))) != .SUCCESS) return error.ShmResizeFailed;
    const map = try std.posix.mmap(null, total, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    return .{ .mapping = .{ .bytes = map, .fd = fd }, .id_len = written.len };
}

/// Open an existing slot by name, mapping `total` bytes read-only.
pub fn openSlot(id: []const u8, total: usize) !Mapping {
    var path_buf: [96:0]u8 = undefined;
    const path = try shmPath(&path_buf, id);
    const open_rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(open_rc) != .SUCCESS) return error.ShmOpenFailed;
    const fd: std.posix.fd_t = @intCast(open_rc);
    errdefer _ = linux.close(fd);
    const map = try std.posix.mmap(null, total, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
    return .{ .bytes = map, .fd = fd };
}

pub fn closeWriter(m: Mapping, id: []const u8) void {
    std.posix.munmap(m.bytes);
    _ = linux.close(m.fd);
    var path_buf: [96:0]u8 = undefined;
    if (shmPath(&path_buf, id)) |path| {
        _ = linux.unlink(path);
    } else |_| {}
}

pub fn closeReader(m: Mapping) void {
    std.posix.munmap(m.bytes);
    _ = linux.close(m.fd);
}

// --- orphan sweeping -------------------------------------------------------------
//
// A slot is unlinked by the writer's teardown — which never runs if the writer process is
// SIGKILLed, panics (Zig panics abort), or exits without teardown. The backing object then
// outlives the process. `sweepOrphans` is the garbage collector for that case: it scans for
// slots whose creator pid (baked into the name) is no longer alive and unlinks them.

/// Whether `pid` names a live process, via `/proc/<pid>`.
fn pidAlive(pid: i32) bool {
    var buf: [32:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "/proc/{d}", .{pid}) catch return true;
    return linux.errno(linux.access(path, 0)) == .SUCCESS;
}

/// Unlink every `micro-state-<pid>-*` slot whose creator process is dead, returning how many
/// were removed. Never touches a slot whose pid is still alive, so a concurrent writer is
/// safe. Sweeps the slots of Rust Micro peers too — same name scheme, same backing store.
pub fn sweepOrphans() error{Unsupported}!usize {
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
            if (linux.errno(linux.unlinkat(dir_fd, name_ptr, 0)) == .SUCCESS) removed += 1;
        }
    }
    return removed;
}

// --- tests (Linux-specific: /dev/shm names and pid liveness) -----------------------------

const testing = std.testing;

test "sweepOrphans removes dead-pid slots and keeps live ones" {
    // A pid that is certainly dead right now: scan downward from past pid_max.
    var dead_pid: i32 = 4_194_304;
    while (pidAlive(dead_pid)) dead_pid -= 1;

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
    try testing.expect(linux.errno(linux.access(dead_path, 0)) != .SUCCESS);
    try testing.expect(linux.errno(linux.access(live_path, 0)) == .SUCCESS);
}
