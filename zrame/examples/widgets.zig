//! `zig build run-widgets`
//!
//! The widget-toolkit showcase: one glass window whose content is rebuilt every frame
//! with `zrame.widget` — tabs, buttons, toggles, radios, slider, stepper, text field,
//! dropdown, progress bar, spinner, tooltip, a scrollable list, and a modal dialog. This is also the reference wiring for apps:
//! window callbacks push into an [`widget.InputQueue`]; `on_draw` runs `Ui.begin` →
//! widgets → `Ui.end`, and requests a repaint while anything animates.

const std = @import("std");
const zrame = @import("zrame");
const widget = zrame.widget;

const Demo = struct {
    gpa: std.mem.Allocator,

    // app state driven by the widgets
    tab: usize = 0,
    power: bool = true,
    phantom: bool = false,
    gain: f32 = 42,
    channels: i64 = 32,
    name: std.ArrayList(u8) = .empty,
    notes: std.ArrayList(u8) = .empty,
    memo: std.ArrayList(u8) = .empty,
    mic: usize = 0,
    pattern: usize = 0,
    selected_row: usize = 0,
    clicks: u32 = 0,
};

const patterns = [_][]const u8{ "Cardioid", "Omni", "Figure-8" };

const mics = [_][]const u8{ "SM58", "SM57", "MD421", "e906", "Beta 52A", "C414" };
const tabs = [_][]const u8{ "Controls", "List", "About" };

// The whole app is this one function: `zrame.Widgets` runs `Ui.begin → build →
// Ui.end`, wires the callbacks, the input queue and the clipboard, and repaints
// only while something animates. No app thread, no framebuffer.
fn build(ui: *widget.Ui, user: ?*anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(user.?));

    ui.heading("zrame widgets");
    _ = ui.tabBar("tabs", &tabs, &demo.tab);
    ui.gap(6);

    switch (demo.tab) {
        0 => {
            ui.beginRow();
            if (ui.buttonPrimary("Primary")) demo.clicks += 1;
            if (ui.button("Default")) demo.clicks += 1;
            if (ui.button("Open dialog")) ui.openDialog("demo-dialog");
            ui.endRow();

            _ = ui.toggle("Power", &demo.power);
            ui.tooltip("Main output power");
            _ = ui.checkbox("Phantom +48V", &demo.phantom);
            _ = ui.slider("Gain", &demo.gain, 0, 100);
            _ = ui.stepper("Input channels", &demo.channels, 8, 128);
            // Two fields: Tab/Shift+Tab traverses them, shift+arrows select,
            // ctrl+A/C/X/V share the store clipboard.
            _ = ui.textField("name", &demo.name);
            _ = ui.textField("notes", &demo.notes);
            _ = ui.dropdown("mic", &mics, &demo.mic);

            ui.beginRow();
            var i: usize = 0;
            while (i < patterns.len) : (i += 1) _ = ui.radio(patterns[i], &demo.pattern, i);
            ui.endRow();

            // gain doubles as a progress source; spinner+sweep only while "busy"
            ui.progressBar(demo.gain / 100);
            if (demo.power) {
                ui.beginRow();
                ui.spinner();
                ui.endRow();
                ui.progressIndeterminate();
            }
        },
        1 => {
            ui.labelDim("A scrollable list (mouse wheel):");
            ui.beginScroll("rows", 220);
            var i: usize = 0;
            var buf: [32]u8 = undefined;
            while (i < 40) : (i += 1) {
                ui.pushIdScopeIndex(i);
                const s = std.fmt.bufPrint(&buf, "Channel {d:0>2}", .{i + 1}) catch "?";
                if (ui.selectable(s, demo.selected_row == i)) demo.selected_row = i;
                ui.popIdScope();
            }
            ui.endScroll();
        },
        else => {
            ui.beginCard(120);
            ui.label("Immediate-mode toolkit over zicro.paint.");
            ui.labelDim("Every frame the UI is rebuilt from state;");
            ui.labelDim("the Store keeps hot/active/focus and offsets.");
            ui.endCard();
            ui.labelDim("A multi-line editor (Enter = newline, ctrl+C/V via the OS):");
            _ = ui.textArea("memo", &demo.memo, 140);
        },
    }

    // status footer
    var sbuf: [160]u8 = undefined;
    const status = std.fmt.bufPrint(&sbuf, "clicks {d}   gain {d:.0}   ch {d}   mic {s}   row {d}   name \"{s}\"", .{
        demo.clicks,    demo.gain,             demo.channels,
        mics[demo.mic], demo.selected_row + 1, demo.name.items,
    }) catch "";
    ui.gap(8);
    ui.labelDim(status);

    // modal on top of everything
    if (ui.beginDialog("demo-dialog", "A modal dialog", 340, 190)) {
        ui.label("Everything underneath is inert.");
        ui.labelDim("Esc, the x, or a click outside closes it.");
        ui.gap(8);
        if (ui.buttonPrimary("Done")) ui.closeDialog();
        ui.endDialog();
    }
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var demo = Demo{ .gpa = gpa };
    defer demo.name.deinit(gpa);
    defer demo.notes.deinit(gpa);
    defer demo.memo.deinit(gpa);

    // The no-thread path: one build function, everything else wired by `Widgets`.
    var w = zrame.Widgets.init(gpa, widget.Theme.light(), build, &demo);
    defer w.deinit();

    const win = try zrame.Window.init(gpa, w.options(.{
        .title = "zrame — widgets",
        .app_id = "dev.zrame.widgets",
        .width = 560,
        .height = 600,
        .style = zrame.Style.macos(),
        .titlebar = true,
    }));
    defer win.deinit();
    w.attach(win);

    try win.run();
}
