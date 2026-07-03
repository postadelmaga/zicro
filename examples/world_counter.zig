//! `zig build run-world_counter`
//!
//! The `sources → world → sinks` spine in miniature, with no UI or devices:
//! * a **source** (`Ticker`) publishes a few counter actions and exits,
//! * the **world** ([`zicro.WorldModule`], wired by [`zicro.App.world`]) reduces them and
//!   republishes the counter on a retained `state` channel,
//! * a **sink** (`Printer`) renders every state it sees.
//!
//! Nothing here references anything else: the three talk only through the bus.

const std = @import("std");
const zicro = @import("zicro");

const actions_ch = "actions";
const state_ch = "state";

const CounterAction = union(enum) {
    add: i64,
    sub: i64,
};

fn reduce(_: ?*anyopaque, state: *i64, action: *const CounterAction) anyerror!void {
    switch (action.*) {
        .add => |n| state.* += n,
        .sub => |n| {
            if (state.* - n < 0) return error.WouldGoNegative;
            state.* -= n;
        },
    }
}

/// A source: emits a fixed script of actions onto the bus, then returns.
const Ticker = struct {
    pub fn id(_: *Ticker) []const u8 {
        return "ticker";
    }

    pub fn run(_: *Ticker, ctx: *zicro.ModuleCtx) anyerror!void {
        const script = [_]CounterAction{
            .{ .add = 10 },
            .{ .add = 5 },
            .{ .sub = 100 }, // rejected by the reducer → world ignores it
            .{ .sub = 3 },
        };
        for (script) |action| {
            if (ctx.shouldStop()) return;
            std.debug.print("  ticker → {t}\n", .{action});
            ctx.publishMsg(actions_ch, action) catch {};
            ctx.io.sleep(.fromMilliseconds(40), .awake) catch {};
        }
    }
};

/// A sink: prints the world's state every time it changes.
const Printer = struct {
    pub fn id(_: *Printer) []const u8 {
        return "printer";
    }

    pub fn subscriptions(_: *Printer) []const []const u8 {
        return &.{state_ch};
    }

    pub fn run(_: *Printer, ctx: *zicro.ModuleCtx) anyerror!void {
        while (!ctx.shouldStop()) {
            const maybe_msg = ctx.recvTimeout(50 * std.time.ns_per_ms) catch break;
            const msg = maybe_msg orelse continue;
            defer msg.deinit();
            const value = msg.env().decode(i64, ctx.gpa) catch continue;
            defer value.deinit();
            std.debug.print("printer ← state = {d}\n", .{value.value});
        }
    }
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try zicro.App.init(gpa, io);
    defer app.deinit();

    try app.world(i64, CounterAction, "world", actions_ch, state_ch, .init(gpa, 0, reduce));
    var printer: Printer = .{};
    try app.sink(zicro.Module.of(Printer, &printer));
    var ticker: Ticker = .{};
    try app.source(zicro.Module.of(Ticker, &ticker));

    // Let the script play out, then wind everything down cleanly.
    io.sleep(.fromMilliseconds(400), .awake) catch {};
    var report = app.shutdownAndJoin();
    defer report.deinit();
    if (!report.isClean()) {
        std.debug.print("modules failed: {d}\n", .{report.failed.len});
    }
}
