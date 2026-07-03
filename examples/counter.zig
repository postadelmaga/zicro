//! Minimal zicro app: `zig build run-counter`
//!
//! Shows the whole core working together — typed bus messages, an action+reducer
//! document, and two modules that never reference each other, only the channels `tick` /
//! `count`. Shutdown is first-class: `main` flips the runtime's signal, modules observe it.

const std = @import("std");
const zicro = @import("zicro");

/// Typed message on the `tick` channel.
const Tick = struct { amount: i64 };

/// Typed message on the `count` channel.
const Count = struct { value: i64 };

/// The document's actions — plain serializable data, not function objects.
const CounterAction = union(enum) { add: i64 };

fn reduce(_: ?*anyopaque, state: *i64, action: *const CounterAction) anyerror!void {
    switch (action.*) {
        .add => |n| state.* += n,
    }
}

/// Pure producer: emit a handful of increments.
const Ticker = struct {
    pub fn id(_: *Ticker) []const u8 {
        return "ticker";
    }
    pub fn run(_: *Ticker, ctx: *zicro.ModuleCtx) anyerror!void {
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            try ctx.publishMsg("tick", Tick{ .amount = 1 });
        }
    }
};

/// Owns the document; turns ticks into actions and republishes the running total.
const Store = struct {
    doc: zicro.Doc(i64, CounterAction),

    pub fn id(_: *Store) []const u8 {
        return "store";
    }
    pub fn subscriptions(_: *Store) []const []const u8 {
        return &.{"tick"};
    }
    pub fn run(self: *Store, ctx: *zicro.ModuleCtx) anyerror!void {
        defer self.doc.deinit();
        while (!ctx.shouldStop()) {
            const maybe_msg = ctx.recvTimeout(50 * std.time.ns_per_ms) catch break; // bus closed
            const msg = maybe_msg orelse continue; // timeout → re-check shouldStop
            defer msg.deinit();
            const tick = msg.env().decode(Tick, ctx.gpa) catch continue;
            defer tick.deinit();
            try self.doc.dispatch(&.{ .add = tick.value.amount });
            try ctx.publishMsg("count", Count{ .value = self.doc.state().* });
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

    var bus = zicro.LocalBus.init(gpa, io);
    defer bus.deinit();
    try bus.retain("count"); // count is durable state: late joiners get the latest value
    var rt = try zicro.Runtime.init(gpa, io, &bus);

    var counts = try bus.subscribe("count");
    defer counts.deinit();

    var store: Store = .{ .doc = .init(gpa, 0, reduce) };
    try rt.spawn(zicro.Module.of(Store, &store));
    var ticker: Ticker = .{};
    try rt.spawn(zicro.Module.of(Ticker, &ticker));

    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout.interface;

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const msg = try counts.recv();
        defer msg.deinit();
        const count = try msg.env().decode(Count, gpa);
        defer count.deinit();
        try w.print("count = {d}\n", .{count.value.value});
    }

    rt.shutdown();
    var report = rt.join();
    defer report.deinit();
    try w.print("done (clean: {}).\n", .{report.isClean()});
    try w.flush();
}
