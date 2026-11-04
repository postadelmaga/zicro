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
//! ## Why translate-c and not a hand-rolled FFI
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
// Translated by a build step (see src/c/webgpu.h): Zig 0.17 removed `@cImport`,
// so webgpu.h arrives as the module "webgpu_c".
pub const c = @import("webgpu_c");

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

/// `paint.GlBackend` on a WebGPU device: the 2D canvas drawn by the GPU.
///
/// It is the same split the browser's WebGL2 path uses, with the platform half moved from
/// JavaScript into this file. Drawing (`Canvas` with `gl = &backend.iface`) only RECORDS:
/// every primitive becomes six vertices of `paint_gl.Vertex` in `recorder`, and every
/// bitmap (glyph, icon, mask) is copied once into the recorder's shared 2048² atlas.
/// Then `encode`/`submit` does what the page's `drawUber` does: upload the atlas rows that
/// changed and the frame's vertices, and draw the WHOLE frame in one call with the
/// ubershader below (a WGSL port of the WebGL2 one, mode for mode).
///
/// A frame:
///
///     backend.reset();                       // forget last frame's vertices (atlas stays)
///     canvas.gl = &backend.iface;            // primitives now record instead of raster
///     ... draw with canvas ...
///     try backend.submit(target_view, w, h, clear_color);
///
/// What the CPU canvas has and this does not: the primitives `paint.GlBackend` lists as
/// CPU-only (`drawChrome`, `blitRgba`, shadows, arcs) assert `gl == null` in debug builds,
/// and `fillConcaveCorner` draws a plain square (the ubershader has no outside-a-circle
/// mode) — the same limits as the WebGL2 backend, because it is the same recorder.
pub const WgpuBackend = struct {
    gpu: *Gpu,
    recorder: paint_gl.GlRecorder,
    /// The vtable `Canvas.gl` points at. Stable for the backend's lifetime (do not copy
    /// the backend after `init`: this points into it).
    iface: paint.GlBackend,
    format: c.WGPUTextureFormat,

    pipeline: c.WGPURenderPipeline,
    pipeline_layout: c.WGPUPipelineLayout,
    bind_group_layout: c.WGPUBindGroupLayout,
    bind_group: c.WGPUBindGroup,
    atlas: c.WGPUTexture,
    atlas_view: c.WGPUTextureView,
    sampler: c.WGPUSampler,
    uniform_buf: c.WGPUBuffer,
    vertex_buf: c.WGPUBuffer = null,
    vertex_buf_cap: u64 = 0,

    pub const DrawError = error{ ShaderFailed, PipelineFailed, OutOfGpuMemory, SubmitFailed };

    /// Build the pipeline for render targets of `format` (the surface's or the offscreen
    /// texture's). The atlas texture is allocated here, once, at its full size: it is the
    /// recorder's, which never shrinks either.
    pub fn init(self: *WgpuBackend, gpu: *Gpu, gpa: std.mem.Allocator, format: c.WGPUTextureFormat) DrawError!void {
        const dev = gpu.device;
        var wgsl = c.WGPUShaderSourceWGSL{
            .chain = .{ .sType = c.WGPUSType_ShaderSourceWGSL },
            .code = sv(uber_wgsl),
        };
        const module = c.wgpuDeviceCreateShaderModule(dev, &.{ .nextInChain = &wgsl.chain, .label = sv("zicro uber2d") }) orelse return error.ShaderFailed;
        defer c.wgpuShaderModuleRelease(module);

        const entries = [3]c.WGPUBindGroupLayoutEntry{
            .{ .binding = 0, .visibility = c.WGPUShaderStage_Vertex, .buffer = .{ .type = c.WGPUBufferBindingType_Uniform, .minBindingSize = 16 } },
            .{ .binding = 1, .visibility = c.WGPUShaderStage_Fragment, .texture = .{ .sampleType = c.WGPUTextureSampleType_Float, .viewDimension = c.WGPUTextureViewDimension_2D } },
            .{ .binding = 2, .visibility = c.WGPUShaderStage_Fragment, .sampler = .{ .type = c.WGPUSamplerBindingType_Filtering } },
        };
        const bgl = c.wgpuDeviceCreateBindGroupLayout(dev, &.{ .entryCount = entries.len, .entries = &entries }) orelse return error.PipelineFailed;
        errdefer c.wgpuBindGroupLayoutRelease(bgl);
        const layout = c.wgpuDeviceCreatePipelineLayout(dev, &.{ .bindGroupLayoutCount = 1, .bindGroupLayouts = &bgl }) orelse return error.PipelineFailed;
        errdefer c.wgpuPipelineLayoutRelease(layout);

        // `paint_gl.Vertex` as six attributes — the WebGL2 page's `attribSpec`, byte for byte.
        const F4 = c.WGPUVertexFormat_Float32x4;
        const attrs = [6]c.WGPUVertexAttribute{
            .{ .format = F4, .offset = 0, .shaderLocation = 0 }, // x y u v
            .{ .format = F4, .offset = 16, .shaderLocation = 1 }, // r g b a
            .{ .format = F4, .offset = 32, .shaderLocation = 2 }, // cx cy hw hh
            .{ .format = F4, .offset = 48, .shaderLocation = 3 }, // corner radii
            .{ .format = F4, .offset = 64, .shaderLocation = 4 }, // mode stroke clip_x0 clip_y0
            .{ .format = c.WGPUVertexFormat_Float32x3, .offset = 80, .shaderLocation = 5 }, // clip_x1 clip_y1 tex
        };
        const vbl = c.WGPUVertexBufferLayout{
            .stepMode = c.WGPUVertexStepMode_Vertex,
            .arrayStride = @sizeOf(paint_gl.Vertex),
            .attributeCount = attrs.len,
            .attributes = &attrs,
        };
        // Straight-alpha source-over, as the WebGL2 path blends (SRC_ALPHA, ONE_MINUS_SRC_ALPHA
        // on all four channels) — so the two GPU backends agree pixel for pixel.
        const over = c.WGPUBlendComponent{
            .operation = c.WGPUBlendOperation_Add,
            .srcFactor = c.WGPUBlendFactor_SrcAlpha,
            .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
        };
        const blend = c.WGPUBlendState{ .color = over, .alpha = over };
        const target = c.WGPUColorTargetState{ .format = format, .blend = &blend, .writeMask = c.WGPUColorWriteMask_All };
        const frag = c.WGPUFragmentState{ .module = module, .entryPoint = sv("fs_main"), .targetCount = 1, .targets = &target };
        const pipeline = c.wgpuDeviceCreateRenderPipeline(dev, &.{
            .label = sv("zicro uber2d"),
            .layout = layout,
            .vertex = .{ .module = module, .entryPoint = sv("vs_main"), .bufferCount = 1, .buffers = &vbl },
            .primitive = .{
                .topology = c.WGPUPrimitiveTopology_TriangleList,
                .frontFace = c.WGPUFrontFace_CCW,
                .cullMode = c.WGPUCullMode_None,
            },
            .multisample = .{ .count = 1, .mask = 0xFFFF_FFFF },
            .fragment = &frag,
        }) orelse return error.PipelineFailed;
        errdefer c.wgpuRenderPipelineRelease(pipeline);

        const atlas = c.wgpuDeviceCreateTexture(dev, &.{
            .label = sv("zicro atlas"),
            .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = paint_gl.atlas_dim, .height = paint_gl.atlas_dim, .depthOrArrayLayers = 1 },
            .format = c.WGPUTextureFormat_RGBA8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        }) orelse return error.OutOfGpuMemory;
        errdefer c.wgpuTextureRelease(atlas);
        const atlas_view = c.wgpuTextureCreateView(atlas, null) orelse return error.OutOfGpuMemory;
        errdefer c.wgpuTextureViewRelease(atlas_view);
        // NEAREST: glyphs and icons are drawn 1:1 in device pixels, as on the page.
        const sampler = c.wgpuDeviceCreateSampler(dev, &.{
            .addressModeU = c.WGPUAddressMode_ClampToEdge,
            .addressModeV = c.WGPUAddressMode_ClampToEdge,
            .addressModeW = c.WGPUAddressMode_ClampToEdge,
            .magFilter = c.WGPUFilterMode_Nearest,
            .minFilter = c.WGPUFilterMode_Nearest,
            .mipmapFilter = c.WGPUMipmapFilterMode_Nearest,
            .lodMinClamp = 0,
            .lodMaxClamp = 32,
            .maxAnisotropy = 1,
        }) orelse return error.OutOfGpuMemory;
        errdefer c.wgpuSamplerRelease(sampler);
        const uniform_buf = c.wgpuDeviceCreateBuffer(dev, &.{
            .label = sv("zicro uber2d res"),
            .usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
            .size = 16,
        }) orelse return error.OutOfGpuMemory;
        errdefer c.wgpuBufferRelease(uniform_buf);

        const bg_entries = [3]c.WGPUBindGroupEntry{
            .{ .binding = 0, .buffer = uniform_buf, .size = 16 },
            .{ .binding = 1, .textureView = atlas_view },
            .{ .binding = 2, .sampler = sampler },
        };
        const bind_group = c.wgpuDeviceCreateBindGroup(dev, &.{ .layout = bgl, .entryCount = bg_entries.len, .entries = &bg_entries }) orelse return error.PipelineFailed;

        self.* = .{
            .gpu = gpu,
            .recorder = paint_gl.GlRecorder.init(gpa),
            .iface = undefined,
            .format = format,
            .pipeline = pipeline,
            .pipeline_layout = layout,
            .bind_group_layout = bgl,
            .bind_group = bind_group,
            .atlas = atlas,
            .atlas_view = atlas_view,
            .sampler = sampler,
            .uniform_buf = uniform_buf,
        };
        self.iface = self.recorder.iface();
        // `iface.ptr` must point at THIS recorder (the one inside self), not the
        // temporary `init` built — hence assigned after `self.*` is in place.
        self.iface.ptr = &self.recorder;
    }

    pub fn deinit(self: *WgpuBackend) void {
        self.recorder.deinit();
        if (self.vertex_buf) |b| c.wgpuBufferRelease(b);
        c.wgpuBindGroupRelease(self.bind_group);
        c.wgpuBufferRelease(self.uniform_buf);
        c.wgpuSamplerRelease(self.sampler);
        c.wgpuTextureViewRelease(self.atlas_view);
        c.wgpuTextureRelease(self.atlas);
        c.wgpuRenderPipelineRelease(self.pipeline);
        c.wgpuPipelineLayoutRelease(self.pipeline_layout);
        c.wgpuBindGroupLayoutRelease(self.bind_group_layout);
        self.* = undefined;
    }

    /// Start a new frame: drop the recorded vertices. The atlas (and what is on the GPU
    /// of it) persists — glyphs and icons are uploaded once per session.
    pub fn reset(self: *WgpuBackend) void {
        self.recorder.reset();
    }

    pub fn vertexCount(self: *const WgpuBackend) usize {
        return self.recorder.vertexCount();
    }

    /// Record the frame into `encoder` as ONE render pass on `target` (`width`×`height`,
    /// of the format given to `init`): the atlas rows touched since the last frame and the
    /// frame's vertices are written to the queue first, then a single draw. `clear` = the
    /// pass's clear colour; `null` loads what the target already holds (drawing the UI
    /// over a 3D frame rendered into the same texture).
    pub fn encode(self: *WgpuBackend, encoder: c.WGPUCommandEncoder, target: c.WGPUTextureView, width: u32, height: u32, clear: ?paint.Color) DrawError!void {
        const queue = self.gpu.queue;
        const rec = &self.recorder;

        // The atlas band the recorder dirtied (whole rows, as the page uploads it).
        if (rec.atlasReady() and rec.dirtyHi() > rec.dirtyLo()) {
            const lo = rec.dirtyLo();
            const rows = rec.dirtyHi() - lo;
            const row_bytes: u32 = paint_gl.atlas_dim * 4;
            c.wgpuQueueWriteTexture(
                queue,
                &.{ .texture = self.atlas, .mipLevel = 0, .origin = .{ .x = 0, .y = lo, .z = 0 }, .aspect = c.WGPUTextureAspect_All },
                rec.atlasPtr() + @as(usize, lo) * row_bytes,
                @as(usize, rows) * row_bytes,
                &.{ .offset = 0, .bytesPerRow = row_bytes, .rowsPerImage = rows },
                &.{ .width = paint_gl.atlas_dim, .height = rows, .depthOrArrayLayers = 1 },
            );
            rec.clearDirty();
        }

        const res = [4]f32{ @floatFromInt(width), @floatFromInt(height), 0, 0 };
        c.wgpuQueueWriteBuffer(queue, self.uniform_buf, 0, &res, @sizeOf(@TypeOf(res)));

        const verts = rec.vertexBytes();
        if (verts.len > 0) try self.ensureVertexCapacity(verts.len);
        if (verts.len > 0) c.wgpuQueueWriteBuffer(queue, self.vertex_buf, 0, verts.ptr, verts.len);

        const cc = clear orelse paint.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const attachment = c.WGPURenderPassColorAttachment{
            .view = target,
            .depthSlice = std.math.maxInt(u32), // WGPU_DEPTH_SLICE_UNDEFINED: a 2D target
            .loadOp = if (clear != null) c.WGPULoadOp_Clear else c.WGPULoadOp_Load,
            .storeOp = c.WGPUStoreOp_Store,
            .clearValue = .{ .r = cc.r, .g = cc.g, .b = cc.b, .a = cc.a },
        };
        const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &.{
            .label = sv("zicro uber2d"),
            .colorAttachmentCount = 1,
            .colorAttachments = &attachment,
        }) orelse return error.SubmitFailed;
        if (verts.len > 0) {
            c.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);
            c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.bind_group, 0, null);
            c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.vertex_buf, 0, verts.len);
            c.wgpuRenderPassEncoderDraw(pass, @intCast(rec.vertexCount()), 1, 0, 0); // the whole frame
        }
        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);
    }

    /// `encode` in an encoder of its own, submitted. For a caller with nothing else to
    /// put in the frame's command buffer.
    pub fn submit(self: *WgpuBackend, target: c.WGPUTextureView, width: u32, height: u32, clear: ?paint.Color) DrawError!void {
        const encoder = c.wgpuDeviceCreateCommandEncoder(self.gpu.device, &.{}) orelse return error.SubmitFailed;
        defer c.wgpuCommandEncoderRelease(encoder);
        try self.encode(encoder, target, width, height, clear);
        const cmd = c.wgpuCommandEncoderFinish(encoder, &.{}) orelse return error.SubmitFailed;
        defer c.wgpuCommandBufferRelease(cmd);
        c.wgpuQueueSubmit(self.gpu.queue, 1, &cmd);
    }

    /// Grow the vertex buffer to the next power of two that holds `bytes` (never shrinks:
    /// a UI's frames are all about the same size, and reallocating each frame is waste).
    fn ensureVertexCapacity(self: *WgpuBackend, bytes: usize) DrawError!void {
        if (self.vertex_buf != null and self.vertex_buf_cap >= bytes) return;
        const cap = std.math.ceilPowerOfTwo(u64, @max(bytes, 64 * 1024)) catch return error.OutOfGpuMemory;
        const buf = c.wgpuDeviceCreateBuffer(self.gpu.device, &.{
            .label = sv("zicro uber2d vertices"),
            .usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
            .size = cap,
        }) orelse return error.OutOfGpuMemory;
        if (self.vertex_buf) |old| c.wgpuBufferRelease(old);
        self.vertex_buf = buf;
        self.vertex_buf_cap = cap;
    }
};

fn sv(s: []const u8) c.WGPUStringView {
    return .{ .data = s.ptr, .length = s.len };
}

/// The 2D ubershader, WGSL. A port of the WebGL2 page's, mode for mode, so the browser's
/// GPU path and this one draw the same pixels from the same vertex stream:
///   0 rounded-rect fill · 1 rounded-rect stroke (SDF) · 2 atlas RGBA × colour (icons)
///   3 plain quad (segments) · 4 atlas coverage in alpha, tinted (glyphs, masks)
/// Positions arrive in pixels with a top-left origin; `res` maps them to clip space.
const uber_wgsl =
    \\struct Res { size: vec2f, pad: vec2f };
    \\@group(0) @binding(0) var<uniform> res: Res;
    \\@group(0) @binding(1) var atlas: texture_2d<f32>;
    \\@group(0) @binding(2) var samp: sampler;
    \\
    \\struct VIn {
    \\  @location(0) a0: vec4f, @location(1) a1: vec4f, @location(2) a2: vec4f,
    \\  @location(3) a3: vec4f, @location(4) a4: vec4f, @location(5) a5: vec3f,
    \\};
    \\struct VOut {
    \\  @builtin(position) pos: vec4f,
    \\  @location(0) p: vec2f, @location(1) uv: vec2f, @location(2) col: vec4f,
    \\  @location(3) rect: vec4f, @location(4) corners: vec4f,
    \\  @location(5) mode: vec2f, @location(6) clip: vec4f,
    \\};
    \\
    \\@vertex fn vs_main(i: VIn) -> VOut {
    \\  var o: VOut;
    \\  o.p = i.a0.xy; o.uv = i.a0.zw; o.col = i.a1; o.rect = i.a2; o.corners = i.a3;
    \\  o.mode = i.a4.xy; o.clip = vec4f(i.a4.z, i.a4.w, i.a5.x, i.a5.y);
    \\  let c = (i.a0.xy / res.size) * 2.0 - 1.0;
    \\  o.pos = vec4f(c.x, -c.y, 0.0, 1.0);
    \\  return o;
    \\}
    \\
    \\fn sdRR(p: vec2f, c: vec2f, h: vec2f, r: vec4f) -> f32 {
    \\  let d = p - c;
    \\  var rad: f32;
    \\  if (d.x > 0.0) { rad = select(r.y, r.z, d.y > 0.0); } else { rad = select(r.x, r.w, d.y > 0.0); }
    \\  let q = abs(d) - h + rad;
    \\  return min(max(q.x, q.y), 0.0) + length(max(q, vec2f(0.0))) - rad;
    \\}
    \\
    \\@fragment fn fs_main(i: VOut) -> @location(0) vec4f {
    \\  let t = textureSampleLevel(atlas, samp, i.uv, 0.0);
    \\  if (i.clip.x >= 0.0) {
    \\    if (i.p.x < i.clip.x || i.p.y < i.clip.y || i.p.x > i.clip.z || i.p.y > i.clip.w) { discard; }
    \\  }
    \\  let m = i.mode.x;
    \\  var o: vec4f;
    \\  if (m < 0.5) {
    \\    let d = sdRR(i.p, i.rect.xy, i.rect.zw, i.corners);
    \\    o = vec4f(i.col.rgb, i.col.a * clamp(0.5 - d, 0.0, 1.0));
    \\  } else if (m < 1.5) {
    \\    let d = sdRR(i.p, i.rect.xy, i.rect.zw, i.corners);
    \\    // Centred on the edge, `stroke` wide — the CPU canvas's ring (|d| - stroke/2).
    \\    o = vec4f(i.col.rgb, i.col.a * clamp(0.5 - (abs(d) - 0.5 * i.mode.y), 0.0, 1.0));
    \\  } else if (m < 2.5) {
    \\    o = t * i.col;
    \\  } else if (m < 3.5) {
    \\    o = i.col;
    \\  } else {
    \\    o = vec4f(i.col.rgb, i.col.a * t.a);
    \\  }
    \\  if (o.a <= 0.003) { discard; }
    \\  return o;
    \\}
;

// ── GPU tests: draw, read back, compare with the CPU canvas ─────────────────────────
//
// The point of these is the one the scaffold this replaced could not pass: the pixels
// have to come out of the GPU. Each scene is drawn twice — by `paint.Canvas` on the CPU
// and by this backend on whatever device the machine has — and the two images compared.

const Readback = struct {
    tex: c.WGPUTexture,
    view: c.WGPUTextureView,
    buf: c.WGPUBuffer,
    w: u32,
    h: u32,
    const fmt = c.WGPUTextureFormat_RGBA8Unorm;

    fn init(gpu: *Gpu, w: u32, h: u32) !Readback {
        std.debug.assert((w * 4) % 256 == 0); // copy rows must be 256-byte aligned
        const tex = c.wgpuDeviceCreateTexture(gpu.device, &.{
            .usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = w, .height = h, .depthOrArrayLayers = 1 },
            .format = fmt,
            .mipLevelCount = 1,
            .sampleCount = 1,
        }) orelse return error.OutOfGpuMemory;
        const buf = c.wgpuDeviceCreateBuffer(gpu.device, &.{
            .usage = c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst,
            .size = @as(u64, w) * h * 4,
        }) orelse return error.OutOfGpuMemory;
        return .{ .tex = tex, .view = c.wgpuTextureCreateView(tex, null).?, .buf = buf, .w = w, .h = h };
    }

    fn deinit(r: *Readback) void {
        c.wgpuBufferRelease(r.buf);
        c.wgpuTextureViewRelease(r.view);
        c.wgpuTextureRelease(r.tex);
    }

    const Mapped = struct { done: bool = false, ok: bool = false };
    fn onMapped(status: c.WGPUMapAsyncStatus, _: c.WGPUStringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const m: *Mapped = @ptrCast(@alignCast(ud1.?));
        m.done = true;
        m.ok = status == c.WGPUMapAsyncStatus_Success;
    }

    /// Copy the target into the map buffer and read it out as RGBA8, `out.len == w*h*4`.
    fn read(r: *Readback, gpu: *Gpu, out: []u8) !void {
        const enc = c.wgpuDeviceCreateCommandEncoder(gpu.device, &.{}).?;
        defer c.wgpuCommandEncoderRelease(enc);
        c.wgpuCommandEncoderCopyTextureToBuffer(
            enc,
            &.{ .texture = r.tex, .mipLevel = 0, .origin = .{ .x = 0, .y = 0, .z = 0 }, .aspect = c.WGPUTextureAspect_All },
            &.{ .layout = .{ .offset = 0, .bytesPerRow = r.w * 4, .rowsPerImage = r.h }, .buffer = r.buf },
            &.{ .width = r.w, .height = r.h, .depthOrArrayLayers = 1 },
        );
        const cmd = c.wgpuCommandEncoderFinish(enc, &.{}).?;
        defer c.wgpuCommandBufferRelease(cmd);
        c.wgpuQueueSubmit(gpu.queue, 1, &cmd);

        var m: Mapped = .{};
        const size: usize = @as(usize, r.w) * r.h * 4;
        _ = c.wgpuBufferMapAsync(r.buf, c.WGPUMapMode_Read, 0, size, .{
            .mode = c.WGPUCallbackMode_AllowProcessEvents,
            .callback = onMapped,
            .userdata1 = &m,
        });
        var spins: usize = 0;
        while (!m.done and spins < 100_000) : (spins += 1) c.wgpuInstanceProcessEvents(gpu.instance);
        if (!m.ok) return error.MapFailed;
        const p: [*]const u8 = @ptrCast(c.wgpuBufferGetConstMappedRange(r.buf, 0, size).?);
        @memcpy(out, p[0..size]);
        c.wgpuBufferUnmap(r.buf);
    }
};

/// Draw `scene` on both backends at `w`×`h` and return how many pixels differ by more
/// than `tol` in any channel. `gpu_px`/`cpu_px` receive the two images (RGBA8).
fn drawBoth(gpu: *Gpu, w: u32, h: u32, scene: *const fn (*paint.Canvas) void, gpu_px: []u8, cpu_px: []u8, tol: u8) !usize {
    const gpa = std.testing.allocator;

    // CPU: straight RGBA8, the same byte layout the GPU target reads back in.
    const cpu = try gpa.alloc(u32, @as(usize, w) * h);
    defer gpa.free(cpu);
    @memset(cpu, 0xFF00_0000); // opaque black (R,G,B,A bytes = 0,0,0,255 little-endian)
    var cv = paint.Canvas.initRgba8(cpu, w, h);
    scene(&cv);
    @memcpy(cpu_px, std.mem.sliceAsBytes(cpu));

    var be: WgpuBackend = undefined;
    try be.init(gpu, gpa, Readback.fmt);
    defer be.deinit();
    var rb = try Readback.init(gpu, w, h);
    defer rb.deinit();
    var gv = paint.Canvas.initRgba8(cpu, w, h); // pixels unused: every primitive records
    gv.gl = &be.iface;
    scene(&gv);
    try std.testing.expect(be.vertexCount() > 0);
    try be.submit(rb.view, w, h, .{ .r = 0, .g = 0, .b = 0, .a = 1 });
    try rb.read(gpu, gpu_px);

    var bad: usize = 0;
    var i: usize = 0;
    while (i < gpu_px.len) : (i += 4) {
        for (0..3) |k| {
            const d = @abs(@as(i16, gpu_px[i + k]) - @as(i16, cpu_px[i + k]));
            if (d > tol) {
                bad += 1;
                break;
            }
        }
    }
    return bad;
}

fn testGpu() !Gpu {
    return init(null) catch |e| {
        std.debug.print("wgpu: no device ({s}) — skipping\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
}

fn px(img: []const u8, w: u32, x: u32, y: u32) [4]u8 {
    const o = (@as(usize, y) * w + x) * 4;
    return img[o..][0..4].*;
}

const shapes_scene = struct {
    fn draw(cv: *paint.Canvas) void {
        cv.fillRoundedRect(8, 8, 48, 40, 10, .{ .r = 1, .g = 0, .b = 0, .a = 1 });
        cv.strokeRoundedRect(4, 52, 56, 10, 4, 2, .{ .r = 0, .g = 1, .b = 0, .a = 1 });
        cv.fillRoundedRect(20, 20, 24, 16, 0, .{ .r = 0, .g = 0, .b = 1, .a = 0.5 });
    }
}.draw;

test "WgpuBackend draws shapes the CPU canvas draws" {
    var gpu = try testGpu();
    defer gpu.deinit();
    const w = 64;
    const h = 64;
    var g: [w * h * 4]u8 = undefined;
    var k: [w * h * 4]u8 = undefined;
    const bad = try drawBoth(&gpu, w, h, shapes_scene, &g, &k, 40);

    // Not "a vertex count came out" — the pixels: red inside the rect, black outside,
    // the half-alpha blue blended over red, the green stroke band.
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, px(&g, w, 12, 40));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, px(&g, w, 1, 1));
    const mixed = px(&g, w, 30, 28);
    try std.testing.expect(mixed[0] > 100 and mixed[0] < 160 and mixed[2] > 100 and mixed[2] < 160);
    try std.testing.expect(px(&g, w, 30, 51)[1] > 200); // the ring straddles y = 52: half outside
    try std.testing.expect(px(&g, w, 30, 52)[1] > 200);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, px(&g, w, 30, 56)); // inside the ring: untouched
    // And the two backends agree everywhere but a thin anti-aliased rim.
    try std.testing.expect(bad < w * h / 50);
}

const mask_scene = struct {
    // A static 8×8 RGBA mask (a filled square with a 1px clear border): the atlas keys
    // bitmaps by address, which this keeps stable for the whole test binary.
    const mask: [8 * 8 * 4]u8 = blk: {
        var m: [8 * 8 * 4]u8 = @splat(0);
        for (1..7) |y| for (1..7) |x| {
            m[(y * 8 + x) * 4 + 3] = 255;
        };
        break :blk m;
    };
    const icon: [2 * 2 * 4]u8 = .{ 255, 255, 0, 255, 255, 255, 0, 255, 255, 255, 0, 255, 255, 255, 0, 255 };
    fn draw(cv: *paint.Canvas) void {
        cv.blitMask(4, 4, 8, 8, &mask, 8, 8, .{ .r = 0, .g = 1, .b = 1, .a = 1 });
        cv.blitImage(40, 40, 16, 16, &icon, 2, 2);
        // The scissor: half of this rect falls outside it and must not appear.
        const prev = cv.setClip(0, 0, 32, 64);
        cv.fillRoundedRect(24, 24, 16, 8, 0, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
        cv.clip = prev;
    }
}.draw;

test "WgpuBackend samples the atlas (masks, icons) and honours the clip" {
    var gpu = try testGpu();
    defer gpu.deinit();
    const w = 64;
    const h = 64;
    var g: [w * h * 4]u8 = undefined;
    var k: [w * h * 4]u8 = undefined;
    const bad = try drawBoth(&gpu, w, h, mask_scene, &g, &k, 40);

    try std.testing.expectEqual([4]u8{ 0, 255, 255, 255 }, px(&g, w, 8, 8)); // mask, tinted
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, px(&g, w, 4, 4)); // its clear border
    try std.testing.expectEqual([4]u8{ 255, 255, 0, 255 }, px(&g, w, 48, 48)); // icon, scaled
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, px(&g, w, 28, 28)); // inside the clip
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, px(&g, w, 36, 28)); // clipped away
    try std.testing.expect(bad < w * h / 50);
}

test "WgpuBackend keeps the atlas across frames and re-records only vertices" {
    var gpu = try testGpu();
    defer gpu.deinit();
    var be: WgpuBackend = undefined;
    try be.init(&gpu, std.testing.allocator, Readback.fmt);
    defer be.deinit();
    var rb = try Readback.init(&gpu, 64, 64);
    defer rb.deinit();
    var scratch: [64 * 64]u32 = undefined;
    var out: [64 * 64 * 4]u8 = undefined;
    for (0..3) |frame| {
        be.reset();
        var cv = paint.Canvas.initRgba8(&scratch, 64, 64);
        cv.gl = &be.iface;
        mask_scene(&cv);
        // After the first frame nothing new enters the atlas: no rows to upload.
        if (frame > 0) try std.testing.expect(be.recorder.dirtyHi() <= be.recorder.dirtyLo());
        try be.submit(rb.view, 64, 64, .{ .r = 0, .g = 0, .b = 0, .a = 1 });
        try rb.read(&gpu, &out);
        try std.testing.expectEqual([4]u8{ 0, 255, 255, 255 }, px(&out, 64, 8, 8));
    }
}
