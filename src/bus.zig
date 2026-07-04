//! # zicro.bus — the in-process pub/sub broker
//!
//! [`LocalBus`] routes purely **by channel name**. A subscriber names the channels it
//! wants; a publisher names the channel it emits on. The broker fans each envelope out to
//! every subscriber of its channel.
//!
//! ## Backpressure (bounded; per-channel overflow policy)
//! Each subscriber inbox is a **bounded** queue (default [`default_capacity`]). What
//! happens when an inbox fills is a **per-channel** choice, set with
//! [`LocalBus.setOverflow`]:
//!
//! * `.drop` (the default) — real-time-friendly: publishing never blocks the broker on a
//!   slow consumer. A full inbox has the envelope **dropped for that subscriber** and
//!   counted in [`LocalBus.dropped`]. Explicit, observable loss under overload — never a
//!   silent stall.
//! * `.block` — true (source-slowing) backpressure: a full inbox makes the publisher
//!   **block** until space frees up, so a fast producer is paced by its slowest consumer
//!   and nothing is lost. Blocking is per-publish, not per-subscriber: within one publish
//!   every subscriber with room receives immediately, even while the publisher waits on a
//!   full one (no head-of-line blocking between subscribers).
//!
//! ## Retained channels (the generic "replay state")
//! A channel marked stateful with [`LocalBus.retain`] keeps its **last** envelope and
//! replays it to any *new* subscriber, so a module that joins late immediately learns the
//! current value. Unmarked channels are transient events — nothing is replayed.
//!
//! Port note (Rust → Zig): Rust's `Arc<Envelope>`-per-subscriber clone becomes an explicit
//! reference count — [`Msg`] is a handle onto one shared envelope; call `Msg.deinit` when
//! done with it. Rust's RAII receiver drop becomes an explicit `Receiver.deinit`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const sync = @import("sync.zig");
const protocol = @import("protocol.zig");
const pool_mod = @import("pool.zig");
const SlabPool = pool_mod.SlabPool;

// The envelope and the subscriber inbox live in their own files (this broker only routes);
// see [`message`](message.zig) and [`inbox`](inbox.zig).
const message = @import("message.zig");
const inbox_mod = @import("inbox.zig");
const Shared = message.Shared;
const SpaceSignal = inbox_mod.SpaceSignal;
const Inbox = inbox_mod.Inbox;

/// A received-envelope handle onto one shared allocation — see [`message.Msg`].
pub const Msg = message.Msg;
/// The consumer handle handed out by every `subscribe*` — see [`inbox.Receiver`].
pub const Receiver = inbox_mod.Receiver;

pub const Envelope = protocol.Envelope;
pub const Channel = protocol.Channel;
pub const ModuleId = protocol.ModuleId;

/// Default bounded inbox depth per subscriber.
pub const default_capacity: usize = 1024;

/// What [`LocalBus.publish`] does when a subscriber's bounded inbox is full.
pub const Overflow = enum {
    /// Drop the envelope for that subscriber and count it in [`LocalBus.dropped`]. Never
    /// blocks — the default, so a slow consumer can never stall the producer.
    drop,
    /// Block the publisher until the inbox has room. True backpressure: nothing is
    /// dropped, the producer is paced by the consumer. Never counted in `dropped`.
    block,
};

pub const BusError = inbox_mod.BusError;

/// A point-in-time snapshot of one channel's traffic, from [`LocalBus.channelMetrics`].
pub const ChannelMetrics = struct {
    /// Envelopes published on the channel (counted once per publish, not per subscriber).
    published: u64 = 0,
    /// Envelopes dropped on the channel because some subscriber's inbox was full.
    dropped: u64 = 0,
    /// Live subscribers on the channel right now.
    subscribers: usize = 0,
};

// --- the broker ---------------------------------------------------------------------------

const SubList = std.ArrayListUnmanaged(*Inbox);

/// In-process pub/sub broker. Share a `*LocalBus` freely across threads; all methods take
/// `*LocalBus` and lock internally.
pub const LocalBus = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    /// channel name → the live subscriber inboxes on it. Keys owned.
    subs: std.StringHashMapUnmanaged(SubList) = .empty,
    /// channel name → its last envelope, for channels marked stateful. Keys owned.
    retained: std.StringHashMapUnmanaged(*Shared) = .empty,
    /// channels whose last value is kept and replayed to new subscribers. Keys owned.
    stateful: std.StringHashMapUnmanaged(void) = .empty,
    /// channel name → its overflow policy. Absent ⇒ `.drop`. Keys owned.
    overflow: std.StringHashMapUnmanaged(Overflow) = .empty,
    /// channel name → (published, dropped) counters. Keys owned.
    counters: std.StringHashMapUnmanaged(struct { published: u64, dropped: u64 }) = .empty,
    /// total envelopes dropped because a subscriber inbox was full (observability).
    dropped_total: u64 = 0,
    /// The shared "space freed" eventcount `.block` publishers wait on. Created with the
    /// first inbox (init cannot allocate); every inbox holds a reference.
    space: ?*SpaceSignal = null,
    /// The envelope slab recycler. Created lazily on first publish (init cannot
    /// allocate); every in-flight envelope holds a reference.
    envelope_pool: std.atomic.Value(?*SlabPool) = .init(null),

    pub fn init(gpa: Allocator, io: Io) LocalBus {
        return .{ .gpa = gpa, .io = io };
    }

    /// Notify all inboxes (wake blocked receivers) without closing them, e.g. during shutdown.
    /// Modules that check [`ModuleCtx.shouldStop`] will wake and can exit gracefully.
    pub fn notifyAllInboxes(bus: *LocalBus) void {
        sync.lock(&bus.mutex, bus.io);
        defer sync.unlock(&bus.mutex, bus.io);
        var subs_it = bus.subs.iterator();
        while (subs_it.next()) |entry| {
            for (entry.value_ptr.items) |inbox| {
                inbox.changed.notifyAll(bus.io);
            }
        }
    }

    pub fn deinit(bus: *LocalBus) void {
        sync.lock(&bus.mutex, bus.io);
        var subs_it = bus.subs.iterator();
        while (subs_it.next()) |entry| {
            for (entry.value_ptr.items) |inbox| {
                inbox.markClosed(bus.io);
                inbox.release(bus.io);
            }
            entry.value_ptr.deinit(bus.gpa);
            bus.gpa.free(entry.key_ptr.*);
        }
        bus.subs.deinit(bus.gpa);
        var ret_it = bus.retained.iterator();
        while (ret_it.next()) |entry| {
            entry.value_ptr.*.release();
            bus.gpa.free(entry.key_ptr.*);
        }
        bus.retained.deinit(bus.gpa);
        var st_it = bus.stateful.keyIterator();
        while (st_it.next()) |key| bus.gpa.free(key.*);
        bus.stateful.deinit(bus.gpa);
        var ov_it = bus.overflow.keyIterator();
        while (ov_it.next()) |key| bus.gpa.free(key.*);
        bus.overflow.deinit(bus.gpa);
        var ct_it = bus.counters.keyIterator();
        while (ct_it.next()) |key| bus.gpa.free(key.*);
        bus.counters.deinit(bus.gpa);
        sync.unlock(&bus.mutex, bus.io);
        if (bus.space) |sp| sp.release();
        if (bus.envelope_pool.load(.acquire)) |pool| pool.release();
    }

    /// Pre-fill the envelope pool for messages of about `envelope_bytes`
    /// (`from.len + channel.len + payload.len`) so that even the first burst of traffic
    /// allocates nothing — call at init time in latency-critical apps. `count` should
    /// cover the in-flight peak: roughly the subscriber inbox capacity per subscriber.
    pub fn prewarmEnvelopes(bus: *LocalBus, envelope_bytes: usize, count: usize) Allocator.Error!void {
        const pool = try bus.getPool();
        try pool.prewarm(@sizeOf(Shared) + envelope_bytes, count);
    }

    /// The slab pool, created on first use (double-checked under the broker lock; the
    /// steady-state cost is one acquire-load).
    fn getPool(bus: *LocalBus) Allocator.Error!*SlabPool {
        if (bus.envelope_pool.load(.acquire)) |pool| return pool;
        sync.lock(&bus.mutex, bus.io);
        defer sync.unlock(&bus.mutex, bus.io);
        if (bus.envelope_pool.load(.acquire)) |pool| return pool;
        const pool = try SlabPool.create(bus.gpa);
        bus.envelope_pool.store(pool, .release);
        return pool;
    }

    /// Mark a channel as stateful: its last published envelope is kept and replayed to any
    /// subscriber that joins afterwards. Call before publishing for the value to be retained.
    pub fn retain(bus: *LocalBus, channel: Channel) Allocator.Error!void {
        sync.lock(&bus.mutex, bus.io);
        defer sync.unlock(&bus.mutex, bus.io);
        const gop = try bus.stateful.getOrPut(bus.gpa, channel);
        if (!gop.found_existing) {
            gop.key_ptr.* = try bus.gpa.dupe(u8, channel);
        }
    }

    /// Choose what publishing does when a subscriber of `channel` has a full inbox.
    /// Mirrors [`retain`](LocalBus.retain): a channel-level setting, `.drop` until changed.
    pub fn setOverflow(bus: *LocalBus, channel: Channel, policy: Overflow) Allocator.Error!void {
        sync.lock(&bus.mutex, bus.io);
        defer sync.unlock(&bus.mutex, bus.io);
        const gop = try bus.overflow.getOrPut(bus.gpa, channel);
        if (!gop.found_existing) {
            gop.key_ptr.* = try bus.gpa.dupe(u8, channel);
        }
        gop.value_ptr.* = policy;
    }

    /// Total number of envelopes dropped so far due to full subscriber inboxes.
    pub fn dropped(bus: *LocalBus) u64 {
        sync.lock(&bus.mutex, bus.io);
        defer sync.unlock(&bus.mutex, bus.io);
        return bus.dropped_total;
    }

    /// A snapshot of one channel's traffic (published, dropped, live subscribers). Cheap
    /// and non-disturbing — poll it from a status line or metrics exporter.
    pub fn channelMetrics(bus: *LocalBus, channel: Channel) ChannelMetrics {
        sync.lock(&bus.mutex, bus.io);
        defer sync.unlock(&bus.mutex, bus.io);
        var m: ChannelMetrics = .{};
        if (bus.counters.get(channel)) |c| {
            m.published = c.published;
            m.dropped = c.dropped;
        }
        if (bus.subs.get(channel)) |list| m.subscribers = list.items.len;
        return m;
    }

    /// Publish a JSON payload from `from` onto `channel`, fanning out to every current
    /// subscriber. On a stateful channel the envelope also becomes the retained value
    /// handed to future subscribers.
    ///
    /// Fan-out depends on the channel's [`Overflow`] policy:
    /// * `.drop` (default) — never blocks: a full inbox has this envelope dropped (and
    ///   counted); a gone receiver is pruned. Runs under the broker lock.
    /// * `.block` — blocks the publisher until **every** inbox has room, but with no
    ///   head-of-line blocking between subscribers: each round sweeps every still-pending
    ///   inbox with a non-blocking push (fast consumers receive immediately, even while a
    ///   slow one is full), then sleeps on the bus-wide space signal until some ring frees
    ///   a slot. The publisher is paced by the slowest consumer; nothing is lost. (The
    ///   Rust original pushes to each subscriber sequentially — this is a deliberate
    ///   improvement, delivery order per subscriber is unchanged.)
    ///   The sweep MUST NOT run while the broker lock is held (a stalled publisher would
    ///   freeze every other publish/subscribe — including the consumer that would drain
    ///   it: deadlock). So the target inboxes are snapshotted under the lock, the lock is
    ///   released, and the sweep runs with no lock held.
    pub fn publish(bus: *LocalBus, from: ModuleId, channel: Channel, payload: []const u8) BusError!void {
        const shared = try Shared.create(try bus.getPool(), from, channel, payload);
        defer shared.release(); // the publisher's own reference

        var space: ?*SpaceSignal = null;
        // Stack space for the `.block` snapshot: only fan-outs beyond ~48 subscribers
        // touch the allocator, keeping the common publish path allocation-free (the list
        // over-reserves on first growth, so leave generous headroom).
        var sfa = std.heap.stackFallback(64 * @sizeOf(*Inbox), bus.gpa);
        const scratch = sfa.get();
        var blocking_targets: SubList = .empty;
        defer {
            // Normally emptied by the sweep; on an error path this releases the snapshot.
            for (blocking_targets.items) |inbox| inbox.release(bus.io);
            blocking_targets.deinit(scratch);
        }

        {
            sync.lock(&bus.mutex, bus.io);
            defer sync.unlock(&bus.mutex, bus.io);

            const counter = bus.counters.getOrPut(bus.gpa, channel) catch |e| return e;
            if (!counter.found_existing) {
                counter.key_ptr.* = bus.gpa.dupe(u8, channel) catch |e| return e;
                counter.value_ptr.* = .{ .published = 0, .dropped = 0 };
            }
            counter.value_ptr.published += 1;

            if (bus.stateful.contains(channel)) {
                const gop = bus.retained.getOrPut(bus.gpa, channel) catch |e| return e;
                if (gop.found_existing) {
                    gop.value_ptr.*.release();
                } else {
                    gop.key_ptr.* = bus.gpa.dupe(u8, channel) catch |e| return e;
                }
                gop.value_ptr.* = shared.retain();
            }

            const policy = bus.overflow.get(channel) orelse .drop;
            if (bus.subs.getPtr(channel)) |list| switch (policy) {
                .drop => {
                    var drops: u64 = 0;
                    var i: usize = 0;
                    while (i < list.items.len) {
                        switch (list.items[i].tryPush(bus.io, shared)) {
                            .ok => i += 1,
                            // Full: drop for this subscriber, keep it subscribed.
                            .full => {
                                drops += 1;
                                i += 1;
                            },
                            // Receiver gone: prune (swap-remove; sub order is unspecified).
                            .gone => {
                                list.swapRemove(i).release(bus.io);
                            },
                        }
                    }
                    bus.dropped_total += drops;
                    counter.value_ptr.dropped += drops;
                },
                // Snapshot the live inboxes (with a reference each, so a concurrent
                // receiver deinit can't free them under us); pushes happen lock-free below.
                .block => {
                    for (list.items) |inbox| {
                        blocking_targets.append(scratch, inbox.retain()) catch |e| return e;
                    }
                    space = bus.space; // non-null: subscribers exist, so an inbox was created
                },
            };
        }

        // The `.block` fan-out: no broker lock held — this is the backpressure. Sweep
        // rounds of non-blocking pushes over the pending inboxes; a gone receiver is
        // simply skipped (not a drop). The snapshot is taken *before* each sweep, so a
        // pop that lands mid-sweep moves the epoch and the wait returns immediately —
        // no missed wakeup.
        while (blocking_targets.items.len > 0) {
            const snapshot = space.?.signal.prepare();
            var progressed = false;
            var i: usize = 0;
            while (i < blocking_targets.items.len) {
                switch (blocking_targets.items[i].tryPush(bus.io, shared)) {
                    .ok, .gone => {
                        blocking_targets.swapRemove(i).release(bus.io);
                        progressed = true;
                    },
                    .full => i += 1,
                }
            }
            if (!progressed and blocking_targets.items.len > 0) {
                space.?.signal.waitSpin(bus.io, snapshot);
            }
        }

        // Prune any .gone inboxes from the original subs lists that accumulated during the
        // lock-free sweep; they were removed from the snapshot but linger in bus.subs.
        sync.lock(&bus.mutex, bus.io);
        defer sync.unlock(&bus.mutex, bus.io);
        var subs_it = bus.subs.iterator();
        while (subs_it.next()) |entry| {
            var i: usize = 0;
            while (i < entry.value_ptr.items.len) {
                if (entry.value_ptr.items[i].receiver_gone) {
                    entry.value_ptr.swapRemove(i).release(bus.io);
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Publish a **typed** message on `channel` (serialized to the payload). Preferred over
    /// raw [`publish`](LocalBus.publish): the contract is a real Zig type, not hand-built JSON.
    pub fn publishMsg(bus: *LocalBus, from: ModuleId, channel: Channel, msg: anytype) BusError!void {
        const payload = try protocol.encodePayload(bus.gpa, msg);
        defer bus.gpa.free(payload);
        return bus.publish(from, channel, payload);
    }

    /// Subscribe to a single channel with the default inbox depth.
    pub fn subscribe(bus: *LocalBus, channel: Channel) Allocator.Error!Receiver {
        return bus.subscribeInner(&.{channel}, default_capacity);
    }

    /// Subscribe to a single channel with an explicit inbox depth — raise it for a
    /// consumer that must not drop events under bursts.
    pub fn subscribeWithCapacity(bus: *LocalBus, channel: Channel, capacity: usize) Allocator.Error!Receiver {
        return bus.subscribeInner(&.{channel}, capacity);
    }

    /// Subscribe to several channels through **one** merged inbox: envelopes from any of
    /// the named channels arrive on the same receiver, in send order.
    pub fn subscribeMany(bus: *LocalBus, channels: []const Channel) Allocator.Error!Receiver {
        return bus.subscribeInner(channels, default_capacity);
    }

    fn subscribeInner(bus: *LocalBus, channels: []const Channel, capacity: usize) Allocator.Error!Receiver {
        sync.lock(&bus.mutex, bus.io);
        defer sync.unlock(&bus.mutex, bus.io);
        if (bus.space == null) bus.space = try SpaceSignal.create(bus.gpa);
        // Start with just the receiver's reference; each *successful* channel append adds
        // one. If a mid-loop OOM aborts the subscription, the errdefers below detach the
        // inbox from the channels already wired and drop every reference — no orphaned
        // inbox (which would otherwise leak its ring, its SpaceSignal ref, and any retained
        // values already pushed into it).
        const inbox = try Inbox.create(bus.gpa, capacity, 1, bus.space.?);
        errdefer inbox.release(bus.io);
        var appended: usize = 0;
        errdefer {
            for (channels[0..appended]) |channel| {
                if (bus.subs.getPtr(channel)) |list| {
                    for (list.items, 0..) |it, i| {
                        if (it == inbox) {
                            _ = list.orderedRemove(i);
                            break;
                        }
                    }
                }
                inbox.release(bus.io);
            }
        }
        for (channels) |channel| {
            // Hand the joiner the current value of a stateful channel right away.
            if (bus.retained.get(channel)) |shared| {
                _ = inbox.tryPush(bus.io, shared);
            }
            const gop = try bus.subs.getOrPut(bus.gpa, channel);
            if (!gop.found_existing) {
                gop.key_ptr.* = try bus.gpa.dupe(u8, channel);
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.append(bus.gpa, inbox);
            _ = inbox.retain();
            appended += 1;
        }
        return .{ .inbox = inbox, .io = bus.io };
    }
};

// --- tests ---------------------------------------------------------------------------------

const TestEnv = struct {
    threaded: std.Io.Threaded,
    bus: LocalBus,

    fn init() TestEnv {
        return .{ .threaded = .init(std.testing.allocator, .{}), .bus = undefined };
    }
};

fn publishN(bus: *LocalBus, from: []const u8, channel: []const u8, n: i64) !void {
    var buf: [64]u8 = undefined;
    const payload = try std.fmt.bufPrint(&buf, "{{\"n\":{d}}}", .{n});
    try bus.publish(from, channel, payload);
}

fn expectN(msg: Msg, n: i64) !void {
    defer msg.deinit();
    const parsed = try msg.env().decode(struct { n: i64 }, std.testing.allocator);
    defer parsed.deinit();
    try std.testing.expectEqual(n, parsed.value.n);
}

test "delivers only to subscribers of the channel" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var bus = LocalBus.init(std.testing.allocator, threaded.io());
    defer bus.deinit();

    var tick = try bus.subscribe("tick");
    defer tick.deinit();
    var other = try bus.subscribe("count");
    defer other.deinit();

    try publishN(&bus, "a", "tick", 1);

    const got = try tick.recv();
    try std.testing.expectEqualStrings("tick", got.env().channel);
    try expectN(got, 1);
    try std.testing.expectEqual(null, try tick.tryRecv());
    try std.testing.expectEqual(null, try other.tryRecv());
}

test "retained channel replays last value to late subscriber" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var bus = LocalBus.init(std.testing.allocator, threaded.io());
    defer bus.deinit();

    try bus.retain("count");
    try publishN(&bus, "store", "count", 41);
    try publishN(&bus, "store", "count", 42);

    var late = try bus.subscribe("count");
    defer late.deinit();
    try expectN(try late.recv(), 42);
    try std.testing.expectEqual(null, try late.tryRecv());
}

test "unretained channel does not replay" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var bus = LocalBus.init(std.testing.allocator, threaded.io());
    defer bus.deinit();

    try publishN(&bus, "a", "tick", 1);
    var late = try bus.subscribe("tick");
    defer late.deinit();
    try std.testing.expectEqual(null, try late.tryRecv());
}

test "merged inbox receives from all named channels" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var bus = LocalBus.init(std.testing.allocator, threaded.io());
    defer bus.deinit();

    var rx = try bus.subscribeMany(&.{ "tick", "control" });
    defer rx.deinit();
    try publishN(&bus, "a", "tick", 1);
    try publishN(&bus, "a", "control", 9);

    const first = try rx.recv();
    defer first.deinit();
    const second = try rx.recv();
    defer second.deinit();
    const on_tick = std.mem.eql(u8, first.env().channel, "tick") or
        std.mem.eql(u8, second.env().channel, "tick");
    const on_control = std.mem.eql(u8, first.env().channel, "control") or
        std.mem.eql(u8, second.env().channel, "control");
    try std.testing.expect(on_tick and on_control);
}

test "dropped subscriber is pruned on publish" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var bus = LocalBus.init(std.testing.allocator, threaded.io());
    defer bus.deinit();

    var rx = try bus.subscribe("tick");
    rx.deinit();
    try publishN(&bus, "a", "tick", 1);
    try std.testing.expectEqual(@as(usize, 0), bus.channelMetrics("tick").subscribers);
}

test "full inbox drops and counts without blocking" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var bus = LocalBus.init(std.testing.allocator, threaded.io());
    defer bus.deinit();

    // Capacity 2, never drained: the 3rd+ publishes are dropped, not blocked.
    var rx = try bus.subscribeWithCapacity("tick", 2);
    defer rx.deinit();
    var i: i64 = 0;
    while (i < 5) : (i += 1) try publishN(&bus, "a", "tick", i);

    try std.testing.expectEqual(@as(u64, 3), bus.dropped());
    // The two that fit are still there.
    (try rx.recv()).deinit();
    (try rx.recv()).deinit();
    try std.testing.expectEqual(null, try rx.tryRecv());
}

test "block policy paces producer and loses nothing" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var bus = LocalBus.init(std.testing.allocator, io);
    defer bus.deinit();

    try bus.setOverflow("tick", .block);
    // Tiny inbox: with capacity 1 a fast producer must block on a slow consumer.
    var rx = try bus.subscribeWithCapacity("tick", 1);
    defer rx.deinit();

    const Drain = struct {
        fn run(receiver: *Receiver, drain_io: Io, got: *[5]i64) void {
            sync.sleepNs(drain_io, 20 * std.time.ns_per_ms);
            for (got) |*slot| {
                const msg = receiver.recv() catch unreachable;
                defer msg.deinit();
                const parsed = msg.env().decode(struct { n: i64 }, std.testing.allocator) catch unreachable;
                defer parsed.deinit();
                slot.* = parsed.value.n;
            }
        }
    };

    var got: [5]i64 = undefined;
    // Drain on a second thread *after* a delay, so the blocked producer can make progress
    // and the test can never hang.
    const drain = try std.Thread.spawn(.{}, Drain.run, .{ &rx, io, &got });

    var i: i64 = 0;
    while (i < 5) : (i += 1) try publishN(&bus, "a", "tick", i);

    drain.join();
    // Every message arrived, in order, and nothing was dropped.
    try std.testing.expectEqualSlices(i64, &.{ 0, 1, 2, 3, 4 }, &got);
    try std.testing.expectEqual(@as(u64, 0), bus.dropped());
}

test "block policy does not head-of-line block across subscribers" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var bus = LocalBus.init(std.testing.allocator, io);
    defer bus.deinit();

    try bus.setOverflow("tick", .block);
    var fast = try bus.subscribeWithCapacity("tick", 8);
    defer fast.deinit();
    // Capacity 1 and not drained until the end: full from the first publish on.
    var slow = try bus.subscribeWithCapacity("tick", 1);
    defer slow.deinit();

    const Producer = struct {
        fn run(b: *LocalBus, finished: *std.atomic.Value(bool)) void {
            publishN(b, "a", "tick", 0) catch unreachable;
            publishN(b, "a", "tick", 1) catch unreachable; // blocks: slow is full
            finished.store(true, .release);
        }
    };
    var finished = std.atomic.Value(bool).init(false);
    const producer = try std.Thread.spawn(.{}, Producer.run, .{ &bus, &finished });

    // The fast subscriber receives *both* messages while the publisher is still blocked
    // pushing the second one into the full slow inbox — no head-of-line blocking.
    try expectN((try fast.recvTimeout(2 * std.time.ns_per_s)) orelse return error.Timeout, 0);
    try expectN((try fast.recvTimeout(2 * std.time.ns_per_s)) orelse return error.Timeout, 1);
    try std.testing.expect(!finished.load(.acquire));

    // Drain the slow inbox: the blocked publish completes, in order, nothing dropped.
    try expectN(try slow.recv(), 0);
    try expectN(try slow.recv(), 1);
    producer.join();
    try std.testing.expect(finished.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), bus.dropped());
}

test "metrics report published dropped and subscribers per channel" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var bus = LocalBus.init(std.testing.allocator, threaded.io());
    defer bus.deinit();

    var rx = try bus.subscribeWithCapacity("tick", 2);
    defer rx.deinit();
    var i: i64 = 0;
    while (i < 5) : (i += 1) try publishN(&bus, "a", "tick", i);

    var rx2 = try bus.subscribe("count");
    defer rx2.deinit();
    try publishN(&bus, "a", "count", 1);

    const tick = bus.channelMetrics("tick");
    try std.testing.expectEqual(@as(u64, 5), tick.published);
    try std.testing.expectEqual(@as(u64, 3), tick.dropped);
    try std.testing.expectEqual(@as(usize, 1), tick.subscribers);

    const count = bus.channelMetrics("count");
    try std.testing.expectEqual(@as(u64, 1), count.published);
    try std.testing.expectEqual(@as(u64, 0), count.dropped);
    try std.testing.expectEqual(@as(usize, 1), count.subscribers);

    try std.testing.expectEqual(@as(u64, 3), bus.dropped());
}

test "message survives bus teardown via pool refcounting" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var bus = LocalBus.init(std.testing.allocator, threaded.io());

    var rx = try bus.subscribe("tick");
    try publishN(&bus, "a", "tick", 5);
    const msg = try rx.recv();
    rx.deinit();
    bus.deinit(); // the bus (and its pool reference) go away first

    // The envelope is still alive and readable; its release recycles into the pool,
    // whose last reference then tears the pool down. The testing allocator verifies
    // that nothing leaks and nothing is freed twice.
    try std.testing.expectEqualStrings("tick", msg.env().channel);
    try expectN(msg, 5);
}

test "recvTimeout returns null then value" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var bus = LocalBus.init(std.testing.allocator, threaded.io());
    defer bus.deinit();

    var rx = try bus.subscribe("tick");
    defer rx.deinit();
    try std.testing.expectEqual(null, try rx.recvTimeout(10 * std.time.ns_per_ms));
    try publishN(&bus, "a", "tick", 7);
    const got = (try rx.recvTimeout(10 * std.time.ns_per_ms)).?;
    try expectN(got, 7);
}
