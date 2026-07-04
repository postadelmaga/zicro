const std = @import("std");
const zicro = @import("zicro");

const paint = zicro.paint;
const text = zicro.text;
const window = zicro.window;
const bus_mod = zicro.bus;

const ShellState = struct {
    gpa: std.mem.Allocator,
    window: *window.Window = undefined,
    font: text.Font,
    bus: *bus_mod.LocalBus,
    
    // Terminal lines history
    lines: std.ArrayList([]const u8),
    input_buf: std.ArrayList(u8),
    
    // Keyboard modifiers
    shift_pressed: bool = false,
    ctrl_pressed: bool = false,
    super_pressed: bool = false,

    pub fn init(gpa: std.mem.Allocator, bus: *bus_mod.LocalBus) !ShellState {
        const font = try text.Font.initDefault(gpa);
        return .{
            .gpa = gpa,
            .font = font,
            .bus = bus,
            .lines = .empty,
            .input_buf = .empty,
        };
    }

    pub fn deinit(self: *ShellState) void {
        self.font.deinit();
        for (self.lines.items) |line| {
            self.gpa.free(line);
        }
        self.lines.deinit(self.gpa);
        self.input_buf.deinit(self.gpa);
    }

    pub fn addLine(self: *ShellState, line: []const u8) !void {
        try self.lines.append(self.gpa, line);
        // Limit history to 20 lines to keep it clean on screen
        if (self.lines.items.len > 20) {
            const old = self.lines.orderedRemove(0);
            self.gpa.free(old);
        }
    }

    pub fn clear(self: *ShellState) void {
        for (self.lines.items) |line| {
            self.gpa.free(line);
        }
        self.lines.clearRetainingCapacity();
    }
};

fn onDraw(canvas: *paint.Canvas, content: window.Rect, user: ?*anyopaque) void {
    const shell: *ShellState = @ptrCast(@alignCast(user.?));
    
    // Translucent dark terminal panel
    const bg_color = paint.Color.rgba(18, 20, 26, 0.85);
    var y_pixel: i32 = 0;
    while (y_pixel < content.h) : (y_pixel += 1) {
        var x_pixel: i32 = 0;
        while (x_pixel < content.w) : (x_pixel += 1) {
            canvas.pixels[@intCast(y_pixel * content.w + x_pixel)] = 
                (@as(u32, @intFromFloat(bg_color.a * 255.0)) << 24) |
                (@as(u32, @intFromFloat(bg_color.r * bg_color.a * 255.0)) << 16) |
                (@as(u32, @intFromFloat(bg_color.g * bg_color.a * 255.0)) << 8) |
                @as(u32, @intFromFloat(bg_color.b * bg_color.a * 255.0));
        }
    }

    const font_size = 16;
    const line_height = shell.font.lineHeight(font_size, .regular);
    const v = shell.font.vmetrics(font_size, .regular);
    
    var text_y = 30 + v.ascent;
    
    // Render lines history
    for (shell.lines.items) |line| {
        canvas.drawText(&shell.font, 25, text_y, line, .{
            .size = font_size,
            .style = .regular,
            .color = paint.Color.rgba(215, 220, 230, 0.95),
        });
        text_y += line_height;
    }

    // Render prompt
    const prompt = "zicro> ";
    canvas.drawText(&shell.font, 25, text_y, prompt, .{
        .size = font_size,
        .style = .regular,
        .color = paint.Color.rgba(120, 230, 160, 1.0),
    });

    const prompt_w = shell.font.measure(font_size, .regular, prompt);
    
    // Render current input
    canvas.drawText(&shell.font, 25 + prompt_w, text_y, shell.input_buf.items, .{
        .size = font_size,
        .style = .regular,
        .color = paint.Color.rgba(255, 255, 255, 1.0),
    });

    // Blinking cursor simulation
    const input_w = shell.font.measure(font_size, .regular, shell.input_buf.items);
    const cursor_x = 25 + prompt_w + input_w;
    
    {
        // Draw a vertical block cursor
        var cy = text_y - v.ascent + 2;
        while (cy < text_y - v.descent) : (cy += 1) {
            var cx: i32 = 0;
            while (cx < 8) : (cx += 1) {
                if (cy >= 0 and cy < content.h and (cursor_x + cx) >= 0 and (cursor_x + cx) < content.w) {
                    canvas.pixels[@intCast(cy * content.w + cursor_x + cx)] = 0xFFFFFFFF;
                }
            }
        }
    }
}

fn handleCommand(shell: *ShellState, cmd: []const u8) !void {
    const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
    if (trimmed.len == 0) {
        try shell.addLine(try shell.gpa.dupe(u8, "zicro> "));
        return;
    }

    const echo = try std.fmt.allocPrint(shell.gpa, "zicro> {s}", .{trimmed});
    try shell.addLine(echo);

    if (std.mem.eql(u8, trimmed, "help")) {
        try shell.addLine(try shell.gpa.dupe(u8, "Available commands:"));
        try shell.addLine(try shell.gpa.dupe(u8, "  help   - Show this help menu"));
        try shell.addLine(try shell.gpa.dupe(u8, "  about  - Describe Zicro micro-kernel"));
        try shell.addLine(try shell.gpa.dupe(u8, "  clear  - Clear history buffer"));
        try shell.addLine(try shell.gpa.dupe(u8, "  topic  - Publish message to the bus"));
        try shell.addLine(try shell.gpa.dupe(u8, "  exit   - Close shell window"));
    } else if (std.mem.eql(u8, trimmed, "about")) {
        try shell.addLine(try shell.gpa.dupe(u8, "--- Zicro Micro-Kernel ---"));
        try shell.addLine(try shell.gpa.dupe(u8, "A lightweight modules + bus real-time architecture in Zig."));
        try shell.addLine(try shell.gpa.dupe(u8, "Window: Wayland (Linux) / Win32 (Windows)"));
        try shell.addLine(try shell.gpa.dupe(u8, "Font: stb_truetype with Hack Mono"));
    } else if (std.mem.eql(u8, trimmed, "clear")) {
        shell.clear();
    } else if (std.mem.eql(u8, trimmed, "topic")) {
        try shell.bus.publishMsg("shell", "control", "Signal from terminal shell!");
        try shell.addLine(try shell.gpa.dupe(u8, "Published action message to topic 'control'"));
    } else if (std.mem.eql(u8, trimmed, "exit")) {
        shell.window.closed = true;
    } else {
        const error_msg = try std.fmt.allocPrint(shell.gpa, "Unknown command '{s}'. Type 'help'.", .{trimmed});
        try shell.addLine(error_msg);
    }
}

fn onKey(win: *window.Window, key: u32, state: u32, user: ?*anyopaque) void {
    const shell: *ShellState = @ptrCast(@alignCast(user.?));
    
    // Key codes and modifiers tracking
    if (key == 42 or key == 54) { // Shift
        shell.shift_pressed = (state == 1);
        return;
    }
    if (key == 29) { // Ctrl
        shell.ctrl_pressed = (state == 1);
        return;
    }
    if (key == 125 or key == 126) { // Super / Meta
        shell.super_pressed = (state == 1);
        return;
    }

    if (state != 1) return; // Only process key pressed events

    // Hotkey: Super + Z -> Minimize (Hide)
    if (key == 44 and shell.super_pressed) { // Z key
        win.setMinimized();
        return;
    }

    // Hotkey: Ctrl + D -> Close Window
    if (key == 32 and shell.ctrl_pressed) { // D key
        win.closed = true;
        return;
    }

    // Hotkey: F (evdev keycode 33) -> Fullscreen Toggle (if Shift is not pressed)
    if (key == 33 and !shell.shift_pressed) {
        win.toggleFullscreen();
        return;
    }

    // Backspace
    if (key == 14) {
        if (shell.input_buf.items.len > 0) {
            _ = shell.input_buf.pop();
        }
        return;
    }

    // Enter -> Execute command
    if (key == 28) {
        handleCommand(shell, shell.input_buf.items) catch {};
        shell.input_buf.clearRetainingCapacity();
        return;
    }

    // Map evdev keycode to character
    if (evdevToChar(key, shell.shift_pressed)) |c| {
        shell.input_buf.append(shell.gpa, c) catch {};
    }
}

fn evdevToChar(key: u32, shift: bool) ?u8 {
    return switch (key) {
        16 => if (shift) 'Q' else 'q',
        17 => if (shift) 'W' else 'w',
        18 => if (shift) 'E' else 'e',
        19 => if (shift) 'R' else 'r',
        20 => if (shift) 'T' else 't',
        21 => if (shift) 'Y' else 'y',
        22 => if (shift) 'U' else 'u',
        23 => if (shift) 'I' else 'i',
        24 => if (shift) 'O' else 'o',
        25 => if (shift) 'P' else 'p',
        30 => if (shift) 'A' else 'a',
        31 => if (shift) 'S' else 's',
        32 => if (shift) 'D' else 'd',
        33 => if (shift) 'F' else 'f',
        34 => if (shift) 'G' else 'g',
        35 => if (shift) 'H' else 'h',
        36 => if (shift) 'J' else 'j',
        37 => if (shift) 'K' else 'k',
        38 => if (shift) 'L' else 'l',
        44 => if (shift) 'Z' else 'z',
        45 => if (shift) 'X' else 'x',
        46 => if (shift) 'C' else 'c',
        47 => if (shift) 'V' else 'v',
        48 => if (shift) 'B' else 'b',
        49 => if (shift) 'N' else 'n',
        50 => if (shift) 'M' else 'm',
        57 => ' ',
        // Numbers and simple punctuation
        2 => if (shift) '!' else '1',
        3 => if (shift) '@' else '2',
        4 => if (shift) '#' else '3',
        5 => if (shift) '$' else '4',
        6 => if (shift) '%' else '5',
        7 => if (shift) '^' else '6',
        8 => if (shift) '&' else '7',
        9 => if (shift) '*' else '8',
        10 => if (shift) '(' else '9',
        11 => if (shift) ')' else '0',
        else => null,
    };
}

pub fn main() !void {
    var gpa_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_allocator.deinit();
    const gpa = gpa_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bus = bus_mod.LocalBus.init(gpa, io);
    defer bus.deinit();

    var shell = try ShellState.init(gpa, &bus);
    defer shell.deinit();

    // Print welcome message
    try shell.addLine(try gpa.dupe(u8, "Zicro Interactive Shell Terminal"));
    try shell.addLine(try gpa.dupe(u8, "Type 'help' for a list of commands."));
    try shell.addLine(try gpa.dupe(u8, "Hotkeys: f (fullscreen), Ctrl+D (exit), Super+Z (hide)"));
    try shell.addLine(try gpa.dupe(u8, ""));

    const win = try window.Window.init(gpa, io, .{
        .title = "zicro-shell",
        .width = 680,
        .height = 440,
        .on_draw = onDraw,
        .on_key = onKey,
        .user = &shell,
    });
    defer win.deinit();

    shell.window = win;

    try win.run();
}
