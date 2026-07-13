//! Minimal `zicro` surface for the `wasm32-freestanding` web target: the pure-Zig
//! software canvas plus the stb_truetype text engine. The full root (bus, threads,
//! std.Io, the Wayland/Win32 windows) is meaningless — and uncompilable — on a
//! single-threaded wasm page, so the web build imports THIS as its "zicro" module
//! instead of `root.zig`.
//!
//! `text` pulls stb_truetype (C); the freestanding libc shims it needs live in
//! `wasm_shim.zig` (referenced below so its `export`s are emitted into the module).

pub const paint = @import("paint.zig");
pub const paint_gl = @import("paint_gl.zig");
pub const text = @import("text.zig");
/// Wayland client bindings — pulled in only for the keycode/cursor CONSTANTS the panels
/// reference (`wl.KEYBOARD_KEY_STATE_*`, cursor shapes); the extern libwayland functions
/// are never called on wasm, so they stay unresolved-but-harmless (lazy analysis).
pub const wl = @import("wl.zig");
pub const anim = @import("anim.zig");
pub const keymap = @import("keymap.zig");
pub const scroll = @import("scroll.zig");
/// The immediate-mode widget toolkit — the whole point of the web port: the same
/// button/checkbox/toggle/slider/dropdown/textField that run natively, in a canvas.
pub const widget = @import("widget.zig");
/// The web `Window` backend: the same `on_draw`/`on_key`/`on_mouse` contract as the
/// native windows, with the browser driving the loop. `zicro.window.Window` on the web.
pub const window = @import("window_web.zig");
/// Recognizer gesti multi-touch (pinch, …) condiviso dai backend. Stessa superficie del
/// root nativo così `zicro.gesture` risolve su wasm.
pub const gesture = @import("gesture.zig");
/// Golden-ratio design constants — the substrate's default proportion (used by zrame's
/// responsive metrics). Same surface as the native root so `zicro.phi` resolves on wasm.
pub const proportion = @import("proportion.zig");
pub const phi = proportion.phi;

comptime {
    _ = @import("wasm_shim.zig"); // keep zig_malloc/zig_free/zig_pow/… in the link
}
