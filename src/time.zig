//! # zicro.time — Clock source and Pacer
//!
//! Two ways to get cadence into the `sources → world → sinks` spine:
//!
//! * [`Clock`] is a **source module**: it publishes a [`Tick`] on a channel at a fixed
//!   rate, so a world (or several sinks) can share one heartbeat over the bus — e.g. a
//!   simulation that steps on every tick, or a UI that repaints on it.
//! * [`Pacer`] is a **self-driven frame limiter** a sink owns: call [`Pacer.tick`] at the
//!   top of a render loop and it sleeps to hold the target rate, returning the elapsed
//!   *delta time* so the sink can advance by real time, not by assumed frames.
//!
//! The two cover the two real shapes: a *pushed* cadence shared on the bus (Clock) and a
//! *pulled* cadence local to one loop (Pacer), the latter being what a video or audio
//! sink usually wants since its rate is dictated by the display or the device, not by
//! the bus.

const std = @import("std");
const Io = std.Io;

const sync = @import("sync.zig");
const core = @import("core.zig");

/// The longest a `Clock` will sleep in one go, so it can observe shutdown promptly even
/// at very low tick rates.
const max_sleep_ns: u64 = 20 * std.time.ns_per_ms;

/// A single beat. `seq` counts from 1; `elapsed` is seconds since the clock started;
/// `dt` is seconds since the previous tick (the first tick's `dt` is the configured
/// interval).
pub const Tick = struct {
    seq: u64,
    elapsed: f64,
    dt: f64,
};

fn intervalNsFromHz(hz: f64) u64 {
    if (hz <= 0.0) return 0;
    return @intFromFloat(std.time.ns_per_s / hz);
}

/// A source module that publishes a [`Tick`] on a channel at a fixed interval. Wire it
/// like any source (`app.source(core.Module.of(Clock, &clock))`); subscribers reduce or
/// render on the beat.
pub const Clock = struct {
    id_: []const u8,
    channel: []const u8,
    interval_ns: u64,

    /// A clock ticking `rate` times per second on `channel`.
    pub fn hz(id_: []const u8, channel: []const u8, rate: f64) Clock {
        return .{ .id_ = id_, .channel = channel, .interval_ns = intervalNsFromHz(rate) };
    }

    /// A clock ticking once per `interval_ns` on `channel`.
    pub fn every(id_: []const u8, channel: []const u8, interval_ns: u64) Clock {
        return .{ .id_ = id_, .channel = channel, .interval_ns = interval_ns };
    }

    pub fn id(clock: *Clock) []const u8 {
        return clock.id_;
    }

    // A clock listens to nothing — it is a pure source (no `subscriptions`).

    pub fn run(clock: *Clock, ctx: *core.ModuleCtx) anyerror!void {
        const io = ctx.io;
        const interval = sync.durationNs(clock.interval_ns);
        const start = sync.now(io);
        var last = start;
        var next = start.addDuration(interval);
        var seq: u64 = 0;

        while (!ctx.shouldStop()) {
            const now = sync.now(io);
            if (now.compare(.gte, next)) {
                seq += 1;
                const tick: Tick = .{
                    .seq = seq,
                    .elapsed = sync.secondsBetween(start, now),
                    .dt = sync.secondsBetween(last, now),
                };
                last = now;
                ctx.publishMsg(clock.channel, tick) catch {};
                next = next.addDuration(interval);
                // If we fell behind (a slow scheduler), resync instead of bursting
                // catch-up ticks forever.
                if (next.compare(.lte, now)) {
                    next = now.addDuration(interval);
                }
            } else {
                // Sleep until the next beat, but never so long we miss shutdown.
                const until_ns: u64 = @intCast(@max(now.raw.durationTo(next.raw).nanoseconds, 0));
                sync.sleepNs(io, @min(until_ns, max_sleep_ns));
            }
        }
    }
};

/// A self-driven frame limiter for a sink's loop. Construct it with a target rate, then
/// call [`tick`](Pacer.tick) once per iteration: it sleeps to the next boundary and hands
/// back the real delta time since the previous call.
pub const Pacer = struct {
    io: Io,
    interval: Io.Clock.Duration,
    last: Io.Clock.Timestamp,
    next: Io.Clock.Timestamp,

    /// A pacer holding `rate` iterations per second.
    pub fn hz(io: Io, rate: f64) Pacer {
        return .every(io, intervalNsFromHz(rate));
    }

    /// A pacer with an explicit per-iteration interval.
    pub fn every(io: Io, interval_ns: u64) Pacer {
        const interval = sync.durationNs(interval_ns);
        const now = sync.now(io);
        return .{
            .io = io,
            .interval = interval,
            .last = now,
            .next = now.addDuration(interval),
        };
    }

    /// Sleep until the next frame boundary, then return seconds elapsed since the
    /// previous `tick` (the loop's delta time). Resyncs without burst-catch-up if a
    /// frame ran long.
    pub fn tick(pacer: *Pacer) f64 {
        const now = sync.now(pacer.io);
        if (now.compare(.lt, pacer.next)) {
            pacer.next.wait(pacer.io) catch {};
        }
        const woke = sync.now(pacer.io);
        const dt = sync.secondsBetween(pacer.last, woke);
        pacer.last = woke;
        pacer.next = pacer.next.addDuration(pacer.interval);
        if (pacer.next.compare(.lte, woke)) {
            pacer.next = woke.addDuration(pacer.interval);
        }
        return dt;
    }
};

// --- tests ---------------------------------------------------------------------------------

test "pacer holds its rate" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 200 Hz → 5 ms/iter. Ten iterations should take clearly more than the time five
    // unpaced iterations would (≈0). Lower-bound only, to stay robust on busy CI.
    var pacer = Pacer.hz(io, 200.0);
    const start = sync.now(io);
    var total_dt: f64 = 0.0;
    var i: usize = 0;
    while (i < 10) : (i += 1) total_dt += pacer.tick();
    const wall = sync.secondsBetween(start, sync.now(io));
    try std.testing.expect(wall >= 0.030);
    try std.testing.expect(total_dt >= 0.030);
}

test "pacer dt is positive" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var pacer = Pacer.hz(threaded.io(), 1000.0);
    try std.testing.expect(pacer.tick() > 0.0);
}

test "clock publishes ticks on its channel" {
    const core_ = core;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bus = core_.LocalBus.init(std.testing.allocator, io);
    defer bus.deinit();
    var rt = try core_.Runtime.init(std.testing.allocator, io, &bus);

    var rx = try bus.subscribe("tick");
    defer rx.deinit();

    var clock = Clock.hz("clock", "tick", 100.0);
    try rt.spawn(core_.Module.of(Clock, &clock));

    // Three beats, in order, with growing elapsed time.
    var last_seq: u64 = 0;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const msg = try rx.recv();
        defer msg.deinit();
        const parsed = try msg.env().decode(Tick, std.testing.allocator);
        defer parsed.deinit();
        try std.testing.expect(parsed.value.seq > last_seq);
        last_seq = parsed.value.seq;
        try std.testing.expect(parsed.value.dt >= 0.0);
    }

    rt.shutdown();
    var report = rt.join();
    defer report.deinit();
    try std.testing.expect(report.isClean());
}
