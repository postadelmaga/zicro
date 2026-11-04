//! `zig build run-runtime` — the tray demo, driven by `zrame.EventLoop` instead of a
//! hand-rolled poll loop.
//!
//! Compare `examples/tray.zig`: there the app grabs `t.fd()`, builds a `pollfd`, calls
//! `poll`, then `t.process()` — and if it later wanted a context menu or a second bus it
//! would have to rewrite that loop. Here it just registers the tray as a source and calls
//! `run()`. Adding more is one `rt.addServer(&menu)` / `rt.add(mySource)` call — the loop
//! never changes.

const std = @import("std");
const zrame = @import("zrame");

fn onActivate(_: ?*anyopaque) void {
    std.debug.print("tray: activated\n", .{});
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    const t = zrame.tray.Tray.init(gpa, .{
        .id = "dev.zrame.runtime-demo",
        .title = "zrame runtime demo",
        .icon_name = "applications-graphics",
        .tooltip = "zrame — unified event loop",
        .on_activate = onActivate,
    }) catch |err| {
        std.debug.print("tray unavailable: {s}\n", .{@errorName(err)});
        return;
    };
    defer t.deinit();

    var rt = try zrame.EventLoop.init(gpa);
    defer rt.deinit();
    try rt.addTray(t);

    std.debug.print("tray registered (pid {d}). Ctrl-C to quit.\n", .{std.os.linux.getpid()});
    try rt.run(); // one loop for every registered source; Ctrl-C to quit
}
