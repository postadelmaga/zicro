//! # zicro.gpu_wgpu — WebGPU GPU memory integration
//!
//! Integration with WebGPU (via wgpu-core) for GPU buffer import/export.
//! Enables zero-copy sharing of `gpu_memory.Buffer` with WebGPU processes via
//! raw device memory handles.
//!
//! WebGPU is a modern, cross-platform GPU API (Vulkan, Metal, DX12 backend).
//! Export pattern: zicro allocates buffer fd, sidecar (or same process in headless)
//! imports via wgpu's external memory mechanisms.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu_mem = @import("gpu_memory.zig");

// --- WebGPU minimal type definitions (language-neutral, matches wgpu C API) ---

pub const WgpuInstance = ?*opaque {};
pub const WgpuAdapter = ?*opaque {};
pub const WgpuDevice = ?*opaque {};
pub const WgpuQueue = ?*opaque {};
pub const WgpuBuffer = ?*opaque {};

pub const WgpuBufferUsage = struct {
    const COPY_SRC: u32 = 0x0001;
    const COPY_DST: u32 = 0x0002;
    const MAP_READ: u32 = 0x0004;
    const MAP_WRITE: u32 = 0x0008;
    const UNIFORM: u32 = 0x0010;
    const STORAGE: u32 = 0x0020;
};

pub const WgpuMemoryPropertyFlags = struct {
    const DEVICE_LOCAL: u32 = 0x0001;
    const HOST_VISIBLE: u32 = 0x0002;
};

pub const WgpuBufferDescriptor = extern struct {
    label: ?[*:0]const u8,
    size: u64,
    usage: u32,
    mapped_at_creation: bool,
};

pub const WgpuBufferImportMemFdDescriptor = extern struct {
    label: ?[*:0]const u8,
    size: u64,
    usage: u32,
    fd: i32,
    stride: u64,
};

// --- WebGPU C-ABI function stubs (linked at runtime) ---
// In production, these would be dlopen'd against wgpu_core or wgpu-native
extern "wgpu" fn wgpu_instance_create() WgpuInstance;

extern "wgpu" fn wgpu_instance_request_adapter(
    instance: WgpuInstance,
    force_fallback: bool,
) WgpuAdapter;

extern "wgpu" fn wgpu_adapter_request_device(
    adapter: WgpuAdapter,
) WgpuDevice;

extern "wgpu" fn wgpu_device_create_buffer(
    device: WgpuDevice,
    descriptor: *const WgpuBufferDescriptor,
) WgpuBuffer;

extern "wgpu" fn wgpu_device_create_buffer_from_mem_fd(
    device: WgpuDevice,
    descriptor: *const WgpuBufferImportMemFdDescriptor,
) WgpuBuffer;

// --- High-level wrapper: zero-copy WebGPU integration ---

/// A WebGPU-aware GPU buffer: wraps a gpu_memory.Buffer and provides
/// WebGPU import/export operations.
pub const WebGpuBuffer = struct {
    buffer: gpu_mem.Buffer,
    wgpu_device: ?WgpuDevice = null,
    wgpu_buffer: ?WgpuBuffer = null,

    /// Create a WebGPU-aware buffer from an autonomous gpu_memory.Buffer.
    pub fn create(buf: gpu_mem.Buffer) WebGpuBuffer {
        return .{ .buffer = buf };
    }

    /// Export the underlying memory fd for a WebGPU process to import.
    /// The process imports via wgpu's `create_buffer_from_mem_fd` or
    /// equivalent mechanism (varies by backend: Vulkan external memory, etc.).
    pub fn exportMemoryFd(self: *const WebGpuBuffer) i32 {
        return self.buffer.exportHandle();
    }

    /// Get buffer metadata for logging/debugging.
    pub fn info(self: *const WebGpuBuffer) struct { size: usize, name: []const u8 } {
        return .{ .size = self.buffer.size, .name = self.buffer.name };
    }

    /// Create a WebGPU buffer descriptor suitable for import.
    /// Caller uses this to initialize a WebGPU buffer from the exported fd.
    pub fn descriptor(
        self: *const WebGpuBuffer,
        label: [*:0]const u8,
        usage: u32,
    ) WgpuBufferImportMemFdDescriptor {
        return .{
            .label = label,
            .size = self.buffer.size,
            .usage = usage,
            .fd = self.buffer.exportHandle(),
            .stride = 1, // contiguous
        };
    }

    /// Free the buffer (CPU side); GPU side must release independently.
    pub fn deinit(self: *WebGpuBuffer, gpa: Allocator) void {
        self.buffer.deinit(gpa);
    }
};

// --- Tests ---

const testing = std.testing;

test "gpu_wgpu.WebGpuBuffer wraps gpu_memory.Buffer" {
    const buf = try gpu_mem.Buffer.allocate(testing.allocator, 1024, "wgpu_test");
    var wgpu_buf = WebGpuBuffer.create(buf);

    const fd = wgpu_buf.exportMemoryFd();
    try testing.expect(fd >= 0);

    const info = wgpu_buf.info();
    try testing.expectEqual(@as(usize, 1024), info.size);
    try testing.expectEqualSlices(u8, "wgpu_test", info.name);

    wgpu_buf.deinit(testing.allocator);
}

test "gpu_wgpu.WebGpuBuffer descriptor generation" {
    const buf = try gpu_mem.Buffer.allocate(testing.allocator, 512, "descriptor_test");
    var wgpu_buf = WebGpuBuffer.create(buf);

    const desc = wgpu_buf.descriptor(
        "my_buffer",
        WgpuBufferUsage.STORAGE | WgpuBufferUsage.COPY_DST,
    );
    try testing.expectEqual(@as(u64, 512), desc.size);
    try testing.expect(desc.fd >= 0);
    try testing.expect((desc.usage & WgpuBufferUsage.STORAGE) != 0);

    wgpu_buf.deinit(testing.allocator);
}
