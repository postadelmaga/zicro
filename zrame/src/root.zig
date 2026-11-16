//! # zrame — the window layer of the Frame architecture
//!
//! zicro owns platform transport (windowing, input, the CPU/GL canvas, text, widgets);
//! zrame picks up from there with the glass chrome, the panel stack and the cross-thread
//! frame mailbox:
//!
//! | file            | role                                                              |
//! |-----------------|--------------------------------------------------------------------|
//! | `window.zig`    | the public facade (`Options`/`Style`/`VideoFit`) + per-OS dispatch |
//! | `window_*.zig`  | the adapters over zicro's window: `window_native` (Wayland + Win32), Cocoa, web, Android |
//! | `chrome.zig`    | shared composition: the frame mailbox, glass panel + content blit |
//! | `plugin.zig`    | the `Panel`/`Host`/`Registry` extension seam (title bar, menu, scrollbars, dlopen plugins) |
//! | `sink.zig`      | zicro `video.FrameSink` adapter                                  |
//! | `sdbus.zig`/`tray.zig`/`dbusmenu.zig` | Linux-desktop-only integrations, Wayland backend only |
//!
//! zrame publishes only what it adds. The substrate — `paint` (Canvas, Color), `text`
//! (Font), `widget`, `keymap`, `wl` (evdev codes), `scroll`, `anim` — is imported from
//! `zicro` itself: one name per thing across the stack.
//!
//! One root for every target: the Linux-only modules (`tray`, `dbusmenu`, `sdbus`,
//! `runtime`, `sink`) are analyzed only when used, so a web or Android app imports this
//! same file and simply never touches them.

pub const window = @import("window.zig");
pub const sink = @import("sink.zig");
pub const plugin = @import("plugin.zig");
pub const controls = @import("controls.zig");
pub const menu = @import("menu.zig");
pub const scroll = @import("scroll.zig");
pub const sdbus = @import("sdbus.zig");
pub const tray = @import("tray.zig");
pub const dbusmenu = @import("dbusmenu.zig");
pub const runtime = @import("runtime.zig");
pub const widgets = @import("widgets.zig");

pub const Window = window.Window;
pub const Options = window.Options;
pub const Style = window.Style;
pub const Rect = window.Rect;
pub const MouseEvent = window.MouseEvent;
pub const WindowSink = sink.WindowSink;
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
