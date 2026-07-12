//! Minimal `zicro` surface for the `aarch64-linux-android` app build: the CPU canvas +
//! text + widgets + the window facade (which resolves to the NDK backend on android).
//! The full `root.zig` pulls in ALSA audio, /dev/shm and the Wayland stack — none of which
//! exist on Android — so the APK build imports THIS as its "zicro" module. Android has a
//! real libc (bionic), so unlike the wasm build the native stb_truetype compiles as-is.

pub const paint = @import("paint.zig");
pub const text = @import("text.zig");
pub const anim = @import("anim.zig");
pub const keymap = @import("keymap.zig");
pub const scroll = @import("scroll.zig");
pub const wl = @import("wl.zig");
pub const widget = @import("widget.zig");
pub const window = @import("window.zig"); // facade → window_android on android
/// The NDK backend module — exposes `android_app` for an app's `android_main` entry.
pub const android = @import("window_android.zig");
