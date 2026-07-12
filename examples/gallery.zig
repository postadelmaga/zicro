//! Offscreen widget gallery — renders the same UI under four themes side by side and
//! writes a PPM to `argv[1]` (default `gallery.ppm`). No window/GPU: the widget toolkit is
//! a pure CPU rasterizer, so this is the honest visual diff for the design tokens.
//!
//!   zig build run-gallery -- /tmp/gallery.ppm

const std = @import("std");
const zicro = @import("zicro");
const widget = zicro.widget;
const paint = zicro.paint;
const text = zicro.text;

const Theme = widget.Theme;

const cols = [_]struct { name: []const u8, theme: Theme }{
    .{ .name = "dark (base)", .theme = Theme.dark() },
    .{ .name = "macOS", .theme = Theme.macos() },
    .{ .name = "Material 3", .theme = Theme.material() },
    .{ .name = "signature", .theme = Theme.signature() },
};

const COL_W: u32 = 300;
const PAD: u32 = 4;
const W: u32 = COL_W * cols.len + PAD * 2;
const H: u32 = 820;
const DIALOG_BAND_Y: u32 = 440; // the modal preview sits below the widget columns

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const pixels = try gpa.alloc(u32, W * H);
    defer gpa.free(pixels);
    var canvas = paint.Canvas.init(pixels, W, H);

    // Dark charcoal backdrop with a faint vertical gradient (dogfooding the new primitive).
    canvas.fillRoundedRectVGradient(0, 0, @floatFromInt(W), @floatFromInt(H), 0, paint.Color.rgba(18, 20, 28, 1.0), paint.Color.rgba(10, 11, 16, 1.0));

    var font = try text.Font.initDefault(gpa);
    defer font.deinit();

    const no_events = &[_]widget.InputEvent{};

    for (cols, 0..) |col, i| {
        var store = widget.Store.init(gpa);
        defer store.deinit();

        // Static demo state so the "on" visuals show (toggle/checkbox on, slider at 65%).
        var check_on = true;
        var toggle_on = true;
        var slider_v: f32 = 0.65;
        var seg: usize = 1;

        const x: f32 = @floatFromInt(PAD + @as(u32, @intCast(i)) * COL_W);
        const bounds = widget.Rect{ .x = x, .y = 8, .w = @floatFromInt(COL_W), .h = @floatFromInt(H - 16) };

        // Tick several frames so state-driven animations (the toggle knob) settle to "on"
        // before we snapshot; only the geometry of the last frame matters for the image.
        var frame: i64 = 0;
        while (frame < 48) : (frame += 1) {
            const now: i64 = 1000 + frame * 16;
            // Repaint this column's opaque backdrop each frame so translucent widget
            // surfaces don't accumulate across the settle loop (source-over stacking).
            canvas.fillRoundedRectVGradient(x, 0, @floatFromInt(COL_W), @floatFromInt(H), 0, paint.Color.rgba(18, 20, 28, 1.0), paint.Color.rgba(10, 11, 16, 1.0));
            var ui = widget.Ui.begin(&store, &canvas, &font, col.theme, bounds, now, no_events);
            ui.heading(col.name);
            ui.separator();
            _ = ui.buttonPrimary("Primary action");
            _ = ui.button("Secondary");
            _ = ui.checkbox("Enable feature", &check_on);
            _ = ui.toggle("Notifications", &toggle_on);
            _ = ui.slider("Volume", &slider_v, 0, 1);
            _ = ui.tabBar("seg", &.{ "One", "Two", "Three" }, &seg);
            ui.beginCard(120);
            ui.heading("Card surface");
            ui.labelDim("Elevated, tinted, with sheen");
            _ = ui.buttonPrimary("Confirm");
            ui.endCard();
            _ = ui.end();
        }
    }

    // Modal-dialog preview: the same long body text the demo uses, to prove labels now
    // wrap inside the panel instead of spilling past its right edge.
    {
        var store = widget.Store.init(gpa);
        defer store.deinit();
        var slider_v: f32 = 0.5;
        const stepper_v: i64 = 42;
        const band = widget.Rect{ .x = 0, .y = @floatFromInt(DIALOG_BAND_Y), .w = @floatFromInt(W), .h = @floatFromInt(H - DIALOG_BAND_Y) };
        var frame: i64 = 0;
        while (frame < 24) : (frame += 1) {
            const now: i64 = 1000 + frame * 16;
            canvas.fillRoundedRectVGradient(band.x, band.y, band.w, band.h, 0, paint.Color.rgba(30, 24, 40, 1.0), paint.Color.rgba(16, 12, 22, 1.0));
            var ui = widget.Ui.begin(&store, &canvas, &font, widget.Theme.signature(), band, now, no_events);
            ui.openDialog("preview"); // force it open for the snapshot
            if (ui.beginDialog("preview", "Conferma Operazione", 420, 260)) {
                ui.label("Attenzione: Stai per eseguire un'azione simulata.");
                ui.labelDim("I dialoghi modali bloccano l'input delle finestre sottostanti.");
                ui.gap(10);
                ui.separator();
                ui.gap(10);
                ui.label("Valori correnti:");
                var stat_buf: [128]u8 = undefined;
                const stat_str = std.fmt.bufPrint(&stat_buf, "Regolazione: {d:0.2} | Contatore: {d}", .{ slider_v, stepper_v }) catch "Stato";
                ui.labelDim(stat_str);
                ui.gap(16);
                ui.label("Vuoi procedere con la conferma?");
                ui.gap(16);
                ui.beginRow();
                _ = ui.buttonPrimary("Conferma");
                _ = ui.button("Annulla");
                ui.endRow();
                ui.endDialog();
            }
            _ = ui.end();
        }
        _ = &slider_v;
    }

    // Write PPM (P6) into the cwd. Background is opaque, so premultiplied RGB == display RGB.
    const path = "gallery.ppm";
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&buf, "P6\n{d} {d}\n255\n", .{ W, H });
    try file.writeStreamingAll(io, header);

    const rgb = try gpa.alloc(u8, @as(usize, W) * H * 3);
    defer gpa.free(rgb);
    for (pixels, 0..) |p, idx| {
        rgb[idx * 3 + 0] = @intCast((p >> 16) & 0xff);
        rgb[idx * 3 + 1] = @intCast((p >> 8) & 0xff);
        rgb[idx * 3 + 2] = @intCast(p & 0xff);
    }
    try file.writeStreamingAll(io, rgb);
    std.debug.print("wrote {s} ({d}x{d})\n", .{ path, W, H });
}
