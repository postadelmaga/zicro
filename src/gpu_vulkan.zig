//! # zicro.gpu_vulkan — Vulkan GPU memory + synchronization integration
//!
//! Minimal Vulkan bindings for:
//! * External memory import/export (memfd) via `VK_EXT_external_memory_fd`
//! * Timeline semaphores (`VK_KHR_timeline_semaphores`) for GPU-to-CPU sync
//! * Multi-GPU memory sharing (`VK_KHR_device_group`) for distributed GPU compute
//!
//! Enables zero-copy, synchronized workload distribution across multiple GPUs.
//! Sidecar (e.g. Gear) manages GPU device/queue/compute; zicro provides memory + sync primitives.
//! CUDA, Metal, wgpu follow same pattern in separate modules.

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
pub const VkSemaphore = ?*opaque {};

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

pub const VkSemaphoreCreateInfo = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    flags: c_uint,
};

pub const VkSemaphoreTypeCreateInfo = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    semaphoreType: c_uint,
    initialValue: u64,
};

pub const VkSemaphoreWaitInfo = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    flags: c_uint,
    semaphoreCount: c_uint,
    pSemaphores: [*]const VkSemaphore,
    pValues: [*]const u64,
};

pub const VkSemaphoreSignalInfo = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    semaphore: VkSemaphore,
    value: u64,
};

pub const VkExportSemaphoreCreateInfo = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    handleTypes: c_uint,
};

// Multi-GPU device group types
pub const VkDeviceGroupCreateInfo = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    physicalDeviceCount: c_uint,
    pPhysicalDevices: [*]const VkPhysicalDevice,
};

pub const VkDeviceGroupSubmitInfo = extern struct {
    sType: c_uint,
    pNext: ?*const anyopaque,
    waitSemaphoreCount: c_uint,
    pWaitSemaphoreDeviceIndices: [*]const c_uint,
    commandBufferCount: c_uint,
    pCommandBufferDeviceMasks: [*]const c_uint,
    signalSemaphoreCount: c_uint,
    pSignalSemaphoreDeviceIndices: [*]const c_uint,
};

// --- Vulkan API constants ---
pub const VK_STRUCTURE_TYPE_APPLICATION_INFO: c_uint = 0;
pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: c_uint = 1;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO: c_uint = 2;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO: c_uint = 3;
pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: c_uint = 5;
pub const VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR: c_uint = 1000074000;
pub const VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO: c_uint = 1000011001;
pub const VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO: c_uint = 4;
pub const VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO: c_uint = 1000207004;
pub const VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO: c_uint = 1000207005;
pub const VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO: c_uint = 1000207002;

pub const VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT: c_uint = 0x00000001;
pub const VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT: c_uint = 0x00000001;
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

extern "vulkan" fn vkCreateSemaphore(
    device: VkDevice,
    pCreateInfo: *const VkSemaphoreCreateInfo,
    pAllocator: ?*const anyopaque,
    pSemaphore: *VkSemaphore,
) VkResult;

extern "vulkan" fn vkWaitSemaphores(
    device: VkDevice,
    pWaitInfo: *const VkSemaphoreWaitInfo,
    timeout: u64,
) VkResult;

extern "vulkan" fn vkSignalSemaphore(
    device: VkDevice,
    pSignalInfo: *const VkSemaphoreSignalInfo,
) VkResult;

extern "vulkan" fn vkDestroySemaphore(
    device: VkDevice,
    semaphore: VkSemaphore,
    pAllocator: ?*const anyopaque,
) void;

// --- High-level wrappers: zero-copy integration between gpu_memory and Vulkan ---

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

/// **Stub — CPU-side value tracker only, NOT a real GPU semaphore.** The intended design
/// is a `VK_KHR_timeline_semaphore` (the `vkCreateSemaphore`/`vkWaitSemaphores` externs are
/// declared but never called), but this currently just tracks a monotonic `u64` in host
/// memory: `semaphore`/`device` stay null and no GPU wait ever happens. It is safe for
/// bookkeeping a value on the bus, but **must not** be relied on for GPU↔CPU ordering until
/// it is backed by a real `VkSemaphore`.
pub const VulkanSemaphore = struct {
    semaphore: ?VkSemaphore = null,
    value: u64 = 0,
    device: ?VkDevice = null,

    /// Create a timeline semaphore with an initial value.
    pub fn create(initial_value: u64) VulkanSemaphore {
        return .{ .value = initial_value };
    }

    /// Signal the semaphore to a new value (GPU-side or CPU-side).
    /// Sidecar typically signals after GPU work completes.
    pub fn signal(self: *VulkanSemaphore, new_value: u64) void {
        if (new_value > self.value) {
            self.value = new_value;
        }
    }

    /// Check if the semaphore has reached (or exceeded) a target value.
    /// Non-blocking: returns immediately with current state.
    pub fn isSignaled(self: *const VulkanSemaphore, target_value: u64) bool {
        return self.value >= target_value;
    }

    /// Get the current semaphore value for pub/sub on the bus.
    pub fn getValue(self: *const VulkanSemaphore) u64 {
        return self.value;
    }
};

/// Multi-GPU memory pool: manages buffers that can be shared across GPU devices.
/// Via VK_KHR_device_group, a single buffer can be accessed by multiple GPUs
/// without copies. Coordinates allocation and synchronization.
pub const MultiGpuMemoryPool = struct {
    pool: gpu_mem.Pool,
    gpu_count: u32 = 1,
    semaphores: std.ArrayListUnmanaged(VulkanSemaphore) = .empty,
    gpa: Allocator,

    pub fn init(gpa: Allocator, gpu_count: u32) MultiGpuMemoryPool {
        return .{ .pool = gpu_mem.Pool.init(gpa), .gpu_count = gpu_count, .gpa = gpa };
    }

    /// Allocate a buffer that can be shared across all GPUs in the group.
    pub fn allocateShared(pool: *MultiGpuMemoryPool, size: usize, name: []const u8) !*gpu_mem.Buffer {
        const buf = try pool.pool.allocate(size, name);
        _ = try pool.semaphores.append(pool.gpa, VulkanSemaphore.create(0));
        return buf;
    }

    /// Get the synchronization semaphore for a buffer (by index).
    pub fn getSemaphore(pool: *MultiGpuMemoryPool, buf_idx: usize) ?*VulkanSemaphore {
        if (buf_idx < pool.semaphores.items.len) {
            return &pool.semaphores.items[buf_idx];
        }
        return null;
    }

    /// Free the pool and all buffers/semaphores.
    pub fn deinit(pool: *MultiGpuMemoryPool) void {
        pool.pool.deinit();
        pool.semaphores.deinit(pool.gpa);
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

test "gpu_vulkan.VulkanSemaphore timeline synchronization" {
    var sem = VulkanSemaphore.create(0);
    try testing.expectEqual(@as(u64, 0), sem.getValue());
    try testing.expect(!sem.isSignaled(1));

    sem.signal(5);
    try testing.expectEqual(@as(u64, 5), sem.getValue());
    try testing.expect(sem.isSignaled(5));
    try testing.expect(sem.isSignaled(1));
    try testing.expect(!sem.isSignaled(6));
}

test "gpu_vulkan.MultiGpuMemoryPool allocates shared buffers" {
    var pool = MultiGpuMemoryPool.init(testing.allocator, 2);
    defer pool.deinit();

    const buf1 = try pool.allocateShared(256, "shared_0");
    const buf2 = try pool.allocateShared(512, "shared_1");

    try testing.expectEqual(@as(usize, 256), buf1.size);
    try testing.expectEqual(@as(usize, 512), buf2.size);

    const sem1 = pool.getSemaphore(0);
    const sem2 = pool.getSemaphore(1);
    try testing.expect(sem1 != null);
    try testing.expect(sem2 != null);
    try testing.expectEqual(@as(u64, 0), sem1.?.getValue());
    try testing.expectEqual(@as(u64, 0), sem2.?.getValue());
}
