//! `zig build run-tray` — a bare StatusNotifierItem tray icon (Phase 6 demo).
//!
//! No window at all: just the icon in your panel's system tray, driven straight off the
//! session bus. Left-click ("Activate") prints a line. This is the smallest possible use
//! of `zrame.tray`; a real app hangs the same item off `Window` via `Options.tray`.

const std = @import("std");
const zrame = @import("zrame");

fn onActivate(_: ?*anyopaque) void {
    std.debug.print("tray: activated\n", .{});
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    const t = zrame.tray.Tray.init(gpa, .{
        .id = "dev.zrame.tray-demo",
        .title = "zrame tray demo",
        .icon_name = "applications-graphics",
        .tooltip = "zrame — Phase 6 tray icon",
        .on_activate = onActivate,
    }) catch |err| {
        std.debug.print("tray unavailable: {s}\n", .{@errorName(err)});
        return;
    };
    defer t.deinit();

    std.debug.print("tray registered (pid {d}). Ctrl-C to quit.\n", .{std.os.linux.getpid()});

    const fd = t.fd();
    while (true) {
        t.flush();
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, -1) catch {};
        t.process();
    }
}
