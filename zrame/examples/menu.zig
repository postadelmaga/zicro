//! `zig build run-menu`
//!
//! A glass window that publishes a **KDE global menu** (`com.canonical.dbusmenu`) over the
//! `org_kde_kwin_appmenu` Wayland protocol. On Plasma with the *Global Menu* applet (or the
//! window-decoration "app menu" button) enabled, the File / Edit / Help bar shows up there;
//! picking an entry prints a line, and File → Quit closes the window.

const std = @import("std");
const zrame = @import("zrame");

// A few panel sizes to spring between; Space cycles them, the File menu jumps to ends.
const sizes = [_][2]u32{ .{ 420, 300 }, .{ 620, 420 }, .{ 900, 600 } };

const Ctx = struct { win: ?*zrame.Window = null, idx: usize = 1 };
var ctx: Ctx = .{};

fn animateTo(c: ?*anyopaque, i: usize) void {
    const cx: *Ctx = @ptrCast(@alignCast(c.?));
    cx.idx = i;
    if (cx.win) |w| w.animateResize(sizes[i][0], sizes[i][1]);
}

fn onNew(c: ?*anyopaque) void {
    std.debug.print("menu: File -> New (grow)\n", .{});
    animateTo(c, sizes.len - 1); // spring to the largest size
}
fn onOpen(c: ?*anyopaque) void {
    std.debug.print("menu: File -> Open (shrink)\n", .{});
    animateTo(c, 0); // spring to the smallest size
}
fn onQuit(c: ?*anyopaque) void {
    std.debug.print("menu: File -> Quit\n", .{});
    const cx: *Ctx = @ptrCast(@alignCast(c.?));
    if (cx.win) |w| w.close();
}
fn onCut(_: ?*anyopaque) void {
    std.debug.print("menu: Edit -> Cut\n", .{});
}
fn onCopy(_: ?*anyopaque) void {
    std.debug.print("menu: Edit -> Copy\n", .{});
}
fn onAbout(_: ?*anyopaque) void {
    std.debug.print("menu: Help -> About\n", .{});
}

/// Space cycles through `sizes`, springing the window to each.
fn onKey(win: *zrame.Window, key: u32, state: u32, user: ?*anyopaque) void {
    if (state != 1) return; // press only
    if (key == zrame.wl.KEY_SPACE) {
        const cx: *Ctx = @ptrCast(@alignCast(user.?));
        cx.idx = (cx.idx + 1) % sizes.len;
        win.animateResize(sizes[cx.idx][0], sizes[cx.idx][1]);
        std.debug.print("space -> resize to {d}x{d}\n", .{ sizes[cx.idx][0], sizes[cx.idx][1] });
    }
}

const menu = [_]zrame.dbusmenu.Item{
    .{ .label = "File", .children = &.{
        .{ .label = "New", .on_click = onNew },
        .{ .label = "Open", .on_click = onOpen },
        .{ .separator = true },
        .{ .label = "Quit", .on_click = onQuit },
    } },
    .{ .label = "Edit", .children = &.{
        .{ .label = "Cut", .on_click = onCut },
        .{ .label = "Copy", .on_click = onCopy },
        .{ .label = "Paste", .enabled = false }, // greyed out, no handler
    } },
    .{ .label = "Help", .children = &.{
        .{ .label = "About zrame", .on_click = onAbout },
    } },
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const win = try zrame.Window.init(gpa, .{
        .title = "zrame — Global Menu",
        .app_id = "dev.zrame.menu",
        .width = sizes[1][0],
        .height = sizes[1][1],
        .titlebar = true,
        .titlebar_style = .macos,
        .style = zrame.Style.macos(),
        .menu = &menu,
        .on_key = onKey,
        .user = @ptrCast(&ctx),
    });
    defer win.deinit();
    ctx.win = win;

    std.debug.print("global menu published. Space cycles size; File -> New/Open spring to big/small.\n", .{});
    try win.run();
}
