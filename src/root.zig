//! # zicro — the minimal, generic core of the Frame architecture, in Zig
//!
//! A port of **Micro** (Rust): a tiny modules + bus micro-kernel — a string-named
//! pub/sub bus, a generic undoable document, an in-process module runtime — plus the
//! opinionated `sources → world → sinks` framework layered on top: time, input, video,
//! audio, a zero-copy media plane, and a bus-over-byte-stream bridge.
//!
//! Layout mirrors the Rust workspace, one file per crate:
//!
//! | Rust crate       | Zig namespace     |
//! |------------------|-------------------|
//! | `micro-protocol` | [`protocol`]      |
//! | `micro-bus`      | [`bus`]           |
//! | `micro-document` | [`document`]      |
//! | `micro-core`     | [`core`]          |
//! | `micro-app`      | [`app`]           |
//! | `micro-media`    | [`media`]         |
//! | `micro-time`     | [`time`]          |
//! | `micro-input`    | [`input`]         |
//! | `micro-video`    | [`video`]         |
//! | `micro-audio`    | [`audio`]         |
//! | `micro-bridge`   | [`bridge`]        |

// -- the micro-kernel: generic, zero domain
pub const protocol = @import("protocol.zig");
pub const bus = @import("bus.zig");
pub const document = @import("document.zig");
pub const core = @import("core.zig");

// -- the framework: opinionated sources → world → sinks, built only on the kernel
pub const app = @import("app.zig");
pub const media = @import("media.zig");
pub const time = @import("time.zig");
pub const anim = @import("anim.zig");
pub const input = @import("input.zig");
pub const video = @import("video.zig");
pub const audio = @import("audio.zig");
pub const audio_device = @import("audio_device.zig");
pub const audio_pipeline = @import("audio_pipeline.zig");
pub const bridge = @import("bridge.zig");

// -- graphics and windowing layer (Wayland/Win32)
pub const wl = @import("wl.zig");
pub const text = @import("text.zig");
pub const paint = @import("paint.zig");
pub const paint_gl = @import("paint_gl.zig");
pub const scroll = @import("scroll.zig");
pub const widget = @import("widget.zig");
pub const keymap = @import("keymap.zig");
pub const window = @import("window.zig");
pub const gesture = @import("gesture.zig");
pub const proportion = @import("proportion.zig");

// -- out-of-process transports (the Rust `ipc` feature of micro-bus)
pub const ipc = @import("ipc.zig");
pub const shmem = @import("shmem.zig");

// -- GPU memory: autonomous, format-agnostic, API-bindable
pub const gpu_memory = @import("gpu_memory.zig");
pub const gpu_vulkan = @import("gpu_vulkan.zig");
pub const gpu_wgpu_bridge_ffi = @import("gpu_wgpu_bridge_ffi.zig");

// -- the short names an app usually wants
pub const Envelope = protocol.Envelope;
pub const Topic = protocol.Topic;
pub const LocalBus = bus.LocalBus;
pub const Doc = document.Doc;
pub const History = document.History;
pub const Module = core.Module;
pub const ModuleCtx = core.ModuleCtx;
pub const Runtime = core.Runtime;
pub const App = app.App;
pub const WorldModule = app.WorldModule;

/// The golden ratio, φ — the substrate's default proportion (see `proportion`).
pub const phi = proportion.phi;

const sync = @import("sync.zig");

test {
    _ = sync;
    _ = @import("pool.zig");
    _ = @import("rc.zig");
    _ = @import("message.zig");
    _ = @import("inbox.zig");
    _ = @import("worker_pool.zig");
    _ = protocol;
    _ = bus;
    _ = document;
    _ = core;
    _ = app;
    _ = media;
    _ = @import("media_types.zig");
    _ = time;
    _ = anim;
    _ = scroll;
    _ = input;
    _ = video;
    _ = audio;
    _ = audio_device;
    _ = audio_pipeline;
    _ = bridge;
    _ = ipc;
    _ = shmem;
    _ = gpu_memory;
    _ = gpu_vulkan;
    _ = gpu_wgpu_bridge_ffi;
    _ = text;
    _ = paint;
    _ = widget;
    _ = keymap;
    _ = window;
    _ = gesture;
    _ = proportion;
}
