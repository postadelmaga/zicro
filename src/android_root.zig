//! Minimal `zicro` surface for the `aarch64-linux-android` app build: the CPU canvas +
//! text + widgets + the window facade (which resolves to the NDK backend on android).
//! The full `root.zig` pulls in ALSA audio, /dev/shm and the Wayland stack — none of which
//! exist on Android — so the APK build imports THIS as its "zicro" module. Android has a
//! real libc (bionic), so unlike the wasm build the native stb_truetype compiles as-is.
//!
//! The re-export list is guarded: the comptime block below checks it against
//! `root.zig`'s `substrate_decls`, so a portable module added to the native root cannot
//! be forgotten here without breaking `zig build android`.

pub const paint = @import("paint.zig");
pub const paint_gl = @import("paint_gl.zig");
pub const theme = @import("theme.zig");
pub const text = @import("text.zig");
pub const anim = @import("anim.zig");
pub const keymap = @import("keymap.zig");
pub const scroll = @import("scroll.zig");
pub const gesture = @import("gesture.zig");
/// Wayland client bindings — only for the keycode/cursor CONSTANTS the panels reference;
/// the extern libwayland functions are never called on android (lazy analysis).
pub const wl = @import("wl.zig");
pub const clipboard = @import("clipboard.zig");
pub const proportion = @import("proportion.zig");
pub const phi = proportion.phi;
pub const widget = @import("widget.zig");
pub const window = @import("window.zig"); // facade → window_android on android
/// The NDK backend module — exposes `android_app` for an app's `android_main` entry.
pub const android = @import("window_android.zig");

comptime {
    // Parity guard: the portable substrate list lives once, in root.zig.
    for (@import("root.zig").substrate_decls) |name|
        if (!@hasDecl(@This(), name)) @compileError("android_root.zig forgot to re-export '" ++ name ++ "'");
}
