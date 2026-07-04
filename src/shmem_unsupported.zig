//! # zicro.shmem — fallback backend for platforms without a shared-memory mapping
//!
//! Selected for any OS that has no [`shmem`](shmem.zig) backend. Every operation reports
//! `error.Unsupported`; `supported = false` lets the core reject `create`/`open` up front,
//! so a caller falls back to its byte-stream transport (bridge/ipc) cleanly.

const std = @import("std");
const page = std.heap.page_size_min;

pub const supported = false;

pub const Mapping = struct {
    bytes: []align(page) u8,
};

pub const CreateResult = struct {
    mapping: Mapping,
    id_len: usize,
};

pub fn createSlot(id_buf: *[64]u8, total: usize) !CreateResult {
    _ = id_buf;
    _ = total;
    return error.Unsupported;
}

pub fn openSlot(id: []const u8, total: usize) !Mapping {
    _ = id;
    _ = total;
    return error.Unsupported;
}

pub fn closeWriter(m: Mapping, id: []const u8) void {
    _ = m;
    _ = id;
}

pub fn closeReader(m: Mapping) void {
    _ = m;
}

pub fn sweepOrphans() error{Unsupported}!usize {
    return error.Unsupported;
}
