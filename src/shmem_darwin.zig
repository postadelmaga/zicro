//! # zicro.shmem — macOS backend (POSIX `shm_open`)
//!
//! Named shared regions via `shm_open`/`shm_unlink` (in libc on Darwin). Unlike Linux,
//! Darwin's shm objects live in an opaque kernel namespace — they cannot be enumerated
//! (so [`sweepOrphans`] is a no-op) and names are capped at 31 chars (`PSHMNAMLEN`), so the
//! slot uses a short `/ms-<pid>-<seq>` scheme instead of the Linux/Rust `micro-state` name.
//! This file owns *only* the platform mapping; the seqlock lives in [`shmem`](shmem.zig).

const std = @import("std");
const page = std.heap.page_size_min;

pub const supported = true;

pub const Mapping = struct {
    bytes: []align(page) u8,
    fd: std.posix.fd_t,
};

pub const CreateResult = struct {
    mapping: Mapping,
    id_len: usize,
};

// Darwin <sys/fcntl.h> flags (hardcoded: this backend only ever compiles for macOS).
const O_RDONLY: c_int = 0x0000;
const O_RDWR: c_int = 0x0002;
const O_CREAT: c_int = 0x0200;
const O_EXCL: c_int = 0x0800;

extern "c" fn shm_open(name: [*:0]const u8, oflag: c_int, mode: c_uint) c_int;
extern "c" fn shm_unlink(name: [*:0]const u8) c_int;
extern "c" fn ftruncate(fd: c_int, length: i64) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn getpid() c_int;

// A process-local counter keeps successive slot names unique without a clock dependency;
// the pid disambiguates across processes.
var name_seq: std.atomic.Value(u32) = .init(0);

pub fn createSlot(id_buf: *[64]u8, total: usize) !CreateResult {
    const seq = name_seq.fetchAdd(1, .monotonic);
    const written = std.fmt.bufPrint(id_buf, "/ms-{d}-{d}", .{ getpid(), seq }) catch unreachable;

    var name_buf: [64:0]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buf, "{s}", .{written}) catch unreachable;
    const fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0o600);
    if (fd < 0) return error.ShmOpenFailed;
    errdefer _ = close(fd);
    errdefer _ = shm_unlink(name);

    if (ftruncate(fd, @intCast(total)) < 0) return error.ShmResizeFailed;
    const map = try std.posix.mmap(null, total, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    return .{ .mapping = .{ .bytes = map, .fd = fd }, .id_len = written.len };
}

pub fn openSlot(id: []const u8, total: usize) !Mapping {
    var name_buf: [64:0]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buf, "{s}", .{id}) catch return error.InvalidSlotId;
    const fd = shm_open(name, O_RDONLY, 0);
    if (fd < 0) return error.ShmOpenFailed;
    errdefer _ = close(fd);
    const map = try std.posix.mmap(null, total, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
    return .{ .bytes = map, .fd = fd };
}

pub fn closeWriter(m: Mapping, id: []const u8) void {
    std.posix.munmap(m.bytes);
    _ = close(m.fd);
    var name_buf: [64:0]u8 = undefined;
    if (std.fmt.bufPrintZ(&name_buf, "{s}", .{id})) |name| {
        _ = shm_unlink(name);
    } else |_| {}
}

pub fn closeReader(m: Mapping) void {
    std.posix.munmap(m.bytes);
    _ = close(m.fd);
}

/// Darwin shm objects can't be enumerated, so there is no portable orphan sweep — a
/// leaked slot is reclaimed by the OS on reboot. No-op.
pub fn sweepOrphans() error{Unsupported}!usize {
    return 0;
}
