//! # zicro.gpu_memory — autonomous GPU buffer allocation & export
//!
//! Allocates and manages buffers via memfd (memory file descriptor) so external GPU
//! processes (Vulkan, CUDA, Metal) can import them as external memory (zero-copy).
//! zicro remains format-agnostic; the importer (e.g. a Vulkan extension) decides
//! the GPU API semantics.
//!
//! ## Export protocol
//! Call [`Buffer.exportHandle`] to get an fd suitable for passing to a GPU process:
//! * Vulkan: [`VK_EXT_external_memory_fd`](https://registry.khronos.org/vulkan/specs/1.3-extensions/man/html/VK_EXT_external_memory_fd.html)
//! * CUDA: cuMemImportFromShareableHandle (IPC handle via Unix domain socket)
//! * Metal: MTLTexture from IOSurface (macOS; requires different export mechanism)

const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

/// Autonomous GPU-friendly buffer: CPU-mapped, exportable to Vulkan/CUDA/etc.
pub const Buffer = struct {
    fd: i32,                                        // memfd file descriptor
    ptr: []align(std.heap.page_size_min) u8,       // CPU-accessible mmap
    size: usize,
    name: []const u8,                               // optional debug name

    /// Allocate a GPU-accessible buffer. The buffer is CPU-readable/writable,
    /// and its fd can be exported for GPU import via external memory APIs.
    pub fn allocate(gpa: Allocator, size: usize, name: []const u8) !Buffer {
        if (size == 0) return error.ZeroSize;

        // Create a memfd — an anonymous file descriptor backed by RAM, suitable
        // for sharing across processes and GPU import.
        const fd = try std.posix.memfd_create(name, 0);
        errdefer _ = linux.close(fd);

        // Resize to the requested size via ftruncate syscall. `linux.ftruncate` returns a
        // `usize`-encoded result, so check the errno rather than a (never-negative) sign.
        if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.FtruncateFailed;

        // Map it into CPU address space. The GPU process will map the same fd
        // independently via its external memory importer.
        const ptr = try std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer std.posix.munmap(ptr);

        const name_dupe = try gpa.dupe(u8, name);
        errdefer gpa.free(name_dupe);

        return .{
            .fd = fd,
            .ptr = ptr,
            .size = size,
            .name = name_dupe,
        };
    }

    /// Get the export handle (file descriptor) to pass to a GPU process for import.
    /// The fd remains valid for the lifetime of this buffer; the receiver can dup it.
    pub fn exportHandle(self: *const Buffer) i32 {
        return self.fd;
    }

    /// Write-access the buffer contents (on the CPU side).
    pub fn write(self: *Buffer, offset: usize, data: []const u8) !void {
        if (offset + data.len > self.size) return error.WriteOutOfBounds;
        @memcpy(self.ptr[offset .. offset + data.len], data);
    }

    /// Read-access the buffer contents (on the CPU side).
    pub fn read(self: *const Buffer, offset: usize, out: []u8) !void {
        if (offset + out.len > self.size) return error.ReadOutOfBounds;
        @memcpy(out, self.ptr[offset .. offset + out.len]);
    }

    /// Get a mutable slice of the buffer for direct access.
    pub fn asMut(self: *Buffer) []u8 {
        return self.ptr;
    }

    /// Get an immutable slice of the buffer for direct access.
    pub fn asConst(self: *const Buffer) []const u8 {
        return self.ptr;
    }

    /// Free the buffer. The underlying memfd is closed; any GPU process holding
    /// a reference to the exported fd can still use it until it releases its import.
    pub fn deinit(self: *Buffer, gpa: Allocator) void {
        std.posix.munmap(self.ptr);
        _ = linux.close(self.fd);
        gpa.free(self.name);
    }
};

/// A GPU memory pool: manages multiple buffers with a simple allocation strategy.
pub const Pool = struct {
    gpa: Allocator,
    buffers: std.ArrayListUnmanaged(Buffer) = .empty,

    pub fn init(gpa: Allocator) Pool {
        return .{ .gpa = gpa };
    }

    /// Allocate a new GPU buffer from the pool.
    pub fn allocate(pool: *Pool, size: usize, name: []const u8) !*Buffer {
        const buf = try Buffer.allocate(pool.gpa, size, name);
        try pool.buffers.append(pool.gpa, buf);
        return &pool.buffers.items[pool.buffers.items.len - 1];
    }

    /// Free the pool and all its buffers.
    pub fn deinit(pool: *Pool) void {
        for (pool.buffers.items) |*buf| buf.deinit(pool.gpa);
        pool.buffers.deinit(pool.gpa);
    }
};

// --- tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "gpu_memory.allocate and read/write" {
    var buf = try Buffer.allocate(testing.allocator, 1024, "test_buffer");
    defer buf.deinit(testing.allocator);

    try buf.write(0, "hello");
    var out: [5]u8 = undefined;
    try buf.read(0, &out);
    try testing.expectEqualSlices(u8, "hello", &out);
}

test "gpu_memory.exportHandle returns valid fd" {
    var buf = try Buffer.allocate(testing.allocator, 512, "export_test");
    defer buf.deinit(testing.allocator);

    const fd = buf.exportHandle();
    try testing.expect(fd >= 0);
}

test "gpu_memory.Pool allocates and manages buffers" {
    var pool = Pool.init(testing.allocator);
    defer pool.deinit();

    const buf1 = try pool.allocate(256, "buf1");
    const buf2 = try pool.allocate(512, "buf2");

    try buf1.write(0, "abc");
    try buf2.write(0, "xyz");

    var out1: [3]u8 = undefined;
    var out2: [3]u8 = undefined;
    try buf1.read(0, &out1);
    try buf2.read(0, &out2);

    try testing.expectEqualSlices(u8, "abc", &out1);
    try testing.expectEqualSlices(u8, "xyz", &out2);
}

test "gpu_memory.zero-copy slice access" {
    var buf = try Buffer.allocate(testing.allocator, 100, "slice_test");
    defer buf.deinit(testing.allocator);

    const slice = buf.asMut();
    @memcpy(slice[0..5], "hello");
    try testing.expectEqualSlices(u8, "hello", buf.asConst()[0..5]);
}
