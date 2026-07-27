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
//! A hand-written FFI makes sense when the real header is a hundred thousand generated
//! lines and only a few dozen are used. `webgpu.h` is the
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

// Only the STANDARD header. wgpu-native ships a `wgpu.h` of its own extensions and it is
// tempting to reach for it — but the browser has no such file, and every symbol taken
// from it is a symbol the web host cannot supply. Everything this module needs is in the
// standard header, SPIR-V passthrough included (it is an optional instance FEATURE, not
// a vendor extension). So the same Zig compiles against Dawn's copy of `webgpu.h` under
// Emscripten and against wgpu-native's on the desktop, unchanged. That is the entire
// reason this header was worth choosing over wgpu's own Rust API.
pub const c = @cImport({
    @cInclude("webgpu/webgpu.h");
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

/// Is this build talking to a browser? The one question the layer above is allowed to
/// ask about its host — and it is here, not in the renderer, because "what am I drawing
/// into" is a window question.
pub const is_web = @import("builtin").target.os.tag == .emscripten;

/// A `<canvas>`, by CSS selector — the browser's whole answer to "what is a window".
///
/// The chained struct is Emscripten's, not the standard header's: `webgpu.h` describes
/// how to make a surface out of a Wayland surface, an HWND, a CAMetalLayer and a canvas,
/// and each of those lives only in the header of a host that HAS one. This is the exact
/// mirror of `surfaceFromWayland` below, and the pair is the whole reason this module
/// sits in zicro: everything above it can be written once, because the two functions
/// that cannot be are both here.
pub fn surfaceFromCanvas(instance: Instance, selector: [:0]const u8) !Surface {
    if (!is_web) @compileError("a canvas is a browser's window — this host has none");
    var src = c.WGPUEmscriptenSurfaceSourceCanvasHTMLSelector{
        .chain = .{ .sType = c.WGPUSType_EmscriptenSurfaceSourceCanvasHTMLSelector },
        .selector = .{ .data = selector.ptr, .length = selector.len },
    };
    const desc = c.WGPUSurfaceDescriptor{ .nextInChain = &src.chain };
    return c.wgpuInstanceCreateSurface(instance, &desc) orelse Error.RequestFailed;
}

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

const paint = @import("paint.zig");
const paint_gl = @import("paint_gl.zig");

/// GPU Backend implementation for WebGPU / Vulkan / DX12 / Metal via wgpu-native.
///
/// NOT YET WIRED INTO Canvas.gl, and not yet a working GPU backend even if it were: every
/// vtable method below only forwards to `recorder` (a `paint_gl.GlRecorder`), which
/// accumulates vertices/atlas data in CPU memory — the same code path the software GL
/// backend uses. Nothing here creates `pipeline`/`bind_group`/`texture`/`vertex_buf` (they
/// stay null; `deinit`'s release-if-set calls are dead code today) or ever calls
/// wgpuQueueWriteBuffer/wgpuRenderPassEncoderDraw/wgpuQueueSubmit — so `recorder`'s output is
/// never actually uploaded or drawn. Assigning `backend()` to `Canvas.gl` today would
/// reproduce the "primitives vanish with no error" failure this vtable shape has hit before:
/// finish the upload+submit step first (feed recorder.vertexBytes()/atlasPtr() to
/// vertex_buf/texture via a real pipeline) before wiring this into Canvas.gl.
pub const WgpuBackend = struct {
    gpu: *Gpu,
    gpa: std.mem.Allocator,
    recorder: paint_gl.GlRecorder,

    // Placeholders for the not-yet-implemented submission path — never created, so always
    // null; `deinit`'s release-if-set is future-proofing for when init actually builds these.
    pipeline: c.WGPURenderPipeline = null,
    bind_group_layout: c.WGPUBindGroupLayout = null,
    bind_group: c.WGPUBindGroup = null,
    texture: c.WGPUTexture = null,
    texture_view: c.WGPUTextureView = null,
    sampler: c.WGPUSampler = null,
    uniform_buf: c.WGPUBuffer = null,
    vertex_buf: c.WGPUBuffer = null,
    vertex_buf_cap: usize = 0,

    pub fn init(gpu: *Gpu, gpa: std.mem.Allocator) WgpuBackend {
        return .{
            .gpu = gpu,
            .gpa = gpa,
            .recorder = paint_gl.GlRecorder.init(gpa),
        };
    }

    pub fn deinit(self: *WgpuBackend) void {
        self.recorder.deinit();
        if (self.vertex_buf) |b| c.wgpuBufferRelease(b);
        if (self.uniform_buf) |b| c.wgpuBufferRelease(b);
        if (self.texture_view) |v| c.wgpuTextureViewRelease(v);
        if (self.texture) |t| c.wgpuTextureRelease(t);
        if (self.sampler) |s| c.wgpuSamplerRelease(s);
        if (self.bind_group) |bg| c.wgpuBindGroupRelease(bg);
        if (self.bind_group_layout) |bgl| c.wgpuBindGroupLayoutRelease(bgl);
        if (self.pipeline) |p| c.wgpuRenderPipelineRelease(p);
    }

    pub fn backend(self: *WgpuBackend) paint.GlBackend {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn reset(self: *WgpuBackend) void {
        self.recorder.reset();
    }

    pub fn vertexBytes(self: *const WgpuBackend) []const u8 {
        return self.recorder.vertexBytes();
    }

    pub fn vertexCount(self: *const WgpuBackend) usize {
        return self.recorder.vertexCount();
    }

    const vtable = paint.GlBackend.VTable{
        .fillRoundedRect = fillRoundedRectImpl,
        .fillRoundedRectPerCorner = fillRoundedRectPerCornerImpl,
        .fillRoundedRectVGradient = fillRoundedRectVGradientImpl,
        .fillConcaveCorner = fillConcaveCornerImpl,
        .strokeSegment = strokeSegmentImpl,
        .strokeRoundedRect = strokeRoundedRectImpl,
        .blitImage = blitImageImpl,
        .blitMask = blitMaskImpl,
        .blitImageRot = blitImageRotImpl,
        .drawText = drawTextImpl,
    };

    fn fillRoundedRectImpl(ptr: *anyopaque, x: f32, y: f32, w: f32, h: f32, radius: f32, color: paint.Color, clip: ?paint.Canvas.Clip) void {
        const self: *WgpuBackend = @ptrCast(@alignCast(ptr));
        const b = self.recorder.iface();
        b.vtable.fillRoundedRect(b.ptr, x, y, w, h, radius, color, clip);
    }
    fn fillRoundedRectPerCornerImpl(ptr: *anyopaque, x: f32, y: f32, w: f32, h: f32, corners: paint.Corners, color: paint.Color, clip: ?paint.Canvas.Clip) void {
        const self: *WgpuBackend = @ptrCast(@alignCast(ptr));
        const b = self.recorder.iface();
        b.vtable.fillRoundedRectPerCorner(b.ptr, x, y, w, h, corners, color, clip);
    }
    fn fillRoundedRectVGradientImpl(ptr: *anyopaque, x: f32, y: f32, w: f32, h: f32, radius: f32, top: paint.Color, bottom: paint.Color, clip: ?paint.Canvas.Clip) void {
        const self: *WgpuBackend = @ptrCast(@alignCast(ptr));
        const b = self.recorder.iface();
        b.vtable.fillRoundedRectVGradient(b.ptr, x, y, w, h, radius, top, bottom, clip);
    }
    fn fillConcaveCornerImpl(ptr: *anyopaque, x: f32, y: f32, size: f32, cx: f32, cy: f32, color: paint.Color, clip: ?paint.Canvas.Clip) void {
        const self: *WgpuBackend = @ptrCast(@alignCast(ptr));
        const b = self.recorder.iface();
        b.vtable.fillConcaveCorner(b.ptr, x, y, size, cx, cy, color, clip);
    }
    fn strokeSegmentImpl(ptr: *anyopaque, ax: f32, ay: f32, bx: f32, by: f32, width: f32, color: paint.Color, clip: ?paint.Canvas.Clip) void {
        const self: *WgpuBackend = @ptrCast(@alignCast(ptr));
        const b = self.recorder.iface();
        b.vtable.strokeSegment(b.ptr, ax, ay, bx, by, width, color, clip);
    }
    fn strokeRoundedRectImpl(ptr: *anyopaque, x: f32, y: f32, w: f32, h: f32, radius: f32, stroke: f32, color: paint.Color, clip: ?paint.Canvas.Clip) void {
        const self: *WgpuBackend = @ptrCast(@alignCast(ptr));
        const b = self.recorder.iface();
        b.vtable.strokeRoundedRect(b.ptr, x, y, w, h, radius, stroke, color, clip);
    }
    fn blitImageImpl(ptr: *anyopaque, dst_x: i32, dst_y: i32, dst_w: u32, dst_h: u32, src: []const u8, src_w: u32, src_h: u32, clip: ?paint.Canvas.Clip) void {
        const self: *WgpuBackend = @ptrCast(@alignCast(ptr));
        const b = self.recorder.iface();
        b.vtable.blitImage(b.ptr, dst_x, dst_y, dst_w, dst_h, src, src_w, src_h, clip);
    }
    fn blitMaskImpl(ptr: *anyopaque, dst_x: i32, dst_y: i32, dst_w: u32, dst_h: u32, src: []const u8, src_w: u32, src_h: u32, tint: paint.Color, clip: ?paint.Canvas.Clip) void {
        const self: *WgpuBackend = @ptrCast(@alignCast(ptr));
        const b = self.recorder.iface();
        b.vtable.blitMask(b.ptr, dst_x, dst_y, dst_w, dst_h, src, src_w, src_h, tint, clip);
    }
    fn blitImageRotImpl(ptr: *anyopaque, dx: f32, dy: f32, dw: f32, dh: f32, src: []const u8, src_w: u32, src_h: u32, angle: f32, clip: ?paint.Canvas.Clip) void {
        const self: *WgpuBackend = @ptrCast(@alignCast(ptr));
        const b = self.recorder.iface();
        b.vtable.blitImageRot(b.ptr, dx, dy, dw, dh, src, src_w, src_h, angle, clip);
    }
    fn drawTextImpl(ptr: *anyopaque, font: *paint.text.Font, x: i32, baseline_y: i32, s: []const u8, opts: paint.TextOpts, clip: ?paint.Canvas.Clip) void {
        const self: *WgpuBackend = @ptrCast(@alignCast(ptr));
        const b = self.recorder.iface();
        b.vtable.drawText(b.ptr, font, x, baseline_y, s, opts, clip);
    }
};

test "WgpuBackend's vtable records draws into its CPU-side GlRecorder (no GPU upload yet)" {
    var fake_gpu: Gpu = undefined;
    var wgpu_b = WgpuBackend.init(&fake_gpu, std.testing.allocator);
    defer wgpu_b.deinit();
    const gb = wgpu_b.backend();
    try std.testing.expect(@as(?*const anyopaque, @ptrCast(gb.vtable.fillRoundedRect)) != null);
    try std.testing.expect(@as(?*const anyopaque, @ptrCast(gb.vtable.drawText)) != null);

    gb.vtable.fillRoundedRect(gb.ptr, 10, 20, 100, 40, 8, .{ .r = 1, .g = 0, .b = 0, .a = 1 }, null);
    try std.testing.expectEqual(@as(usize, 6), wgpu_b.vertexCount());
    wgpu_b.reset();
    try std.testing.expectEqual(@as(usize, 0), wgpu_b.vertexCount());
}

