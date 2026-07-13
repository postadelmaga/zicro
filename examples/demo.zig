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

/// The theme presets the header button cycles through — neutral tokens dressed as macOS,
/// Material 3, or the signature look, in dark and light. Click the header button to advance.
const Preset = struct { name: []const u8, dark_bg: bool, make: *const fn () widget.Theme };
const presets = [_]Preset{
    .{ .name = "dark (base)", .dark_bg = true, .make = &widget.Theme.dark },
    .{ .name = "light (base)", .dark_bg = false, .make = &widget.Theme.light },
    .{ .name = "macOS", .dark_bg = true, .make = &widget.Theme.macos },
    .{ .name = "macOS · light", .dark_bg = false, .make = &widget.Theme.macosLight },
    .{ .name = "Material 3", .dark_bg = true, .make = &widget.Theme.material },
    .{ .name = "Material 3 · light", .dark_bg = false, .make = &widget.Theme.materialLight },
    .{ .name = "signature", .dark_bg = true, .make = &widget.Theme.signature },
    .{ .name = "signature · light", .dark_bg = false, .make = &widget.Theme.signatureLight },
};

const AppState = struct {
    gpa: std.mem.Allocator,
    window: *window.Window = undefined,
    font: text.Font,
    widget_store: widget.Store,
    queue: widget.InputQueue,

    // Theme state: index into `presets`, advanced by the header button.
    theme_idx: usize = 6, // start on the signature look

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
        try text_area_buf.appendSlice(gpa, "This is a multi-line text editor.\nPress Enter for a new line and use the keyboard.");

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

    const preset = presets[state.theme_idx % presets.len];

    // Choose window background based on active preset
    const bg_color = if (preset.dark_bg)
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

    const theme = preset.make();

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
    ui.gap(ui.availW() - 300); // Push controls to the right
    ui.labelDim("Theme →");
    if (ui.buttonPrimary(preset.name)) state.theme_idx +%= 1; // click to cycle presets
    ui.endRow();
    ui.endCard();

    ui.gap(10);

    // Tab bar to switch categories
    const tab_labels = &[_][]const u8{ "Basic Widgets", "Advanced Inputs", "Indicators & Dialogs", "Scroll Area" };
    _ = ui.tabBar("main_tabs", tab_labels, &state.active_tab);

    ui.gap(15);

    // Render contents based on selected tab
    switch (state.active_tab) {
        0 => { // Basic Widgets
            ui.beginCard(320);
            ui.heading("Buttons and Selections");
            ui.separator();
            ui.gap(5);

            ui.beginRow();
            if (ui.button("Simple Button")) {
                state.button_clicks += 1;
            }
            if (ui.buttonPrimary("Primary Button")) {
                state.primary_clicks += 1;
            }
            ui.endRow();

            ui.gap(5);
            ui.beginRow();
            ui.label("Simple button clicks:");
            var clicks_buf: [32]u8 = undefined;
            const clicks_str = std.fmt.bufPrint(&clicks_buf, "{d}", .{state.button_clicks}) catch "0";
            ui.labelDim(clicks_str);
            ui.gap(20);
            ui.label("Primary button clicks:");
            var pclicks_buf: [32]u8 = undefined;
            const pclicks_str = std.fmt.bufPrint(&pclicks_buf, "{d}", .{state.primary_clicks}) catch "0";
            ui.labelDim(pclicks_str);
            ui.endRow();

            ui.separator();
            ui.gap(5);
            ui.heading("Checkbox, Toggle and Radio");

            ui.beginRow();
            _ = ui.checkbox("Enable feature", &state.checkbox_val);
            _ = ui.toggle("Activate option", &state.toggle_val);
            ui.endRow();

            ui.gap(5);
            ui.beginRow();
            ui.label("Single selection (Radio):");
            _ = ui.radio("Option A", &state.radio_val, 0);
            _ = ui.radio("Option B", &state.radio_val, 1);
            _ = ui.radio("Option C", &state.radio_val, 2);
            ui.endRow();

            ui.endCard();
        },
        1 => { // Advanced Inputs
            ui.beginCard(320);
            ui.heading("Advanced Controls");
            ui.separator();
            ui.gap(5);

            ui.beginRow();
            _ = ui.stepper("Integer Counter", &state.stepper_val, 0, 100);
            _ = ui.slider("Adjustment", &state.slider_val, 0.0, 1.0);
            ui.endRow();

            ui.gap(10);
            ui.label("Text Fields (Click to focus, Tab to cycle, Esc to exit)");

            ui.beginRow();
            ui.label("Name:");
            _ = ui.textField("name_field", &state.text_field_buf);
            ui.endRow();

            ui.gap(10);
            ui.label("Notes / Description:");
            _ = ui.textArea("notes_field", &state.text_area_buf, 90);

            ui.gap(10);
            ui.beginRow();
            ui.label("Dropdown menu:");
            const dropdown_options = &[_][]const u8{ "Option 1", "Option 2", "Option 3", "Option 4" };
            _ = ui.dropdown("opts_dropdown", dropdown_options, &state.dropdown_val);
            ui.endRow();

            ui.endCard();
        },
        2 => { // Indicators & Dialogs
            ui.beginCard(320);
            ui.heading("Status and Modals");
            ui.separator();
            ui.gap(10);

            ui.label("Operation Progress (Determinate and Indeterminate)");
            ui.progressBar(state.progress_val);
            ui.gap(10);
            ui.progressIndeterminate();

            ui.gap(10);
            ui.beginRow();
            ui.label("Animated spinner:");
            ui.spinner();
            ui.gap(40);
            if (ui.buttonPrimary("Open Modal Dialog")) {
                ui.openDialog("demo_dialog");
            }
            ui.endRow();
            
            ui.gap(20);
            ui.label("Hover the mouse over the button below to show a tooltip:");
            if (ui.button("Button with Tooltip")) {
                // Useless action, just there to show the tooltip
            }
            ui.tooltip("This is an interactive tooltip generated by Zicro!");

            ui.endCard();
        },
        3 => { // Scrolling
            ui.beginCard(320);
            ui.heading("Scrollable Content");
            ui.separator();
            ui.gap(5);

            // A vertical scroll area containing dynamically built rows
            ui.beginScroll("list_scroller", 250);
            var i: usize = 0;
            while (i < 20) : (i += 1) {
                ui.pushIdScopeIndex(i);
                
                var item_buf: [64]u8 = undefined;
                const item_str = std.fmt.bufPrint(&item_buf, "List item {d} (Click to select)", .{i}) catch "Item";
                
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
    if (ui.beginDialog("demo_dialog", "Confirm Operation", 420, 260)) {
        ui.label("Warning: You are about to perform a simulated action.");
        ui.labelDim("Modal dialogs block input to the windows underneath.");
        ui.gap(10);
        ui.separator();
        ui.gap(10);

        ui.label("Current values:");
        var stat_buf: [128]u8 = undefined;
        const stat_str = std.fmt.bufPrint(&stat_buf, "Adjustment: {d:0.2} | Counter: {d}", .{ state.slider_val, state.stepper_val }) catch "Status";
        ui.textLine(stat_str, theme.font_small, .regular, theme.text_dim);

        ui.gap(20);
        ui.label("Do you want to proceed with the confirmation?");
        ui.gap(20);

        ui.beginRow();
        if (ui.buttonPrimary("Confirm")) {
            ui.closeDialog();
        }
        if (ui.button("Cancel")) {
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
