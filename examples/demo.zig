//! Interactive widget demo app showing all available immediate-mode widgets in Zicro.
//! Supports dark and light styles, modal dialogs, text input, sliders, steppers, tab bar, and scroll areas.
//! Run with: `zig build run-demo`

const std = @import("std");
const zicro = @import("zicro");

const paint = zicro.paint;
const text = zicro.text;
const window = zicro.window;
const widget = zicro.widget;

const BTN_LEFT: u32 = widget.BTN_LEFT;
const BTN_RIGHT: u32 = widget.BTN_RIGHT;
const BTN_MIDDLE: u32 = widget.BTN_MIDDLE;

const AppState = struct {
    gpa: std.mem.Allocator,
    window: *window.Window = undefined,
    font: text.Font,
    widget_store: widget.Store,
    queue: widget.InputQueue,

    // Theme state
    is_dark: bool = true,

    // Widget states
    active_tab: usize = 0,
    button_clicks: usize = 0,
    primary_clicks: usize = 0,
    checkbox_val: bool = false,
    toggle_val: bool = true,
    radio_val: usize = 0,
    slider_val: f32 = 0.5,
    stepper_val: i64 = 42,
    dropdown_val: usize = 0,
    progress_val: f32 = 0.0,

    text_field_buf: std.ArrayList(u8),
    text_area_buf: std.ArrayList(u8),
    selectable_vals: [3]bool,

    pub fn init(gpa: std.mem.Allocator) !AppState {
        const font = try text.Font.initDefault(gpa);
        var text_field_buf: std.ArrayList(u8) = .empty;
        try text_field_buf.appendSlice(gpa, "Zicro input");
        var text_area_buf: std.ArrayList(u8) = .empty;
        try text_area_buf.appendSlice(gpa, "Questo è un editor di testo multi-riga.\nPuoi premere Invio per andare a capo e usare la tastiera.");

        return AppState{
            .gpa = gpa,
            .font = font,
            .widget_store = widget.Store.init(gpa),
            .queue = .{},
            .text_field_buf = text_field_buf,
            .text_area_buf = text_area_buf,
            .selectable_vals = .{ false, true, false },
        };
    }

    pub fn deinit(self: *AppState) void {
        self.font.deinit();
        self.widget_store.deinit();
        self.text_field_buf.deinit(self.gpa);
        self.text_area_buf.deinit(self.gpa);
    }
};

fn onDraw(canvas: *paint.Canvas, content: window.Rect, user: ?*anyopaque) void {
    const state = @as(*AppState, @ptrCast(@alignCast(user.?)));

    // Choose window background based on active style
    const bg_color = if (state.is_dark)
        paint.Color.rgba(18, 20, 26, 1.0)
    else
        paint.Color.rgba(240, 242, 245, 1.0);

    // Clear the whole canvas
    canvas.fillRoundedRect(
        @floatFromInt(content.x),
        @floatFromInt(content.y),
        @floatFromInt(content.w),
        @floatFromInt(content.h),
        0,
        bg_color,
    );

    const theme = if (state.is_dark) widget.Theme.dark() else widget.Theme.light();

    const bounds = widget.Rect{
        .x = @floatFromInt(content.x),
        .y = @floatFromInt(content.y),
        .w = @floatFromInt(content.w),
        .h = @floatFromInt(content.h),
    };

    const now = widget.nowMs();
    const events = state.queue.take();

    var ui = widget.Ui.begin(&state.widget_store, canvas, &state.font, theme, bounds, now, events);

    // Draw overall demo header
    ui.beginCard(65);
    ui.beginRow();
    ui.heading("Zicro Widget Demo");
    ui.gap(ui.availW() - 250); // Push controls to the right
    _ = ui.toggle(if (state.is_dark) "Stile Dark" else "Stile Light", &state.is_dark);
    ui.endRow();
    ui.endCard();

    ui.gap(10);

    // Tab bar to switch categories
    const tab_labels = &[_][]const u8{ "Widget Base", "Input Avanzati", "Indicatori & Dialoghi", "Area Scorrimento" };
    _ = ui.tabBar("main_tabs", tab_labels, &state.active_tab);

    ui.gap(15);

    // Render contents based on selected tab
    switch (state.active_tab) {
        0 => { // Basic Widgets
            ui.beginCard(320);
            ui.heading("Pulsanti e Selezioni");
            ui.separator();
            ui.gap(5);

            ui.beginRow();
            if (ui.button("Pulsante Semplice")) {
                state.button_clicks += 1;
            }
            if (ui.buttonPrimary("Pulsante Primario")) {
                state.primary_clicks += 1;
            }
            ui.endRow();

            ui.gap(5);
            ui.beginRow();
            ui.label("Click pulsante semplice:");
            var clicks_buf: [32]u8 = undefined;
            const clicks_str = std.fmt.bufPrint(&clicks_buf, "{d}", .{state.button_clicks}) catch "0";
            ui.labelDim(clicks_str);
            ui.gap(20);
            ui.label("Click pulsante primario:");
            var pclicks_buf: [32]u8 = undefined;
            const pclicks_str = std.fmt.bufPrint(&pclicks_buf, "{d}", .{state.primary_clicks}) catch "0";
            ui.labelDim(pclicks_str);
            ui.endRow();

            ui.separator();
            ui.gap(5);
            ui.heading("Checkbox, Toggle e Radio");

            ui.beginRow();
            _ = ui.checkbox("Abilita funzionalità", &state.checkbox_val);
            _ = ui.toggle("Attiva opzione", &state.toggle_val);
            ui.endRow();

            ui.gap(5);
            ui.beginRow();
            ui.label("Selezione singola (Radio):");
            _ = ui.radio("Opzione A", &state.radio_val, 0);
            _ = ui.radio("Opzione B", &state.radio_val, 1);
            _ = ui.radio("Opzione C", &state.radio_val, 2);
            ui.endRow();

            ui.endCard();
        },
        1 => { // Advanced Inputs
            ui.beginCard(320);
            ui.heading("Controlli Avanzati");
            ui.separator();
            ui.gap(5);

            ui.beginRow();
            _ = ui.stepper("Contatore Intero", &state.stepper_val, 0, 100);
            _ = ui.slider("Regolazione", &state.slider_val, 0.0, 1.0);
            ui.endRow();

            ui.gap(10);
            ui.label("Campi di Testo (Fuoco con click, Tab per scorrere, Esc per uscire)");
            
            ui.beginRow();
            ui.label("Nome:");
            _ = ui.textField("name_field", &state.text_field_buf);
            ui.endRow();

            ui.gap(10);
            ui.label("Note / Descrizione:");
            _ = ui.textArea("notes_field", &state.text_area_buf, 90);

            ui.gap(10);
            ui.beginRow();
            ui.label("Menu a tendina:");
            const dropdown_options = &[_][]const u8{ "Opzione 1", "Opzione 2", "Opzione 3", "Opzione 4" };
            _ = ui.dropdown("opts_dropdown", dropdown_options, &state.dropdown_val);
            ui.endRow();

            ui.endCard();
        },
        2 => { // Indicators & Dialogs
            ui.beginCard(320);
            ui.heading("Stato e Modali");
            ui.separator();
            ui.gap(10);

            ui.label("Avanzamento Operazione (Determinato ed Indeterminato)");
            ui.progressBar(state.progress_val);
            ui.gap(10);
            ui.progressIndeterminate();

            ui.gap(10);
            ui.beginRow();
            ui.label("Spinner animato:");
            ui.spinner();
            ui.gap(40);
            if (ui.buttonPrimary("Apri Dialogo Modale")) {
                ui.openDialog("demo_dialog");
            }
            ui.endRow();
            
            ui.gap(20);
            ui.label("Passa con il mouse sopra il pulsante sotto per visualizzare un tooltip:");
            if (ui.button("Pulsante con Tooltip")) {
                // Azione inutile, serve solo a mostrare il tooltip
            }
            ui.tooltip("Questo è un tooltip interattivo generato da Zicro!");

            ui.endCard();
        },
        3 => { // Scrolling
            ui.beginCard(320);
            ui.heading("Contenuto con Scorrimento");
            ui.separator();
            ui.gap(5);

            // A vertical scroll area containing dynamically built rows
            ui.beginScroll("list_scroller", 250);
            var i: usize = 0;
            while (i < 20) : (i += 1) {
                ui.pushIdScopeIndex(i);
                
                var item_buf: [64]u8 = undefined;
                const item_str = std.fmt.bufPrint(&item_buf, "Elemento della lista {d} (Click per selezionare)", .{i}) catch "Elemento";
                
                const sel_idx = i % 3;
                if (ui.selectable(item_str, state.selectable_vals[sel_idx])) {
                    state.selectable_vals[sel_idx] = !state.selectable_vals[sel_idx];
                }
                
                ui.popIdScope();
            }
            ui.endScroll();

            ui.endCard();
        },
        else => {},
    }

    // --- Modal dialog drawing ---
    // If the modal dialog is open, it will overlay and dim the application background.
    if (ui.beginDialog("demo_dialog", "Conferma Operazione", 420, 260)) {
        ui.label("Attenzione: Stai per eseguire un'azione simulata.");
        ui.labelDim("I dialoghi modali bloccano l'input delle finestre sottostanti.");
        ui.gap(10);
        ui.separator();
        ui.gap(10);

        ui.label("Valori correnti:");
        var stat_buf: [128]u8 = undefined;
        const stat_str = std.fmt.bufPrint(&stat_buf, "Regolazione: {d:0.2} | Contatore: {d}", .{ state.slider_val, state.stepper_val }) catch "Stato";
        ui.textLine(stat_str, theme.font_small, .regular, theme.text_dim);

        ui.gap(20);
        ui.label("Vuoi procedere con la conferma?");
        ui.gap(20);

        ui.beginRow();
        if (ui.buttonPrimary("Conferma")) {
            ui.closeDialog();
        }
        if (ui.button("Annulla")) {
            ui.closeDialog();
        }
        ui.endRow();

        ui.endDialog();
    }

    const report = ui.end();
    if (report.needs_repaint) {
        state.window.requestRedraw();
    }
}

fn onMouse(win: *window.Window, event: window.MouseEvent, user: ?*anyopaque) void {
    const state = @as(*AppState, @ptrCast(@alignCast(user.?)));
    switch (event.kind) {
        .motion => state.queue.push(.{ .motion = .{ .x = event.x, .y = event.y } }),
        .press => state.queue.push(.{ .button = .{ .button = event.button, .pressed = true } }),
        .release => state.queue.push(.{ .button = .{ .button = event.button, .pressed = false } }),
        .scroll => state.queue.push(.{ .scroll = .{ .axis = 0, .px = event.scroll_dy * 24.0 } }),
    }
    win.requestRedraw();
}

fn onKey(win: *window.Window, key: u32, state_val: u32, user: ?*anyopaque) void {
    const state = @as(*AppState, @ptrCast(@alignCast(user.?)));
    const pressed = (state_val == 1 or state_val == 2);
    state.queue.push(.{ .key = .{ .code = key, .pressed = pressed } });
    win.requestRedraw();
}

fn onTick(win: *window.Window, user: ?*anyopaque) void {
    const state = @as(*AppState, @ptrCast(@alignCast(user.?)));
    
    // Slow animation for the progress bar
    state.progress_val += 0.002;
    if (state.progress_val > 1.0) {
        state.progress_val = 0.0;
    }
    
    win.requestRedraw();
}

pub fn main() !void {
    var gpa_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_allocator.deinit();
    const gpa = gpa_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var state = try AppState.init(gpa);
    defer state.deinit();

    const win = try window.Window.init(gpa, io, .{
        .title = "zicro-widget-demo",
        .width = 720,
        .height = 480,
        .on_draw = onDraw,
        .on_key = onKey,
        .on_mouse = onMouse,
        .on_tick = onTick,
        .tick_ms = 16, // tick target ~60fps
        .decorations = true,
        .user = &state,
    });
    defer win.deinit();

    state.window = win;

    try win.run();
}
