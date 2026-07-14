//! # zicro.gpu_wgpu — a WebGPU device, and a place to put pixels
//!
//! The `webgpu.h` C ABI, bound for Zig, plus the four calls it takes to get from
//! nothing to a device you can render with. That is ALL this module does, and the
//! boundary is deliberate:
//!
//!   **zicro owns the device and the window. The engine above owns the frame.**
//!
//! So there is no render graph here, no frame ring, no material, no pass — those are
//! opinions, and they belong to whoever is drawing. What belongs *here* is the part
//! that cannot be written without knowing what a window is: a `WGPUSurface` comes from
//! a Wayland `wl_surface`, a Cocoa `CAMetalLayer`, a Win32 `HWND` or a `<canvas>`, and
//! zicro is the only thing in the stack that knows which of those it has.
//!
//! ## Why `@cImport` and not a hand-rolled FFI
//!
//! `gpu_vulkan.zig` next door is hand-written, because Vulkan's real header is a
//! hundred thousand generated lines and we use a few dozen of them. `webgpu.h` is the
//! opposite animal: 6,700 lines describing a small, stable, deliberately C-shaped ABI,
//! most of it chained structs whose layout must be exact. Retyping those by hand is a
//! bug farm with no upside — translate-c gets them right for free, and gets them right
//! again when the header moves.
//!
//! ## The two hosts
//!
//! The same header is implemented twice: by **wgpu-native** on the desktop (a prebuilt
//! static library — Vulkan, Metal or DX12 underneath, no Rust toolchain required), and
//! by the **browser** over the WebGPU it already has. Code written against this module
//! does not know which. That is the entire point of choosing this header.
//!
//! Native only, for now: the browser host arrives with `window_web.zig`'s canvas.

const std = @import("std");

pub const c = @cImport({
    @cInclude("webgpu/webgpu.h");
    @cInclude("webgpu/wgpu.h"); // wgpu-native's own extensions (SPIR-V passthrough, poll)
});

pub const Error = error{
    NoInstance,
    NoAdapter,
    NoDevice,
    RequestFailed,
};

pub const Instance = c.WGPUInstance;
pub const Adapter = c.WGPUAdapter;
pub const Device = c.WGPUDevice;
pub const Queue = c.WGPUQueue;
pub const Surface = c.WGPUSurface;

/// A device, its queue, and the adapter they came from — everything the layer above
/// needs and nothing it does not.
pub const Gpu = struct {
    instance: Instance,
    adapter: Adapter,
    device: Device,
    queue: Queue,
    /// The instance took SPIR-V. It decides whether the engine above hands over the
    /// SPIR-V it already compiles for Vulkan, or the WGSL it has to transpile — and it
    /// is the ONE branch in the whole backend that the browser forces.
    spirv: bool,

    pub fn deinit(self: *Gpu) void {
        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.device);
        c.wgpuAdapterRelease(self.adapter);
        c.wgpuInstanceRelease(self.instance);
        self.* = undefined;
    }
};

/// SPIR-V passthrough. Note *where* it sits: this is an INSTANCE feature, not a device
/// one — you ask for it before you have an adapter, because it is a statement about
/// what the shader front end will accept, not about what any GPU can do. It is not in
/// the WebGPU standard and never will be: a browser cannot be handed SPIR-V, for the
/// same reason it cannot be handed a file descriptor.
const spirv_source: c.WGPUInstanceFeatureName = c.WGPUInstanceFeatureName_ShaderSourceSPIRV;

// ── the four calls ───────────────────────────────────────────────────────────────
//
// WebGPU's adapter and device requests are asynchronous because in a BROWSER they are:
// there, getting a GPU is a permission-shaped question with a human somewhere behind
// it. Natively the answer is already known, and wgpu-native admits as much — the whole
// future machinery (`wgpuInstanceWaitAny`) is `unimplemented!()`, and the callback
// fires inside the request call. So this bring-up is written as what it is: four
// synchronous calls wearing an async costume.

const Pending = struct {
    got: ?*anyopaque = null,
    failed: bool = false,
};

fn onAdapter(
    status: c.WGPURequestAdapterStatus,
    adapter: c.WGPUAdapter,
    _: c.WGPUStringView,
    ud1: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    const p: *Pending = @ptrCast(@alignCast(ud1.?));
    if (status == c.WGPURequestAdapterStatus_Success) p.got = adapter else p.failed = true;
}

fn onDevice(
    status: c.WGPURequestDeviceStatus,
    device: c.WGPUDevice,
    _: c.WGPUStringView,
    ud1: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    const p: *Pending = @ptrCast(@alignCast(ud1.?));
    if (status == c.WGPURequestDeviceStatus_Success) p.got = device else p.failed = true;
}

/// The future the request hands back is not usable: `wgpuInstanceWaitAny` is
/// `unimplemented!()` in wgpu-native, in every form, and a timed wait is itself an
/// instance feature that is not built. What IS true of this implementation — and of
/// every native one — is that the adapter and the device are already there: the async
/// shape exists because a BROWSER needs it, and the callback fires inside the request
/// call itself under `AllowSpontaneous`.
///
/// So we do not wait. We ask, and by the time the call returns the answer is in
/// `Pending`. That is a fact about the native host and not about the API, which is
/// exactly why it is checked rather than assumed.
fn took(p: *const Pending) !*anyopaque {
    if (p.failed) return Error.RequestFailed;
    return p.got orelse Error.RequestFailed;
}

/// Bring up a device. `surface` may be null (`WGPUSurface` is itself a nullable
/// handle) — a headless device is a perfectly good device, and it is how this engine's
/// golden tests run: render into a texture, read it back, compare it to the CPU twin.
/// Nothing about that needs a window.
pub fn init(surface: Surface) !Gpu {
    // Ask the instance for SPIR-V. If it refuses (it will, in a browser) fall back to
    // a plain instance and tell the caller through `Gpu.spirv` — a WGSL-only device is
    // not a degraded device, it is the standard one.
    var inst_features: [1]c.WGPUInstanceFeatureName = .{spirv_source};
    const inst_desc = c.WGPUInstanceDescriptor{
        .requiredFeatureCount = 1,
        .requiredFeatures = &inst_features,
    };
    var spirv = true;
    const instance = c.wgpuCreateInstance(&inst_desc) orelse blk: {
        spirv = false;
        break :blk c.wgpuCreateInstance(null) orelse return Error.NoInstance;
    };
    errdefer c.wgpuInstanceRelease(instance);

    var p_adapter = Pending{};
    const adapter_opts = c.WGPURequestAdapterOptions{
        .compatibleSurface = surface,
        .powerPreference = c.WGPUPowerPreference_HighPerformance,
    };
    _ = c.wgpuInstanceRequestAdapter(instance, &adapter_opts, .{
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = onAdapter,
        .userdata1 = &p_adapter,
    });
    const adapter: Adapter = @ptrCast(took(&p_adapter) catch return Error.NoAdapter);
    errdefer c.wgpuAdapterRelease(adapter);

    var p_device = Pending{};
    const dev_desc = c.WGPUDeviceDescriptor{};
    _ = c.wgpuAdapterRequestDevice(adapter, &dev_desc, .{
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = onDevice,
        .userdata1 = &p_device,
    });
    const device: Device = @ptrCast(took(&p_device) catch return Error.NoDevice);
    errdefer c.wgpuDeviceRelease(device);

    const queue = c.wgpuDeviceGetQueue(device) orelse return Error.NoDevice;

    return .{ .instance = instance, .adapter = adapter, .device = device, .queue = queue, .spirv = spirv };
}

// ── the window half ──────────────────────────────────────────────────────────────
//
// This is the part that could not live anywhere else. A surface is made OF a window,
// and the window backends are zicro's (`window_wayland.zig`, `window_cocoa.zig`,
// `window_win32.zig`, `window_web.zig`). Each host has exactly one way in.

/// A Wayland surface. The two pointers are the compositor's, and the caller got them
/// from `window_wayland.zig` — which is why this function is here and not in the
/// renderer.
pub fn surfaceFromWayland(instance: Instance, display: *anyopaque, wl_surface: *anyopaque) !Surface {
    var src = c.WGPUSurfaceSourceWaylandSurface{
        .chain = .{ .sType = c.WGPUSType_SurfaceSourceWaylandSurface },
        .display = display,
        .surface = wl_surface,
    };
    const desc = c.WGPUSurfaceDescriptor{ .nextInChain = &src.chain };
    return c.wgpuInstanceCreateSurface(instance, &desc) orelse Error.RequestFailed;
}

// ── tests ────────────────────────────────────────────────────────────────────────
//
// A headless device on whatever the machine has. It is not much of a test — but it is
// the test that fails loudly the day the header, the prebuilt library and this file
// stop agreeing about the ABI, which is the only thing that can actually go wrong in a
// binding.

test "a headless device comes up, and says whether it will take our SPIR-V" {
    var gpu = init(null) catch |e| {
        // No GPU in the sandbox is not a failing binding.
        std.debug.print("wgpu: no device ({s}) — skipping\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer gpu.deinit();
    try std.testing.expect(gpu.device != null);
    try std.testing.expect(gpu.queue != null);
    std.debug.print("wgpu: device up, SPIR-V source {s}\n", .{if (gpu.spirv) "yes" else "no"});
}
