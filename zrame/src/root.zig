//! # zrame — the window layer of the Frame architecture
//!
//! zicro owns platform transport (windowing, input, the CPU/GL canvas); zrame picks up
//! from there with the chrome, panel stack, and multi-backend facade:
//!
//! | file            | role                                                              |
//! |-----------------|--------------------------------------------------------------------|
//! | `window.zig`    | the public facade (`Options`/`MouseEvent`/`Style`) + per-OS dispatch |
//! | `window_*.zig`  | the five backends (Wayland/Win32/Cocoa/web/Android), thin adapters over zicro's window |
//! | `chrome.zig`    | shared composition: the frame mailbox, glass panel + content blit |
//! | `plugin.zig`    | the `Panel`/`Host`/`Registry` extension seam (title bar, menu, scrollbars, dlopen plugins) |
//! | `sink.zig`      | zicro `video.FrameSink` adapter                                  |
//! | `sdbus.zig`/`tray.zig`/`dbusmenu.zig` | Linux-desktop-only integrations, Wayland backend only |
//!
//! `wl.zig`/`paint.zig`/`paint_gl.zig`/`text.zig`/`widget.zig` are re-exports of zicro's
//! own modules (below) — zrame reuses the substrate rather than duplicating it.

const zicro = @import("zicro");
pub const wl = zicro.wl;
pub const paint = zicro.paint;
pub const paint_gl = zicro.paint_gl;
pub const window = @import("window.zig");
pub const sink = @import("sink.zig");
pub const text = zicro.text;
pub const plugin = @import("plugin.zig");
pub const ui = @import("ui.zig");
pub const controls = @import("controls.zig");
pub const menu = @import("menu.zig");
pub const scroll = @import("scroll.zig");
pub const sdbus = @import("sdbus.zig");
pub const tray = @import("tray.zig");
pub const dbusmenu = @import("dbusmenu.zig");
pub const runtime = @import("runtime.zig");
// The immediate-mode toolkit lives in zicro (it only needs paint/text/anim and the
// normalized input events); re-exported so zrame apps keep their spelling.
pub const widget = zicro.widget;
pub const density = zicro.density; // compact / regular / touch geometry presets
pub const keymap = zicro.keymap;
pub const proportion = zicro.proportion;
pub const phi = zicro.phi; // substrate's golden ratio (proportion default)
pub const clipboard = zicro.clipboard; // substrate's generic clipboard (opaque blob + tag)
pub const widgets = @import("widgets.zig");

pub const Window = window.Window;
pub const Options = window.Options;
pub const Style = window.Style;
pub const Rect = window.Rect;
pub const MouseEvent = window.MouseEvent;
pub const Color = paint.Color;
pub const Canvas = paint.Canvas;
pub const WindowSink = sink.WindowSink;
pub const Font = text.Font;
pub const TextStyle = text.Style;
pub const TextOpts = paint.TextOpts;
pub const Panel = plugin.Panel;
pub const Host = plugin.Host;
pub const TitlebarStyle = window.TitlebarStyle;
pub const Registry = plugin.Registry;
pub const Event = plugin.Event;
pub const Action = plugin.Action;
pub const Info = plugin.Info;
pub const Widgets = widgets.Widgets;
// Named EventLoop, not Runtime: zicro already has a `Runtime` (the threaded module
// host over the pub/sub bus) — a same-named, unrelated type one import away was a
// naming trap for apps that use both modules.
pub const EventLoop = runtime.EventLoop;

test {
    @import("std").testing.refAllDecls(@This());
}
