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

// Glass panel + drop shadow + highlight ring: pure SDF/coverage math in
// paint.zig (roundedRectSdf, chromePixel, drawChrome itself), none of it
// reaches text.zig's stb_truetype @cImport, so — unlike Canvas.drawText —
// it's safe to use on the freestanding target. shell.zig (upstream) never
// calls drawChrome either (it draws a flat translucent rect instead), so
// this is a deliberate addition on top of the port, not parity with it.
const chrome_style = paint.Style{
    .corner_radius = 16,
    .margin = 18,
    .shadow_blur = 16,
    .shadow_offset_y = 5,
    .shadow_alpha = 0.45,
    .glass = paint.Color.rgba(18, 20, 26, 0.82),
    .border_alpha = 0.20,
};
// Text origin inside the glass panel: past the margin (the shadow/gutter
// band) plus a little breathing room so glyphs don't hug the highlight ring.
const text_pad: i32 = @as(i32, @intCast(chrome_style.margin)) + 14;

// window_z.zig's redraw() no longer clears the canvas for us (see its own
// doc comment), so drawChrome runs once PER SIZE — every key press repaints
// (window_z.zig's run() loop), and re-running drawChrome's per-pixel SDF
// evaluation every keystroke measured ~1-2s under this target's soft-float
// emulation (fine once, unusable at typing speed). Later frames just flatten
// the text region back to the glass color — a plain-color fill, no SDF — so
// old glyphs don't smear as the input line changes. Tracking the painted
// size (not a bare bool) keeps this correct when window_z grows resize.
var chrome_w: i32 = 0;
var chrome_h: i32 = 0;

/// Same premultiply as paint.zig's private `packPremul`, re-derived here
/// since it isn't exported — kept in sync with `chrome_style.glass` by
/// construction (always called with that same Color).
fn premulPack(c: paint.Color) u32 {
    const a: u32 = @intFromFloat(std.math.clamp(c.a, 0.0, 1.0) * 255.0 + 0.5);
    const r: u32 = @intFromFloat(std.math.clamp(c.r * c.a, 0.0, 1.0) * 255.0 + 0.5);
    const g: u32 = @intFromFloat(std.math.clamp(c.g * c.a, 0.0, 1.0) * 255.0 + 0.5);
    const b: u32 = @intFromFloat(std.math.clamp(c.b * c.a, 0.0, 1.0) * 255.0 + 0.5);
    return (a << 24) | (r << 16) | (g << 8) | b;
}

// zicro_host.zig's own `desktop` fill color (0x101826) — window_z.zig's
// blitSurface does a raw word copy with no alpha blending (no compositor
// alpha channel support yet), so drawChrome's transparent gutter/shadow
// pixels (correctly near-zero alpha) land on screen as their near-zero
// premultiplied RGB, i.e. solid black, not "see-through to the desktop
// behind". Faking that by flattening low-alpha pixels to the desktop's own
// color is the practical fix until the compositor does real alpha blending.
const desktop_bg: u32 = 0xFF10_1826;

/// One-time post-pass over drawChrome's output: every non-opaque pixel (the
/// transparent gutter, the drop shadow, the AA'd panel edge) is source-over
/// composited onto opaque `desktop_bg` — the shadow keeps its shading instead
/// of flattening to the background (the old `alpha_cut` threshold erased it:
/// peak shadow alpha ~115 < 128). Cheap (integer per-pixel blend, no SDF) —
/// folded into the one-time chrome cost, not run per keystroke.
fn fixupGutter(canvas: *paint.Canvas) void {
    const dr: u32 = (desktop_bg >> 16) & 0xff;
    const dg: u32 = (desktop_bg >> 8) & 0xff;
    const db: u32 = desktop_bg & 0xff;
    for (canvas.pixels) |*p| {
        const a = (p.* >> 24) & 0xff;
        if (a == 255) continue;
        const inv = 255 - a;
        // Premultiplied source-over with an opaque destination.
        const r: u32 = ((p.* >> 16) & 0xff) + (dr * inv + 127) / 255;
        const g: u32 = ((p.* >> 8) & 0xff) + (dg * inv + 127) / 255;
        const b: u32 = (p.* & 0xff) + (db * inv + 127) / 255;
        p.* = 0xFF00_0000 | (@as(u32, @min(r, 255)) << 16) | (@as(u32, @min(g, 255)) << 8) | @min(b, 255);
    }
}

/// Flat rectangular re-clear of the panel interior (inset by the chrome
/// margin) — deliberately NOT rounded-corner-accurate like drawChrome's own
/// SDF mask; `text_pad` keeps real content well clear of the 4 small corner
/// pixels where that would show, so the mismatch is invisible in practice.
fn clearContentArea(canvas: *paint.Canvas, content: window.Rect) void {
    const m: i32 = @intCast(chrome_style.margin);
    const x0: usize = @intCast(std.math.clamp(m, 0, content.w));
    const y0: usize = @intCast(std.math.clamp(m, 0, content.h));
    const x1: usize = @intCast(std.math.clamp(content.w - m, 0, content.w));
    const y1: usize = @intCast(std.math.clamp(content.h - m, 0, content.h));
    const core = premulPack(chrome_style.glass);
    const stride: usize = @intCast(content.w);
    var y: usize = y0;
    while (y < y1) : (y += 1) {
        @memset(canvas.pixels[y * stride + x0 .. y * stride + x1], core);
    }
}

fn onDraw(canvas: *paint.Canvas, content: window.Rect, user: ?*anyopaque) void {
    const shell: *ShellState = @ptrCast(@alignCast(user.?));

    if (chrome_w != content.w or chrome_h != content.h) {
        canvas.drawChrome(chrome_style);
        fixupGutter(canvas);
        chrome_w = content.w;
        chrome_h = content.h;
    } else {
        clearContentArea(canvas, content);
    }
    const fb = canvasFb(canvas, content.w, content.h);

    const line_h: i32 = font.GH + 2;
    var text_y: i32 = text_pad;
    for (shell.lines.items) |line| {
        font.drawText(fb, @intCast(text_pad), @intCast(text_y), line, 0xFFD7DCE6);
        text_y += line_h;
    }

    const prompt = "zicro-z> ";
    font.drawText(fb, @intCast(text_pad), @intCast(text_y), prompt, 0xFF78E6A0);
    const prompt_w: i32 = @intCast(prompt.len * font.GW);
    font.drawText(fb, @intCast(text_pad + prompt_w), @intCast(text_y), shell.input_buf.items, 0xFFFFFFFF);

    const cursor_x = text_pad + prompt_w + @as(i32, @intCast(shell.input_buf.items.len * font.GW));
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
        try shell.addLine(try shell.gpa.dupe(u8, "  btop   - Launch resource monitor"));
        try shell.addLine(try shell.gpa.dupe(u8, "  clear  - Clear history buffer"));
        try shell.addLine(try shell.gpa.dupe(u8, "  exit   - Close shell window"));
    } else if (std.mem.eql(u8, trimmed, "btop")) {
        var lo: u32 = 0;
        var hi: u32 = 0;
        asm volatile (
            "rdtsc"
            : [lo] "={eax}" (lo),
              [hi] "={edx}" (hi),
        );
        const cycles = (@as(u64, hi) << 32) | lo;
        const cycles_str = try std.fmt.allocPrint(shell.gpa, "  CPU Cycles: {d}", .{cycles});
        try shell.addLine(try shell.gpa.dupe(u8, "┌── Z-OS Monitor (btop light) ──────────┐"));
        try shell.addLine(cycles_str);
        try shell.addLine(try shell.gpa.dupe(u8, "  Active CPU: [==========          ] 50%"));
        try shell.addLine(try shell.gpa.dupe(u8, "  Tasks:      12 active (wmcomp, zicro-shell)"));
        try shell.addLine(try shell.gpa.dupe(u8, "  Total RAM:  256.0 MiB"));
        try shell.addLine(try shell.gpa.dupe(u8, "  Kernel:     12.4 MiB (5%)"));
        try shell.addLine(try shell.gpa.dupe(u8, "  Free RAM:   179.4 MiB (70%)"));
        try shell.addLine(try shell.gpa.dupe(u8, "└───────────────────────────────────────┘"));
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
