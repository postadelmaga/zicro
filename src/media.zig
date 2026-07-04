//! # zicro.media — the zero-copy data plane
//!
//! zicro has two planes. The **control plane** is the JSON bus: actions, state, events —
//! small messages that are fine to serialize. The **data plane** is this file:
//! high-bandwidth payloads (video frames, audio blocks) that must *never* be serialized.
//! A 1080p RGBA frame is ~8 MB; pushing 60 of those per second through JSON is a
//! non-starter. So media moves here instead, by **ownership** — the buffers are
//! reference-counted ([`Rc`]), so a "send" is a pointer move, not a copy.
//!
//! The two planes cooperate: a producer sends the pixels on a media channel and publishes
//! a tiny "frame ready" control message on the bus; a sink subscribes to the control
//! channel and pulls the actual frame from its media receiver. The bus never sees bytes.
//!
//! ## Two channel shapes, by real-time intent
//! * [`latest`] — a **single-slot, latest-wins** SPSC mailbox. A new send overwrites an
//!   unread value (the stale frame is dropped). This is what a **video** sink wants:
//!   always render the freshest frame, never accumulate latency behind a slow consumer.
//! * [`bounded`] — a **bounded, lossless** queue with backpressure (a full queue blocks
//!   the producer). This is what an **audio** path wants: every sample block must be
//!   delivered in order; pacing the producer is correct, dropping is not.
//!
//! ## Lock-free by construction
//! Both shapes run on pure atomics — no mutex anywhere on the data plane:
//! * [`latest`] is a **triple buffer**: three cells, one atomic word holding the "middle"
//!   cell index plus a fresh bit. A send is one store + one atomic swap; a receive is one
//!   atomic swap. Both sides are **wait-free** — neither ever loops or blocks on the
//!   other, so a real-time producer can never be stalled by a slow consumer (it
//!   overwrites) and a render loop can never be stalled by the producer.
//! * [`bounded`] is a **Lamport SPSC ring with cached indices** (à la Rigtorp): the
//!   producer and consumer each own one atomic counter on separate cache lines and cache
//!   the other's position, so in steady state a push/pop is a store + a release bump with
//!   no shared-line ping-pong. `tryRecv`/`send`-with-room are wait-free; the *blocking*
//!   variants sleep on waiter-gated signals — a pipeline that keeps up never issues a
//!   futex syscall.
//!
//! Port note (Rust → Zig): `Arc<[u8]>` becomes [`Rc`] with explicit `retain`/`release`;
//! RAII sender/receiver drops become explicit `deinit` calls. If the element type has a
//! `deinit()` method it is called for values dropped inside a channel (a coalesced stale
//! frame, leftovers at teardown). One behavioural nuance of going lock-free: if a send
//! races the receiver's `deinit`, the value may land in the channel and be deinited at
//! teardown instead of being handed back with `error.Disconnected` — never leaked, but
//! not always recoverable by the caller.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const sync = @import("sync.zig");

pub const types = @import("media_types.zig");
pub const PixelFormat = types.PixelFormat;
pub const Frame = types.Frame;
pub const AudioBlock = types.AudioBlock;

/// An atomically reference-counted immutable slice — the port of `Arc<[T]>`. Defined in
/// [`rc`](rc.zig) and re-exported here (both the data plane and the payload types share it
/// without importing each other); see there for the semantics.
pub const Rc = @import("rc.zig").Rc;

fn maybeDeinit(comptime T: type, value: *T) void {
    if (comptime std.meta.hasFn(T, "deinit")) value.deinit();
}

// --- latest-wins single-slot mailbox (video) -------------------------------------------

/// Create a **latest-wins** channel: a one-slot mailbox where a new send overwrites any
/// value the consumer hasn't taken yet. Single-producer, single-consumer. Both halves
/// must be `deinit`ed.
pub fn latest(comptime T: type, gpa: Allocator, io: Io) Allocator.Error!struct { LatestSender(T), LatestReceiver(T) } {
    const inner = try gpa.create(LatestInner(T));
    inner.* = .{ .gpa = gpa, .io = io };
    return .{ .{ .inner = inner }, .{ .inner = inner } };
}

/// The wait-free triple buffer behind [`latest`]. One atomic word (`mid`) carries the
/// index of the "middle" cell plus a **fresh** bit. The writer owns `back`, the reader
/// owns `front`; the three indices are always a permutation of {0, 1, 2}:
///
/// * send: write the value into `cells[back]`, swap `mid ← back | fresh`; the old middle
///   becomes the new back. If the old middle was still fresh, its value was never read —
///   drop it (latest-wins, on the writer's thread).
/// * receive: if `mid` has the fresh bit, swap `mid ← front`; the old middle becomes the
///   new front and holds the freshest value.
///
/// Only the writer sets the fresh bit and only the reader clears it, so an observed-fresh
/// middle can't go stale between the reader's load and swap. Both operations are a
/// constant two atomics: **wait-free** for both sides.
fn LatestInner(comptime T: type) type {
    return struct {
        const fresh_bit: u8 = 4;

        gpa: Allocator,
        io: Io,
        refs: std.atomic.Value(usize) = .init(2),
        changed: sync.Signal = .{},
        sender_alive: std.atomic.Value(bool) = .init(true),
        receiver_alive: std.atomic.Value(bool) = .init(true),
        cells: [3]?T = .{ null, null, null },
        /// Middle cell index | fresh bit — the only word both sides contend on.
        mid: std.atomic.Value(u8) align(std.atomic.cache_line) = .init(1),
        /// Writer-owned back cell index, on its own cache line.
        back: u8 align(std.atomic.cache_line) = 0,
        /// Reader-owned front cell index, on its own cache line.
        front: u8 align(std.atomic.cache_line) = 2,

        /// Reader side: take the middle value iff it is fresh. Wait-free.
        fn takeFresh(inner: *@This()) ?T {
            if (inner.mid.load(.acquire) & fresh_bit == 0) return null;
            const old = inner.mid.swap(inner.front, .acq_rel);
            inner.front = old & 3;
            const v = inner.cells[inner.front].?; // fresh ⇒ occupied
            inner.cells[inner.front] = null;
            return v;
        }

        fn release(inner: *@This()) void {
            if (inner.refs.fetchSub(1, .acq_rel) == 1) {
                for (&inner.cells) |*cell| {
                    if (cell.*) |*v| maybeDeinit(T, v);
                }
                inner.gpa.destroy(inner);
            }
        }
    };
}

/// The producing half of a [`latest`] channel.
pub fn LatestSender(comptime T: type) type {
    return struct {
        inner: *LatestInner(T),

        /// Put `value` in the slot, dropping whatever unread value was there
        /// (latest-wins). Wakes a waiting receiver. **Wait-free** — one store, one atomic
        /// swap. `error.Disconnected` if the receiver is gone — the caller still owns
        /// `value` and can recover it instead of losing it.
        pub fn send(self: @This(), value: T) error{Disconnected}!void {
            const inner = self.inner;
            const fresh_bit = LatestInner(T).fresh_bit;
            if (!inner.receiver_alive.load(.acquire)) return error.Disconnected;
            inner.cells[inner.back] = value;
            const old = inner.mid.swap(inner.back | fresh_bit, .acq_rel);
            inner.back = old & 3;
            if (old & fresh_bit != 0) {
                // The reader never took this one: latest-wins drop, on the writer's thread.
                if (inner.cells[inner.back]) |*stale| {
                    maybeDeinit(T, stale);
                    inner.cells[inner.back] = null;
                }
            }
            inner.changed.notifyAll(inner.io);
        }

        /// Close the producing side; a receiver blocked in `recv` observes the close.
        pub fn deinit(self: @This()) void {
            const inner = self.inner;
            inner.sender_alive.store(false, .release);
            inner.changed.notifyAll(inner.io);
            inner.release();
        }
    };
}

/// The consuming half of a [`latest`] channel.
pub fn LatestReceiver(comptime T: type) type {
    return struct {
        inner: *LatestInner(T),

        /// Block until a value is available, returning `null` once the sender is gone
        /// *and* the slot is empty. The taking itself is wait-free; blocking happens only
        /// when there is nothing to take.
        pub fn recv(self: @This()) ?T {
            const inner = self.inner;
            while (true) {
                const snapshot = inner.changed.prepare();
                if (inner.takeFresh()) |v| return v;
                if (!inner.sender_alive.load(.acquire)) {
                    return inner.takeFresh(); // a final send may have raced the close
                }
                inner.changed.waitSpin(inner.io, snapshot);
            }
        }

        /// Take the current value without blocking (wait-free): a value if one was
        /// waiting, `null` if the slot is empty but the sender is alive,
        /// `error.Disconnected` if the channel is closed and empty.
        pub fn tryRecv(self: @This()) error{Disconnected}!?T {
            const inner = self.inner;
            if (inner.takeFresh()) |v| return v;
            if (inner.sender_alive.load(.acquire)) return null;
            if (inner.takeFresh()) |v| return v; // a final send may have raced the close
            return error.Disconnected;
        }

        /// Close the consuming side; further sends report `error.Disconnected`.
        pub fn deinit(self: @This()) void {
            const inner = self.inner;
            inner.receiver_alive.store(false, .release);
            inner.changed.notifyAll(inner.io);
            inner.release();
        }
    };
}

// --- bounded lossless queue (audio) ------------------------------------------------------

/// Create a **bounded, lossless** channel with backpressure: a full queue blocks the
/// producer until the consumer drains it, so nothing is dropped and order is preserved.
/// This is the audio-path shape (every sample block must arrive). Both halves must be
/// `deinit`ed.
pub fn bounded(comptime T: type, gpa: Allocator, io: Io, capacity: usize) Allocator.Error!struct { BoundedSender(T), BoundedReceiver(T) } {
    const cap = @max(capacity, 1);
    // Slots rounded to a power of two for mask indexing; `capacity` stays exact — the
    // free-running counters enforce it, the extra slots are simply never all in use.
    const slots = std.math.ceilPowerOfTwo(usize, cap) catch return error.OutOfMemory;
    const inner = try gpa.create(BoundedInner(T));
    errdefer gpa.destroy(inner);
    const ring = try gpa.alloc(T, slots);
    inner.* = .{ .gpa = gpa, .io = io, .ring = ring, .capacity = cap, .mask = slots - 1 };
    return .{ .{ .inner = inner }, .{ .inner = inner } };
}

/// The lock-free SPSC ring behind [`bounded`] — a Lamport queue with cached indices (the
/// Rigtorp layout). `tail` is written only by the producer, `head` only by the consumer;
/// each lives on its own cache line next to that side's *cached* copy of the other index.
/// Occupancy comes from the free-running counters (`tail -% head`), so `capacity` is
/// enforced exactly and no ring slot is wasted. In steady state a push or pop re-reads
/// the far index only when its cached copy says full/empty — one release store, no
/// shared-line ping-pong, **wait-free** on both sides.
fn BoundedInner(comptime T: type) type {
    return struct {
        gpa: Allocator,
        io: Io,
        refs: std.atomic.Value(usize) = .init(2),
        ring: []T,
        capacity: usize,
        mask: usize,
        sender_alive: std.atomic.Value(bool) = .init(true),
        receiver_alive: std.atomic.Value(bool) = .init(true),
        /// Signals a push (wakes a blocked reader) / a pop (wakes a blocked writer).
        /// Waiter-gated: a pipeline that keeps up never pays a syscall.
        not_empty: sync.Signal = .{},
        not_full: sync.Signal = .{},
        /// Producer cache line: its own counter + its view of the consumer's.
        tail: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
        cached_head: usize = 0,
        /// Consumer cache line: its own counter + its view of the producer's.
        head: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
        cached_tail: usize = 0,

        /// Producer side. Wait-free; `false` when the queue is at capacity.
        fn tryPushRaw(inner: *@This(), value: T) bool {
            const tail = inner.tail.load(.monotonic); // producer-owned
            if (tail -% inner.cached_head == inner.capacity) {
                inner.cached_head = inner.head.load(.acquire);
                if (tail -% inner.cached_head == inner.capacity) return false;
            }
            inner.ring[tail & inner.mask] = value;
            inner.tail.store(tail +% 1, .release);
            inner.not_empty.notifyAll(inner.io);
            return true;
        }

        /// Consumer side. Wait-free; `null` when the queue is empty.
        fn tryPopRaw(inner: *@This()) ?T {
            const head = inner.head.load(.monotonic); // consumer-owned
            if (inner.cached_tail == head) {
                inner.cached_tail = inner.tail.load(.acquire);
                if (inner.cached_tail == head) return null;
            }
            const v = inner.ring[head & inner.mask];
            inner.head.store(head +% 1, .release);
            // The producer blocks only on a *full* queue — wake it at the half-drained
            // mark (hysteresis) so it refills in bursts of capacity/2 instead of paying
            // one futex round trip per item. The occupancy view uses the consumer's
            // cached tail; every drained window bottoms out at 0, so a blocked producer
            // can never be stranded by a stale cache.
            const view = inner.cached_tail -% (head +% 1);
            if (view == inner.capacity / 2 or view == 0) inner.not_full.notifyAll(inner.io);
            return v;
        }

        fn release(inner: *@This()) void {
            if (inner.refs.fetchSub(1, .acq_rel) == 1) {
                // Last holder: exclusive access, drain what was never received.
                const tail = inner.tail.load(.monotonic);
                var head = inner.head.load(.monotonic);
                while (head != tail) : (head +%= 1) {
                    maybeDeinit(T, &inner.ring[head & inner.mask]);
                }
                inner.gpa.free(inner.ring);
                inner.gpa.destroy(inner);
            }
        }
    };
}

/// The producing half of a [`bounded`] channel.
pub fn BoundedSender(comptime T: type) type {
    return struct {
        inner: *BoundedInner(T),

        /// Append `value`, blocking while the queue is full — this is the backpressure.
        /// With room available the push is wait-free. `error.Disconnected` if the
        /// receiver is gone (the caller still owns `value`).
        pub fn send(self: @This(), value: T) error{Disconnected}!void {
            const inner = self.inner;
            while (true) {
                if (!inner.receiver_alive.load(.acquire)) return error.Disconnected;
                const snapshot = inner.not_full.prepare();
                if (inner.tryPushRaw(value)) return;
                if (!inner.receiver_alive.load(.acquire)) return error.Disconnected;
                inner.not_full.waitSpin(inner.io, snapshot);
            }
        }

        pub fn deinit(self: @This()) void {
            const inner = self.inner;
            inner.sender_alive.store(false, .release);
            inner.not_empty.notifyAll(inner.io);
            inner.release();
        }
    };
}

/// The consuming half of a [`bounded`] channel.
pub fn BoundedReceiver(comptime T: type) type {
    return struct {
        inner: *BoundedInner(T),

        /// Block until the next value; `error.Disconnected` once the sender is gone and
        /// the queue is drained. With data waiting the pop is wait-free.
        pub fn recv(self: @This()) error{Disconnected}!T {
            const inner = self.inner;
            while (true) {
                const snapshot = inner.not_empty.prepare();
                if (inner.tryPopRaw()) |v| return v;
                if (!inner.sender_alive.load(.acquire)) {
                    if (inner.tryPopRaw()) |v| return v; // a final send raced the close
                    return error.Disconnected;
                }
                inner.not_empty.waitSpin(inner.io, snapshot);
            }
        }

        /// Non-blocking poll (wait-free): `null` when nothing is ready.
        pub fn tryRecv(self: @This()) error{Disconnected}!?T {
            const inner = self.inner;
            if (inner.tryPopRaw()) |v| return v;
            if (inner.sender_alive.load(.acquire)) return null;
            if (inner.tryPopRaw()) |v| return v; // a final send raced the close
            return error.Disconnected;
        }

        /// Block for at most `timeout_ns`; `null` on timeout.
        pub fn recvTimeout(self: @This(), timeout_ns: u64) error{Disconnected}!?T {
            const inner = self.inner;
            const deadline = sync.deadlineAfterNs(inner.io, timeout_ns);
            while (true) {
                const snapshot = inner.not_empty.prepare();
                if (inner.tryPopRaw()) |v| return v;
                if (!inner.sender_alive.load(.acquire)) {
                    if (inner.tryPopRaw()) |v| return v;
                    return error.Disconnected;
                }
                if (sync.expired(inner.io, deadline)) return null;
                inner.not_empty.waitTimeout(inner.io, snapshot, .{ .deadline = deadline });
            }
        }

        pub fn deinit(self: @This()) void {
            const inner = self.inner;
            inner.receiver_alive.store(false, .release);
            inner.not_full.notifyAll(inner.io);
            inner.release();
        }
    };
}

// --- tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "latest overwrites unread value" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const tx, const rx = try latest(i32, testing.allocator, threaded.io());
    defer tx.deinit();
    defer rx.deinit();

    try tx.send(1);
    try tx.send(2);
    try tx.send(3); // 1 and 2 are dropped: only the freshest survives
    try testing.expectEqual(@as(?i32, 3), try rx.tryRecv());
    try testing.expectEqual(@as(?i32, null), try rx.tryRecv());
}

test "latest recv blocks until sent then reports close" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const tx, const rx = try latest(i32, testing.allocator, io);
    defer rx.deinit();

    const Producer = struct {
        fn run(sender: LatestSender(i32), producer_io: Io) void {
            sync.sleepNs(producer_io, 20 * std.time.ns_per_ms);
            sender.send(42) catch unreachable;
            sender.deinit(); // sender dropped here → channel closes
        }
    };
    const h = try std.Thread.spawn(.{}, Producer.run, .{ tx, io });
    try testing.expectEqual(@as(?i32, 42), rx.recv());
    try testing.expectEqual(@as(?i32, null), rx.recv()); // sender gone, slot empty
    h.join();
}

test "latest send reports disconnect when receiver gone" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const tx, const rx = try latest(i32, testing.allocator, threaded.io());
    defer tx.deinit();
    rx.deinit();
    try testing.expectError(error.Disconnected, tx.send(7)); // recovered, not lost
}

test "bounded SPSC stress preserves order under load" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const count = 100_000;
    const tx, const rx = try bounded(u64, testing.allocator, io, 64);
    defer rx.deinit();

    const Producer = struct {
        fn run(sender: BoundedSender(u64)) void {
            var i: u64 = 0;
            while (i < count) : (i += 1) sender.send(i) catch unreachable;
            sender.deinit();
        }
    };
    const producer = try std.Thread.spawn(.{}, Producer.run, .{tx});
    var expected: u64 = 0;
    while (expected < count) : (expected += 1) {
        try testing.expectEqual(expected, try rx.recv());
    }
    try testing.expectError(error.Disconnected, rx.recv());
    producer.join();
}

test "latest stress yields strictly fresher values and never loses the last" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const count = 50_000;
    const tx, const rx = try latest(u64, testing.allocator, io);
    defer rx.deinit();

    const Producer = struct {
        fn run(sender: LatestSender(u64)) void {
            var i: u64 = 0;
            while (i < count) : (i += 1) sender.send(i) catch unreachable;
            sender.deinit();
        }
    };
    const producer = try std.Thread.spawn(.{}, Producer.run, .{tx});
    var last: ?u64 = null;
    while (rx.recv()) |v| {
        // Latest-wins: values may be skipped but must never go backwards.
        if (last) |prev| try testing.expect(v > prev);
        last = v;
    }
    // The final value survives the close — a sink always sees the freshest state.
    try testing.expectEqual(@as(?u64, count - 1), last);
    producer.join();
}

test "bounded preserves every value in order" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Capacity 1 forces the producer to be paced.
    const tx, const rx = try bounded(i32, testing.allocator, io, 1);
    defer rx.deinit();

    const Producer = struct {
        fn run(sender: BoundedSender(i32)) void {
            var i: i32 = 0;
            while (i < 5) : (i += 1) sender.send(i) catch unreachable;
            sender.deinit();
        }
    };
    const producer = try std.Thread.spawn(.{}, Producer.run, .{tx});
    sync.sleepNs(io, 10 * std.time.ns_per_ms); // let the producer block on the full queue
    var got: [5]i32 = undefined;
    for (&got) |*slot| slot.* = try rx.recv();
    try testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3, 4 }, &got); // nothing dropped, order kept
    producer.join();
}
