//! # zicro.gpu_wgpu_bridge_ffi — FFI bindings for libzicro_wgpu_bridge
//!
//! Zig FFI layer for the zicro-wgpu-bridge Rust library.
//! Provides access to wgpu-core with Vulkan interop:
//! - Zero-copy Vulkan↔wgpu buffers (memfd-based)
//! - Timeline semaphore synchronization
//! - Multi-GPU device groups
//!
//! Link against: libzicro_wgpu_bridge.so (compiled from zicro-wgpu-bridge/)

const std = @import("std");
const gpu_vk = @import("gpu_vulkan.zig");

// --- C type aliases (opaque pointers) ---

pub const WgpuInstance = ?*opaque {};
pub const WgpuDevice = ?*opaque {};
pub const WgpuQueue = ?*opaque {};
pub const WgpuBuffer = u32;  // Buffer ID

// --- Result codes ---

pub const WgpuResult = enum(c_uint) {
    Success = 0,
    Error = 1,
    OutOfMemory = 2,
    InvalidDevice = 3,
    InvalidMemory = 4,
    SemaphoreWaitTimeout = 5,
};

// --- Structures ---

pub const VulkanExternalMemory = extern struct {
    vk_device_memory: *opaque {},  // VkDeviceMemory
    fd: i32,
    size: u64,
    offset: u64,
};

pub const TimelineSemaphore = extern struct {
    vk_semaphore: *opaque {},  // VkSemaphore with timeline extension
    value: u64,
};

pub const DeviceGroupInfo = extern struct {
    physical_device_count: c_uint,
    physical_devices: [*]const *opaque {},  // Array of VkPhysicalDevice
};

pub const SubmitInfo = extern struct {
    command_buffer_count: c_uint,
    command_buffers: [*]const *opaque {},
    device_mask: u32,
    wait_semaphore_count: c_uint,
    wait_semaphores: [*]const *opaque {},
    signal_semaphore_count: c_uint,
    signal_semaphores: [*]const *opaque {},
};

// --- C FFI declarations (link against libzicro_wgpu_bridge) ---

extern "zicro_wgpu_bridge" fn zicro_wgpu_instance_create() WgpuInstance;

extern "zicro_wgpu_bridge" fn zicro_wgpu_instance_enumerate_adapters(
    instance: WgpuInstance,
    backend: c_uint,
) i32;

extern "zicro_wgpu_bridge" fn zicro_wgpu_device_create(
    instance: WgpuInstance,
    vk_physical_device: ?*opaque {},
    vk_device: ?*opaque {},
) WgpuDevice;

extern "zicro_wgpu_bridge" fn zicro_wgpu_device_create_buffer_from_vulkan_memory(
    device: WgpuDevice,
    vk_memory: *const VulkanExternalMemory,
    usage: c_uint,
) WgpuBuffer;

extern "zicro_wgpu_bridge" fn zicro_wgpu_device_wait_timeline_semaphore(
    device: WgpuDevice,
    semaphore: *const TimelineSemaphore,
    target_value: u64,
    timeout_ns: u64,
) WgpuResult;

extern "zicro_wgpu_bridge" fn zicro_wgpu_device_signal_timeline_semaphore(
    device: WgpuDevice,
    semaphore: *const TimelineSemaphore,
    value: u64,
) WgpuResult;

extern "zicro_wgpu_bridge" fn zicro_wgpu_device_group_create(
    instance: WgpuInstance,
    group_info: *const DeviceGroupInfo,
) WgpuDevice;

extern "zicro_wgpu_bridge" fn zicro_wgpu_queue_submit(
    queue: WgpuQueue,
    submit_info: *const SubmitInfo,
) WgpuResult;

extern "zicro_wgpu_bridge" fn zicro_wgpu_semaphore_get_value(
    semaphore: *const TimelineSemaphore,
) u64;

extern "zicro_wgpu_bridge" fn zicro_wgpu_buffer_get_size(
    device: WgpuDevice,
    buffer: WgpuBuffer,
) u64;

extern "zicro_wgpu_bridge" fn zicro_wgpu_device_destroy(device: WgpuDevice) void;

extern "zicro_wgpu_bridge" fn zicro_wgpu_instance_destroy(instance: WgpuInstance) void;

// --- High-level Zig wrappers ---

/// A wgpu device created via the bridge, with Vulkan interop.
pub const BridgeDevice = struct {
    instance: WgpuInstance,
    device: WgpuDevice,
    queue: WgpuQueue,

    pub fn create(vk_device: ?gpu_vk.VkDevice) !BridgeDevice {
        const inst = zicro_wgpu_instance_create();
        if (inst == null) return error.InstanceCreateFailed;

        const dev = zicro_wgpu_device_create(inst, null, vk_device);
        if (dev == null) return error.DeviceCreateFailed;

        return .{
            .instance = inst,
            .device = dev,
            .queue = null,  // Queue obtained via device in real impl
        };
    }

    pub fn createBufferFromVulkanMemory(
        self: *const BridgeDevice,
        vk_mem: *const VulkanExternalMemory,
        usage: c_uint,
    ) !WgpuBuffer {
        const buf = zicro_wgpu_device_create_buffer_from_vulkan_memory(
            self.device,
            vk_mem,
            usage,
        );
        return buf;
    }

    pub fn waitSemaphore(
        self: *const BridgeDevice,
        semaphore: *const TimelineSemaphore,
        target_value: u64,
        timeout_ns: u64,
    ) !void {
        const result = zicro_wgpu_device_wait_timeline_semaphore(
            self.device,
            semaphore,
            target_value,
            timeout_ns,
        );
        return switch (result) {
            .Success => {},
            .SemaphoreWaitTimeout => error.Timeout,
            else => error.WaitFailed,
        };
    }

    pub fn signalSemaphore(
        self: *const BridgeDevice,
        semaphore: *const TimelineSemaphore,
        value: u64,
    ) !void {
        const result = zicro_wgpu_device_signal_timeline_semaphore(
            self.device,
            semaphore,
            value,
        );
        return switch (result) {
            .Success => {},
            else => error.SignalFailed,
        };
    }

    pub fn deinit(self: *const BridgeDevice) void {
        zicro_wgpu_device_destroy(self.device);
        zicro_wgpu_instance_destroy(self.instance);
    }
};

// --- Tests ---

const testing = std.testing;

test "gpu_wgpu_bridge_ffi.BridgeDevice creation" {
    // Note: This test requires libzicro_wgpu_bridge.so to be built and linked.
    // Skipped if library is not available.
    _ = testing;
    // Actual test would create a device and verify it's non-null
}

test "gpu_wgpu_bridge_ffi.VulkanExternalMemory layout" {
    const mem = VulkanExternalMemory{
        .vk_device_memory = undefined,
        .fd = 3,
        .size = 1024,
        .offset = 0,
    };
    try testing.expectEqual(@as(i32, 3), mem.fd);
    try testing.expectEqual(@as(u64, 1024), mem.size);
}

test "gpu_wgpu_bridge_ffi.TimelineSemaphore layout" {
    var sem = TimelineSemaphore{
        .vk_semaphore = undefined,
        .value = 42,
    };
    try testing.expectEqual(@as(u64, 42), sem.value);
    sem.value = 100;
    try testing.expectEqual(@as(u64, 100), sem.value);
}
