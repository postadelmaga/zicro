//! # zicro.gpu_wgpu_native — wgpu-native integration with Vulkan buffers
//!
//! Uses wgpu-native (official C bindings for wgpu) to enable:
//! * Unified GPU API across Vulkan/Metal/DX12 via wgpu backends
//! * Zero-copy buffer sharing with Vulkan via memfd (on Vulkan backend)
//! * Pure Zig (no Rust FFI complexity)
//!
//! Architecture: zicro allocates buffer (memfd), wgpu-native imports it via
//! the underlying backend (Vulkan on Linux, Metal on macOS, DX12 on Windows).

const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu_mem = @import("gpu_memory.zig");
const gpu_vk = @import("gpu_vulkan.zig");

// --- Minimal wgpu-native C bindings ---

pub const WgpuInstance = ?*opaque {};
pub const WgpuAdapter = ?*opaque {};
pub const WgpuDevice = ?*opaque {};
pub const WgpuQueue = ?*opaque {};
pub const WgpuBuffer = ?*opaque {};
pub const WgpuSurface = ?*opaque {};

pub const WgpuRequestAdapterOptions = extern struct {
    nextInChain: ?*const anyopaque,
    compatibleSurface: WgpuSurface,
    powerPreference: c_uint,
    forceFallbackAdapter: bool,
};

pub const WgpuDeviceDescriptor = extern struct {
    nextInChain: ?*const anyopaque,
    label: ?[*:0]const u8,
    requiredFeaturesCount: usize,
    requiredFeatures: ?[*]const c_uint,
    requiredLimits: ?*const anyopaque,
    defaultQueue: anyopaque, // WgpuQueueDescriptor
};

pub const WgpuBufferBindingType = enum(c_uint) {
    Undefined = 0,
    Uniform = 1,
    Storage = 2,
    ReadOnlyStorage = 3,
};

pub const WgpuBufferUsage = struct {
    const COPY_SRC: u32 = 0x0001;
    const COPY_DST: u32 = 0x0002;
    const MAP_READ: u32 = 0x0004;
    const MAP_WRITE: u32 = 0x0008;
    const UNIFORM: u32 = 0x0010;
    const STORAGE: u32 = 0x0020;
    const INDIRECT: u32 = 0x0100;
    const QUERY_RESOLVE: u32 = 0x0200;
};

pub const WgpuBufferDescriptor = extern struct {
    nextInChain: ?*const anyopaque,
    label: ?[*:0]const u8,
    usage: u32,
    size: u64,
    mappedAtCreation: bool,
};

// --- wgpu-native C functions (link against libwgpu) ---

extern "wgpu" fn wgpu_create_instance(descriptor: ?*const anyopaque) WgpuInstance;

extern "wgpu" fn wgpu_instance_request_adapter(
    instance: WgpuInstance,
    options: ?*const WgpuRequestAdapterOptions,
    callback: ?*const anyopaque,
    userdata: ?*const anyopaque,
) void;

extern "wgpu" fn wgpu_adapter_request_device(
    adapter: WgpuAdapter,
    descriptor: ?*const WgpuDeviceDescriptor,
    callback: ?*const anyopaque,
    userdata: ?*const anyopaque,
) void;

extern "wgpu" fn wgpu_device_create_buffer(
    device: WgpuDevice,
    descriptor: *const WgpuBufferDescriptor,
) WgpuBuffer;

extern "wgpu" fn wgpu_device_get_queue(device: WgpuDevice) WgpuQueue;

extern "wgpu" fn wgpu_buffer_destroy(buffer: WgpuBuffer) void;

// --- High-level wrapper: zero-copy Vulkan↔wgpu integration ---

/// A wgpu-native buffer that can share memory with Vulkan via memfd (on Vulkan backend).
pub const WgpuNativeBuffer = struct {
    buffer: gpu_mem.Buffer,
    wgpu_device: ?WgpuDevice = null,
    wgpu_buffer: ?WgpuBuffer = null,

    /// Create a wgpu-native buffer from an autonomous gpu_memory.Buffer.
    pub fn create(buf: gpu_mem.Buffer) WgpuNativeBuffer {
        return .{ .buffer = buf };
    }

    /// Export the underlying memory fd for wgpu to import.
    /// On Vulkan backend: imported as VkDeviceMemory via external memory
    /// On Metal backend: imported as shared Metal texture
    /// On DX12 backend: imported as D3D12 shared resource
    pub fn exportMemoryFd(self: *const WgpuNativeBuffer) i32 {
        return self.buffer.exportHandle();
    }

    /// Create a wgpu buffer descriptor suitable for this memory.
    /// Caller passes to wgpu_device_create_buffer_from_fd (backend-specific).
    pub fn descriptor(
        self: *const WgpuNativeBuffer,
        label: [*:0]const u8,
        usage: u32,
    ) WgpuBufferDescriptor {
        return .{
            .nextInChain = null,
            .label = label,
            .usage = usage,
            .size = self.buffer.size,
            .mappedAtCreation = false,
        };
    }

    /// Get buffer metadata for logging.
    pub fn info(self: *const WgpuNativeBuffer) struct { size: usize, name: []const u8 } {
        return .{ .size = self.buffer.size, .name = self.buffer.name };
    }

    /// Free the buffer (CPU side); wgpu must release independently.
    pub fn deinit(self: *WgpuNativeBuffer, gpa: Allocator) void {
        self.buffer.deinit(gpa);
    }
};

/// A Vulkan-aware wgpu device that can zero-copy share buffers with Vulkan.
/// On Linux: wgpu backend is Vulkan, uses same VkDevice
/// On macOS: wgpu backend is Metal, requires additional Metal binding
/// On Windows: wgpu backend is DX12, requires additional D3D12 binding
pub const WgpuVulkanDevice = struct {
    wgpu_device: ?WgpuDevice = null,
    vk_device: ?gpu_vk.VkDevice = null,
    is_vulkan_backend: bool = false,

    /// Create a wgpu device that is aware of an optional Vulkan device.
    /// If vk_device is provided and wgpu uses Vulkan backend, they share memory.
    pub fn create(wgpu_dev: WgpuDevice, vk_dev: ?gpu_vk.VkDevice) WgpuVulkanDevice {
        return .{
            .wgpu_device = wgpu_dev,
            .vk_device = vk_dev,
            .is_vulkan_backend = vk_dev != null, // assumption: Linux w/ Vulkan
        };
    }

    /// Create a buffer that can be shared between wgpu and Vulkan (zero-copy).
    /// Returns a wgpu buffer and a Vulkan buffer referencing the same fd.
    pub fn createSharedBuffer(
        self: *WgpuVulkanDevice,
        gpa: Allocator,
        size: usize,
        name: []const u8,
        wgpu_usage: u32,
        vk_usage: u32,
    ) !struct { wgpu_buf: WgpuNativeBuffer, vk_buf: gpu_vk.VulkanBuffer } {
        _ = self;
        // Allocate autonomous GPU buffer (memfd-backed)
        const buf = try gpu_mem.Buffer.allocate(gpa, size, name);

        // Wrap for wgpu
        const wgpu_buf = WgpuNativeBuffer.create(buf);

        // Wrap for Vulkan (same fd, shared)
        const vk_buf = gpu_vk.VulkanBuffer.create(buf);
        _ = wgpu_usage; // wgpu will handle in wgpu_device_create_buffer_from_fd
        _ = vk_usage;   // Vulkan will handle in vkAllocateMemory + VkImportMemoryFdInfoKHR

        return .{ .wgpu_buf = wgpu_buf, .vk_buf = vk_buf };
    }

    /// Check if this device can share buffers with Vulkan (Linux w/ Vulkan backend).
    pub fn canShareVulkan(self: *const WgpuVulkanDevice) bool {
        return self.is_vulkan_backend and self.vk_device != null;
    }
};

// --- Tests ---

const testing = std.testing;

test "gpu_wgpu_native.WgpuNativeBuffer wraps gpu_memory.Buffer" {
    const buf = try gpu_mem.Buffer.allocate(testing.allocator, 1024, "wgpu_native_test");
    var wgpu_buf = WgpuNativeBuffer.create(buf);

    const fd = wgpu_buf.exportMemoryFd();
    try testing.expect(fd >= 0);

    const info = wgpu_buf.info();
    try testing.expectEqual(@as(usize, 1024), info.size);
    try testing.expectEqualSlices(u8, "wgpu_native_test", info.name);

    wgpu_buf.deinit(testing.allocator);
}

test "gpu_wgpu_native.WgpuNativeBuffer descriptor generation" {
    var buf = try gpu_mem.Buffer.allocate(testing.allocator, 512, "descriptor_test");
    const wgpu_buf = WgpuNativeBuffer.create(buf);

    const desc = wgpu_buf.descriptor(
        "my_buffer",
        WgpuBufferUsage.STORAGE | WgpuBufferUsage.COPY_DST,
    );
    try testing.expectEqual(@as(u64, 512), desc.size);
    try testing.expect((desc.usage & WgpuBufferUsage.STORAGE) != 0);

    buf.deinit(testing.allocator);
}

test "gpu_wgpu_native.WgpuVulkanDevice detects Vulkan backend capability" {
    const vk_dev: gpu_vk.VkDevice = null; // mock
    const wgpu_dev: WgpuDevice = null;

    var dev = WgpuVulkanDevice.create(wgpu_dev, vk_dev);
    try testing.expect(!dev.canShareVulkan()); // no actual Vulkan device

    dev.is_vulkan_backend = true;
    try testing.expect(!dev.canShareVulkan()); // vk_device still null
}
