//! zicro bench — the performance contract, in numbers.
//!
//! Measures the two planes end to end: control-plane latency (publish→recv round trip,
//! blocking and busy-spin), control-plane throughput (lossless `.block` fan-out),
//! allocator calls in steady state (the zero-allocation claim), and the media plane
//! (latest-wins freshness + conflation, bounded SPSC throughput).
//!
//! Run with `zig build bench` (always ReleaseFast). `--quick` divides the iteration
//! counts by 10 — the CI setting; local full runs are the authoritative numbers.

const std = @import("std");
const zicro = @import("zicro");
const LocalBus = zicro.LocalBus;
const media = zicro.media;
const Io = std.Io;

// --- timing ---------------------------------------------------------------------------

/// Monotonic nanoseconds since bench start, comparable across threads (same clock).
const Stopwatch = struct {
    io: Io,
    base: i96,

    fn init(io: Io) Stopwatch {
        return .{ .io = io, .base = Io.Timestamp.now(io, .awake).nanoseconds };
    }

    fn ns(w: *const Stopwatch) u64 {
        return @intCast(Io.Timestamp.now(w.io, .awake).nanoseconds - w.base);
    }
};

const Stats = struct { p50: u64, p99: u64, p999: u64, max: u64 };

fn percentiles(samples: []u64) Stats {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const n = samples.len;
    return .{
        .p50 = samples[n / 2],
        .p99 = samples[(n * 99) / 100],
        .p999 = samples[(n * 999) / 1000],
        .max = samples[n - 1],
    };
}

fn us(nanos: u64) f64 {
    return @as(f64, @floatFromInt(nanos)) / std.time.ns_per_us;
}

fn printLatency(name: []const u8, s: Stats) void {
    std.debug.print(
        "{s:<38} p50 {d:>8.2} µs   p99 {d:>8.2} µs   p999 {d:>8.2} µs   max {d:>9.2} µs\n",
        .{ name, us(s.p50), us(s.p99), us(s.p999), us(s.max) },
    );
}

fn mps(count: u64, elapsed_ns: u64) f64 {
    return @as(f64, @floatFromInt(count)) * std.time.ns_per_s /
        @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
}

// --- allocation counting ----------------------------------------------------------------

/// Pass-through allocator that counts every alloc/remap request — how the steady-state
/// zero-allocation claim is verified rather than asserted.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    calls: std.atomic.Value(u64) = .init(0),

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
        return self.child.vtable.alloc(self.child.ptr, len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
        return self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, memory, alignment, ra);
    }
};

// --- bus latency (ping-pong RTT) ----------------------------------------------------------

fn busLatency(gpa: std.mem.Allocator, io: Io, watch: *const Stopwatch, iters: u32) !Stats {
    var bus = LocalBus.init(gpa, io);
    defer bus.deinit();

    var pong = try bus.subscribe("pong");
    defer pong.deinit();

    const Echo = struct {
        fn run(b: *LocalBus, n: u32) void {
            var ping = b.subscribe("ping") catch unreachable;
            defer ping.deinit();
            b.publish("echo", "pong", "ready") catch unreachable;
            for (0..n) |_| {
                const msg = ping.recv() catch return;
                msg.deinit();
                b.publish("echo", "pong", "x") catch return;
            }
        }
    };
    const echo = try std.Thread.spawn(.{}, Echo.run, .{ &bus, iters });
    (try pong.recv()).deinit(); // echo is subscribed and ready

    const samples = try gpa.alloc(u64, iters);
    defer gpa.free(samples);
    for (samples) |*sample| {
        const t0 = watch.ns();
        try bus.publish("main", "ping", "x");
        const msg = try pong.recv();
        msg.deinit();
        sample.* = watch.ns() - t0;
    }
    echo.join();
    return percentiles(samples);
}

// --- bus throughput (lossless fan-out) ------------------------------------------------------

fn busThroughput(gpa: std.mem.Allocator, io: Io, watch: *const Stopwatch, iters: u32, consumers: u32) !f64 {
    var bus = LocalBus.init(gpa, io);
    defer bus.deinit();
    try bus.setOverflow("data", .block);

    const Drain = struct {
        fn run(b: *LocalBus, n: u32) void {
            var rx = b.subscribeWithCapacity("data", 1024) catch unreachable;
            defer rx.deinit();
            b.publish("drain", "ready", "up") catch unreachable;
            for (0..n) |_| {
                const msg = rx.recv() catch return;
                msg.deinit();
            }
        }
    };

    var ready = try bus.subscribe("ready");
    defer ready.deinit();
    const threads = try gpa.alloc(std.Thread, consumers);
    defer gpa.free(threads);
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, Drain.run, .{ &bus, iters });
    for (0..consumers) |_| (try ready.recv()).deinit();

    const payload = "0123456789abcdef" ** 4; // 64 bytes, a typical control message
    const t0 = watch.ns();
    for (0..iters) |_| try bus.publish("main", "data", payload);
    for (threads) |t| t.join();
    return mps(iters, watch.ns() - t0);
}

// --- steady-state allocations ---------------------------------------------------------------

fn busAllocsInRegime(io: Io, iters: u32) !u64 {
    var counting: CountingAllocator = .{ .child = std.heap.smp_allocator };
    var bus = LocalBus.init(counting.allocator(), io);
    defer bus.deinit();
    try bus.setOverflow("data", .block);
    // RT init-time hygiene: cover the in-flight peak (the 1024-deep inbox) up front.
    try bus.prewarmEnvelopes(128, 1100);

    const Drain = struct {
        fn run(b: *LocalBus, n: u32) void {
            var rx = b.subscribeWithCapacity("data", 1024) catch unreachable;
            defer rx.deinit();
            b.publish("drain", "ready", "up") catch unreachable;
            for (0..n) |_| {
                const msg = rx.recv() catch return;
                msg.deinit();
            }
        }
    };
    var ready = try bus.subscribe("ready");
    defer ready.deinit();
    const warmup: u32 = 10_000;
    const drain = try std.Thread.spawn(.{}, Drain.run, .{ &bus, warmup + iters });
    (try ready.recv()).deinit();

    const payload = "0123456789abcdef" ** 4;
    for (0..warmup) |_| try bus.publish("main", "data", payload); // warm the slab rings
    const before = counting.calls.load(.monotonic);
    for (0..iters) |_| try bus.publish("main", "data", payload);
    const after = counting.calls.load(.monotonic);
    drain.join();
    return after - before;
}

// --- media plane ------------------------------------------------------------------------------

const LatestResult = struct { stats: Stats, sends_per_s: f64, conflation: f64 };

fn mediaLatest(gpa: std.mem.Allocator, io: Io, watch: *const Stopwatch, iters: u32) !LatestResult {
    const tx, const rx = try media.latest(u64, gpa, io);
    defer rx.deinit();

    const Producer = struct {
        fn run(sender: media.LatestSender(u64), w: *const Stopwatch, n: u32, elapsed: *u64) void {
            const t0 = w.ns();
            for (0..n) |_| sender.send(w.ns()) catch break;
            elapsed.* = w.ns() - t0;
            sender.deinit();
        }
    };
    var send_elapsed: u64 = 0;
    const producer = try std.Thread.spawn(.{}, Producer.run, .{ tx, watch, iters, &send_elapsed });

    const samples = try gpa.alloc(u64, iters);
    defer gpa.free(samples);
    var received: usize = 0;
    while (rx.recv()) |sent_at| {
        samples[received] = watch.ns() - sent_at;
        received += 1;
    }
    producer.join();
    return .{
        .stats = percentiles(samples[0..received]),
        .sends_per_s = mps(iters, send_elapsed),
        .conflation = @as(f64, @floatFromInt(iters)) / @as(f64, @floatFromInt(@max(received, 1))),
    };
}

fn mediaBounded(gpa: std.mem.Allocator, io: Io, watch: *const Stopwatch, iters: u32) !f64 {
    const tx, const rx = try media.bounded(u64, gpa, io, 256);
    defer rx.deinit();

    const Producer = struct {
        fn run(sender: media.BoundedSender(u64), n: u32) void {
            for (0..n) |i| sender.send(i) catch break;
            sender.deinit();
        }
    };
    const t0 = watch.ns();
    const producer = try std.Thread.spawn(.{}, Producer.run, .{ tx, iters });
    for (0..iters) |_| _ = try rx.recv();
    const elapsed = watch.ns() - t0;
    producer.join();
    return mps(iters, elapsed);
}

// --- main -------------------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const watch = Stopwatch.init(io);

    var quick = false;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip(); // program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--quick")) quick = true;
    }
    const div: u32 = if (quick) 10 else 1;
    const lat_iters = 100_000 / div;
    const thr_iters = 1_000_000 / div;

    const cpus = std.Thread.getCpuCount() catch 1;
    std.debug.print(
        "zicro bench — ReleaseFast, {d} cpus{s}\n\n",
        .{ cpus, if (quick) " (--quick)" else "" },
    );

    printLatency("bus  ping-pong RTT (blocking recv)", try busLatency(gpa, io, &watch, lat_iters));

    const t1 = try busThroughput(gpa, io, &watch, thr_iters, 1);
    std.debug.print("{s:<38} {d:>7.2} M msg/s\n", .{ "bus  throughput 1P\u{2192}1C (.block)", t1 });
    const t4 = try busThroughput(gpa, io, &watch, thr_iters, 4);
    std.debug.print(
        "{s:<38} {d:>7.2} M msg/s ({d:.2} M delivered/s)\n",
        .{ "bus  throughput 1P\u{2192}4C (.block)", t4, t4 * 4 },
    );

    const allocs = try busAllocsInRegime(io, thr_iters);
    std.debug.print(
        "{s:<38} {d} allocator calls / {d} publishes\n",
        .{ "bus  allocations in steady state", allocs, thr_iters },
    );

    const latest_result = try mediaLatest(gpa, io, &watch, thr_iters);
    printLatency("media latest freshness (one-way)", latest_result.stats);
    std.debug.print(
        "{s:<38} {d:>7.2} M send/s, conflation {d:.2}:1\n",
        .{ "media latest producer rate", latest_result.sends_per_s, latest_result.conflation },
    );

    const spsc = try mediaBounded(gpa, io, &watch, thr_iters);
    std.debug.print("{s:<38} {d:>7.2} M items/s (capacity 256)\n", .{ "media bounded SPSC throughput", spsc });
}
