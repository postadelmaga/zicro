//! # zicro.widget — an immediate-mode widget toolkit over `zicro.paint`
//!
//! The missing layer between a zicro window (canvas + normalized input) and an
//! application UI: a small egui-shaped toolkit. Each frame the app rebuilds its UI from
//! state — no retained widget objects, no invalidation protocol:
//!
//! ```zig
//! var ui = widget.Ui.begin(&store, canvas, font, theme, bounds, now_ms, queue.take());
//! if (ui.button("Save")) save();
//! _ = ui.textField("name", &name_buf);
//! const report = ui.end();
//! if (report.needs_repaint) win.host().do(.request_redraw);
//! ```
//!
//! * [`Store`] is the only persistent object (hot/active/focus ids, animation factors,
//!   scroll offsets, text cursor). Widget identity is a hash of the label (or explicit
//!   id) scoped by [`Ui.pushIdScope`] — two `button("Ok")` in different scopes are
//!   distinct.
//! * [`InputQueue`] adapts the window callbacks (`on_mouse`/`on_key`/`on_scroll`) to a
//!   per-frame event slice; button presses use the last motion position (window button
//!   events carry no position).
//! * Layout is a cursor: vertical stack by default, [`Ui.beginRow`]/[`Ui.endRow`] for
//!   horizontal runs, [`Ui.beginScroll`] for clipped scrolling regions.
//! * Overlays (dropdown list, modal dialog) are the two places immediate mode needs
//!   care: their *input* is claimed in [`Ui.begin`] against the previous frame's
//!   geometry (so widgets underneath never see the click), their *pixels* are drawn in
//!   [`Ui.end`] / after the main content (so they sit on top).
//!
//! Text editing is byte-oriented UTF-8 (cursor never lands inside a sequence); the
//! character map is US-layout for now (see `keymap.zig` for the limit).

const std = @import("std");
const paint = @import("paint.zig");
const text = @import("text.zig");
const anim = @import("anim.zig");
const keymap = @import("keymap.zig");

pub const Color = paint.Color;
pub const Key = keymap.Key;

// evdev button codes (what the window backends' MouseEvent carries).
pub const BTN_LEFT: u32 = 272;
pub const BTN_RIGHT: u32 = 273;
pub const BTN_MIDDLE: u32 = 274;

/// Monotonic milliseconds for [`Ui.begin`]'s `now_ms` — the per-OS clock apps need for
/// caret blink and animations (0.16 has no ambient `std.time` clock; tests pass explicit
/// timestamps instead and stay pure).
pub fn nowMs() i64 {
    switch (@import("builtin").os.tag) {
        .windows => return @intCast(std.os.windows.kernel32.GetTickCount64()),
        else => {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
            return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
        },
    }
}

/// Widget identity: 0 = none, 1 = the "ground" (a press that hit no widget).
pub const Id = u64;
const ground_id: Id = 1;

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }
};

// --- input -----------------------------------------------------------------------------

pub const InputEvent = union(enum) {
    motion: struct { x: f32, y: f32 },
    button: struct { button: u32, pressed: bool },
    /// `axis` 0 = vertical, 1 = horizontal; `px` is the scroll amount in pixels
    /// (zrame's `on_scroll` delivers 1/256 units: divide before pushing).
    scroll: struct { axis: u32, px: f32 },
    key: struct { code: u32, pressed: bool },
};

/// Bridges window callbacks (any thread-confined event source) to the per-frame event
/// slice [`Ui.begin`] consumes. `take` hands out the buffered events and resets — call
/// it exactly once per frame, before pushing new events.
pub const InputQueue = struct {
    events: [256]InputEvent = undefined,
    len: usize = 0,

    pub fn push(q: *InputQueue, e: InputEvent) void {
        if (q.len == q.events.len) return; // overflow: drop oldest-frame extras
        q.events[q.len] = e;
        q.len += 1;
    }

    pub fn take(q: *InputQueue) []const InputEvent {
        const out = q.events[0..q.len];
        q.len = 0;
        return out;
    }
};

// --- theme -----------------------------------------------------------------------------

pub const Theme = struct {
    text: Color,
    text_dim: Color,
    accent: Color,
    accent_text: Color,
    bg_card: Color,
    bg_widget: Color,
    bg_widget_hot: Color,
    bg_widget_active: Color,
    border: Color,
    focus_ring: Color,
    danger: Color,
    dim_overlay: Color,

    window_pad: f32 = 14,
    gap: f32 = 8,
    pad_x: f32 = 12,
    radius: f32 = 7,
    ctl_h: f32 = 30,
    check_size: f32 = 18,
    font_size: u16 = 15,
    font_small: u16 = 13,
    font_heading: u16 = 19,

    pub fn dark() Theme {
        return .{
            .text = Color.rgba(235, 238, 245, 0.95),
            .text_dim = Color.rgba(205, 214, 235, 0.62),
            .accent = Color.rgba(112, 156, 255, 0.95),
            .accent_text = Color.rgba(12, 16, 28, 0.98),
            .bg_card = Color.rgba(255, 255, 255, 0.055),
            .bg_widget = Color.rgba(255, 255, 255, 0.085),
            .bg_widget_hot = Color.rgba(255, 255, 255, 0.14),
            .bg_widget_active = Color.rgba(255, 255, 255, 0.20),
            .border = Color.rgba(255, 255, 255, 0.13),
            .focus_ring = Color.rgba(112, 156, 255, 0.85),
            .danger = Color.rgba(245, 120, 120, 0.95),
            .dim_overlay = Color.rgba(8, 10, 16, 0.42),
        };
    }

    /// A copy with all geometry × `f` (font sizes rounded). Pair with the window's
    /// fractional scale (`win.scaleFactor()`) so widgets keep their visual size on
    /// HiDPI outputs while rendering at native (crisp) pixels.
    pub fn scaled(t: Theme, f: f32) Theme {
        var s = t;
        s.window_pad *= f;
        s.gap *= f;
        s.pad_x *= f;
        s.radius *= f;
        s.ctl_h *= f;
        s.check_size *= f;
        s.font_size = scaleFont(t.font_size, f);
        s.font_small = scaleFont(t.font_small, f);
        s.font_heading = scaleFont(t.font_heading, f);
        return s;
    }

    fn scaleFont(px: u16, f: f32) u16 {
        const v = @as(f32, @floatFromInt(px)) * f;
        return @intFromFloat(@max(1, @round(v)));
    }

    pub fn light() Theme {
        return .{
            .text = Color.rgba(24, 28, 38, 0.95),
            .text_dim = Color.rgba(24, 28, 38, 0.58),
            .accent = Color.rgba(56, 108, 235, 0.95),
            .accent_text = Color.rgba(255, 255, 255, 0.98),
            .bg_card = Color.rgba(0, 0, 20, 0.045),
            .bg_widget = Color.rgba(0, 0, 20, 0.07),
            .bg_widget_hot = Color.rgba(0, 0, 20, 0.11),
            .bg_widget_active = Color.rgba(0, 0, 20, 0.17),
            .border = Color.rgba(0, 0, 20, 0.14),
            .focus_ring = Color.rgba(56, 108, 235, 0.85),
            .danger = Color.rgba(205, 60, 60, 0.95),
            .dim_overlay = Color.rgba(20, 24, 34, 0.30),
        };
    }
};

// --- persistent state --------------------------------------------------------------------

/// One ordered text operation (see `Store.text_ops`).
pub const TextOp = union(enum) { char: u8, key: Key };

pub const Nav = enum { none, next, prev };

/// Everything that must survive between frames. One per UI surface (window/panel).
pub const Store = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    // pointer state
    mouse_x: f32 = -1e9,
    mouse_y: f32 = -1e9,
    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,
    left_down: bool = false,
    left_pressed: bool = false,
    left_released: bool = false,
    right_pressed: bool = false,
    wheel: f32 = 0,

    // keyboard state (frame-scoped chars/keys; persistent modifiers)
    shift_down: bool = false,
    ctrl_down: bool = false,
    /// Ordered text operations (chars + editing keys, in arrival order — a `Home`
    /// between two chars must land between them).
    text_ops: [64]TextOp = undefined,
    text_ops_len: usize = 0,
    keys: [32]Key = undefined,
    keys_len: usize = 0,

    // widget state
    active: Id = 0,
    focus: Id = 0,
    text_cursor: usize = 0,
    /// Selection anchor of the focused text field: selection = anchor..cursor
    /// (either order); null = no selection.
    text_anchor: ?usize = null,
    modal: Id = 0,

    // Tab traversal: request parsed in begin(), satisfied by the focusables laid
    // out during the frame (wrap in end()).
    nav: Nav = .none,
    /// Set when Tab moved the focus here — the field selects-all on arrival.
    focus_via_nav: Id = 0,

    /// App-wide clipboard for ctrl+C/X/V between text fields. (OS clipboard
    /// integration is the window layer's job — a later slice.)
    clipboard: std.ArrayList(u8) = .empty,

    // dropdown overlay (geometry persists so next-frame clicks are claimed in begin())
    dd_open: Id = 0,
    dd_owner: Rect = .{},
    dd_panel: Rect = .{},
    dd_rects: std.ArrayList(Rect) = .empty,
    dd_pending: ?usize = null,
    dd_scroll: f32 = 0,
    /// Keyboard highlight while the overlay is open (arrows move it, Enter picks it).
    dd_hover: ?usize = null,
    dd_ensure_visible: bool = false,

    // tooltip (which widget is armed, and since when — the delay gate)
    tt_id: Id = 0,
    tt_since_ms: i64 = 0,

    /// Monotonic seconds accumulated across frames — phase source for indeterminate
    /// spinners/bars (stays small, unlike epoch ms, so f32 keeps precision).
    phase_s: f32 = 0,

    anims: std.AutoHashMapUnmanaged(Id, f32) = .empty,
    scrolls: std.AutoHashMapUnmanaged(Id, f32) = .empty,

    last_now_ms: i64 = 0,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(s: *Store) void {
        s.clipboard.deinit(s.gpa);
        s.dd_rects.deinit(s.gpa);
        s.anims.deinit(s.gpa);
        s.scrolls.deinit(s.gpa);
        s.arena.deinit();
    }

    /// True while a text field owns the keyboard — apps should skip their own
    /// shortcut handling then.
    pub fn wantsKeyboard(s: *const Store) bool {
        return s.focus != 0;
    }
};

// --- layout ------------------------------------------------------------------------------

const Cursor = struct {
    dir: enum { v, h },
    x: f32,
    y: f32,
    start_x: f32,
    start_y: f32,
    avail_w: f32,
    /// Tallest (row) / widest (column) widget seen — the cross-axis extent on pop.
    cross: f32 = 0,
};

pub const EndReport = struct {
    needs_repaint: bool,
    /// Content height actually laid out (root cursor extent) — lets callers size
    /// scrollable hosts.
    content_h: f32,
};

// --- the per-frame context -----------------------------------------------------------------

pub const Ui = struct {
    store: *Store,
    canvas: *paint.Canvas,
    font: *text.Font,
    theme: Theme,
    bounds: Rect,
    now_ms: i64,
    dt: f32,

    cursors: [12]Cursor = undefined,
    depth: usize = 0,
    id_scopes: [12]Id = undefined,
    scope_depth: usize = 0,
    clip: Rect,
    saved_clips: [12]struct { rect: Rect, canvas: ?paint.Canvas.Clip, id: Id, top: f32, viewport_h: f32 } = undefined,
    clip_depth: usize = 0,

    in_modal: bool = false,
    dialog_saved_cursor: ?Cursor = null,
    dialog_rect: Rect = .{},
    animating: bool = false,
    /// Rect of the last widget placed — for tests and tooling.
    last_rect: Rect = .{},
    dd_draw: ?DdDraw = null,
    tt_draw: ?[]const u8 = null,

    // Tab-traversal bookkeeping (frame-scoped, driven by navFocusHook).
    focus_first: Id = 0,
    focus_last: Id = 0,
    focus_prev: Id = 0,
    focus_take_next: bool = false,
    focus_seen: bool = false,

    const DdDraw = struct { rect: Rect, options: []const []const u8, selected: usize, content_h: f32 };

    // --- frame lifecycle ---------------------------------------------------------------

    pub fn begin(
        store: *Store,
        canvas: *paint.Canvas,
        font: *text.Font,
        theme: Theme,
        bounds: Rect,
        now_ms: i64,
        events: []const InputEvent,
    ) Ui {
        const dt: f32 = if (store.last_now_ms == 0)
            0.016
        else
            std.math.clamp(@as(f32, @floatFromInt(now_ms - store.last_now_ms)) / 1000.0, 0.0, 0.1);
        store.last_now_ms = now_ms;
        store.phase_s += dt;

        // Reset frame-scoped input, aggregate the event slice.
        store.mouse_dx = 0;
        store.mouse_dy = 0;
        store.left_pressed = false;
        store.left_released = false;
        store.right_pressed = false;
        store.wheel = 0;
        store.text_ops_len = 0;
        store.keys_len = 0;

        for (events) |e| switch (e) {
            .motion => |m| {
                if (store.mouse_x > -1e8) {
                    store.mouse_dx += m.x - store.mouse_x;
                    store.mouse_dy += m.y - store.mouse_y;
                }
                store.mouse_x = m.x;
                store.mouse_y = m.y;
            },
            .button => |b| {
                if (b.button == BTN_LEFT) {
                    if (b.pressed) {
                        store.left_pressed = true;
                        store.left_down = true;
                    } else {
                        store.left_released = true;
                        store.left_down = false;
                    }
                } else if (b.button == BTN_RIGHT and b.pressed) {
                    store.right_pressed = true;
                }
            },
            .scroll => |s| {
                if (s.axis == 0) store.wheel += s.px;
            },
            .key => |k| {
                const sym = Key.fromEvdev(k.code);
                switch (sym) {
                    .shift => store.shift_down = k.pressed,
                    .ctrl => store.ctrl_down = k.pressed,
                    else => if (k.pressed) {
                        if (sym == .other) {
                            if (keymap.toChar(k.code, store.shift_down)) |c| {
                                if (store.text_ops_len < store.text_ops.len) {
                                    store.text_ops[store.text_ops_len] = .{ .char = c };
                                    store.text_ops_len += 1;
                                }
                            }
                        } else {
                            if (store.keys_len < store.keys.len) {
                                store.keys[store.keys_len] = sym;
                                store.keys_len += 1;
                            }
                            // Editing keys also join the ordered text stream.
                            switch (sym) {
                                .backspace, .delete, .left, .right, .home, .end, .enter, .escape => {
                                    if (store.text_ops_len < store.text_ops.len) {
                                        store.text_ops[store.text_ops_len] = .{ .key = sym };
                                        store.text_ops_len += 1;
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                }
            },
        };

        // Overlay input pre-pass: claim input aimed at the (previous frame's) dropdown
        // geometry BEFORE any widget can see it — this is what makes the overlay
        // opaque to the widgets underneath.
        store.dd_pending = null;
        if (store.dd_open != 0) {
            // Keyboard: Esc closes, arrows move the highlight, Enter picks it.
            // Consumed keys are stripped so nothing else reacts (e.g. a dialog's Esc).
            var ki: usize = 0;
            while (ki < store.keys_len) {
                var consumed = true;
                switch (store.keys[ki]) {
                    .escape => {
                        store.dd_open = 0;
                        store.dd_hover = null;
                    },
                    .up => {
                        const hi = store.dd_hover orelse 0;
                        store.dd_hover = if (hi > 0) hi - 1 else 0;
                        store.dd_ensure_visible = true;
                    },
                    .down => {
                        const n = store.dd_rects.items.len;
                        if (n > 0) {
                            const hi = store.dd_hover orelse 0;
                            store.dd_hover = @min(hi + 1, n - 1);
                            store.dd_ensure_visible = true;
                        }
                    },
                    .enter => store.dd_pending = store.dd_hover,
                    .tab => {}, // swallowed: no focus traversal under an open list
                    else => consumed = false,
                }
                if (consumed) {
                    std.mem.copyForwards(Key, store.keys[ki .. store.keys_len - 1], store.keys[ki + 1 .. store.keys_len]);
                    store.keys_len -= 1;
                } else ki += 1;
            }

            // Wheel over the open panel scrolls the list, not what's underneath.
            const in_panel = store.dd_panel.contains(store.mouse_x, store.mouse_y);
            if (store.wheel != 0 and in_panel) {
                store.dd_scroll += store.wheel; // clamped in dropdown(), where content height is known
                store.wheel = 0;
            }

            if (store.left_pressed) {
                var hit = false;
                if (in_panel) {
                    for (store.dd_rects.items, 0..) |r, i| {
                        if (r.contains(store.mouse_x, store.mouse_y)) {
                            store.dd_pending = i;
                            break;
                        }
                    }
                    hit = true; // panel padding/scrollbar clicks are swallowed, stay open
                }
                if (!hit and !store.dd_owner.contains(store.mouse_x, store.mouse_y)) {
                    store.dd_open = 0;
                    store.dd_hover = null;
                    hit = true; // click-away closes AND is swallowed (menu semantics)
                }
                if (hit) store.left_pressed = false; // consumed
            }
        }

        // Tab / Shift+Tab: focus traversal. Consumed here; satisfied by the
        // focusables laid out this frame (navFocusHook), wrap resolved in end().
        store.nav = .none;
        if (store.dd_open == 0) {
            var ki: usize = 0;
            while (ki < store.keys_len) {
                if (store.keys[ki] == .tab) {
                    store.nav = if (store.shift_down) .prev else .next;
                    std.mem.copyForwards(Key, store.keys[ki .. store.keys_len - 1], store.keys[ki + 1 .. store.keys_len]);
                    store.keys_len -= 1;
                } else ki += 1;
            }
        }

        var ui = Ui{
            .store = store,
            .canvas = canvas,
            .font = font,
            .theme = theme,
            .bounds = bounds,
            .now_ms = now_ms,
            .dt = dt,
            .clip = bounds,
        };
        ui.cursors[0] = .{
            .dir = .v,
            .x = bounds.x + theme.window_pad,
            .y = bounds.y + theme.window_pad,
            .start_x = bounds.x + theme.window_pad,
            .start_y = bounds.y + theme.window_pad,
            .avail_w = bounds.w - 2 * theme.window_pad,
        };
        ui.depth = 1;
        ui.id_scopes[0] = 0x5a656e_464c4f57; // root seed
        ui.scope_depth = 1;
        return ui;
    }

    pub fn end(ui: *Ui) EndReport {
        // Dropdown overlay pixels — after everything, so it sits on top.
        if (ui.dd_draw) |dd| ui.drawDropdownOverlay(dd);
        if (ui.tt_draw) |s| ui.drawTooltip(s);

        // Unsatisfied Tab traversal: wrap around the ends, or focus the first
        // focusable when nothing (or something no longer laid out) had focus.
        if (ui.store.nav != .none) {
            const s = ui.store;
            if (ui.focus_first != 0) {
                const wrap = switch (s.nav) {
                    .next => ui.focus_first,
                    .prev => ui.focus_last,
                    .none => unreachable,
                };
                if (s.focus == 0 or !ui.focus_seen or ui.focus_take_next or
                    (s.nav == .prev and s.focus == ui.focus_first))
                {
                    s.focus = wrap;
                    s.focus_via_nav = wrap;
                }
            }
            s.nav = .none;
        }

        // A press nothing claimed grounds the interaction (so a later release over a
        // widget is not a click).
        if (ui.store.left_pressed and ui.store.active == 0) ui.store.active = ground_id;
        if (ui.store.left_released) ui.store.active = 0;

        _ = ui.store.arena.reset(.retain_capacity);

        const busy = ui.animating or ui.store.focus != 0 or (ui.store.active > ground_id) or ui.store.dd_open != 0;
        return .{ .needs_repaint = busy, .content_h = ui.cursors[0].y - ui.cursors[0].start_y };
    }

    // --- ids ------------------------------------------------------------------------------

    pub fn pushIdScope(ui: *Ui, s: []const u8) void {
        std.debug.assert(ui.scope_depth < ui.id_scopes.len);
        ui.id_scopes[ui.scope_depth] = std.hash.Wyhash.hash(ui.id_scopes[ui.scope_depth - 1], s);
        ui.scope_depth += 1;
    }

    pub fn pushIdScopeIndex(ui: *Ui, i: usize) void {
        var buf: [16]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], i, .little);
        std.mem.writeInt(u64, buf[8..16], 0x1d8, .little);
        std.debug.assert(ui.scope_depth < ui.id_scopes.len);
        ui.id_scopes[ui.scope_depth] = std.hash.Wyhash.hash(ui.id_scopes[ui.scope_depth - 1], &buf);
        ui.scope_depth += 1;
    }

    pub fn popIdScope(ui: *Ui) void {
        std.debug.assert(ui.scope_depth > 1);
        ui.scope_depth -= 1;
    }

    pub fn makeId(ui: *Ui, s: []const u8) Id {
        const h = std.hash.Wyhash.hash(ui.id_scopes[ui.scope_depth - 1], s);
        // 0 and 1 are reserved sentinels.
        return if (h < 2) h + 2 else h;
    }

    // --- layout ---------------------------------------------------------------------------

    fn cur(ui: *Ui) *Cursor {
        return &ui.cursors[ui.depth - 1];
    }

    /// Width still available on the current line/column.
    pub fn availW(ui: *Ui) f32 {
        const c = ui.cur();
        return switch (c.dir) {
            .v => c.avail_w,
            .h => @max(0, c.avail_w - (c.x - c.start_x)),
        };
    }

    /// Claim a `w × h` rect at the cursor and advance it.
    pub fn allocRect(ui: *Ui, w: f32, h: f32) Rect {
        const c = ui.cur();
        const r = Rect{ .x = c.x, .y = c.y, .w = w, .h = h };
        switch (c.dir) {
            .v => {
                c.y += h + ui.theme.gap;
                c.cross = @max(c.cross, w);
            },
            .h => {
                c.x += w + ui.theme.gap;
                c.cross = @max(c.cross, h);
            },
        }
        ui.last_rect = r;
        return r;
    }

    pub fn beginRow(ui: *Ui) void {
        std.debug.assert(ui.depth < ui.cursors.len);
        const c = ui.cur();
        ui.cursors[ui.depth] = .{
            .dir = .h,
            .x = c.x,
            .y = c.y,
            .start_x = c.x,
            .start_y = c.y,
            .avail_w = ui.availW(),
        };
        ui.depth += 1;
    }

    pub fn endRow(ui: *Ui) void {
        std.debug.assert(ui.depth > 1);
        const row = ui.cur();
        const h = row.cross;
        ui.depth -= 1;
        const c = ui.cur();
        std.debug.assert(c.dir == .v);
        c.y += h + ui.theme.gap;
        c.cross = @max(c.cross, row.x - row.start_x);
    }

    pub fn gap(ui: *Ui, px: f32) void {
        const c = ui.cur();
        switch (c.dir) {
            .v => c.y += px,
            .h => c.x += px,
        }
    }

    pub fn separator(ui: *Ui) void {
        const r = ui.allocRect(ui.availW(), 1);
        ui.canvas.strokeSegment(r.x, r.y + 0.5, r.x + r.w, r.y + 0.5, 1, ui.theme.border);
    }

    // --- interaction ----------------------------------------------------------------------

    pub const Sig = struct {
        hovered: bool = false,
        pressed: bool = false,
        clicked: bool = false,
        right_clicked: bool = false,
        held: bool = false,
        drag_dx: f32 = 0,
        drag_dy: f32 = 0,
    };

    fn inputEnabled(ui: *Ui) bool {
        return ui.store.modal == 0 or ui.in_modal;
    }

    /// Every keyboard-focusable widget calls this once per frame, in layout order:
    /// it satisfies a pending Tab request by handing the focus to the widget after
    /// (or before) the currently focused one.
    fn navFocusHook(ui: *Ui, id: Id) void {
        const s = ui.store;
        if (s.nav == .none or !ui.inputEnabled()) return;
        if (ui.focus_first == 0) ui.focus_first = id;
        if (ui.focus_take_next) {
            ui.focus_take_next = false;
            s.focus = id;
            s.focus_via_nav = id;
            s.nav = .none;
        } else if (s.focus != 0 and id == s.focus) {
            ui.focus_seen = true;
            switch (s.nav) {
                .next => ui.focus_take_next = true,
                .prev => if (ui.focus_prev != 0) {
                    s.focus = ui.focus_prev;
                    s.focus_via_nav = ui.focus_prev;
                    s.nav = .none;
                }, // focused is the first: wrap to the last, resolved in end()
                .none => unreachable,
            }
        }
        ui.focus_prev = id;
        ui.focus_last = id;
    }

    pub fn interact(ui: *Ui, id: Id, rect: Rect) Sig {
        if (!ui.inputEnabled()) return .{};
        var sig = Sig{};
        const s = ui.store;
        const in_clip = ui.clip.contains(s.mouse_x, s.mouse_y);
        // An open dropdown panel eats hover for whatever sits under it (either side
        // of the dropdown call — the panel rect persists across frames).
        const dd_blocks = s.dd_open != 0 and s.dd_panel.contains(s.mouse_x, s.mouse_y);
        sig.hovered = in_clip and rect.contains(s.mouse_x, s.mouse_y) and !dd_blocks;
        if (sig.hovered and s.left_pressed and s.active == 0) {
            s.active = id;
            sig.pressed = true;
        }
        if (s.active == id) {
            sig.held = s.left_down or s.left_released;
            sig.drag_dx = s.mouse_dx;
            sig.drag_dy = s.mouse_dy;
            if (s.left_released and sig.hovered) sig.clicked = true;
        }
        if (sig.hovered and s.right_pressed) sig.right_clicked = true;
        return sig;
    }

    /// Animated 0..1 hover factor for `id` (frame-rate independent).
    fn hoverT(ui: *Ui, id: Id, hovered: bool) f32 {
        const old = ui.store.anims.get(id) orelse 0;
        const new = anim.approach(old, hovered, ui.dt);
        if (new != old) {
            ui.store.anims.put(ui.store.gpa, id, new) catch return new;
            ui.animating = true;
        }
        return new;
    }

    fn lerpColor(a: Color, b: Color, t: f32) Color {
        return .{
            .r = anim.lerp(a.r, b.r, t),
            .g = anim.lerp(a.g, b.g, t),
            .b = anim.lerp(a.b, b.b, t),
            .a = anim.lerp(a.a, b.a, t),
        };
    }

    // --- text helpers -----------------------------------------------------------------------

    pub fn measureText(ui: *Ui, s: []const u8, size: u16, style: text.Style) f32 {
        return @floatFromInt(ui.font.measure(size, style, s));
    }

    const HAlign = enum { left, center, right };

    fn drawTextIn(ui: *Ui, rect: Rect, s: []const u8, halign: HAlign, size: u16, style: text.Style, color: Color) void {
        const v = ui.font.vmetrics(size, style);
        const text_h: f32 = @floatFromInt(v.ascent - v.descent);
        const baseline = rect.y + (rect.h - text_h) / 2 + @as(f32, @floatFromInt(v.ascent));
        const tw = ui.measureText(s, size, style);
        const x = switch (halign) {
            .left => rect.x,
            .center => rect.x + (rect.w - tw) / 2,
            .right => rect.x + rect.w - tw,
        };
        ui.canvas.drawText(ui.font, @intFromFloat(@round(x)), @intFromFloat(@round(baseline)), s, .{
            .size = size,
            .style = style,
            .color = color,
        });
    }

    // --- passive widgets ---------------------------------------------------------------------

    pub fn label(ui: *Ui, s: []const u8) void {
        ui.textLine(s, ui.theme.font_size, .regular, ui.theme.text);
    }

    pub fn labelDim(ui: *Ui, s: []const u8) void {
        ui.textLine(s, ui.theme.font_size, .regular, ui.theme.text_dim);
    }

    pub fn heading(ui: *Ui, s: []const u8) void {
        ui.textLine(s, ui.theme.font_heading, .bold, ui.theme.text);
    }

    pub fn textLine(ui: *Ui, s: []const u8, size: u16, style: text.Style, color: Color) void {
        const h: f32 = @floatFromInt(ui.font.lineHeight(size, style));
        const w = ui.measureText(s, size, style);
        const r = ui.allocRect(w, h);
        ui.drawTextIn(r, s, .left, size, style, color);
    }

    // --- buttons -------------------------------------------------------------------------------

    pub fn button(ui: *Ui, label_: []const u8) bool {
        return ui.buttonStyled(label_, false);
    }

    pub fn buttonPrimary(ui: *Ui, label_: []const u8) bool {
        return ui.buttonStyled(label_, true);
    }

    fn buttonStyled(ui: *Ui, label_: []const u8, primary: bool) bool {
        const t = ui.theme;
        const id = ui.makeId(label_);
        const w = ui.measureText(label_, t.font_size, .regular) + 2 * t.pad_x;
        const r = ui.allocRect(w, t.ctl_h);
        const sig = ui.interact(id, r);
        const ht = ui.hoverT(id, sig.hovered);

        var bg = if (primary) t.accent else lerpColor(t.bg_widget, t.bg_widget_hot, ht);
        if (sig.held) bg = if (primary) lerpColor(t.accent, t.bg_widget_active, 0.3) else t.bg_widget_active;
        if (primary and !sig.held) bg = lerpColor(bg, Color.rgba(255, 255, 255, bg.a), 0.12 * ht);
        ui.canvas.fillRoundedRect(r.x, r.y, r.w, r.h, t.radius, bg);
        if (!primary) ui.canvas.strokeRoundedRect(r.x, r.y, r.w, r.h, t.radius, 1, t.border);
        ui.drawTextIn(r, label_, .center, t.font_size, .regular, if (primary) t.accent_text else t.text);
        return sig.clicked;
    }

    /// A full-width, list-style clickable row (palette entries, list items).
    pub fn selectable(ui: *Ui, label_: []const u8, is_selected: bool) bool {
        const t = ui.theme;
        const id = ui.makeId(label_);
        const r = ui.allocRect(ui.availW(), t.ctl_h);
        const sig = ui.interact(id, r);
        const ht = ui.hoverT(id, sig.hovered);
        if (is_selected) {
            ui.canvas.fillRoundedRect(r.x, r.y, r.w, r.h, t.radius, lerpColor(t.accent, t.bg_widget_active, 0.55));
        } else if (ht > 0.01) {
            var bg = t.bg_widget_hot;
            bg.a *= ht;
            ui.canvas.fillRoundedRect(r.x, r.y, r.w, r.h, t.radius, bg);
        }
        var inner = r;
        inner.x += t.pad_x;
        inner.w -= 2 * t.pad_x;
        ui.drawTextIn(inner, label_, .left, t.font_size, .regular, t.text);
        return sig.clicked;
    }

    // --- toggles ---------------------------------------------------------------------------------

    pub fn checkbox(ui: *Ui, label_: []const u8, value: *bool) bool {
        const t = ui.theme;
        const id = ui.makeId(label_);
        const box = t.check_size;
        const w = box + 8 + ui.measureText(label_, t.font_size, .regular);
        const r = ui.allocRect(w, t.ctl_h);
        const sig = ui.interact(id, r);
        if (sig.clicked) value.* = !value.*;
        const ht = ui.hoverT(id, sig.hovered);

        const by = r.y + (r.h - box) / 2;
        const bg = if (value.*) t.accent else lerpColor(t.bg_widget, t.bg_widget_hot, ht);
        ui.canvas.fillRoundedRect(r.x, by, box, box, 5, bg);
        if (!value.*) ui.canvas.strokeRoundedRect(r.x, by, box, box, 5, 1, t.border);
        if (value.*) {
            const cx = r.x;
            const cy = by;
            ui.canvas.strokeSegment(cx + box * 0.24, cy + box * 0.52, cx + box * 0.44, cy + box * 0.72, 2, t.accent_text);
            ui.canvas.strokeSegment(cx + box * 0.44, cy + box * 0.72, cx + box * 0.78, cy + box * 0.30, 2, t.accent_text);
        }
        var lr = r;
        lr.x += box + 8;
        lr.w -= box + 8;
        ui.drawTextIn(lr, label_, .left, t.font_size, .regular, t.text);
        return sig.clicked;
    }

    pub fn toggle(ui: *Ui, label_: []const u8, value: *bool) bool {
        const t = ui.theme;
        const id = ui.makeId(label_);
        const pill_w: f32 = 40;
        const pill_h: f32 = 22;
        const w = pill_w + 8 + ui.measureText(label_, t.font_size, .regular);
        const r = ui.allocRect(w, t.ctl_h);
        const sig = ui.interact(id, r);
        if (sig.clicked) value.* = !value.*;
        const on_t = ui.hoverT(id ^ 0x70676c, value.*); // animate by state, not hover

        const py = r.y + (r.h - pill_h) / 2;
        const bg = lerpColor(ui.theme.bg_widget, t.accent, anim.cubicOut(on_t));
        ui.canvas.fillRoundedRect(r.x, py, pill_w, pill_h, pill_h / 2, bg);
        ui.canvas.strokeRoundedRect(r.x, py, pill_w, pill_h, pill_h / 2, 1, t.border);
        const knob_r = pill_h - 6;
        const kx = r.x + 3 + anim.cubicOut(on_t) * (pill_w - knob_r - 6);
        ui.canvas.fillRoundedRect(kx, py + 3, knob_r, knob_r, knob_r / 2, Color.rgba(255, 255, 255, 0.95));
        var lr = r;
        lr.x += pill_w + 8;
        lr.w -= pill_w + 8;
        ui.drawTextIn(lr, label_, .left, t.font_size, .regular, t.text);
        return sig.clicked;
    }

    /// One radio option; a group is N calls sharing `selected` with distinct `index`.
    /// Returns true when this option was just picked.
    pub fn radio(ui: *Ui, label_: []const u8, selected: *usize, index: usize) bool {
        const t = ui.theme;
        const id = ui.makeId(label_);
        const d = t.check_size;
        const w = d + 8 + ui.measureText(label_, t.font_size, .regular);
        const r = ui.allocRect(w, t.ctl_h);
        const sig = ui.interact(id, r);
        var changed = false;
        if (sig.clicked and selected.* != index) {
            selected.* = index;
            changed = true;
        }
        const ht = ui.hoverT(id, sig.hovered);
        const on = selected.* == index;

        const cy = r.y + (r.h - d) / 2;
        const bg = if (on) t.accent else lerpColor(t.bg_widget, t.bg_widget_hot, ht);
        ui.canvas.fillRoundedRect(r.x, cy, d, d, d / 2, bg);
        if (!on) ui.canvas.strokeRoundedRect(r.x, cy, d, d, d / 2, 1, t.border);
        if (on) {
            const dot = d * 0.4;
            ui.canvas.fillRoundedRect(r.x + (d - dot) / 2, cy + (d - dot) / 2, dot, dot, dot / 2, t.accent_text);
        }
        var lr = r;
        lr.x += d + 8;
        lr.w -= d + 8;
        ui.drawTextIn(lr, label_, .left, t.font_size, .regular, t.text);
        return changed;
    }

    // --- progress ------------------------------------------------------------------------------

    /// Determinate progress bar across the available width; `frac` clamped 0..1.
    pub fn progressBar(ui: *Ui, frac: f32) void {
        const t = ui.theme;
        const h: f32 = 8;
        const r = ui.allocRect(ui.availW(), h);
        ui.canvas.fillProgressBar(r.x, r.y, r.w, r.h, h / 2, frac, t.bg_widget, t.accent);
    }

    /// Indeterminate sweep; keeps the frame loop alive while visible.
    pub fn progressIndeterminate(ui: *Ui) void {
        const t = ui.theme;
        const h: f32 = 8;
        const r = ui.allocRect(ui.availW(), h);
        ui.canvas.fillProgressBarIndeterminate(r.x, r.y, r.w, r.h, h / 2, ui.store.phase_s, t.bg_widget, t.accent);
        ui.animating = true;
    }

    /// Indeterminate spinner sized to the control height; keeps the frame loop alive.
    pub fn spinner(ui: *Ui) void {
        const t = ui.theme;
        const d = t.ctl_h;
        const r = ui.allocRect(d, d);
        ui.canvas.drawSpinner(r.x + d / 2, r.y + d / 2, d / 2 - 3, 2.5, ui.store.phase_s, t.accent);
        ui.animating = true;
    }

    // --- slider / stepper --------------------------------------------------------------------------

    pub fn slider(ui: *Ui, label_: []const u8, value: *f32, min: f32, max: f32) bool {
        const t = ui.theme;
        const id = ui.makeId(label_);
        const label_w = if (label_.len > 0) ui.measureText(label_, t.font_size, .regular) + 10 else 0;
        const r = ui.allocRect(ui.availW(), t.ctl_h);
        if (label_.len > 0) {
            var lr = r;
            lr.w = label_w;
            ui.drawTextIn(lr, label_, .left, t.font_size, .regular, t.text);
        }
        const track = Rect{ .x = r.x + label_w, .y = r.y, .w = @max(20, r.w - label_w), .h = r.h };
        const sig = ui.interact(id, track);
        var changed = false;
        if (sig.held or sig.pressed) {
            const nt = std.math.clamp((ui.store.mouse_x - track.x) / track.w, 0, 1);
            const nv = min + nt * (max - min);
            if (nv != value.*) {
                value.* = nv;
                changed = true;
            }
        }
        const ht = ui.hoverT(id, sig.hovered or sig.held);
        const vt = if (max > min) std.math.clamp((value.* - min) / (max - min), 0, 1) else 0;
        const ty = r.y + r.h / 2 - 3;
        ui.canvas.fillRoundedRect(track.x, ty, track.w, 6, 3, t.bg_widget);
        ui.canvas.fillRoundedRect(track.x, ty, track.w * vt, 6, 3, t.accent);
        const knob: f32 = 14 + 2 * ht;
        const kx = track.x + track.w * vt - knob / 2;
        ui.canvas.fillRoundedRect(kx, r.y + (r.h - knob) / 2, knob, knob, knob / 2, Color.rgba(255, 255, 255, 0.95));
        return changed;
    }

    /// `label  [−] value [+]` on one row; steps by 1 within `[min,max]`.
    pub fn stepper(ui: *Ui, label_: []const u8, value: *i64, min: i64, max: i64) bool {
        const t = ui.theme;
        ui.pushIdScope(label_);
        defer ui.popIdScope();

        const r = ui.allocRect(ui.availW(), t.ctl_h);
        var lr = r;
        lr.w = r.w - (2 * t.ctl_h + 64 + 2 * ui.theme.gap);
        ui.drawTextIn(lr, label_, .left, t.font_size, .regular, t.text);

        var changed = false;
        const minus = Rect{ .x = r.x + lr.w, .y = r.y, .w = t.ctl_h, .h = t.ctl_h };
        const valr = Rect{ .x = minus.x + t.ctl_h + ui.theme.gap, .y = r.y, .w = 64 - 2 * ui.theme.gap, .h = t.ctl_h };
        const plus = Rect{ .x = valr.x + valr.w + ui.theme.gap, .y = r.y, .w = t.ctl_h, .h = t.ctl_h };

        if (ui.squareButton(minus, "-") and value.* > min) {
            value.* -= 1;
            changed = true;
        }
        var buf: [24]u8 = undefined;
        const vs = std.fmt.bufPrint(&buf, "{d}", .{value.*}) catch "?";
        ui.drawTextIn(valr, vs, .center, t.font_size, .regular, t.text);
        if (ui.squareButton(plus, "+") and value.* < max) {
            value.* += 1;
            changed = true;
        }
        return changed;
    }

    fn squareButton(ui: *Ui, r: Rect, glyph: []const u8) bool {
        const t = ui.theme;
        const id = ui.makeId(glyph);
        const sig = ui.interact(id, r);
        const ht = ui.hoverT(id, sig.hovered);
        var bg = lerpColor(t.bg_widget, t.bg_widget_hot, ht);
        if (sig.held) bg = t.bg_widget_active;
        ui.canvas.fillRoundedRect(r.x, r.y, r.w, r.h, t.radius, bg);
        ui.canvas.strokeRoundedRect(r.x, r.y, r.w, r.h, t.radius, 1, t.border);
        ui.drawTextIn(r, glyph, .center, t.font_size, .bold, t.text);
        return sig.clicked;
    }

    // --- text field ----------------------------------------------------------------------------------

    pub const TextEdit = enum { idle, changed, submitted };

    /// Single-line editable text. `buf` is app-owned; edits allocate through the
    /// store's gpa. Click to focus (drag selects), Tab reaches it (select-all),
    /// shift+arrows/home/end select, ctrl+arrows jump words, ctrl+A/C/X/V use the
    /// store clipboard. Esc/Enter unfocus (Enter reports `.submitted`).
    pub fn textField(ui: *Ui, id_str: []const u8, buf: *std.ArrayList(u8)) TextEdit {
        const t = ui.theme;
        const s = ui.store;
        const id = ui.makeId(id_str);
        const r = ui.allocRect(ui.availW(), t.ctl_h);
        ui.navFocusHook(id);
        const sig = ui.interact(id, r);
        const focused = s.focus == id;

        if (sig.pressed) {
            if (!focused) {
                s.focus = id;
                s.text_anchor = null;
            }
            const p = ui.caretFromX(buf.items, s.mouse_x - (r.x + t.pad_x));
            if (s.shift_down and focused) {
                if (s.text_anchor == null) s.text_anchor = s.text_cursor;
            } else {
                s.text_anchor = null;
            }
            s.text_cursor = p;
        } else if (s.left_pressed and !sig.hovered and focused) {
            s.focus = 0; // click-away unfocuses
            s.text_anchor = null;
        } else if (s.active == id and s.left_down and s.focus == id) {
            // Drag: extend the selection from the press point.
            const p = ui.caretFromX(buf.items, s.mouse_x - (r.x + t.pad_x));
            if (p != s.text_cursor) {
                if (s.text_anchor == null) s.text_anchor = s.text_cursor;
                s.text_cursor = p;
            }
        }

        // Tab just landed here: select everything, caret at the end.
        if (s.focus == id and s.focus_via_nav == id) {
            s.focus_via_nav = 0;
            s.text_anchor = 0;
            s.text_cursor = buf.items.len;
        }

        var result: TextEdit = .idle;
        if (s.focus == id) {
            if (s.text_cursor > buf.items.len) s.text_cursor = buf.items.len;
            if (s.text_anchor) |a| {
                if (a > buf.items.len) s.text_anchor = buf.items.len;
            }
            // Ordered stream: chars and editing keys interleave exactly as they arrived.
            for (s.text_ops[0..s.text_ops_len]) |op| switch (op) {
                .char => |c| if (s.ctrl_down) switch (c) {
                    'a' => {
                        s.text_anchor = 0;
                        s.text_cursor = buf.items.len;
                    },
                    'c' => _ = ui.copySelection(buf.items),
                    'x' => if (ui.copySelection(buf.items)) {
                        _ = ui.deleteSelection(buf);
                        result = .changed;
                    },
                    'v' => if (s.clipboard.items.len > 0 or selRange(s) != null) {
                        _ = ui.deleteSelection(buf);
                        buf.insertSlice(s.gpa, s.text_cursor, s.clipboard.items) catch break;
                        s.text_cursor += s.clipboard.items.len;
                        result = .changed;
                    },
                    else => {},
                } else {
                    _ = ui.deleteSelection(buf);
                    buf.insert(s.gpa, s.text_cursor, c) catch break;
                    s.text_cursor += 1;
                    result = .changed;
                },
                .key => |k| switch (k) {
                    .backspace => if (ui.deleteSelection(buf)) {
                        result = .changed;
                    } else if (s.text_cursor > 0) {
                        const prev = prevBoundary(buf.items, s.text_cursor);
                        buf.replaceRange(s.gpa, prev, s.text_cursor - prev, &.{}) catch {};
                        s.text_cursor = prev;
                        result = .changed;
                    },
                    .delete => if (ui.deleteSelection(buf)) {
                        result = .changed;
                    } else if (s.text_cursor < buf.items.len) {
                        const next = nextBoundary(buf.items, s.text_cursor);
                        buf.replaceRange(s.gpa, s.text_cursor, next - s.text_cursor, &.{}) catch {};
                        result = .changed;
                    },
                    .left => {
                        if (s.shift_down) {
                            if (s.text_anchor == null) s.text_anchor = s.text_cursor;
                            s.text_cursor = if (s.ctrl_down) prevWord(buf.items, s.text_cursor) else prevBoundary(buf.items, s.text_cursor);
                        } else if (selRange(s)) |sel| {
                            s.text_cursor = sel[0]; // collapse to the left edge
                            s.text_anchor = null;
                        } else {
                            s.text_cursor = if (s.ctrl_down) prevWord(buf.items, s.text_cursor) else prevBoundary(buf.items, s.text_cursor);
                        }
                    },
                    .right => {
                        if (s.shift_down) {
                            if (s.text_anchor == null) s.text_anchor = s.text_cursor;
                            s.text_cursor = if (s.ctrl_down) nextWord(buf.items, s.text_cursor) else nextBoundary(buf.items, s.text_cursor);
                        } else if (selRange(s)) |sel| {
                            s.text_cursor = sel[1]; // collapse to the right edge
                            s.text_anchor = null;
                        } else {
                            s.text_cursor = if (s.ctrl_down) nextWord(buf.items, s.text_cursor) else nextBoundary(buf.items, s.text_cursor);
                        }
                    },
                    .home => {
                        if (s.shift_down) {
                            if (s.text_anchor == null) s.text_anchor = s.text_cursor;
                        } else s.text_anchor = null;
                        s.text_cursor = 0;
                    },
                    .end => {
                        if (s.shift_down) {
                            if (s.text_anchor == null) s.text_anchor = s.text_cursor;
                        } else s.text_anchor = null;
                        s.text_cursor = buf.items.len;
                    },
                    .enter => {
                        s.focus = 0;
                        s.text_anchor = null;
                        result = .submitted;
                    },
                    .escape => {
                        s.focus = 0;
                        s.text_anchor = null;
                    },
                    else => {},
                },
            };
            // An empty selection is no selection.
            if (s.text_anchor) |a| {
                if (a == s.text_cursor) s.text_anchor = null;
            }
        }

        // draw
        const ht = ui.hoverT(id, sig.hovered);
        ui.canvas.fillRoundedRect(r.x, r.y, r.w, r.h, t.radius, lerpColor(t.bg_widget, t.bg_widget_hot, ht * 0.6));
        const ring = if (s.focus == id) t.focus_ring else t.border;
        ui.canvas.strokeRoundedRect(r.x, r.y, r.w, r.h, t.radius, if (s.focus == id) 1.5 else 1, ring);

        const saved = ui.canvas.setClip(
            @intFromFloat(@max(0, r.x + 2)),
            @intFromFloat(@max(0, r.y)),
            @intFromFloat(@max(0, r.w - 4)),
            @intFromFloat(@max(0, r.h)),
        );
        defer ui.canvas.clip = saved;
        var inner = r;
        inner.x += t.pad_x;
        inner.w -= 2 * t.pad_x;

        // Selection highlight under the glyphs.
        if (s.focus == id) if (selRange(s)) |sel| {
            const x0 = inner.x + ui.measureText(buf.items[0..sel[0]], t.font_size, .regular);
            const x1 = inner.x + ui.measureText(buf.items[0..sel[1]], t.font_size, .regular);
            const v = ui.font.vmetrics(t.font_size, .regular);
            const sel_h: f32 = @floatFromInt(v.ascent - v.descent);
            var sc = t.accent;
            sc.a *= 0.35;
            ui.canvas.fillRoundedRect(x0, r.y + (r.h - sel_h) / 2, x1 - x0, sel_h, 2, sc);
        };

        ui.drawTextIn(inner, buf.items, .left, t.font_size, .regular, t.text);

        if (s.focus == id and @rem(@divTrunc(ui.now_ms, 530), 2) == 0) {
            const cx = inner.x + ui.measureText(buf.items[0..s.text_cursor], t.font_size, .regular);
            const v = ui.font.vmetrics(t.font_size, .regular);
            const text_h: f32 = @floatFromInt(v.ascent - v.descent);
            const cy0 = r.y + (r.h - text_h) / 2;
            ui.canvas.strokeSegment(cx, cy0, cx, cy0 + text_h, 1.4, t.text);
        }
        return result;
    }

    fn caretFromX(ui: *Ui, s: []const u8, x: f32) usize {
        if (x <= 0) return 0;
        var i: usize = 0;
        var w: f32 = 0;
        while (i < s.len) {
            const next = nextBoundary(s, i);
            const cw = ui.measureText(s[i..next], ui.theme.font_size, .regular);
            if (w + cw / 2 > x) return i;
            w += cw;
            i = next;
        }
        return s.len;
    }

    /// Selection of the focused field as an ordered `[lo, hi]`, or null when empty.
    fn selRange(s: *const Store) ?[2]usize {
        const a = s.text_anchor orelse return null;
        if (a == s.text_cursor) return null;
        return .{ @min(a, s.text_cursor), @max(a, s.text_cursor) };
    }

    /// Delete the selection from `buf` (cursor lands at its start). False if none.
    fn deleteSelection(ui: *Ui, buf: *std.ArrayList(u8)) bool {
        const sel = selRange(ui.store) orelse return false;
        buf.replaceRange(ui.store.gpa, sel[0], sel[1] - sel[0], &.{}) catch return false;
        ui.store.text_cursor = sel[0];
        ui.store.text_anchor = null;
        return true;
    }

    /// Copy the selection into the store clipboard. False if none.
    fn copySelection(ui: *Ui, chars: []const u8) bool {
        const sel = selRange(ui.store) orelse return false;
        ui.store.clipboard.clearRetainingCapacity();
        ui.store.clipboard.appendSlice(ui.store.gpa, chars[sel[0]..sel[1]]) catch return false;
        return true;
    }

    /// Start of the word before `i` (skip spaces, then the word).
    fn prevWord(s: []const u8, i: usize) usize {
        var j = i;
        while (j > 0 and s[j - 1] == ' ') j -= 1;
        while (j > 0 and s[j - 1] != ' ') j -= 1;
        return j;
    }

    /// Start of the word after `i` (skip the word, then spaces).
    fn nextWord(s: []const u8, i: usize) usize {
        var j = i;
        while (j < s.len and s[j] != ' ') j += 1;
        while (j < s.len and s[j] == ' ') j += 1;
        return j;
    }

    fn prevBoundary(s: []const u8, i: usize) usize {
        if (i == 0) return 0;
        var j = i - 1;
        while (j > 0 and (s[j] & 0xC0) == 0x80) j -= 1;
        return j;
    }

    fn nextBoundary(s: []const u8, i: usize) usize {
        if (i >= s.len) return s.len;
        var j = i + 1;
        while (j < s.len and (s[j] & 0xC0) == 0x80) j += 1;
        return j;
    }

    // --- dropdown --------------------------------------------------------------------------------------

    /// A closed dropdown is a button showing `options[selected.*]`; open, it overlays
    /// the option list (drawn in [`end`], input claimed in [`begin`] — see module doc).
    /// Returns true when the selection changed.
    pub fn dropdown(ui: *Ui, id_str: []const u8, options: []const []const u8, selected: *usize) bool {
        const t = ui.theme;
        const s = ui.store;
        const id = ui.makeId(id_str);
        if (selected.* >= options.len and options.len > 0) selected.* = options.len - 1;

        var changed = false;
        if (s.dd_open == id) {
            if (s.dd_pending) |i| {
                if (i < options.len and i != selected.*) {
                    selected.* = i;
                    changed = true;
                }
                s.dd_open = 0;
                s.dd_pending = null;
                s.dd_hover = null;
            }
        }

        const r = ui.allocRect(ui.availW(), t.ctl_h);
        const sig = ui.interact(id, r);
        if (sig.clicked) {
            if (s.dd_open == id) {
                s.dd_open = 0;
                s.dd_hover = null;
            } else {
                s.dd_open = id;
                s.dd_scroll = 0;
                s.dd_hover = if (options.len > 0) selected.* else null;
                s.dd_ensure_visible = true; // scroll the current selection into view
            }
            s.dd_owner = r;
        }

        const ht = ui.hoverT(id, sig.hovered);
        ui.canvas.fillRoundedRect(r.x, r.y, r.w, r.h, t.radius, lerpColor(t.bg_widget, t.bg_widget_hot, ht));
        ui.canvas.strokeRoundedRect(r.x, r.y, r.w, r.h, t.radius, 1, if (s.dd_open == id) t.focus_ring else t.border);
        var inner = r;
        inner.x += t.pad_x;
        inner.w -= 2 * t.pad_x + 16;
        const current = if (options.len > 0) options[selected.*] else "";
        ui.drawTextIn(inner, current, .left, t.font_size, .regular, t.text);
        // chevron
        const cxm = r.x + r.w - t.pad_x - 5;
        const cym = r.y + r.h / 2 - 2;
        ui.canvas.strokeSegment(cxm - 4, cym, cxm, cym + 4, 1.6, t.text_dim);
        ui.canvas.strokeSegment(cxm, cym + 4, cxm + 4, cym, 1.6, t.text_dim);

        if (s.dd_open == id) {
            // Register the overlay: geometry now (for end()'s pixels AND next frame's
            // input pre-pass), pixels later.
            const content_h = @as(f32, @floatFromInt(options.len)) * t.ctl_h + 8;
            const oh = @min(content_h, @max(t.ctl_h + 8, @min(320, ui.bounds.h - 8)));
            var oy = r.y + r.h + 4;
            if (oy + oh > ui.bounds.y + ui.bounds.h) oy = @max(ui.bounds.y, r.y - oh - 4);
            const orect = Rect{ .x = r.x, .y = oy, .w = r.w, .h = oh };

            // Long lists scroll inside the panel; keep the keyboard highlight in view.
            const max_scroll = @max(0, content_h - oh);
            if (s.dd_ensure_visible) {
                if (s.dd_hover) |hi| {
                    const iy = 4 + @as(f32, @floatFromInt(hi)) * t.ctl_h; // content-space top
                    if (iy - s.dd_scroll < 4) s.dd_scroll = iy - 4;
                    if (iy + t.ctl_h - s.dd_scroll > oh - 4) s.dd_scroll = iy + t.ctl_h - (oh - 4);
                }
                s.dd_ensure_visible = false;
            }
            s.dd_scroll = std.math.clamp(s.dd_scroll, 0, max_scroll);
            const gutter: f32 = if (max_scroll > 0) 6 else 0;

            s.dd_owner = r;
            s.dd_panel = orect;
            s.dd_rects.clearRetainingCapacity();
            for (options, 0..) |_, i| {
                s.dd_rects.append(s.gpa, .{
                    .x = orect.x + 4,
                    .y = orect.y + 4 + @as(f32, @floatFromInt(i)) * t.ctl_h - s.dd_scroll,
                    .w = orect.w - 8 - gutter,
                    .h = t.ctl_h,
                }) catch break;
            }
            ui.dd_draw = .{ .rect = orect, .options = options, .selected = selected.*, .content_h = content_h };
        }
        return changed;
    }

    fn drawDropdownOverlay(ui: *Ui, dd: DdDraw) void {
        const t = ui.theme;
        // Solid-ish backdrop so the list is readable over any content.
        var bg = t.bg_card;
        bg.a = @max(bg.a, 0.92);
        bg = lerpColor(Color.rgba(24, 27, 38, 0.96), bg, 0.15);
        ui.canvas.fillRoundedRect(dd.rect.x, dd.rect.y, dd.rect.w, dd.rect.h, t.radius, bg);
        ui.canvas.strokeRoundedRect(dd.rect.x, dd.rect.y, dd.rect.w, dd.rect.h, t.radius, 1, t.border);

        // Scrolled items stay inside the panel.
        const saved = ui.canvas.setClip(
            @intFromFloat(@max(0, dd.rect.x + 1)),
            @intFromFloat(@max(0, dd.rect.y + 1)),
            @intFromFloat(@max(0, dd.rect.w - 2)),
            @intFromFloat(@max(0, dd.rect.h - 2)),
        );
        defer ui.canvas.clip = saved;

        const in_panel = dd.rect.contains(ui.store.mouse_x, ui.store.mouse_y);
        for (ui.store.dd_rects.items, 0..) |r, i| {
            if (i >= dd.options.len) break;
            if (r.y + r.h < dd.rect.y or r.y > dd.rect.y + dd.rect.h) continue; // culled
            const hovered = in_panel and r.contains(ui.store.mouse_x, ui.store.mouse_y);
            const kb_hover = if (ui.store.dd_hover) |hi| hi == i else false;
            if (i == dd.selected) {
                ui.canvas.fillRoundedRect(r.x, r.y, r.w, r.h, t.radius - 2, lerpColor(t.accent, t.bg_widget_active, 0.55));
            } else if (hovered or kb_hover) {
                ui.canvas.fillRoundedRect(r.x, r.y, r.w, r.h, t.radius - 2, t.bg_widget_hot);
            }
            var inner = r;
            inner.x += t.pad_x;
            inner.w -= 2 * t.pad_x;
            ui.drawTextIn(inner, dd.options[i], .left, t.font_size, .regular, t.text);
        }

        // Thin scrollbar, same look as endScroll's.
        if (dd.content_h > dd.rect.h) {
            const max_off = dd.content_h - dd.rect.h;
            const track_h = dd.rect.h - 4;
            const thumb_h = @max(24, track_h * dd.rect.h / dd.content_h);
            const ty = dd.rect.y + 2 + (track_h - thumb_h) * (ui.store.dd_scroll / max_off);
            ui.canvas.fillRoundedRect(dd.rect.x + dd.rect.w - 6, ty, 4, thumb_h, 2, Color.rgba(255, 255, 255, 0.25));
        }
    }

    // --- tooltip ---------------------------------------------------------------------------------------

    /// Attach a tooltip to the last-placed widget: after a short hover delay, `s` pops
    /// up near the pointer (drawn in [`end`], on top of everything). Call it right
    /// after the widget it annotates. `s` must outlive the frame (literals do).
    pub fn tooltip(ui: *Ui, s: []const u8) void {
        const st = ui.store;
        const id = ui.makeId(s);
        const dd_blocks = st.dd_open != 0 and st.dd_panel.contains(st.mouse_x, st.mouse_y);
        const over = ui.inputEnabled() and !dd_blocks and
            ui.clip.contains(st.mouse_x, st.mouse_y) and ui.last_rect.contains(st.mouse_x, st.mouse_y);
        if (!over) {
            if (st.tt_id == id) st.tt_id = 0;
            return;
        }
        if (st.tt_id != id) {
            st.tt_id = id;
            st.tt_since_ms = ui.now_ms;
        }
        if (ui.now_ms - st.tt_since_ms >= 450) {
            ui.tt_draw = s;
        } else {
            ui.animating = true; // keep frames coming until the delay elapses
        }
    }

    fn drawTooltip(ui: *Ui, s: []const u8) void {
        const t = ui.theme;
        const pad: f32 = 8;
        const tw = ui.measureText(s, t.font_size, .regular);
        const th: f32 = @floatFromInt(ui.font.lineHeight(t.font_size, .regular));
        const w = tw + 2 * pad;
        const h = th + 10;
        var x = ui.store.mouse_x + 12;
        var y = ui.store.mouse_y + 18;
        if (x + w > ui.bounds.x + ui.bounds.w) x = ui.bounds.x + ui.bounds.w - w - 2;
        if (y + h > ui.bounds.y + ui.bounds.h) y = ui.store.mouse_y - h - 6;
        var bg = lerpColor(Color.rgba(20, 22, 30, 0.97), t.bg_card, 0.1);
        bg.a = 0.97;
        ui.canvas.fillRoundedRect(x, y, w, h, t.radius, bg);
        ui.canvas.strokeRoundedRect(x, y, w, h, t.radius, 1, t.border);
        ui.drawTextIn(.{ .x = x + pad, .y = y + 5, .w = tw, .h = th }, s, .left, t.font_size, .regular, t.text);
    }

    // --- tab bar -----------------------------------------------------------------------------------------

    /// Segmented control across the available width. Returns true when the active tab
    /// changed.
    pub fn tabBar(ui: *Ui, id_str: []const u8, labels: []const []const u8, active: *usize) bool {
        if (labels.len == 0) return false;
        const t = ui.theme;
        ui.pushIdScope(id_str);
        defer ui.popIdScope();
        const r = ui.allocRect(ui.availW(), t.ctl_h);
        ui.canvas.fillRoundedRect(r.x, r.y, r.w, r.h, t.radius, t.bg_widget);
        const tw = r.w / @as(f32, @floatFromInt(labels.len));
        var changed = false;
        for (labels, 0..) |lb, i| {
            const tr = Rect{ .x = r.x + tw * @as(f32, @floatFromInt(i)), .y = r.y, .w = tw, .h = r.h };
            const id = ui.makeId(lb);
            const sig = ui.interact(id, tr);
            if (sig.clicked and active.* != i) {
                active.* = i;
                changed = true;
            }
            const ht = ui.hoverT(id, sig.hovered);
            if (i == active.*) {
                ui.canvas.fillRoundedRect(tr.x + 2, tr.y + 2, tr.w - 4, tr.h - 4, t.radius - 2, t.accent);
            } else if (ht > 0.01) {
                var bg = t.bg_widget_hot;
                bg.a *= ht;
                ui.canvas.fillRoundedRect(tr.x + 2, tr.y + 2, tr.w - 4, tr.h - 4, t.radius - 2, bg);
            }
            ui.drawTextIn(tr, lb, .center, t.font_size, .regular, if (i == active.*) t.accent_text else t.text);
        }
        return changed;
    }

    // --- scroll area ---------------------------------------------------------------------------------------

    /// Clipped, wheel-scrollable vertical region of fixed viewport height. Content is
    /// laid out normally inside; [`endScroll`] clamps the offset, draws a thin
    /// scrollbar and consumes the wheel when hovered.
    pub fn beginScroll(ui: *Ui, id_str: []const u8, viewport_h: f32) void {
        const id = ui.makeId(id_str);
        const c = ui.cur();
        const vp = Rect{ .x = c.x, .y = c.y, .w = ui.availW(), .h = viewport_h };
        const off = ui.store.scrolls.get(id) orelse 0;

        std.debug.assert(ui.clip_depth < ui.saved_clips.len);
        const saved_canvas = ui.canvas.setClip(
            @intFromFloat(@max(0, vp.x)),
            @intFromFloat(@max(0, vp.y)),
            @intFromFloat(@max(0, vp.w)),
            @intFromFloat(@max(0, vp.h)),
        );
        ui.saved_clips[ui.clip_depth] = .{ .rect = ui.clip, .canvas = saved_canvas, .id = id, .top = vp.y, .viewport_h = viewport_h };
        ui.clip_depth += 1;
        ui.clip = ui.clip.intersect(vp);

        std.debug.assert(ui.depth < ui.cursors.len);
        ui.cursors[ui.depth] = .{
            .dir = .v,
            .x = vp.x,
            .y = vp.y - off,
            .start_x = vp.x,
            .start_y = vp.y - off,
            .avail_w = vp.w - 10, // leave a scrollbar gutter
        };
        ui.depth += 1;
    }

    pub fn endScroll(ui: *Ui) void {
        const t = ui.theme;
        std.debug.assert(ui.depth > 1 and ui.clip_depth > 0);
        const inner = ui.cur();
        const content_h = inner.y - inner.start_y;
        ui.depth -= 1;

        ui.clip_depth -= 1;
        const saved = ui.saved_clips[ui.clip_depth];
        const id = saved.id;
        const viewport_h = saved.viewport_h;
        const vp_top = saved.top;

        const max_off = @max(0, content_h - viewport_h);
        var off = ui.store.scrolls.get(id) orelse 0;

        const c = ui.cur();
        const vp = Rect{ .x = c.x, .y = vp_top, .w = ui.availW(), .h = viewport_h };
        const hovered = ui.inputEnabled() and vp.contains(ui.store.mouse_x, ui.store.mouse_y);
        if (hovered and ui.store.wheel != 0) {
            off += ui.store.wheel;
            ui.store.wheel = 0; // consumed
        }
        off = std.math.clamp(off, 0, max_off);
        ui.store.scrolls.put(ui.store.gpa, id, off) catch {};

        // thin scrollbar
        if (max_off > 0) {
            const track_h = viewport_h - 4;
            const thumb_h = @max(24, track_h * viewport_h / content_h);
            const ty = vp_top + 2 + (track_h - thumb_h) * (off / max_off);
            const tx = vp.x + vp.w - 6;
            ui.canvas.fillRoundedRect(tx, ty, 4, thumb_h, 2, Color.rgba(255, 255, 255, if (hovered) 0.35 else 0.18));
        }

        // restore clip and advance the parent cursor past the viewport
        ui.clip = saved.rect;
        ui.canvas.clip = saved.canvas;
        c.y += viewport_h + t.gap;
        c.cross = @max(c.cross, vp.w);
        ui.last_rect = vp;
    }

    // --- card ------------------------------------------------------------------------------------------------

    /// Fixed-height card: background painted immediately, content laid out inside with
    /// padding. (Auto-height would need a second pass — deliberate slice-1 limit.)
    pub fn beginCard(ui: *Ui, h: f32) void {
        const t = ui.theme;
        const c = ui.cur();
        const r = Rect{ .x = c.x, .y = c.y, .w = ui.availW(), .h = h };
        ui.canvas.fillRoundedRect(r.x, r.y, r.w, r.h, t.radius + 2, t.bg_card);
        ui.canvas.strokeRoundedRect(r.x, r.y, r.w, r.h, t.radius + 2, 1, t.border);
        std.debug.assert(ui.depth < ui.cursors.len);
        ui.cursors[ui.depth] = .{
            .dir = .v,
            .x = r.x + t.pad_x,
            .y = r.y + t.pad_x,
            .start_x = r.x + t.pad_x,
            .start_y = r.y + t.pad_x,
            .avail_w = r.w - 2 * t.pad_x,
        };
        ui.depth += 1;
        ui.last_rect = r;
        // remember the outer advance on the saved cursor itself
        c.y += h + t.gap;
        c.cross = @max(c.cross, r.w);
    }

    pub fn endCard(ui: *Ui) void {
        std.debug.assert(ui.depth > 1);
        ui.depth -= 1;
    }

    // --- modal dialog -------------------------------------------------------------------------------------------

    pub fn openDialog(ui: *Ui, id_str: []const u8) void {
        ui.store.modal = ui.makeId(id_str);
    }

    pub fn dialogOpen(ui: *Ui, id_str: []const u8) bool {
        return ui.store.modal == ui.makeId(id_str);
    }

    pub fn closeDialog(ui: *Ui) void {
        ui.store.modal = 0;
        ui.in_modal = false;
    }

    /// Centered modal panel. Contract: call this AFTER building the underlying UI (the
    /// dim + panel paint over it), and only lay dialog content while it returns true;
    /// finish with [`endDialog`]. Esc and the ✕ button close it.
    pub fn beginDialog(ui: *Ui, id_str: []const u8, title: []const u8, w: f32, h: f32) bool {
        const t = ui.theme;
        const id = ui.makeId(id_str);
        if (ui.store.modal != id) return false;
        ui.in_modal = true;

        // Esc closes.
        for (ui.store.keys[0..ui.store.keys_len]) |k| {
            if (k == .escape) {
                ui.closeDialog();
                return false;
            }
        }

        // Dim everything under the dialog.
        ui.canvas.fillRoundedRect(ui.bounds.x, ui.bounds.y, ui.bounds.w, ui.bounds.h, 0, t.dim_overlay);

        const r = Rect{
            .x = ui.bounds.x + (ui.bounds.w - w) / 2,
            .y = ui.bounds.y + (ui.bounds.h - h) / 2,
            .w = w,
            .h = h,
        };
        ui.dialog_rect = r;
        var bg = lerpColor(Color.rgba(26, 29, 40, 0.97), t.bg_card, 0.2);
        bg.a = 0.97;
        ui.canvas.fillRoundedRect(r.x, r.y, r.w, r.h, t.radius + 4, bg);
        ui.canvas.strokeRoundedRect(r.x, r.y, r.w, r.h, t.radius + 4, 1, t.border);

        // Title row + close button.
        const title_h: f32 = 40;
        var tr = r;
        tr.x += t.pad_x + 2;
        tr.h = title_h;
        tr.w -= 2 * t.pad_x;
        ui.drawTextIn(tr, title, .left, t.font_heading, .bold, t.text);
        const xr = Rect{ .x = r.x + r.w - 34, .y = r.y + 8, .w = 26, .h = 26 };
        if (ui.squareButton(xr, "x")) {
            ui.closeDialog();
            return false;
        }

        // A press outside the panel closes (and is consumed by modality anyway).
        if (ui.store.left_pressed and !r.contains(ui.store.mouse_x, ui.store.mouse_y)) {
            ui.closeDialog();
            return false;
        }

        std.debug.assert(ui.depth < ui.cursors.len);
        ui.dialog_saved_cursor = ui.cursors[ui.depth - 1];
        ui.cursors[ui.depth] = .{
            .dir = .v,
            .x = r.x + t.pad_x + 2,
            .y = r.y + title_h + 4,
            .start_x = r.x + t.pad_x + 2,
            .start_y = r.y + title_h + 4,
            .avail_w = r.w - 2 * (t.pad_x + 2),
        };
        ui.depth += 1;
        return true;
    }

    pub fn endDialog(ui: *Ui) void {
        std.debug.assert(ui.depth > 1);
        ui.depth -= 1;
        ui.in_modal = false;
    }
};

// --- tests ---------------------------------------------------------------------------------

const testing = std.testing;

const Harness = struct {
    buf: []u32,
    canvas: paint.Canvas,
    font: text.Font,
    store: Store,

    fn init(gpa: std.mem.Allocator) !Harness {
        const w = 360;
        const h = 280;
        const buf = try gpa.alloc(u32, w * h);
        @memset(buf, 0);
        return .{
            .buf = buf,
            .canvas = paint.Canvas.init(buf, w, h),
            .font = try text.Font.initDefault(gpa),
            .store = Store.init(gpa),
        };
    }

    fn deinit(h: *Harness, gpa: std.mem.Allocator) void {
        h.store.deinit();
        h.font.deinit();
        gpa.free(h.buf);
    }

    fn frame(h: *Harness, now: i64, events: []const InputEvent) Ui {
        return Ui.begin(&h.store, &h.canvas, &h.font, Theme.dark(), .{ .x = 0, .y = 0, .w = 360, .h = 280 }, now, events);
    }
};

test "button: click fires on release inside; press outside never clicks" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);

    // Frame 1: hover the button (first widget: near top-left inside window pad).
    var ui = h.frame(10, &.{.{ .motion = .{ .x = 30, .y = 25 } }});
    try testing.expect(!ui.button("Ok"));
    const r = ui.last_rect;
    _ = ui.end();
    try testing.expect(r.contains(30, 25));

    // Frame 2: press.
    ui = h.frame(20, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = true } }});
    try testing.expect(!ui.button("Ok"));
    _ = ui.end();

    // Frame 3: release → the click.
    ui = h.frame(30, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = false } }});
    try testing.expect(ui.button("Ok"));
    _ = ui.end();

    // Press on empty ground, drag onto the button, release: no click.
    ui = h.frame(40, &.{ .{ .motion = .{ .x = 300, .y = 250 } }, .{ .button = .{ .button = BTN_LEFT, .pressed = true } } });
    try testing.expect(!ui.button("Ok"));
    _ = ui.end();
    ui = h.frame(50, &.{ .{ .motion = .{ .x = 30, .y = 25 } }, .{ .button = .{ .button = BTN_LEFT, .pressed = false } } });
    try testing.expect(!ui.button("Ok"));
    _ = ui.end();
}

test "layout: vertical stack with gap; row places side by side" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);

    var ui = h.frame(10, &.{});
    _ = ui.button("A");
    const ra = ui.last_rect;
    _ = ui.button("B");
    const rb = ui.last_rect;
    try testing.expectEqual(ra.x, rb.x);
    try testing.expectApproxEqAbs(ra.y + ra.h + ui.theme.gap, rb.y, 0.01);

    ui.beginRow();
    _ = ui.button("C");
    const rc = ui.last_rect;
    _ = ui.button("D");
    const rd = ui.last_rect;
    ui.endRow();
    try testing.expectEqual(rc.y, rd.y);
    try testing.expectApproxEqAbs(rc.x + rc.w + ui.theme.gap, rd.x, 0.01);
    _ = ui.end();
}

test "ids: same label in different scopes stays distinct" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);
    var ui = h.frame(10, &.{});
    ui.pushIdScope("a");
    const id_a = ui.makeId("Ok");
    ui.popIdScope();
    ui.pushIdScope("b");
    const id_b = ui.makeId("Ok");
    ui.popIdScope();
    try testing.expect(id_a != id_b);
    _ = ui.end();
}

test "textField: type, backspace, arrows, submit" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // Focus by click (field is the first widget).
    var ui = h.frame(10, &.{ .{ .motion = .{ .x = 40, .y = 25 } }, .{ .button = .{ .button = BTN_LEFT, .pressed = true } } });
    _ = ui.textField("name", &buf);
    _ = ui.end();
    try testing.expect(h.store.wantsKeyboard());

    // Type "as" (evdev 30 = a, 31 = s).
    ui = h.frame(20, &.{ .{ .key = .{ .code = 30, .pressed = true } }, .{ .key = .{ .code = 31, .pressed = true } } });
    try testing.expectEqual(Ui.TextEdit.changed, ui.textField("name", &buf));
    _ = ui.end();
    try testing.expectEqualStrings("as", buf.items);

    // Backspace → "a".
    ui = h.frame(30, &.{.{ .key = .{ .code = 14, .pressed = true } }});
    try testing.expectEqual(Ui.TextEdit.changed, ui.textField("name", &buf));
    _ = ui.end();
    try testing.expectEqualStrings("a", buf.items);

    // Home, then type "s" at the start → "sa".
    ui = h.frame(40, &.{ .{ .key = .{ .code = 102, .pressed = true } }, .{ .key = .{ .code = 31, .pressed = true } } });
    _ = ui.textField("name", &buf);
    _ = ui.end();
    try testing.expectEqualStrings("sa", buf.items);

    // Enter submits and unfocuses.
    ui = h.frame(50, &.{.{ .key = .{ .code = 28, .pressed = true } }});
    try testing.expectEqual(Ui.TextEdit.submitted, ui.textField("name", &buf));
    _ = ui.end();
    try testing.expect(!h.store.wantsKeyboard());
}

test "toggle and checkbox flip on click" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);
    var on = false;

    var ui = h.frame(10, &.{.{ .motion = .{ .x = 30, .y = 25 } }});
    _ = ui.toggle("Power", &on);
    _ = ui.end();
    ui = h.frame(20, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = true } }});
    _ = ui.toggle("Power", &on);
    _ = ui.end();
    ui = h.frame(30, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = false } }});
    try testing.expect(ui.toggle("Power", &on));
    _ = ui.end();
    try testing.expect(on);
}

test "scroll area: wheel scrolls and clamps" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);

    // 40 rows of 20px in a 100px viewport → max offset = 40*(20+gap) - gap? — just
    // check monotonic clamping behaviour.
    const build = struct {
        fn run(ui: *Ui) void {
            ui.beginScroll("list", 100);
            var i: usize = 0;
            while (i < 40) : (i += 1) {
                ui.pushIdScopeIndex(i);
                ui.label("row");
                ui.popIdScope();
            }
            ui.endScroll();
        }
    }.run;

    // Hover the viewport and wheel down a lot → offset clamps to max.
    var ui = h.frame(10, &.{ .{ .motion = .{ .x = 100, .y = 60 } }, .{ .scroll = .{ .axis = 0, .px = 1.0e6 } } });
    build(&ui);
    _ = ui.end();
    const id = blk: {
        var ui2 = h.frame(20, &.{});
        defer _ = ui2.end();
        break :blk ui2.makeId("list");
    };
    const max_off = h.store.scrolls.get(id).?;
    try testing.expect(max_off > 0);

    // Wheel back way past the top → clamps to 0.
    ui = h.frame(30, &.{.{ .scroll = .{ .axis = 0, .px = -1.0e6 } }});
    build(&ui);
    _ = ui.end();
    try testing.expectEqual(@as(f32, 0), h.store.scrolls.get(id).?);
}

test "dropdown: opens on click, selects via next-frame click on the overlay" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);
    const options = [_][]const u8{ "uno", "due", "tre" };
    var sel: usize = 0;

    // Click the closed dropdown (full-width control at the top).
    var ui = h.frame(10, &.{.{ .motion = .{ .x = 100, .y = 25 } }});
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    ui = h.frame(20, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = true } }});
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    ui = h.frame(30, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = false } }});
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    try testing.expect(h.store.dd_open != 0);
    try testing.expect(h.store.dd_rects.items.len == 3);

    // Click option 1 ("due"): position over its stored rect, press.
    const r1 = h.store.dd_rects.items[1];
    ui = h.frame(40, &.{ .{ .motion = .{ .x = r1.x + 5, .y = r1.y + 5 } }, .{ .button = .{ .button = BTN_LEFT, .pressed = true } } });
    const changed = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    try testing.expect(changed);
    try testing.expectEqual(@as(usize, 1), sel);
    try testing.expectEqual(@as(Id, 0), h.store.dd_open);
}

test "dialog: modality blocks the UI underneath" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);

    var clicked_under = false;
    // Open the dialog, then click where the underlying button sits: no click.
    var ui = h.frame(10, &.{.{ .motion = .{ .x = 30, .y = 25 } }});
    _ = ui.button("Under");
    ui.openDialog("dlg");
    if (ui.beginDialog("dlg", "Dialog", 200, 120)) ui.endDialog();
    _ = ui.end();

    ui = h.frame(20, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = true } }});
    clicked_under = ui.button("Under");
    if (ui.beginDialog("dlg", "Dialog", 200, 120)) ui.endDialog();
    _ = ui.end();
    ui = h.frame(30, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = false } }});
    clicked_under = ui.button("Under") or clicked_under;
    if (ui.beginDialog("dlg", "Dialog", 200, 120)) ui.endDialog();
    _ = ui.end();
    try testing.expect(!clicked_under);
    try testing.expect(h.store.modal == 0); // the press outside the panel closed it
}

test "dropdown: Esc closes and the key is consumed" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);
    const options = [_][]const u8{ "uno", "due", "tre" };
    var sel: usize = 0;

    var ui = h.frame(10, &.{.{ .motion = .{ .x = 100, .y = 25 } }});
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    ui = h.frame(20, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = true } }});
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    ui = h.frame(30, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = false } }});
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    try testing.expect(h.store.dd_open != 0);

    // Esc (evdev 1) closes; the pre-pass strips it so nothing else sees it.
    ui = h.frame(40, &.{.{ .key = .{ .code = 1, .pressed = true } }});
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    try testing.expectEqual(@as(Id, 0), h.store.dd_open);
    try testing.expectEqual(@as(usize, 0), h.store.keys_len);
    try testing.expectEqual(@as(usize, 0), sel);
}

test "dropdown: arrows move the highlight, Enter selects" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);
    const options = [_][]const u8{ "uno", "due", "tre" };
    var sel: usize = 0;

    var ui = h.frame(10, &.{.{ .motion = .{ .x = 100, .y = 25 } }});
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    ui = h.frame(20, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = true } }});
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    ui = h.frame(30, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = false } }});
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    try testing.expect(h.store.dd_open != 0);
    try testing.expectEqual(@as(?usize, 0), h.store.dd_hover); // starts at the selection

    // Down twice (evdev 108) → highlight on "tre"; clamped at the end of the list.
    ui = h.frame(40, &.{ .{ .key = .{ .code = 108, .pressed = true } }, .{ .key = .{ .code = 108, .pressed = true } }, .{ .key = .{ .code = 108, .pressed = true } } });
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    try testing.expectEqual(@as(?usize, 2), h.store.dd_hover);

    // Enter (evdev 28) picks it and closes.
    ui = h.frame(50, &.{.{ .key = .{ .code = 28, .pressed = true } }});
    const changed = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    try testing.expect(changed);
    try testing.expectEqual(@as(usize, 2), sel);
    try testing.expectEqual(@as(Id, 0), h.store.dd_open);
}

test "dropdown: long list is capped and scrolls; clicks outside the panel never select" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);
    var bufs: [30][8]u8 = undefined;
    var options: [30][]const u8 = undefined;
    for (0..30) |i| options[i] = std.fmt.bufPrint(&bufs[i], "op{d}", .{i}) catch unreachable;
    var sel: usize = 0;

    var ui = h.frame(10, &.{.{ .motion = .{ .x = 100, .y = 25 } }});
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    ui = h.frame(20, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = true } }});
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    ui = h.frame(30, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = false } }});
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    try testing.expect(h.store.dd_open != 0);

    // The panel is capped well below the 30-item content height.
    const panel = h.store.dd_panel;
    const content_h = @as(f32, 30) * Theme.dark().ctl_h + 8;
    try testing.expect(panel.h < content_h);

    // An item rect past the panel bottom exists; pressing there must NOT select it
    // (it is a click-away: closes without changing the selection).
    var out_idx: ?usize = null;
    for (h.store.dd_rects.items, 0..) |r, i| {
        if (r.y > panel.y + panel.h) {
            out_idx = i;
            break;
        }
    }
    try testing.expect(out_idx != null);
    const out = h.store.dd_rects.items[out_idx.?];
    ui = h.frame(40, &.{ .{ .motion = .{ .x = out.x + 5, .y = out.y + 5 } }, .{ .button = .{ .button = BTN_LEFT, .pressed = true } } });
    const changed = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    try testing.expect(!changed);
    try testing.expectEqual(@as(usize, 0), sel);
    try testing.expectEqual(@as(Id, 0), h.store.dd_open);

    // Reopen, wheel over the panel: the list scrolls (offset clamps to the content).
    ui = h.frame(50, &.{ .{ .motion = .{ .x = 100, .y = 25 } }, .{ .button = .{ .button = BTN_LEFT, .pressed = true } } });
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    ui = h.frame(60, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = false } }});
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    try testing.expect(h.store.dd_open != 0);
    const p = h.store.dd_panel;
    ui = h.frame(70, &.{ .{ .motion = .{ .x = p.x + p.w / 2, .y = p.y + p.h / 2 } }, .{ .scroll = .{ .axis = 0, .px = 1.0e6 } } });
    _ = ui.dropdown("dd", &options, &sel);
    _ = ui.end();
    try testing.expect(h.store.dd_scroll > 0);
    try testing.expect(h.store.dd_scroll <= content_h - p.h + 1);
}

test "radio: click picks exactly one option" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);
    var sel: usize = 0;

    // Lay out two options, remember where the second lands.
    var ui = h.frame(10, &.{});
    _ = ui.radio("Alfa", &sel, 0);
    _ = ui.radio("Beta", &sel, 1);
    const rb = ui.last_rect;
    _ = ui.end();

    // Hover + press + release on "Beta".
    ui = h.frame(20, &.{ .{ .motion = .{ .x = rb.x + 5, .y = rb.y + rb.h / 2 } }, .{ .button = .{ .button = BTN_LEFT, .pressed = true } } });
    _ = ui.radio("Alfa", &sel, 0);
    _ = ui.radio("Beta", &sel, 1);
    _ = ui.end();
    ui = h.frame(30, &.{.{ .button = .{ .button = BTN_LEFT, .pressed = false } }});
    _ = ui.radio("Alfa", &sel, 0);
    const changed = ui.radio("Beta", &sel, 1);
    _ = ui.end();
    try testing.expect(changed);
    try testing.expectEqual(@as(usize, 1), sel);
}

test "textField: shift-selection, clipboard copy/paste, replace-typing" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "hello world");

    // Focus with a click, then End → caret after "world".
    var ui = h.frame(10, &.{ .{ .motion = .{ .x = 100, .y = 25 } }, .{ .button = .{ .button = BTN_LEFT, .pressed = true } } });
    _ = ui.textField("f", &buf);
    _ = ui.end();
    ui = h.frame(20, &.{ .{ .button = .{ .button = BTN_LEFT, .pressed = false } }, .{ .key = .{ .code = 107, .pressed = true } } });
    _ = ui.textField("f", &buf);
    _ = ui.end();
    try testing.expect(h.store.focus != 0);
    try testing.expectEqual(@as(usize, 11), h.store.text_cursor);

    // Shift+Left ×5 selects "world"; ctrl+C copies it.
    ui = h.frame(30, &.{ .{ .key = .{ .code = 42, .pressed = true } }, .{ .key = .{ .code = 105, .pressed = true } }, .{ .key = .{ .code = 105, .pressed = true } }, .{ .key = .{ .code = 105, .pressed = true } }, .{ .key = .{ .code = 105, .pressed = true } }, .{ .key = .{ .code = 105, .pressed = true } } });
    _ = ui.textField("f", &buf);
    _ = ui.end();
    try testing.expectEqual(@as(?usize, 11), h.store.text_anchor);
    try testing.expectEqual(@as(usize, 6), h.store.text_cursor);
    ui = h.frame(40, &.{ .{ .key = .{ .code = 42, .pressed = false } }, .{ .key = .{ .code = 29, .pressed = true } }, .{ .key = .{ .code = 46, .pressed = true } } });
    _ = ui.textField("f", &buf);
    _ = ui.end();
    try testing.expectEqualStrings("world", h.store.clipboard.items);
    try testing.expectEqualStrings("hello world", buf.items); // copy does not edit

    // Home, then ctrl+V pastes at the start.
    ui = h.frame(50, &.{ .{ .key = .{ .code = 29, .pressed = false } }, .{ .key = .{ .code = 102, .pressed = true } } });
    _ = ui.textField("f", &buf);
    _ = ui.end();
    ui = h.frame(60, &.{ .{ .key = .{ .code = 29, .pressed = true } }, .{ .key = .{ .code = 47, .pressed = true } } });
    const pasted = ui.textField("f", &buf);
    _ = ui.end();
    try testing.expectEqual(Ui.TextEdit.changed, pasted);
    try testing.expectEqualStrings("worldhello world", buf.items);
    try testing.expectEqual(@as(usize, 5), h.store.text_cursor);

    // Ctrl+A then a plain char replaces everything.
    ui = h.frame(70, &.{.{ .key = .{ .code = 30, .pressed = true } }});
    _ = ui.textField("f", &buf);
    _ = ui.end();
    ui = h.frame(80, &.{ .{ .key = .{ .code = 29, .pressed = false } }, .{ .key = .{ .code = 16, .pressed = true } } });
    _ = ui.textField("f", &buf);
    _ = ui.end();
    try testing.expectEqualStrings("q", buf.items);
}

test "textField: Tab traversal tra i campi, con wrap e Shift+Tab" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);
    var b1: std.ArrayList(u8) = .empty;
    var b2: std.ArrayList(u8) = .empty;
    defer b1.deinit(gpa);
    defer b2.deinit(gpa);
    try b1.appendSlice(gpa, "uno");

    const ids = blk: {
        var ui2 = h.frame(5, &.{});
        defer _ = ui2.end();
        break :blk [2]Id{ ui2.makeId("f1"), ui2.makeId("f2") };
    };
    const build = struct {
        fn run(ui: *Ui, a: *std.ArrayList(u8), b: *std.ArrayList(u8)) void {
            _ = ui.textField("f1", a);
            _ = ui.textField("f2", b);
        }
    }.run;

    // Tab with nothing focused → the first field, with select-all on arrival.
    var ui = h.frame(10, &.{.{ .key = .{ .code = 15, .pressed = true } }});
    build(&ui, &b1, &b2);
    _ = ui.end();
    try testing.expectEqual(ids[0], h.store.focus);
    ui = h.frame(20, &.{});
    build(&ui, &b1, &b2);
    _ = ui.end();
    try testing.expectEqual(@as(?usize, 0), h.store.text_anchor);
    try testing.expectEqual(@as(usize, 3), h.store.text_cursor);

    // Tab → second field; Tab again → wraps back to the first.
    ui = h.frame(30, &.{.{ .key = .{ .code = 15, .pressed = true } }});
    build(&ui, &b1, &b2);
    _ = ui.end();
    try testing.expectEqual(ids[1], h.store.focus);
    ui = h.frame(40, &.{.{ .key = .{ .code = 15, .pressed = true } }});
    build(&ui, &b1, &b2);
    _ = ui.end();
    try testing.expectEqual(ids[0], h.store.focus);

    // Shift+Tab from the first wraps backwards to the last.
    ui = h.frame(50, &.{ .{ .key = .{ .code = 42, .pressed = true } }, .{ .key = .{ .code = 15, .pressed = true } } });
    build(&ui, &b1, &b2);
    _ = ui.end();
    try testing.expectEqual(ids[1], h.store.focus);

    // Shift+Tab again (shift still held) → back to the first.
    ui = h.frame(60, &.{.{ .key = .{ .code = 15, .pressed = true } }});
    build(&ui, &b1, &b2);
    _ = ui.end();
    try testing.expectEqual(ids[0], h.store.focus);
}

test "slider: press on track sets the value" {
    const gpa = testing.allocator;
    var h = try Harness.init(gpa);
    defer h.deinit(gpa);
    var v: f32 = 0;

    // The slider is the first widget; its track spans most of the width. Press at
    // ~half of the window.
    var ui = h.frame(10, &.{ .{ .motion = .{ .x = 180, .y = 25 } }, .{ .button = .{ .button = BTN_LEFT, .pressed = true } } });
    const changed = ui.slider("", &v, 0, 100);
    _ = ui.end();
    try testing.expect(changed);
    try testing.expect(v > 20 and v < 80);
}
