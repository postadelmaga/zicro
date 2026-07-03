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
pub const input = @import("input.zig");
pub const video = @import("video.zig");
pub const audio = @import("audio.zig");
pub const bridge = @import("bridge.zig");

// -- out-of-process transports (the Rust `ipc` feature of micro-bus)
pub const ipc = @import("ipc.zig");
pub const shmem = @import("shmem.zig");

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

const sync = @import("sync.zig");

test {
    _ = sync;
    _ = @import("pool.zig");
    _ = protocol;
    _ = bus;
    _ = document;
    _ = core;
    _ = app;
    _ = media;
    _ = @import("media_types.zig");
    _ = time;
    _ = input;
    _ = video;
    _ = audio;
    _ = bridge;
    _ = ipc;
    _ = shmem;
}
