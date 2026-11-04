//! # zrame.plugin — the extension seam
//!
//! Everything interactive in zrame — the title-bar controls, the context menu, the
//! scrollbars — is a *panel*: a thing the window draws over its content, routes input
//! to, and ticks once per animation frame. The window owns a [`Registry`] of panels
//! and knows nothing about what any of them do; a panel reaches back to the window only
//! through the narrow [`Host`] interface (minimize/close/resize/geometry/font).
//!
//! This is deliberately the same shape a loadable plugin needs. In-process Zig panels
//! (`controls.zig`, `menu.zig`, `scroll.zig`) implement [`Panel`] directly; a future
//! `dlopen`'d `.so` (see `loadDir`) exposes a C-ABI vtable that a shim adapts to the
//! very same [`Panel`]. Building the built-ins on this contract first is how we know the
//! contract is right before it's frozen across the C boundary.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zicro = @import("zicro");
const paint = zicro.paint;
const text = zicro.text;

/// An axis-aligned rectangle in canvas (buffer) pixels — the coordinate space of both
/// the [`paint.Canvas`] and the pointer events (surface-local == buffer-local here).
pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// Bounding box of the union of two rects (for damage accumulation).
pub fn unionOf(a: Rect, b: Rect) Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + a.w, b.x + b.w);
    const y1 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// An input event delivered to panels. Coordinates are canvas pixels (include the shadow
/// gutter margin), matching what a panel sees when it draws. Richer than zicro's
/// `input.InputEvent`: buttons/axes carry a position, scroll carries a real axis and a
/// line/pixel hint, so scrollbars can smooth wheel notches but not trackpad pixels.
pub const Event = union(enum) {
    motion: struct { x: f32, y: f32 },
    button: struct { x: f32, y: f32, button: u32, pressed: bool },
    /// `axis` is `wl_pointer` axis (0 = vertical, 1 = horizontal); `value` is the scroll
    /// amount (fixed→f32); `line` is true for discrete mouse-wheel steps (smooth them),
    /// false for trackpad pixel deltas (apply verbatim).
    axis: struct { x: f32, y: f32, axis: u32, value: f32, line: bool },
    key: struct { key: u32, pressed: bool },
    /// The pointer left the surface (`wl_pointer.leave`). Carries no position; panels
    /// use it to drop hover state. Broadcast to every panel — no panel should consume
    /// it (return `false` from `onInput`).
    leave,
};

/// A window operation a panel asks the host to perform. The host owns the Wayland
/// objects and the input serial, so a panel never touches them directly.
pub const Action = union(enum) {
    minimize,
    toggle_maximize,
    toggle_fullscreen,
    close,
    /// Start an interactive move (compositor grabs the last pointer serial).
    begin_move,
    /// Start an interactive resize toward an `xdg_toplevel` edge bitmask.
    begin_resize: u32,
    /// Set the pointer cursor to a `wp_cursor_shape_device_v1` shape id.
    set_cursor: u32,
    /// Force a repaint next loop turn even if nothing else is dirty.
    request_redraw,
    /// Create a secondary surface (`xdg_popup`) for menus, tooltips, dropdowns, or IME candidates.
    /// (Wayland-supported; no-op stub on other backends currently.)
    create_popup: PopupSpec,
    /// Dismiss a secondary popup surface by ID.
    /// (Wayland-supported; no-op stub on other backends currently.)
    dismiss_popup: u32,
    /// Enable IME/text input for focused text widget (`zwp_text_input_v3`).
    /// (Wayland-supported; no-op stub on other backends currently.)
    enable_text_input: TextInputSpec,
    /// Disable IME/text input when focus leaves text field.
    /// (Wayland-supported; no-op stub on other backends currently.)
    disable_text_input,
};

/// Platform-neutral popup specification.
pub const PopupSpec = struct {
    pub const Anchor = enum {
        none,
        top,
        bottom,
        left,
        right,
        top_left,
        bottom_left,
        top_right,
        bottom_right,
    };

    pub const Gravity = enum {
        none,
        top,
        bottom,
        left,
        right,
        top_left,
        bottom_left,
        top_right,
        bottom_right,
    };

    id: u32 = 0,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    anchor: Anchor = .none,
    gravity: Gravity = .none,
    grab: bool = true,
};

/// Platform-neutral IME/text input specification.
pub const TextInputSpec = struct {
    pub const Hint = struct {
        completion: bool = false,
        spellcheck: bool = false,
        auto_capitalization: bool = false,
        lowercase: bool = false,
        uppercase: bool = false,
        titlecase: bool = false,
        hidden_text: bool = false,
        sensitive_data: bool = false,
        latin: bool = false,
        multiline: bool = false,
    };

    pub const Purpose = enum {
        normal,
        alpha,
        digits,
        number,
        phone,
        url,
        email,
        name,
        password,
        pin,
        terminal,
    };

    x: i32 = 0,
    y: i32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    purpose: Purpose = .normal,
    hint: Hint = .{},
};

/// A snapshot of window geometry and state, handed to panels each draw/input so they can
/// lay themselves out without holding a reference to the window.
pub const Info = struct {
    /// Content rectangle (panel interior, canvas coords): `{margin, margin, panel_w, panel_h}`.
    content: Rect,
    panel_w: u32,
    panel_h: u32,
    margin: u32,
    maximized: bool,
    fullscreen: bool,
};

/// The window, as a panel sees it: three calls, no Wayland types. `window.zig` builds one
/// of these over itself; the dlopen loader will build one whose calls cross into C.
pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        do: *const fn (ptr: *anyopaque, action: Action) void,
        info: *const fn (ptr: *anyopaque) Info,
        font: *const fn (ptr: *anyopaque) ?*text.Font,
    };

    pub inline fn do(self: Host, action: Action) void {
        self.vtable.do(self.ptr, action);
    }
    pub inline fn info(self: Host) Info {
        return self.vtable.info(self.ptr);
    }
    pub inline fn font(self: Host) ?*text.Font {
        return self.vtable.font(self.ptr);
    }
};

/// A drawable, interactive, animatable overlay. Implement `draw` and `onInput` on a
/// struct `T`; optionally `tick` (return true while still animating) and `deinit` (only
/// called for panels the registry owns). Wrap it with [`Panel.of`].
pub const Panel = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Paint over the window content. Called every redraw, low z-order first.
        draw: *const fn (ptr: *anyopaque, canvas: *paint.Canvas, host: Host) void,
        /// Handle an event; return true to consume it (stops propagation to lower
        /// panels and to the app callbacks).
        on_input: *const fn (ptr: *anyopaque, event: Event, host: Host) bool,
        /// Advance animation by `dt` seconds; return true while more frames are needed.
        tick: *const fn (ptr: *anyopaque, dt: f32, host: Host) bool,
        /// Release resources. `null` for borrowed (caller-owned) panels.
        deinit: ?*const fn (ptr: *anyopaque, gpa: Allocator) void,
        /// Optional damage hint: the canvas rect this panel's animations may touch
        /// (superset of anything it drew or just stopped drawing), or null when it
        /// currently draws nothing. Panels WITHOUT this fn force a full redraw on
        /// every animation tick (safe default).
        dirty_bounds: ?*const fn (ptr: *anyopaque, host: Host) ?Rect,
    };

    /// Damage hint of a panel: `unknown` (no `dirtyBounds` — caller must repaint
    /// everything), `none` (draws nothing right now), or a canvas rect.
    pub const Dirty = union(enum) { unknown, none, rect: Rect };

    /// Build a `Panel` from `*T`, deriving the vtable from `T`'s methods. `T.draw` and
    /// `T.onInput` are required; `T.tick` and `T.deinit` are optional.
    /// The hooks must be `pub`: since Zig 0.17 `@hasDecl` reports only public
    /// declarations, so a non-pub `tick`/`deinit`/`dirtyBounds` is silently not
    /// picked up here — it compiles, and the panel just never ticks or frees.
    pub fn of(comptime T: type, instance: *T) Panel {
        const gen = struct {
            fn drawFn(ptr: *anyopaque, canvas: *paint.Canvas, host: Host) void {
                T.draw(@ptrCast(@alignCast(ptr)), canvas, host);
            }
            fn inputFn(ptr: *anyopaque, event: Event, host: Host) bool {
                return T.onInput(@ptrCast(@alignCast(ptr)), event, host);
            }
            fn tickFn(ptr: *anyopaque, dt: f32, host: Host) bool {
                if (@hasDecl(T, "tick")) return T.tick(@ptrCast(@alignCast(ptr)), dt, host);
                return false;
            }
            fn deinitFn(ptr: *anyopaque, gpa: Allocator) void {
                T.deinit(@ptrCast(@alignCast(ptr)), gpa);
            }
            fn dirtyFn(ptr: *anyopaque, host: Host) ?Rect {
                return T.dirtyBounds(@ptrCast(@alignCast(ptr)), host);
            }
            const vtable = VTable{
                .draw = drawFn,
                .on_input = inputFn,
                .tick = tickFn,
                .deinit = if (@hasDecl(T, "deinit")) deinitFn else null,
                .dirty_bounds = if (@hasDecl(T, "dirtyBounds")) dirtyFn else null,
            };
        };
        return .{ .ptr = instance, .vtable = &gen.vtable };
    }

    pub inline fn draw(self: Panel, canvas: *paint.Canvas, host: Host) void {
        self.vtable.draw(self.ptr, canvas, host);
    }
    pub inline fn onInput(self: Panel, event: Event, host: Host) bool {
        return self.vtable.on_input(self.ptr, event, host);
    }
    pub inline fn tick(self: Panel, dt: f32, host: Host) bool {
        return self.vtable.tick(self.ptr, dt, host);
    }

    pub inline fn dirty(self: Panel, host: Host) Dirty {
        const f = self.vtable.dirty_bounds orelse return .unknown;
        return if (f(self.ptr, host)) |r| .{ .rect = r } else .none;
    }
};

/// The window's ordered set of panels. Draw order is insertion order (first added is
/// bottom-most); input is offered top-most first and stops at the first consumer.
pub const Registry = struct {
    gpa: Allocator,
    panels: std.ArrayList(Entry) = .empty,

    const Entry = struct { panel: Panel, owned: bool };

    pub fn init(gpa: Allocator) Registry {
        return .{ .gpa = gpa };
    }

    /// Register a panel. `owned` = the registry calls its `deinit` (and, once dlopen
    /// lands, frees/`dlclose`s it) at teardown; borrowed panels are left to the caller.
    pub fn add(self: *Registry, panel: Panel, owned: bool) !void {
        try self.panels.append(self.gpa, .{ .panel = panel, .owned = owned });
    }

    /// Remove the first entry whose panel points at `ptr`. Runs its `deinit` if owned.
    pub fn remove(self: *Registry, ptr: *anyopaque) void {
        for (self.panels.items, 0..) |e, i| {
            if (e.panel.ptr == ptr) {
                if (e.owned) if (e.panel.vtable.deinit) |d| d(e.panel.ptr, self.gpa);
                _ = self.panels.orderedRemove(i);
                return;
            }
        }
    }

    /// Paint every panel, bottom-most first.
    pub fn draw(self: *Registry, canvas: *paint.Canvas, host: Host) void {
        for (self.panels.items) |e| e.panel.draw(canvas, host);
    }

    /// Offer `event` top-most first; stop and return true at the first consumer.
    pub fn route(self: *Registry, event: Event, host: Host) bool {
        var i = self.panels.items.len;
        while (i > 0) {
            i -= 1;
            // A panel may remove itself (or others) inside `onInput` and the
            // list shrinks under our feet: realign the index to the new tail
            // before dereferencing.
            if (i >= self.panels.items.len) {
                i = self.panels.items.len;
                continue;
            }
            if (self.panels.items[i].panel.onInput(event, host)) return true;
        }
        return false;
    }

    /// Tick every panel; return true if any still wants frames.
    pub fn tick(self: *Registry, dt: f32, host: Host) bool {
        var active = false;
        for (self.panels.items) |e| {
            if (e.panel.tick(dt, host)) active = true;
        }
        return active;
    }

    /// Bounding box of what the panels may have touched (union of the
    /// `dirtyBounds`): `.rect` for partial damage, `.none` if no panel
    /// draws anything, `.unknown` if AT LEAST one panel cannot declare it — the
    /// caller then redraws everything (conservative default).
    pub fn dirtyBounds(self: *Registry, host: Host) Panel.Dirty {
        var acc: Panel.Dirty = .none;
        for (self.panels.items) |e| switch (e.panel.dirty(host)) {
            .unknown => return .unknown,
            .none => {},
            .rect => |r| acc = switch (acc) {
                .none => .{ .rect = r },
                .rect => |cur| .{ .rect = unionOf(cur, r) },
                .unknown => unreachable,
            },
        };
        return acc;
    }

    pub fn deinit(self: *Registry) void {
        for (self.panels.items) |e| {
            if (e.owned) if (e.panel.vtable.deinit) |d| d(e.panel.ptr, self.gpa);
        }
        self.panels.deinit(self.gpa);
    }
};

// --- dlopen loader ---------------------------------------------------------------------

/// The C-ABI entry point a loadable plugin `.so` must export under [`register_symbol`].
/// It receives the window's panel [`Registry`] and registers whatever it provides —
/// typically `reg.add(Panel.of(MyPanel, instance), true)` for a UI panel, or a Zicro
/// `core.Module` for a headless one. Allocate through `reg.gpa`. Returns 0 on success.
///
/// The plugin is a Zig object built against this same `zrame` module, so it shares the
/// `Panel`/`Registry`/`Host` layouts and can call `Canvas` drawing directly — nothing but
/// these plain structs and function pointers crosses the boundary. (The allocator isn't a
/// parameter because `std.mem.Allocator` has no guaranteed C-ABI layout; it rides along
/// inside the `Registry` instead.)
pub const RegisterFn = *const fn (reg: *Registry) callconv(.c) c_int;

pub const register_symbol = "zrame_plugin_register";

/// `dlopen` `path`, resolve [`register_symbol`], and let it register its panels into
/// `reg`. Returns the open library handle — keep it alive for as long as the panels are
/// registered, and `close()` it only *after* the registry has run their `deinit`s (their
/// code lives in the library). See `Window.loadPlugin`.
pub fn loadPlugin(reg: *Registry, path: []const u8) !std.DynLib {
    var lib = try std.DynLib.open(path);
    errdefer lib.close();
    const reg_fn = lib.lookup(RegisterFn, register_symbol) orelse return error.MissingPluginEntry;
    if (reg_fn(reg) != 0) return error.PluginRegisterFailed;
    return lib;
}

// --- tests -----------------------------------------------------------------------------

const TestPanel = struct {
    draws: u32 = 0,
    inputs: u32 = 0,
    ticks: u32 = 0,
    consume: bool = false,
    frames_left: u32 = 0,
    deinited: *bool,

    pub fn draw(self: *TestPanel, canvas: *paint.Canvas, host: Host) void {
        _ = canvas;
        _ = host;
        self.draws += 1;
    }
    // Note: no `dirtyBounds` — so a bare TestPanel reports `.unknown` (forces a
    // full redraw). The damage-declaring variant is `DirtyPanel` below.
    pub fn onInput(self: *TestPanel, event: Event, host: Host) bool {
        _ = event;
        _ = host;
        self.inputs += 1;
        return self.consume;
    }
    pub fn tick(self: *TestPanel, dt: f32, host: Host) bool {
        _ = dt;
        _ = host;
        self.ticks += 1;
        if (self.frames_left > 0) self.frames_left -= 1;
        return self.frames_left > 0;
    }
    pub fn deinit(self: *TestPanel, gpa: Allocator) void {
        _ = gpa;
        self.deinited.* = true;
    }
};

fn nullHost() Host {
    const gen = struct {
        fn do(_: *anyopaque, _: Action) void {}
        fn info(_: *anyopaque) Info {
            return .{ .content = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .panel_w = 0, .panel_h = 0, .margin = 0, .maximized = false, .fullscreen = false };
        }
        fn font(_: *anyopaque) ?*text.Font {
            return null;
        }
        const vtable = Host.VTable{ .do = do, .info = info, .font = font };
        var dummy: u8 = 0;
    };
    return .{ .ptr = &gen.dummy, .vtable = &gen.vtable };
}

test "registry routes top-most first and stops at a consumer" {
    const gpa = std.testing.allocator;
    var d1 = false;
    var d2 = false;
    var bottom = TestPanel{ .deinited = &d1, .consume = false };
    var top = TestPanel{ .deinited = &d2, .consume = true };

    var reg = Registry.init(gpa);
    defer reg.deinit();
    try reg.add(Panel.of(TestPanel, &bottom), false);
    try reg.add(Panel.of(TestPanel, &top), false);

    const host = nullHost();
    const consumed = reg.route(.{ .motion = .{ .x = 1, .y = 2 } }, host);
    try std.testing.expect(consumed);
    // Top consumed it; bottom never saw it.
    try std.testing.expectEqual(@as(u32, 1), top.inputs);
    try std.testing.expectEqual(@as(u32, 0), bottom.inputs);
}

test "registry draws bottom-most first and ticks report activity" {
    const gpa = std.testing.allocator;
    var d = false;
    var p = TestPanel{ .deinited = &d, .frames_left = 3 };

    var reg = Registry.init(gpa);
    defer reg.deinit();
    try reg.add(Panel.of(TestPanel, &p), false);

    const host = nullHost();
    var px: [1]u32 = .{0};
    var canvas = paint.Canvas.init(&px, 1, 1);
    reg.draw(&canvas, host);
    try std.testing.expectEqual(@as(u32, 1), p.draws);

    try std.testing.expect(reg.tick(0.016, host)); // 3 -> 2, still active
    try std.testing.expect(reg.tick(0.016, host)); // 2 -> 1, still active
    try std.testing.expect(!reg.tick(0.016, host)); // 1 -> 0, done
}

test "owned panels are deinited, borrowed ones are not" {
    const gpa = std.testing.allocator;
    var owned_deinited = false;
    var borrowed_deinited = false;
    var owned = TestPanel{ .deinited = &owned_deinited };
    var borrowed = TestPanel{ .deinited = &borrowed_deinited };

    var reg = Registry.init(gpa);
    try reg.add(Panel.of(TestPanel, &owned), true);
    try reg.add(Panel.of(TestPanel, &borrowed), false);
    reg.deinit();

    try std.testing.expect(owned_deinited);
    try std.testing.expect(!borrowed_deinited);
}

/// A panel that declares a damage rect (or none), used to exercise `dirtyBounds`.
const DirtyPanel = struct {
    bounds: ?Rect,
    pub fn draw(_: *DirtyPanel, _: *paint.Canvas, _: Host) void {}
    pub fn onInput(_: *DirtyPanel, _: Event, _: Host) bool {
        return false;
    }
    pub fn dirtyBounds(self: *DirtyPanel, _: Host) ?Rect {
        return self.bounds;
    }
};

test "registry dirtyBounds: one panel without the hook forces unknown (full redraw)" {
    const gpa = std.testing.allocator;
    var d = false;
    var declares = DirtyPanel{ .bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 } };
    var opaque_panel = TestPanel{ .deinited = &d }; // no dirtyBounds → unknown

    var reg = Registry.init(gpa);
    defer reg.deinit();
    try reg.add(Panel.of(DirtyPanel, &declares), false);
    try reg.add(Panel.of(TestPanel, &opaque_panel), false);

    try std.testing.expect(reg.dirtyBounds(nullHost()) == .unknown);
}

test "registry dirtyBounds: unions declared rects, ignores none" {
    const gpa = std.testing.allocator;
    var a = DirtyPanel{ .bounds = .{ .x = 10, .y = 10, .w = 20, .h = 20 } }; // → (10,10)-(30,30)
    var b = DirtyPanel{ .bounds = null }; // draws nothing → none
    var c = DirtyPanel{ .bounds = .{ .x = 40, .y = 5, .w = 10, .h = 10 } }; // → (40,5)-(50,15)

    var reg = Registry.init(gpa);
    defer reg.deinit();
    try reg.add(Panel.of(DirtyPanel, &a), false);
    try reg.add(Panel.of(DirtyPanel, &b), false);
    try reg.add(Panel.of(DirtyPanel, &c), false);

    const d = reg.dirtyBounds(nullHost());
    try std.testing.expect(d == .rect);
    // Union: x0=10,y0=5, x1=50,y1=30 → {10,5,40,25}
    try std.testing.expectEqual(Rect{ .x = 10, .y = 5, .w = 40, .h = 25 }, d.rect);
}

test "registry dirtyBounds: all-none reports none" {
    const gpa = std.testing.allocator;
    var a = DirtyPanel{ .bounds = null };
    var b = DirtyPanel{ .bounds = null };

    var reg = Registry.init(gpa);
    defer reg.deinit();
    try reg.add(Panel.of(DirtyPanel, &a), false);
    try reg.add(Panel.of(DirtyPanel, &b), false);

    try std.testing.expect(reg.dirtyBounds(nullHost()) == .none);
}

test "host secondary surface and text input actions" {
    const Tracker = struct {
        last_action: ?Action = null,
        fn do(ptr: *anyopaque, action: Action) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.last_action = action;
        }
        fn info(_: *anyopaque) Info {
            return .{ .content = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .panel_w = 100, .panel_h = 100, .margin = 0, .maximized = false, .fullscreen = false };
        }
        fn font(_: *anyopaque) ?*text.Font {
            return null;
        }
    };
    var tr = Tracker{};
    const vt = Host.VTable{ .do = Tracker.do, .info = Tracker.info, .font = Tracker.font };
    const h = Host{ .ptr = &tr, .vtable = &vt };

    h.do(.{ .create_popup = .{ .x = 10, .y = 20, .w = 100, .h = 50, .anchor = .bottom, .gravity = .bottom } });
    try std.testing.expect(tr.last_action != null);
    try std.testing.expectEqual(@as(i32, 10), tr.last_action.?.create_popup.x);
    try std.testing.expectEqual(@as(i32, 20), tr.last_action.?.create_popup.y);
    try std.testing.expectEqual(PopupSpec.Anchor.bottom, tr.last_action.?.create_popup.anchor);
    try std.testing.expectEqual(PopupSpec.Gravity.bottom, tr.last_action.?.create_popup.gravity);

    h.do(.{ .enable_text_input = .{ .x = 5, .y = 15, .w = 50, .h = 20, .purpose = .password, .hint = .{ .hidden_text = true } } });
    try std.testing.expectEqual(@as(i32, 5), tr.last_action.?.enable_text_input.x);
    try std.testing.expectEqual(TextInputSpec.Purpose.password, tr.last_action.?.enable_text_input.purpose);
    try std.testing.expect(tr.last_action.?.enable_text_input.hint.hidden_text);

    h.do(.disable_text_input);
    try std.testing.expect(tr.last_action.? == .disable_text_input);
}
