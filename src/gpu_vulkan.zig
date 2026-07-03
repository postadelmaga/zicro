//! # zicro.gpu_vulkan — Vulkan GPU memory integration
//!
//! Minimal Vulkan bindings for importing/exporting GPU buffers via external memory (memfd).
//! Enables zero-copy sharing of `gpu_memory.Buffer` with Vulkan processes via
//! `VK_EXT_external_memory_fd` on Linux.
//!
//! This is a lean foundation; CUDA, Metal, wgpu follow the same export/import pattern
//! in separate modules (gpu_cuda.zig, gpu_metal.zig, gpu_wgpu.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const gpu_mem = @import("gpu_memory.zig");

// --- Minimal Vulkan C bindings (sufficient for external memory import/export) ---

pub const VkResult = c_uint;
pub const VK_SUCCESS: VkResult = 0;

pub const VkInstance = ?*opaque {};
pub const VkPhysicalDevice = ?*opaque {};
pub const VkDevice = ?*opaque {};
pub const VkQueue = ?*opaque {};
pub const VkBuffer = ?*opaque {};
pub const VkDeviceMemory = ?*opaque {};

pub const VkApplicationInfo = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    pApplicationName: ?[*:0]const u8,
    applicationVersion: c_uint,
    pEngineName: ?[*:0]const u8,
    engineVersion: c_uint,
    apiVersion: c_uint,
};

pub const VkInstanceCreateInfo = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    flags: c_uint,
    pApplicationInfo: ?*const VkApplicationInfo,
    enabledLayerCount: c_uint,
    ppEnabledLayerNames: ?[*][*:0]const u8,
    enabledExtensionCount: c_uint,
    ppEnabledExtensionNames: ?[*][*:0]const u8,
};

pub const VkDeviceQueueCreateInfo = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    flags: c_uint,
    queueFamilyIndex: c_uint,
    queueCount: c_uint,
    pQueuePriorities: [*]const f32,
};

pub const VkDeviceCreateInfo = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    flags: c_uint,
    queueCreateInfoCount: c_uint,
    pQueueCreateInfos: [*]const VkDeviceQueueCreateInfo,
    enabledLayerCount: c_uint,
    ppEnabledLayerNames: ?[*][*:0]const u8,
    enabledExtensionCount: c_uint,
    ppEnabledExtensionNames: ?[*][*:0]const u8,
    pEnabledFeatures: ?*const anyopaque,
};

pub const VkPhysicalDeviceProperties = extern struct {
    apiVersion: c_uint,
    driverVersion: c_uint,
    vendorID: c_uint,
    deviceID: c_uint,
    deviceType: c_uint,
    deviceName: [256]u8,
    pipelineCacheUUID: [16]u8,
    limits: [512]u8, // Opaque limits struct
    sparseProperties: [32]u8,
};

pub const VkBufferCreateInfo = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    flags: c_uint,
    size: u64,
    usage: c_uint,
    sharingMode: c_uint,
    queueFamilyIndexCount: c_uint,
    pQueueFamilyIndices: ?[*]const c_uint,
};

pub const VkMemoryAllocateInfo = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    allocationSize: u64,
    memoryTypeIndex: c_uint,
};

pub const VkImportMemoryFdInfoKHR = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    handleType: c_uint,
    fd: i32,
};

pub const VkExportMemoryAllocateInfo = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    handleTypes: c_uint,
};

// --- Vulkan API constants ---
pub const VK_STRUCTURE_TYPE_APPLICATION_INFO: c_uint = 0;
pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: c_uint = 1;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO: c_uint = 2;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO: c_uint = 3;
pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: c_uint = 5;
pub const VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR: c_uint = 1000074000;
pub const VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO: c_uint = 1000011001;

pub const VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT: c_uint = 0x00000001;
pub const VK_BUFFER_USAGE_TRANSFER_DST_BIT: c_uint = 0x00000001;
pub const VK_BUFFER_USAGE_TRANSFER_SRC_BIT: c_uint = 0x00000002;
pub const VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT: c_uint = 0x00000008;
pub const VK_BUFFER_USAGE_STORAGE_BUFFER_BIT: c_uint = 0x00000010;
pub const VK_SHARING_MODE_EXCLUSIVE: c_uint = 0;

pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT: c_uint = 0x00000001;
pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT: c_uint = 0x00000002;

// --- Vulkan function pointers (linked at runtime via dlopen/dlsym or statically) ---
extern "vulkan" fn vkCreateInstance(
    pCreateInfo: *const VkInstanceCreateInfo,
    pAllocator: ?*const anyopaque,
    pInstance: *VkInstance,
) VkResult;

extern "vulkan" fn vkEnumeratePhysicalDevices(
    instance: VkInstance,
    pPhysicalDeviceCount: *c_uint,
    pPhysicalDevices: ?[*]VkPhysicalDevice,
) VkResult;

extern "vulkan" fn vkGetPhysicalDeviceProperties(
    physicalDevice: VkPhysicalDevice,
    pProperties: *VkPhysicalDeviceProperties,
) void;

extern "vulkan" fn vkGetPhysicalDeviceMemoryProperties(
    physicalDevice: VkPhysicalDevice,
    pMemoryProperties: *anyopaque,
) void;

extern "vulkan" fn vkCreateDevice(
    physicalDevice: VkPhysicalDevice,
    pCreateInfo: *const VkDeviceCreateInfo,
    pAllocator: ?*const anyopaque,
    pDevice: *VkDevice,
) VkResult;

extern "vulkan" fn vkCreateBuffer(
    device: VkDevice,
    pCreateInfo: *const VkBufferCreateInfo,
    pAllocator: ?*const anyopaque,
    pBuffer: *VkBuffer,
) VkResult;

extern "vulkan" fn vkAllocateMemory(
    device: VkDevice,
    pAllocateInfo: *const VkMemoryAllocateInfo,
    pAllocator: ?*const anyopaque,
    pMemory: *VkDeviceMemory,
) VkResult;

extern "vulkan" fn vkGetMemoryFdKHR(
    device: VkDevice,
    pGetFdInfo: *const anyopaque,
    pFd: *i32,
) VkResult;

// --- High-level wrapper: zero-copy integration between gpu_memory and Vulkan ---

/// A Vulkan-aware GPU buffer: wraps a gpu_memory.Buffer and provides
/// Vulkan import/export operations.
pub const VulkanBuffer = struct {
    buffer: gpu_mem.Buffer,
    vk_device: ?VkDevice = null,
    vk_buffer: ?VkBuffer = null,
    vk_memory: ?VkDeviceMemory = null,

    /// Create a Vulkan-aware buffer from an autonomous gpu_memory.Buffer.
    /// The buffer remains independent; Vulkan integration is optional.
    pub fn create(buf: gpu_mem.Buffer) VulkanBuffer {
        return .{ .buffer = buf };
    }

    /// Export the underlying memory fd for a Vulkan process to import.
    /// The sidecar imports this as VK_EXT_external_memory_fd.
    pub fn exportMemoryFd(self: *const VulkanBuffer) i32 {
        return self.buffer.exportHandle();
    }

    /// Query buffer size and name for logging/debugging.
    pub fn info(self: *const VulkanBuffer) struct { size: usize, name: []const u8 } {
        return .{ .size = self.buffer.size, .name = self.buffer.name };
    }

    /// Free the buffer (CPU side); GPU side must release independently.
    pub fn deinit(self: *VulkanBuffer, gpa: Allocator) void {
        self.buffer.deinit(gpa);
    }
};

// --- Tests ---

const testing = std.testing;

test "gpu_vulkan.VulkanBuffer wraps gpu_memory.Buffer" {
    const buf = try gpu_mem.Buffer.allocate(testing.allocator, 512, "vk_test");
    var vk_buf = VulkanBuffer.create(buf);

    const fd = vk_buf.exportMemoryFd();
    try testing.expect(fd >= 0);

    const info = vk_buf.info();
    try testing.expectEqual(@as(usize, 512), info.size);
    try testing.expectEqualSlices(u8, "vk_test", info.name);

    vk_buf.deinit(testing.allocator);
}

test "gpu_vulkan.VkImportMemoryFdInfoKHR has correct layout" {
    const info = VkImportMemoryFdInfoKHR{
        .sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
        .pNext = null,
        .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT,
        .fd = 3,
    };
    try testing.expectEqual(VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR, info.sType);
    try testing.expectEqual(@as(i32, 3), info.fd);
}
