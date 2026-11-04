//! Minimal `zrame` surface for the `wasm32-freestanding` web target: the glass window
//! (via the web backend) + the panels + the drawing types, WITHOUT the Linux transport
//! (Wayland, sd-bus tray, dbusmenu, the dmabuf sink). The full `root.zig` pulls those in
//! and can't compile on a wasm page; a browser app only needs the platform-independent
//! window/chrome/widget stack, which is exactly this.

const zicro = @import("zicro");

pub const paint = zicro.paint;
pub const paint_gl = zicro.paint_gl;
pub const text = zicro.text;
pub const widget = zicro.widget;
pub const density = zicro.density; // compact / regular / touch geometry presets
pub const keymap = zicro.keymap;
pub const proportion = zicro.proportion;
pub const phi = zicro.phi; // substrate golden ratio (default proportion)
pub const clipboard = zicro.clipboard; // substrate clipboard (opaque blob + tag)

pub const window = @import("window.zig"); // facade → wasm branch → window_web
pub const plugin = @import("plugin.zig");
pub const controls = @import("controls.zig");
pub const menu = @import("menu.zig");
pub const scroll = @import("scroll.zig");

pub const Window = window.Window;
pub const Options = window.Options;
pub const Style = window.Style;
pub const Rect = window.Rect;
pub const MouseEvent = window.MouseEvent;
pub const TitlebarStyle = window.TitlebarStyle;
pub const Color = paint.Color;
pub const Canvas = paint.Canvas;
pub const Font = text.Font;
pub const Panel = plugin.Panel;
pub const Host = plugin.Host;
