//! Minimal `zrame` surface for the `aarch64-linux-android` app build: the window (via the
//! NDK backend) + panels + drawing types, WITHOUT the Linux transport (Wayland, sd-bus
//! tray, dbusmenu, the dmabuf sink). Mirrors `web_root.zig` for the Android target.

const zicro = @import("zicro");

pub const paint = zicro.paint;
pub const text = zicro.text;
pub const widget = zicro.widget;
pub const density = zicro.density; // compact / regular / touch geometry presets
pub const keymap = zicro.keymap;
pub const clipboard = zicro.clipboard;
pub const proportion = zicro.proportion;
pub const phi = zicro.phi; // substrate golden ratio (default proportion)
/// The NDK glue struct (`android_app`) an `android_main` entry receives.
pub const android = zicro.android;

pub const window = @import("window.zig"); // facade → window_android on android
pub const plugin = @import("plugin.zig");
pub const controls = @import("controls.zig");
pub const menu = @import("menu.zig");
pub const scroll = @import("scroll.zig");

pub const Window = window.Window;
pub const Options = window.Options;
pub const Style = window.Style;
pub const Rect = window.Rect;
pub const MouseEvent = window.MouseEvent;
pub const Color = paint.Color;
pub const Canvas = paint.Canvas;
pub const Font = text.Font;
