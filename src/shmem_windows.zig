//! # zicro.shmem — Windows backend (`CreateFileMapping`)
//!
//! Named shared regions via a pagefile-backed section object in the `Local\` namespace.
//! Unlike the POSIX backends there is no filesystem object to leak: the section is freed
//! when the last handle closes, so [`sweepOrphans`] is a no-op. The slot name carried in
//! the env var is bare UTF-8 (`ms-<pid>-<seq>`); this backend prepends `Local\` and widens
//! it to UTF-16 for the Win32 calls. Only the platform mapping lives here; the seqlock is
//! in [`shmem`](shmem.zig).

const std = @import("std");
const page = std.heap.page_size_min;

pub const supported = true;

const HANDLE = ?*anyopaque;
const DWORD = u32;
const BOOL = i32;

const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const PAGE_READWRITE: DWORD = 0x04;
const FILE_MAP_READ: DWORD = 0x0004;
const FILE_MAP_WRITE: DWORD = 0x0002;

extern "kernel32" fn CreateFileMappingW(hFile: HANDLE, lpAttributes: ?*anyopaque, flProtect: DWORD, dwMaximumSizeHigh: DWORD, dwMaximumSizeLow: DWORD, lpName: ?[*:0]const u16) callconv(.winapi) HANDLE;
extern "kernel32" fn OpenFileMappingW(dwDesiredAccess: DWORD, bInheritHandle: BOOL, lpName: [*:0]const u16) callconv(.winapi) HANDLE;
extern "kernel32" fn MapViewOfFile(hFileMappingObject: HANDLE, dwDesiredAccess: DWORD, dwFileOffsetHigh: DWORD, dwFileOffsetLow: DWORD, dwNumberOfBytesToMap: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: ?*const anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;

pub const Mapping = struct {
    bytes: []align(page) u8,
    handle: HANDLE,
};

pub const CreateResult = struct {
    mapping: Mapping,
    id_len: usize,
};

var name_seq: std.atomic.Value(u32) = .init(0);

/// Build the UTF-16, `Local\`-namespaced, null-terminated section name from the bare id.
fn wideName(out: *[160:0]u16, id: []const u8) ![:0]const u16 {
    var u8buf: [140]u8 = undefined;
    const s = std.fmt.bufPrint(&u8buf, "Local\\{s}", .{id}) catch return error.InvalidSlotId;
    const n = std.unicode.utf8ToUtf16Le(out[0..160], s) catch return error.InvalidSlotId;
    out[n] = 0;
    return out[0..n :0];
}

fn viewSlice(ptr: *anyopaque, total: usize) []align(page) u8 {
    const base: [*]align(page) u8 = @ptrCast(@alignCast(ptr));
    return base[0..total];
}

pub fn createSlot(id_buf: *[64]u8, total: usize) !CreateResult {
    const seq = name_seq.fetchAdd(1, .monotonic);
    const written = std.fmt.bufPrint(id_buf, "ms-{d}-{d}", .{ GetCurrentProcessId(), seq }) catch unreachable;

    var wbuf: [160:0]u16 = undefined;
    const name = try wideName(&wbuf, written);
    const hi: DWORD = @truncate(total >> 32);
    const lo: DWORD = @truncate(total);
    const handle = CreateFileMappingW(INVALID_HANDLE_VALUE, null, PAGE_READWRITE, hi, lo, name) orelse return error.ShmOpenFailed;
    errdefer _ = CloseHandle(handle);

    const view = MapViewOfFile(handle, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, total) orelse return error.ShmResizeFailed;
    return .{ .mapping = .{ .bytes = viewSlice(view, total), .handle = handle }, .id_len = written.len };
}

pub fn openSlot(id: []const u8, total: usize) !Mapping {
    var wbuf: [160:0]u16 = undefined;
    const name = try wideName(&wbuf, id);
    const handle = OpenFileMappingW(FILE_MAP_READ, 0, name) orelse return error.ShmOpenFailed;
    errdefer _ = CloseHandle(handle);
    const view = MapViewOfFile(handle, FILE_MAP_READ, 0, 0, total) orelse return error.ShmOpenFailed;
    return .{ .bytes = viewSlice(view, total), .handle = handle };
}

pub fn closeWriter(m: Mapping, id: []const u8) void {
    _ = id; // the section object is reclaimed when its last handle closes — nothing to unlink.
    _ = UnmapViewOfFile(m.bytes.ptr);
    _ = CloseHandle(m.handle);
}

pub fn closeReader(m: Mapping) void {
    _ = UnmapViewOfFile(m.bytes.ptr);
    _ = CloseHandle(m.handle);
}

/// No filesystem object to leak on Windows — the section dies with its last handle.
pub fn sweepOrphans() error{Unsupported}!usize {
    return 0;
}
