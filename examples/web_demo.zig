//! zicro on the WEB — an app written against the `zicro.window` contract, in a browser.
//!
//! This is the SAME shape as the native `demo.zig`: an `AppState`, `on_draw`/`on_key`/
//! `on_mouse`/`on_tick` callbacks, an immediate-mode `Ui` rebuilt each frame. The only
//! web-specific line is `zicroBoot` (wasm has no auto-`main`, so JS calls it once to
//! create the window); everything else is the platform-agnostic toolkit. The web `Window`
//! backend (`window_web.zig`) owns the exported ABI and calls these callbacks — the
//! browser drives the loop that a native `run()` would.
//!
//!   zig build web   → zig-out/web/{zicro.wasm,index.html}

const std = @import("std");
const zicro = @import("zicro");
const window = zicro.window; // the web Window backend on this target
const paint = zicro.paint;
const text = zicro.text;
const widget = zicro.widget;
const Color = paint.Color;

const gpa = std.heap.wasm_allocator;

const Preset = struct { name: []const u8, dark_bg: bool, make: *const fn () widget.Theme };
const presets = [_]Preset{
    .{ .name = "signature", .dark_bg = true, .make = &widget.Theme.signature },
    .{ .name = "signature · light", .dark_bg = false, .make = &widget.Theme.signatureLight },
    .{ .name = "macOS", .dark_bg = true, .make = &widget.Theme.macos },
    .{ .name = "macOS · light", .dark_bg = false, .make = &widget.Theme.macosLight },
    .{ .name = "Material 3", .dark_bg = true, .make = &widget.Theme.material },
    .{ .name = "Material 3 · light", .dark_bg = false, .make = &widget.Theme.materialLight },
    .{ .name = "dark", .dark_bg = true, .make = &widget.Theme.dark },
    .{ .name = "light", .dark_bg = false, .make = &widget.Theme.light },
};

const AppState = struct {
    font: text.Font,
    store: widget.Store,
    queue: widget.InputQueue = .{},
    theme_idx: usize = 0,
    active_tab: usize = 0,
    button_clicks: usize = 0,
    primary_clicks: usize = 0,
    checkbox_val: bool = false,
    toggle_val: bool = true,
    radio_val: usize = 0,
    slider_val: f32 = 0.5,
    stepper_val: i64 = 42,
    dropdown_val: usize = 0,
    progress_val: f32 = 0,
    selectable_vals: [3]bool = .{ false, true, false },
    name_buf: std.ArrayList(u8) = .empty,
};

var state: AppState = undefined;
var booted = false;

/// The one web-specific entry: JS calls this once (there is no auto-main on wasm) to
/// build the app state and open the window. From here on it's the native contract.
export fn zicroBoot() void {
    if (booted) return;
    state = .{
        .font = text.Font.initDefault(gpa) catch return,
        .store = widget.Store.init(gpa),
    };
    state.name_buf.appendSlice(gpa, "zicro web") catch {};
    _ = window.Window.init(gpa, undefined, .{
        .title = "zicro-web-demo",
        .width = 1000,
        .height = 720,
        .on_draw = onDraw,
        .on_key = onKey,
        .on_mouse = onMouse,
        .on_tick = onTick,
        .user = &state,
    }) catch return;
    booted = true;
}

fn onTick(win: *window.Window, user: ?*anyopaque) void {
    const s: *AppState = @ptrCast(@alignCast(user.?));
    s.progress_val += 0.004;
    if (s.progress_val > 1) s.progress_val = 0;
    win.requestRedraw();
}

fn onKey(win: *window.Window, key: u32, kstate: u32, user: ?*anyopaque) void {
    const s: *AppState = @ptrCast(@alignCast(user.?));
    s.queue.push(.{ .key = .{ .code = key, .pressed = kstate == 1 } });
    win.requestRedraw();
}

fn onMouse(win: *window.Window, event: window.MouseEvent, user: ?*anyopaque) void {
    const s: *AppState = @ptrCast(@alignCast(user.?));
    switch (event.kind) {
        .motion => s.queue.push(.{ .motion = .{ .x = event.x, .y = event.y } }),
        .press => s.queue.push(.{ .button = .{ .button = event.button, .pressed = true } }),
        .release => s.queue.push(.{ .button = .{ .button = event.button, .pressed = false } }),
        .scroll => s.queue.push(.{ .scroll = .{ .axis = 0, .px = event.scroll_dy } }),
    }
    win.requestRedraw();
}

fn onDraw(canvas: *paint.Canvas, content: window.Rect, user: ?*anyopaque) void {
    const s: *AppState = @ptrCast(@alignCast(user.?));
    const preset = presets[s.theme_idx % presets.len];

    const bg = if (preset.dark_bg) Color.rgba(18, 20, 26, 1.0) else Color.rgba(240, 242, 245, 1.0);
    canvas.fillRoundedRect(@floatFromInt(content.x), @floatFromInt(content.y), @floatFromInt(content.w), @floatFromInt(content.h), 0, bg);

    const bounds = widget.Rect{ .x = @floatFromInt(content.x), .y = @floatFromInt(content.y), .w = @floatFromInt(content.w), .h = @floatFromInt(content.h) };
    // HiDPI: the buffer is physical pixels, so scale the theme (and the layout literals
    // below, via `ui.theme.s`) by devicePixelRatio — widgets keep their visual size and
    // render crisp at native resolution.
    const theme = preset.make().scaled(window.scaleFactor());
    var ui = widget.Ui.begin(&s.store, canvas, &s.font, theme, bounds, window.nowMs(), s.queue.take());

    ui.beginCard(ui.theme.s(64));
    ui.beginRow();
    ui.heading("zicro · web");
    ui.gap(ui.theme.s(24));
    ui.labelDim("Theme:");
    if (ui.buttonPrimary(preset.name)) s.theme_idx +%= 1;
    ui.gap(ui.theme.s(16));
    ui.labelDim("(click to cycle)");
    ui.endRow();
    ui.endCard();
    ui.gap(ui.theme.s(10));

    const tabs = &[_][]const u8{ "Basic Widgets", "Input Avanzati", "Indicators", "Scroll" };
    _ = ui.tabBar("main_tabs", tabs, &s.active_tab);
    ui.gap(ui.theme.s(12));

    switch (s.active_tab) {
        0 => {
            ui.beginCard(ui.theme.s(300));
            ui.heading("Pulsanti e selezioni");
            ui.separator();
            ui.gap(ui.theme.s(5));
            ui.beginRow();
            if (ui.button("Button")) s.button_clicks += 1;
            if (ui.buttonPrimary("Primary")) s.primary_clicks += 1;
            ui.endRow();
            ui.gap(ui.theme.s(5));
            ui.beginRow();
            ui.labelDim("click:");
            var b: [48]u8 = undefined;
            ui.label(std.fmt.bufPrint(&b, "{d} / {d}", .{ s.button_clicks, s.primary_clicks }) catch "0 / 0");
            ui.endRow();
            ui.separator();
            ui.gap(ui.theme.s(5));
            ui.beginRow();
            _ = ui.checkbox("Enable", &s.checkbox_val);
            _ = ui.toggle("Notifiche", &s.toggle_val);
            ui.endRow();
            ui.gap(ui.theme.s(5));
            ui.beginRow();
            ui.label("Radio:");
            _ = ui.radio("A", &s.radio_val, 0);
            _ = ui.radio("B", &s.radio_val, 1);
            _ = ui.radio("C", &s.radio_val, 2);
            ui.endRow();
            ui.endCard();
        },
        1 => {
            ui.beginCard(ui.theme.s(320));
            ui.heading("Controlli avanzati");
            ui.separator();
            ui.gap(ui.theme.s(5));
            _ = ui.stepper("Counter", &s.stepper_val, 0, 100);
            ui.gap(ui.theme.s(8));
            _ = ui.slider("Volume", &s.slider_val, 0, 1);
            ui.gap(ui.theme.s(10));
            ui.beginRow();
            ui.label("Name:");
            _ = ui.textField("name_field", &s.name_buf);
            ui.endRow();
            ui.gap(ui.theme.s(10));
            ui.beginRow();
            ui.label("Menu:");
            const opts = &[_][]const u8{ "Option 1", "Option 2", "Option 3", "Option 4" };
            _ = ui.dropdown("opts_dd", opts, &s.dropdown_val);
            ui.endRow();
            ui.endCard();
        },
        2 => {
            ui.beginCard(ui.theme.s(280));
            ui.heading("Status");
            ui.separator();
            ui.gap(ui.theme.s(10));
            ui.label("Avanzamento");
            ui.progressBar(s.progress_val);
            ui.gap(ui.theme.s(10));
            ui.progressIndeterminate();
            ui.gap(ui.theme.s(10));
            ui.beginRow();
            ui.label("Spinner:");
            ui.spinner();
            ui.endRow();
            ui.endCard();
        },
        else => {
            ui.beginCard(ui.theme.s(300));
            ui.heading("Lista scorrevole");
            ui.separator();
            ui.gap(ui.theme.s(5));
            ui.beginScroll("list", ui.theme.s(220));
            var i: usize = 0;
            while (i < 24) : (i += 1) {
                ui.pushIdScopeIndex(i);
                var ib: [48]u8 = undefined;
                const str = std.fmt.bufPrint(&ib, "Item {d}", .{i}) catch "Item";
                const sel = i % 3;
                if (ui.selectable(str, s.selectable_vals[sel])) s.selectable_vals[sel] = !s.selectable_vals[sel];
                ui.popIdScope();
            }
            ui.endScroll();
            ui.endCard();
        },
    }

    _ = ui.end();
}
