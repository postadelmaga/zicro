<div align="center">

# ▢ zrame

**The window layer of the Frame architecture — a cross-platform window for
[zicro](../Zicro), in Zig.**

zicro deliberately stops at the `FrameSink` contract ("the actual GPU/window backend is
the app's job"). zrame is that backend, and it owns the OS: the app hands it a
premultiplied-ARGB frame and hooks `on_key` / `on_mouse` / `on_scroll`, and zrame does
whatever each platform needs to put a window on screen. On Linux that's a frameless
Wayland glass toplevel (rounded translucent chrome, drop shadow, real compositor blur);
on Windows it's a native decorated GDI window; macOS, the web and Android get thin
adapters over zicro's own window for that platform. Same public API everywhere —
**apps built on zrame don't know which OS they're running on.**

</div>

---

## Cross-platform by design

zrame (and [zicro](../Zicro) beneath it) exist so that **Frame apps stay OS-agnostic**.
The window is one type with a per-OS backend, selected at compile time — the same shape
zicro uses for its own `Window`:

| OS/target | backend               | how it presents                                             |
|-----------|------------------------|-------------------------------------------------------------|
| Linux     | `window_wayland.zig`   | frameless Wayland toplevel: client-side glass chrome, `ext-background-effect-v1` blur, sd-bus tray + KDE global menu, dmabuf zero-copy video |
| Windows   | `window_win32.zig`     | native decorated, resizable window; the composed ARGB frame blitted via GDI (`SetDIBitsToDevice`) |
| macOS     | `window_cocoa.zig`     | thin adapter delegating to zicro's own Cocoa `Window` backend — native decorations |
| Web       | `window_web.zig`       | thin adapter over zicro's wasm canvas backend; the glass chrome paints into the `<canvas>` |
| Android   | `window_android.zig`   | thin adapter over zicro's NDK `Window` backend               |

The whole compositing pipeline — chrome, panels (title bar, context menu, floating
scrollbars), fonts, animation — is pure-CPU and platform-independent (`composeFrame` is
the documented seam). Only the *transport* differs: how each backend acquires a writable
pixel buffer, pumps events, and presents. Input is normalized so callbacks are identical
everywhere — Win32 `VK` codes are translated to the same evdev keycodes Wayland emits,
wheel deltas to the same 1/256 axis units. Linux-desktop-only surfaces (tray, global
menu, compositor blur) degrade to no-ops where the OS has no equivalent.

---

## What you get

* **Frameless + transparent** — an `xdg_toplevel` with client-side chrome painted into a
  premultiplied ARGB `wl_shm` buffer. No titlebar, no border, alpha everywhere.
* **Real background blur** — via the standard `ext-background-effect-v1` protocol
  (KWin 6.4+, and any compositor that adopts it). The blur region is built scanline-by-
  scanline through the corner arcs, so the frost follows the rounded shape exactly.
* **Rounded corners & shadow, analytically** — the chrome is one signed-distance
  function: the panel is the SDF's anti-aliased coverage, the shadow is a smooth falloff
  of the same SDF (clipped to the outside so the glass stays clean), the 1 px highlight
  ring is its zero crossing. No textures, no GPU.
* **Honest window management** — xdg window geometry and the input region describe the
  *panel*, not the buffer: the shadow gutter doesn't catch clicks and doesn't count when
  the compositor tiles or snaps the window. Drag the title bar to move it, grab an edge to
  resize it, Esc closes it (raw evdev keycodes — apps hook `Options.on_key` / `on_scroll`).
* **Window controls & context menu** — an optional client-side title bar with modern,
  procedural controls in two layouts: macOS traffic-lights (glyphs reveal on hover) or
  Material right-aligned min/max/close. Right-click opens a glass context menu
  (Minimize / Maximize / Full Screen / Close). Minimize, maximize/restore and fullscreen
  are wired to the compositor; the glyphs are drawn from SDF strokes, no image assets.
* **Thin, fluid scrollbars** — a faithful port of egui's *floating* `ScrollArea`: bars
  invisible at rest, a 2 px thumb that fades in on hover and swells to 10 px, `cubic_out`
  fades, low-pass-smoothed mouse-wheel scrolling, linear kinetic friction, no overscroll.
* **A plugin seam, everything on it** — the title bar, context menu and scrollbars are all
  *panels*: `draw` + `onInput` + `tick` over the [`plugin.Panel`] contract, driven by an
  idle-friendly `timerfd` animation clock and routed input. The same contract loads as a
  POSIX `.so` at runtime (`Window.loadPlugin` / `loadPluginDir`, `std.DynLib`).
* **The zicro seam** — `WindowSink` implements zicro's `video.FrameSink`. A standard
  pipeline (producer module → `media.latest` → `VideoSink` module) presents straight
  into the panel; `Window.presentRgba` is the single thread-safe door (staging buffer +
  eventfd wake), so no Wayland object is ever touched off the window thread.
* **A system-tray icon** — an optional `StatusNotifierItem` (KDE/freedesktop tray) over
  **sd-bus**, hand-declared FFI in the same spirit as the Wayland glue. Set `Options.tray`
  and the item registers with the tray host; its socket is polled alongside Wayland, so it
  costs nothing at rest. Left-click (`Activate`) calls back on the window thread. (The
  `com.canonical.dbusmenu` right-click menu is the next slice — see the Phase 6 issue.)

## Layout

The `wl`, `paint`, `paint_gl`, `text` and `widget` modules are inherited from zicro
(`zicro.wl` / `zicro.paint` / …) rather than duplicated here — every Wayland protocol
table (xdg-shell, ext-background-effect, cursor-shape, dmabuf, viewporter,
fractional-scale, appmenu…) is generated once, by zicro's `build.zig`. What lives in
`src/`:

```
src/
  window.zig       the public facade (Options/MouseEvent/Style) + per-OS backend dispatch
  window_wayland.zig / window_win32.zig / window_cocoa.zig / window_web.zig / window_android.zig
                   the five backends — Wayland/Win32 own their transport; the other three
                   are thin adapters over zicro's native window for that OS
  chrome.zig       shared composition: the cross-thread frame mailbox, glass panel + content blit
  plugin.zig       the extension seam: Panel / Registry / Host, and the dlopen loader
  ui.zig           shared widget math (frame-rate-independent fades, easing)
  controls.zig     title-bar window controls panel (macOS traffic-lights / Material)
  menu.zig         glass context-menu panel
  scroll.zig       floating scrollbar panel (egui parity)
  sink.zig         zicro video.FrameSink adapter
  runtime.zig      poll(2) event loop for windowless Linux apps (tray/menu only)
  tray.zig / dbusmenu.zig / sdbus.zig / xkb.zig
                   Linux-desktop-only integrations (tray icon, KDE global menu, DBus FFI,
                   keyboard layout), used only by the Wayland backend
```

## Try it

```sh
zig build test         # unit tests (SDF, panel routing, scroll math, easing)
zig build run-hello    # four styled glass windows with title-bar controls, drag/resize
zig build run-frames   # 60 Hz plasma in the animated border band; Space cycles presets
zig build run-scroll   # a long list with the thin fluid scrollbars
zig build run-plugin   # a window that dlopens libzrame_clock.so and runs its panel
zig build run-tray     # a bare system-tray icon; left-click prints "activated"
```

Requirements: Linux + Wayland, `libwayland-client`, `wayland-scanner`,
`wayland-protocols` ≥ 1.41 (for `ext-background-effect-v1`), Zig 0.17.

> **No blur?** The window still works — translucent, rounded, shadowed — but the frost
> needs the compositor's blur effect. On KDE Plasma it must be enabled: System Settings →
> Desktop Effects → *Blur*, or one-off: `qdbus6 org.kde.KWin /Effects
> org.kde.kwin.Effects.loadEffect blur`. `Window.hasBlur()` tells you whether the
> protocol is present.

## Design notes

* **Latest-wins everywhere.** The present path mirrors zicro's media plane: a staged
  frame overwrites the previous unshown one, the window loop coalesces wakeups, a busy
  double buffer drops the frame rather than blocking. A slow compositor never stalls a
  producer.
* **Chrome is cached.** The SDF raster runs once per resize into a decor cache; a frame
  present is a `memcpy` + masked blit, cheap enough for 60 Hz in Debug builds.
* **Panels animate off one clock.** A `timerfd` is armed only while a panel reports it's
  still animating (`tick` returns true) and disarmed the moment everything settles, so an
  idle window's `poll` blocks indefinitely — no busy-loop for a static frame.
* **HiDPI is wired.** `wp_fractional_scale_v1` + `wp_viewporter` report the compositor's
  preferred scale; the buffer renders at physical resolution and the viewport presents it
  at logical size, so text and chrome stay crisp on fractional scaling. The system tray
  (StatusNotifierItem) and the `com.canonical.dbusmenu` KDE global menu have both landed —
  icon, tooltip, left-click `Activate`, and the appmenu Wayland handshake that tells KWin
  where to find the menu's DBus object.

---

<sub>Part of the Frame architecture: Micro 🦀 → zicro ⚡ → zrame ▢.</sub>

---

## License

`zrame` is **dual-licensed** — pick the one that fits you:

- **Open source** · GNU **AGPL v3.0** (see [`LICENSE`](LICENSE)). Free to use, study and
  modify, but derivative works — **including services offered over a network** — must also be
  released under the AGPLv3 with complete source available.
- **Commercial** · for use in a **proprietary / closed-source** product, without the AGPL
  copyleft, buy a commercial license from the author. See [`LICENSING.md`](LICENSING.md) —
  contact **Francesco Magazzù** <postadelmaga@gmail.com>.

© 2026 Francesco Magazzù.
