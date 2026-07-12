//! Minimal `zicro` surface for the `wasm32-freestanding` web target: the pure-Zig
//! software canvas plus the stb_truetype text engine. The full root (bus, threads,
//! std.Io, the Wayland/Win32 windows) is meaningless — and uncompilable — on a
//! single-threaded wasm page, so the web build imports THIS as its "zicro" module
//! instead of `root.zig`.
//!
//! `text` pulls stb_truetype (C); the freestanding libc shims it needs live in
//! `wasm_shim.zig` (referenced below so its `export`s are emitted into the module).

pub const paint = @import("paint.zig");
pub const text = @import("text.zig");
pub const anim = @import("anim.zig");
pub const keymap = @import("keymap.zig");
/// The immediate-mode widget toolkit — the whole point of the web port: the same
/// button/checkbox/toggle/slider/dropdown/textField that run natively, in a canvas.
pub const widget = @import("widget.zig");
/// The web `Window` backend: the same `on_draw`/`on_key`/`on_mouse` contract as the
/// native windows, with the browser driving the loop. `zicro.window.Window` on the web.
pub const window = @import("window_web.zig");

comptime {
    _ = @import("wasm_shim.zig"); // keep zig_malloc/zig_free/zig_pow/… in the link
}
