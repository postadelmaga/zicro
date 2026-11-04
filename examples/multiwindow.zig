//! Several windows on ONE Wayland connection: a root, a child toplevel parented to it
//! (`initChild`, e.g. a dialog) and an anchored panel (`initSub`, a subsurface that moves
//! with the root). All three are driven by the root's `run` loop — the shape Zart's
//! multi-window backend uses. Children are created from `on_tick`, on the loop thread.
//! Esc closes the window that has the keyboard; closing the root ends the program.
//!
//! Wayland only: elsewhere it opens just the root window.

const std = @import("std");
const zicro = @import("zicro");
const window = zicro.window;
const paint = zicro.paint;

const State = struct {
    ticks: u32 = 0,
    root: ?*window.Window = null,
    child: ?*window.Window = null,
    panel: ?*window.Window = null,
};

const Tint = struct { color: paint.Color, state: *State };

fn onDraw(canvas: *paint.Canvas, content: window.Rect, user: ?*anyopaque) void {
    const tint: *Tint = @ptrCast(@alignCast(user.?));
    canvas.fillRoundedRect(
        @floatFromInt(content.x),
        @floatFromInt(content.y),
        @floatFromInt(content.w),
        @floatFromInt(content.h),
        14,
        tint.color,
    );
}

fn onKey(win: *window.Window, key: u32, state: u32, _: ?*anyopaque) void {
    if (key == 1 and state == 1) win.requestClose(); // Esc
}

fn onChildClose(win: *window.Window, user: ?*anyopaque) void {
    const tint: *Tint = @ptrCast(@alignCast(user.?));
    if (tint.state.child == win) tint.state.child = null;
    if (tint.state.panel == win) tint.state.panel = null;
}

var child_tint: Tint = undefined;
var panel_tint: Tint = undefined;

fn onTick(win: *window.Window, user: ?*anyopaque) void {
    const tint: *Tint = @ptrCast(@alignCast(user.?));
    const st = tint.state;
    st.ticks += 1;
    if (comptime !@hasDecl(window.Window, "initChild")) return;
    if (st.ticks == 2) {
        st.child = window.Window.initChild(win, .{
            .title = "zicro — child",
            .width = 320,
            .height = 200,
            .on_draw = onDraw,
            .on_key = onKey,
            .on_close = onChildClose,
            .user = &child_tint,
        }) catch null;
    }
    if (st.ticks == 3) {
        st.panel = window.Window.initSub(win, .{
            .title = "zicro — panel",
            .width = 160,
            .height = 120,
            .on_draw = onDraw,
            .on_close = onChildClose,
            .user = &panel_tint,
        }, 40, 40) catch null;
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var state: State = .{};
    var root_tint: Tint = .{ .color = paint.Color.rgba(40, 60, 90, 1.0), .state = &state };
    child_tint = .{ .color = paint.Color.rgba(150, 70, 60, 1.0), .state = &state };
    panel_tint = .{ .color = paint.Color.rgba(70, 140, 80, 1.0), .state = &state };

    const win = try window.Window.init(gpa, init.io, .{
        .title = "zicro — multiwindow",
        .width = 560,
        .height = 360,
        .on_draw = onDraw,
        .on_key = onKey,
        .on_tick = onTick,
        .tick_ms = 100,
        .user = &root_tint,
    });
    defer win.deinit();
    state.root = win;
    try win.run();
}
