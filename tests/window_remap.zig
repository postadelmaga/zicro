//! Regression check for the window that never came back after a remap.
//!
//! `setContentSize` (and `setVisible`) remap a Wayland toplevel: a null-buffer commit
//! resets the xdg surface, and the commit after it draws a fresh `configure` at the size
//! the app asked for. That only holds while the surface is mapped. On a surface that
//! has acked its configure but has not attached its first buffer yet, the null-buffer
//! commit resets nothing, no `configure` follows, and the window stays without a buffer
//! for good: it is gone from the screen with the program still running.
//!
//! The loop runs `on_tick` before the redraw, so a tick is exactly that gap. Each mode
//! drives one sequence through it and expects the window mapped again at the end:
//!
//!   back-to-back   a second `setContentSize` right after the first one's configure
//!   hide           `setVisible(false)` in that same gap, then `setVisible(true)`
//!   spaced         the second `setContentSize` on a window already on screen (control)
//!
//! Needs a running Wayland compositor (a headless one will do), so it is not part of
//! `zig build test`. The mode is the first argument (default: back-to-back);
//! the build step runs all three:
//!
//!   zig build check-remap
//!
//! Exit status 0 when the window came back, 1 when it did not, 2 when it could not run.

const std = @import("std");
const zicro = @import("zicro");
const window = zicro.window;
const paint = zicro.paint;

const Mode = enum { @"back-to-back", hide, spaced };

/// Ticks to let the window settle before the first remap.
const settle_ticks = 15;
/// Ticks between a hide and the show that follows, and between two spaced remaps.
const gap_ticks = 10;
/// Ticks the remapped window must stay drawn before the check passes.
const hold_ticks = 10;
/// Ticks without a configure after which the window is given up for lost (3 s).
const stuck_ticks = 100;

const Phase = enum { settle, first_remap_done, hidden, expect_mapped, done };

const State = struct {
    mode: Mode,
    phase: Phase = .settle,
    ticks: u32 = 0,
    wait: u32 = 0,
    passed: bool = false,
};

fn onDraw(canvas: *paint.Canvas, c: window.Rect, _: ?*anyopaque) void {
    canvas.fillRoundedRect(@floatFromInt(c.x), @floatFromInt(c.y), @floatFromInt(c.w), @floatFromInt(c.h), 10, paint.Color.rgba(200, 60, 60, 1.0));
}

/// The remap finished and a buffer went out for it: the window is on screen.
fn onScreen(win: *window.Window) bool {
    if (!win.configured) return false;
    return if (@hasField(window.Window, "mapped")) win.mapped else true;
}

fn onTick(win: *window.Window, user: ?*anyopaque) void {
    const st: *State = @ptrCast(@alignCast(user.?));
    st.ticks += 1;
    switch (st.phase) {
        .settle => if (st.ticks >= settle_ticks and onScreen(win)) {
            win.setContentSize(500, 400);
            st.phase = .first_remap_done;
        },
        // `configured` turns true when the remap's configure is acked, and this tick runs
        // before the redraw that attaches the first buffer: the gap under test.
        .first_remap_done => if (win.configured) {
            if (st.mode == .spaced and st.wait < gap_ticks) {
                st.wait += 1;
                return;
            }
            st.wait = 0;
            if (st.mode == .hide) {
                win.setVisible(false);
                st.phase = .hidden;
            } else {
                win.setContentSize(600, 300);
                st.phase = .expect_mapped;
            }
        },
        .hidden => {
            st.wait += 1;
            if (st.wait >= gap_ticks) {
                win.setVisible(true);
                st.wait = 0;
                st.phase = .expect_mapped;
            }
        },
        .expect_mapped => {
            st.wait += 1;
            if (onScreen(win) and st.wait >= hold_ticks) {
                st.passed = true;
                st.phase = .done;
                win.requestClose();
            } else if (st.wait >= stuck_ticks) {
                st.phase = .done;
                win.requestClose();
            }
        },
        .done => {},
    }
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip(); // program name
    const mode: Mode = if (args.next()) |raw| std.meta.stringToEnum(Mode, raw) orelse {
        std.debug.print("check-remap: unknown mode '{s}' (back-to-back, hide, spaced)\n", .{raw});
        std.process.exit(2);
    } else .@"back-to-back";
    var st: State = .{ .mode = mode };
    const win = window.Window.init(init.gpa, init.io, .{
        .title = "zicro check-remap",
        .width = 400,
        .height = 300,
        .on_draw = onDraw,
        .on_tick = onTick,
        .tick_ms = 30,
        .user = &st,
    }) catch |err| {
        std.debug.print("check-remap: no window ({t}): is a Wayland compositor running?\n", .{err});
        std.process.exit(2);
    };
    defer win.deinit();
    try win.run();

    if (st.passed) {
        std.debug.print("check-remap {t}: PASS window back on screen at {d}x{d}\n", .{ mode, win.width, win.height });
        return;
    }
    if (st.phase != .done) {
        std.debug.print("check-remap {t}: the window was closed before the check finished\n", .{mode});
        std.process.exit(2);
    }
    std.debug.print("check-remap {t}: FAIL no configure after the remap, the window has no buffer\n", .{mode});
    std.process.exit(1);
}
