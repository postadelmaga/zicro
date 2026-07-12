//! zicro on the WEB — the full immediate-mode widget toolkit in a browser tab.
//!
//! The whole render + widget stack is platform-independent CPU code, so the web port is
//! just an event/loop shim: this wasm module owns an RGBA buffer, a `widget.Store`, a
//! `Font` and an `InputQueue`; the JS glue (`web/index.html`) drives one `zicroFrame`
//! per requestAnimationFrame, forwards DOM pointer/wheel/keyboard events into the queue,
//! and blits the buffer into a `<canvas>`. Same `Ui.button/checkbox/toggle/slider/
//! dropdown/textField` that run natively — no WebGL, no emscripten, no libc.
//!
//!   zig build web   → zig-out/web/{zicro.wasm,index.html}

const std = @import("std");
const zicro = @import("zicro");
const paint = zicro.paint;
const text = zicro.text;
const widget = zicro.widget;
const Color = paint.Color;

const gpa = std.heap.wasm_allocator;

// Straight RGBA8888 backing buffer (exactly a browser `ImageData`), fixed-size so the
// module needs no allocator for the framebuffer itself.
const MAX_W: u32 = 2560;
const MAX_H: u32 = 1600;
var pixels: [MAX_W * MAX_H]u32 = undefined;

var width: u32 = 1000;
var height: u32 = 720;

// --- theme presets (the header button cycles them) ---------------------------------
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

// --- app state ---------------------------------------------------------------------
var initialized = false;
var font: text.Font = undefined;
var store: widget.Store = undefined;
var queue: widget.InputQueue = .{};

var theme_idx: usize = 0;
var active_tab: usize = 0;
var button_clicks: usize = 0;
var primary_clicks: usize = 0;
var checkbox_val = false;
var toggle_val = true;
var radio_val: usize = 0;
var slider_val: f32 = 0.5;
var stepper_val: i64 = 42;
var dropdown_val: usize = 0;
var progress_val: f32 = 0;
var selectable_vals = [_]bool{ false, true, false };
var name_buf: std.ArrayList(u8) = .empty;
var notes_buf: std.ArrayList(u8) = .empty;

fn ensureInit() bool {
    if (initialized) return true;
    font = text.Font.initDefault(gpa) catch return false;
    store = widget.Store.init(gpa);
    name_buf.appendSlice(gpa, "zicro web") catch {};
    notes_buf.appendSlice(gpa, "Testo multi-riga.\nInvio per andare a capo.") catch {};
    initialized = true;
    return true;
}

// --- exported wasm ABI (JS drives these) -------------------------------------------

export fn zicroPixels() [*]u8 {
    return @ptrCast(&pixels);
}
export fn zicroWidth() u32 {
    return width;
}
export fn zicroHeight() u32 {
    return height;
}
export fn zicroResize(w: u32, h: u32) void {
    width = std.math.clamp(w, 1, MAX_W);
    height = std.math.clamp(h, 1, MAX_H);
}
export fn zicroPointerMove(x: f32, y: f32) void {
    queue.push(.{ .motion = .{ .x = x, .y = y } });
}
export fn zicroPointerButton(pressed: i32) void {
    queue.push(.{ .button = .{ .button = widget.BTN_LEFT, .pressed = pressed != 0 } });
}
export fn zicroScroll(dy: f32) void {
    queue.push(.{ .scroll = .{ .axis = 0, .px = dy } });
}
/// Special keys, as evdev codes (Backspace/Enter/Tab/arrows/Esc/…). JS sends the code.
export fn zicroKey(code: u32, pressed: i32) void {
    queue.push(.{ .key = .{ .code = code, .pressed = pressed != 0 } });
}
/// One typed character (a Unicode code point) → a layout-aware `.text` event.
export fn zicroText(cp: u32) void {
    var bytes: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(@intCast(cp), &bytes) catch return;
    queue.push(.{ .text = .{ .bytes = bytes, .len = @intCast(n) } });
}

/// One frame at monotonic millis `now_ms` (from JS `performance.now()`).
export fn zicroFrame(now_ms: f64) void {
    if (!ensureInit()) return;
    var canvas = paint.Canvas.initRgba8(pixels[0 .. width * height], width, height);
    const preset = presets[theme_idx % presets.len];

    // Window background.
    const bg = if (preset.dark_bg) Color.rgba(18, 20, 26, 1.0) else Color.rgba(240, 242, 245, 1.0);
    canvas.fillRoundedRect(0, 0, @floatFromInt(width), @floatFromInt(height), 0, bg);

    progress_val += 0.004;
    if (progress_val > 1) progress_val = 0;

    buildUi(&canvas, preset, @intFromFloat(now_ms));
}

fn buildUi(canvas: *paint.Canvas, preset: Preset, now_ms: i64) void {
    const bounds = widget.Rect{ .x = 0, .y = 0, .w = @floatFromInt(width), .h = @floatFromInt(height) };
    var ui = widget.Ui.begin(&store, canvas, &font, preset.make(), bounds, now_ms, queue.take());

    // Header: title + theme cycler.
    ui.beginCard(64);
    ui.beginRow();
    ui.heading("zicro · web");
    ui.gap(24);
    ui.labelDim("Tema:");
    if (ui.buttonPrimary(preset.name)) theme_idx +%= 1;
    ui.gap(16);
    ui.labelDim("(click per ciclare)");
    ui.endRow();
    ui.endCard();
    ui.gap(10);

    const tabs = &[_][]const u8{ "Widget Base", "Input Avanzati", "Indicatori", "Scorrimento" };
    _ = ui.tabBar("main_tabs", tabs, &active_tab);
    ui.gap(12);

    switch (active_tab) {
        0 => {
            ui.beginCard(300);
            ui.heading("Pulsanti e selezioni");
            ui.separator();
            ui.gap(5);
            ui.beginRow();
            if (ui.button("Pulsante")) button_clicks += 1;
            if (ui.buttonPrimary("Primario")) primary_clicks += 1;
            ui.endRow();
            ui.gap(5);
            ui.beginRow();
            ui.labelDim("click:");
            var b: [48]u8 = undefined;
            ui.label(std.fmt.bufPrint(&b, "{d} / {d}", .{ button_clicks, primary_clicks }) catch "0 / 0");
            ui.endRow();
            ui.separator();
            ui.gap(5);
            ui.beginRow();
            _ = ui.checkbox("Abilita", &checkbox_val);
            _ = ui.toggle("Notifiche", &toggle_val);
            ui.endRow();
            ui.gap(5);
            ui.beginRow();
            ui.label("Radio:");
            _ = ui.radio("A", &radio_val, 0);
            _ = ui.radio("B", &radio_val, 1);
            _ = ui.radio("C", &radio_val, 2);
            ui.endRow();
            ui.endCard();
        },
        1 => {
            ui.beginCard(320);
            ui.heading("Controlli avanzati");
            ui.separator();
            ui.gap(5);
            _ = ui.stepper("Contatore", &stepper_val, 0, 100);
            ui.gap(8);
            _ = ui.slider("Volume", &slider_val, 0, 1);
            ui.gap(10);
            ui.beginRow();
            ui.label("Nome:");
            _ = ui.textField("name_field", &name_buf);
            ui.endRow();
            ui.gap(10);
            ui.beginRow();
            ui.label("Menu:");
            const opts = &[_][]const u8{ "Opzione 1", "Opzione 2", "Opzione 3", "Opzione 4" };
            _ = ui.dropdown("opts_dd", opts, &dropdown_val);
            ui.endRow();
            ui.endCard();
        },
        2 => {
            ui.beginCard(280);
            ui.heading("Stato");
            ui.separator();
            ui.gap(10);
            ui.label("Avanzamento");
            ui.progressBar(progress_val);
            ui.gap(10);
            ui.progressIndeterminate();
            ui.gap(10);
            ui.beginRow();
            ui.label("Spinner:");
            ui.spinner();
            ui.endRow();
            ui.endCard();
        },
        else => {
            ui.beginCard(300);
            ui.heading("Lista scorrevole");
            ui.separator();
            ui.gap(5);
            ui.beginScroll("list", 220);
            var i: usize = 0;
            while (i < 24) : (i += 1) {
                ui.pushIdScopeIndex(i);
                var ib: [48]u8 = undefined;
                const s = std.fmt.bufPrint(&ib, "Elemento {d}", .{i}) catch "Elemento";
                const sel = i % 3;
                if (ui.selectable(s, selectable_vals[sel])) selectable_vals[sel] = !selectable_vals[sel];
                ui.popIdScope();
            }
            ui.endScroll();
            ui.endCard();
        },
    }

    _ = ui.end();
}
