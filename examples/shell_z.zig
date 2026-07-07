//! Zicro's shell, ported to run under Z (Z-Scenic phase 2, Z#76) — real
//! `paint.Canvas` rendering and real keyboard interaction (kernel/ps2.zig's
//! evdev-numbered events), hosted by Z's zicro_host.zig instead of a
//! Wayland compositor.
//!
//! A SEPARATE file from examples/shell.zig, not a modification of it:
//! upstream's `main()` constructs `std.heap.DebugAllocator` (needs OS mmap)
//! and `std.Io.Threaded` (needs real OS threads) — neither exists on Z's
//! freestanding target, and there is no simpler built-in `std.Io` provider
//! to fall back to (its VTable is ~110 functions; hand-stubbing all of them
//! correctly to satisfy the type without ever truly implementing them was
//! judged not worth the risk for what this port actually needs). The
//! `bus`-driven "topic" command is dropped for the same reason — LocalBus
//! takes a real `io`. Text is Z's own 8x16 bitmap font ("zfont", Z's
//! user/font.zig — see the build.zig comment) rather than `zicro.text.Font`:
//! that module's `@cImport("stb_truetype.h")` has no libc headers to
//! translate against on `x86_64-freestanding-none`, so merely putting a
//! `text.Font` field on this file's own state (even unused) fails the
//! build. Everything else (command handling, evdev key decoding) is copied
//! verbatim from shell.zig; drift between the two is a real cost of this
//! fork, worth watching if shell.zig's UI logic changes upstream.
//!
//! `io: std.Io = undefined` below is deliberate, not a shortcut taken
//! lightly: this file's entire call graph — window_z.zig, paint.Canvas —
//! never reads a single field of it. That is what makes leaving it
//! uninitialized sound rather than merely convenient; the moment any future
//! change here starts actually doing async I/O, this needs a real
//! implementation (or at least the specific VTable entries that change
//! touches) — TODO(#76 phase 3+) — not another `undefined`.

const std = @import("std");
const zicro = @import("zicro");
const paint = zicro.paint;
const window = zicro.window;
const font = @import("zfont");
// Z's native process entry is `export fn main(handle: usize) callconv(.c)
// void` (zrt's `_start` calls it by that exact symbol/signature) — NOT
// Zig's own `pub fn main() !void` convention shell.zig uses. Getting this
// wrong doesn't error at compile time; it links a hollow ELF (0 program
// headers, entry 0x0) that panics the kernel's loader on spawn.

const ShellState = struct {
    gpa: std.mem.Allocator,
    window: *window.Window = undefined,

    lines: std.ArrayList([]const u8),
    input_buf: std.ArrayList(u8),

    shift_pressed: bool = false,
    ctrl_pressed: bool = false,
    super_pressed: bool = false,

    pub fn init(gpa: std.mem.Allocator) !ShellState {
        return .{ .gpa = gpa, .lines = .empty, .input_buf = .empty };
    }

    pub fn deinit(self: *ShellState) void {
        for (self.lines.items) |line| self.gpa.free(line);
        self.lines.deinit(self.gpa);
        self.input_buf.deinit(self.gpa);
    }

    pub fn addLine(self: *ShellState, line: []const u8) !void {
        try self.lines.append(self.gpa, line);
        if (self.lines.items.len > 20) {
            const old = self.lines.orderedRemove(0);
            self.gpa.free(old);
        }
    }

    pub fn clear(self: *ShellState) void {
        for (self.lines.items) |line| self.gpa.free(line);
        self.lines.clearRetainingCapacity();
    }
};

/// Duck-typed view of `canvas.pixels` shaped like `zfont`'s expected `fb`
/// (`.ptr`/`.width`/`.height`/`.stride`) — see zfont's module doc for why
/// `anytype` there matters: this is a plain non-volatile slice, not Z's own
/// `rt.Fb`, and the two are distinct types by design.
fn canvasFb(canvas: *paint.Canvas, w: i32, h: i32) struct { ptr: [*]u32, width: usize, height: usize, stride: usize } {
    return .{ .ptr = canvas.pixels.ptr, .width = @intCast(w), .height = @intCast(h), .stride = @intCast(w) };
}

fn onDraw(canvas: *paint.Canvas, content: window.Rect, user: ?*anyopaque) void {
    const shell: *ShellState = @ptrCast(@alignCast(user.?));

    @memset(canvas.pixels, 0xFF12141A); // opaque premultiplied dark background
    const fb = canvasFb(canvas, content.w, content.h);

    const line_h: i32 = font.GH + 2;
    var text_y: i32 = 20;
    for (shell.lines.items) |line| {
        font.drawText(fb, 20, @intCast(text_y), line, 0xFFD7DCE6);
        text_y += line_h;
    }

    const prompt = "zicro-z> ";
    font.drawText(fb, 20, @intCast(text_y), prompt, 0xFF78E6A0);
    const prompt_w: i32 = @intCast(prompt.len * font.GW);
    font.drawText(fb, @intCast(20 + prompt_w), @intCast(text_y), shell.input_buf.items, 0xFFFFFFFF);

    const cursor_x = 20 + prompt_w + @as(i32, @intCast(shell.input_buf.items.len * font.GW));
    var cy: i32 = text_y;
    while (cy < text_y + font.GH) : (cy += 1) {
        var cx: i32 = 0;
        while (cx < font.GW) : (cx += 1) {
            if (cy >= 0 and cy < content.h and (cursor_x + cx) >= 0 and (cursor_x + cx) < content.w) {
                canvas.pixels[@intCast(cy * content.w + cursor_x + cx)] = 0xFFFFFFFF;
            }
        }
    }
}

fn handleCommand(shell: *ShellState, cmd: []const u8) !void {
    const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
    if (trimmed.len == 0) {
        try shell.addLine(try shell.gpa.dupe(u8, "zicro-z> "));
        return;
    }
    const echo = try std.fmt.allocPrint(shell.gpa, "zicro-z> {s}", .{trimmed});
    try shell.addLine(echo);

    if (std.mem.eql(u8, trimmed, "help")) {
        try shell.addLine(try shell.gpa.dupe(u8, "Available commands:"));
        try shell.addLine(try shell.gpa.dupe(u8, "  help   - Show this help menu"));
        try shell.addLine(try shell.gpa.dupe(u8, "  about  - Describe this port"));
        try shell.addLine(try shell.gpa.dupe(u8, "  clear  - Clear history buffer"));
        try shell.addLine(try shell.gpa.dupe(u8, "  exit   - Close shell window"));
    } else if (std.mem.eql(u8, trimmed, "about")) {
        try shell.addLine(try shell.gpa.dupe(u8, "--- Zicro shell, on Z ---"));
        try shell.addLine(try shell.gpa.dupe(u8, "Real paint.Canvas + Z bitmap-font rendering."));
        try shell.addLine(try shell.gpa.dupe(u8, "Window: Z-Scenic (window_z.zig), real PS/2 keyboard input."));
    } else if (std.mem.eql(u8, trimmed, "clear")) {
        shell.clear();
    } else if (std.mem.eql(u8, trimmed, "exit")) {
        shell.window.closed = true;
    } else {
        const error_msg = try std.fmt.allocPrint(shell.gpa, "Unknown command '{s}'. Type 'help'.", .{trimmed});
        try shell.addLine(error_msg);
    }
}

fn onKey(win: *window.Window, key: u32, state: u32, user: ?*anyopaque) void {
    const shell: *ShellState = @ptrCast(@alignCast(user.?));

    if (key == 42 or key == 54) {
        shell.shift_pressed = (state == 1);
        return;
    }
    if (key == 29) {
        shell.ctrl_pressed = (state == 1);
        return;
    }
    if (key == 125 or key == 126) {
        shell.super_pressed = (state == 1);
        return;
    }
    if (state != 1) return;

    if (key == 32 and shell.ctrl_pressed) { // Ctrl+D
        win.closed = true;
        return;
    }
    if (key == 14) { // Backspace
        if (shell.input_buf.items.len > 0) _ = shell.input_buf.pop();
        return;
    }
    if (key == 28) { // Enter
        handleCommand(shell, shell.input_buf.items) catch {};
        shell.input_buf.clearRetainingCapacity();
        return;
    }
    if (evdevToChar(key, shell.shift_pressed)) |c| shell.input_buf.append(shell.gpa, c) catch {};
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

// A static arena — no OS heap on Z, so no growth beyond this. Z's ELF
// loader caps a process image (.text + .bss) at 1 MiB total (CAP=256 pages,
// kernel/process.zig's loadSegments — computed from memsz, so this array's
// SIZE counts even though it holds no file bytes); a multi-MiB buffer here
// makes `process.spawn` fail with no compile-time signal. Only scrollback
// line strings and the small ShellState/Window structs come out of this
// arena now that text.Font/stb_truetype is gone — a few KB of real use.
var heap_buf: [64 * 1024]u8 = undefined;

fn run(gpa: std.mem.Allocator) !void {
    var shell = try ShellState.init(gpa);
    defer shell.deinit();

    try shell.addLine(try gpa.dupe(u8, "Zicro shell - running on Z (Z-Scenic phase 2)"));
    try shell.addLine(try gpa.dupe(u8, "Type 'help' for a list of commands."));
    try shell.addLine(try gpa.dupe(u8, ""));

    // See the module doc: never dereferenced anywhere in this call graph.
    const io: std.Io = undefined;

    const win = try window.Window.init(gpa, io, .{
        .title = "zicro-shell-z",
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

// zrt's `_start` calls this exact symbol/signature — see the import note
// above. `run()` keeps the original `!void` body so every `try` inside it
// still works; only this boundary needs the C-convention adapter. Startup
// failure (OOM against the fixed heap_buf, host rejecting the handshake)
// has no sensible recovery — return and let `_start`'s own post-call exit
// tear the process down, same as zicro_host.zig's early-return-on-
// disconnect convention.
export fn main(_: usize) callconv(.c) void {
    var fba = std.heap.FixedBufferAllocator.init(&heap_buf);
    run(fba.allocator()) catch return;
}
